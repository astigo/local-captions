import XCTest
import Combine
import AVFoundation
import CoreML
import FluidAudio
@testable import LocalCaptions

/// Opt-in diagnostic: feeds PCM at wall-clock speed through the unchanged app pipeline.
/// Measures CaptionStore updates, not ScreenCaptureKit, physical speaker output, or screen rendering.
final class LatencyProbeTests: XCTestCase {
    struct Input: Decodable { let id: String; let audioPath: String; let duration: Double }
    struct Point: Codable {
        let kind: String
        let captionID: UUID
        let seconds: Double
        let english: String
        let russian: String?
    }
    struct Run: Codable {
        let inputID: String
        let repetition: Int
        let audioSeconds: Double
        let startupSeconds: Double
        let maxFeedLatenessSeconds: Double
        let model: String
        let peakFootprintMB: Double
        let events: [Point]
        let statuses: [Status]
    }
    struct Status: Codable { let seconds: Double; let message: String }
    final class StatusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var origin: Double = 0
        private var points: [Status] = []
        func begin(at time: Double) { lock.lock(); defer { lock.unlock() }; origin = time }
        func record(_ message: String) {
            lock.lock(); defer { lock.unlock() }
            if origin > 0 { points.append(Status(seconds: ProcessInfo.processInfo.systemUptime - origin, message: message)) }
        }
        func snapshot() -> [Status] { lock.lock(); defer { lock.unlock() }; return points }
    }

    @MainActor func testRealtimeLatencyProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["LOCAL_CAPTIONS_PROBE_MANIFEST"], let runtimePath = env["LOCAL_CAPTIONS_PROBE_RUNTIME"] else {
            throw XCTSkip("Set LOCAL_CAPTIONS_PROBE_MANIFEST and LOCAL_CAPTIONS_PROBE_RUNTIME for the latency probe")
        }
        let manifestURL = URL(fileURLWithPath: manifest)
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: manifestURL))
        let runtime = URL(fileURLWithPath: runtimePath)
        let repetitions = Int(env["LOCAL_CAPTIONS_PROBE_REPETITIONS"] ?? "2") ?? 2
        XCTAssertTrue((1...10).contains(repetitions))
        guard (1...10).contains(repetitions) else { return }
        var runs: [Run] = []
        for input in inputs {
            let raw = try Self.readPCM(input.audioPath)
            // Feed silence in real time to flush the tail without giving the recognizer future audio.
            let samples = raw + [Float](repeating: 0, count: 30720)
            for repetition in 1...repetitions {
                let startup = ProcessInfo.processInfo.systemUptime
                let worker = LocalWorker()
                try await worker.start(runtime: runtime, script: runtime.deletingLastPathComponent().appendingPathComponent("backend/worker.py"))
                let store = CaptionStore(); store.begin()
                let statuses = StatusRecorder()
                let model = RecognitionModel(rawValue: env["LOCAL_CAPTIONS_PROBE_MODEL"] ?? "ultra") ?? .ultra
                // LOCAL_CAPTIONS_PROBE_MODE=transcription decodes without the English language hint.
                let mode = CaptionMode(rawValue: env["LOCAL_CAPTIONS_PROBE_MODE"] ?? "") ?? .translation
                let recognizer = Recognition(worker: worker, store: store, session: store.session, model: model, mode: mode, onStatus: { statuses.record($0) })
                try await recognizer.load(runtime: runtime)
                let startupSeconds = ProcessInfo.processInfo.systemUptime - startup
                var previous: [UUID: Caption] = [:], events: [Point] = []
                let origin = ProcessInfo.processInfo.systemUptime
                statuses.begin(at: origin)
                let observation = store.$history.sink { history in
                    for caption in history {
                        let old = previous[caption.id]
                        let kind: String?
                        if caption.russian != old?.russian, caption.russian != nil { kind = "translation" }
                        else if caption.finalized && old?.finalized != true { kind = "english_final" }
                        else if caption.english != old?.english { kind = "english_update" }
                        else { kind = nil }
                        if let kind {
                            events.append(Point(kind: kind, captionID: caption.id,
                                seconds: ProcessInfo.processInfo.systemUptime - origin,
                                english: caption.english, russian: caption.russian))
                        }
                        previous[caption.id] = caption
                    }
                }
                let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(200))
                let reader = Task {
                    for await block in stream { try await recognizer.consume(block) }
                    try await recognizer.finishInput()
                }
                var maxFeedLateness = 0.0, peakFootprint = ProbeMemory.footprintMB()
                for offset in stride(from: 0, to: samples.count, by: 320) {
                    let end = min(offset + 320, samples.count)
                    let deadline = origin + Double(end) / 16000
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    maxFeedLateness = max(maxFeedLateness, ProcessInfo.processInfo.systemUptime - deadline)
                    if case .dropped = continuation.yield(Array(samples[offset..<end])) { XCTFail("Audio queue overflow") }
                    if offset % 5120 == 0 { peakFootprint = max(peakFootprint, ProbeMemory.footprintMB()) }
                }
                continuation.finish()
                try await reader.value
                observation.cancel()
                await recognizer.stop(); await worker.stop()
                XCTAssertTrue(events.contains { $0.kind == "translation" })
                runs.append(Run(inputID: input.id, repetition: repetition, audioSeconds: input.duration,
                    startupSeconds: startupSeconds, maxFeedLatenessSeconds: maxFeedLateness,
                    model: model.rawValue, peakFootprintMB: peakFootprint,
                    events: events, statuses: statuses.snapshot()))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(runs).write(to: manifestURL.deletingLastPathComponent().appendingPathComponent("trace.json"), options: .atomic)
                print("LATENCY_PROBE \(input.id) run \(repetition): \(events.count) events, max feed lateness \(maxFeedLateness) s")
            }
        }
    }

    /// Checks in-app metrics against real recognizer timestamps: words must map to audio,
    /// and the measured display delay must be plausible next to the external probe.
    @MainActor func testInAppMetricsOnRealAudio() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifest = env["LOCAL_CAPTIONS_PROBE_MANIFEST"], let runtimePath = env["LOCAL_CAPTIONS_PROBE_RUNTIME"],
              env["LOCAL_CAPTIONS_METRICS_PROBE"] == "1" else {
            throw XCTSkip("Set LOCAL_CAPTIONS_METRICS_PROBE=1 with the probe manifest and runtime")
        }
        let input = try XCTUnwrap(try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: manifest))).first)
        let samples = try Self.readPCM(input.audioPath) + [Float](repeating: 0, count: 30720)
        let model = RecognitionModel(rawValue: env["LOCAL_CAPTIONS_PROBE_MODEL"] ?? "ultra") ?? .ultra
        let store = CaptionStore(); store.begin(mode: .learning)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "MetricsProbe-\(UUID())")!)
        settings.wordPacing = env["LOCAL_CAPTIONS_WORD_PACING"] != "0"
        let presenter = LivePresenter(store: store, settings: settings)
        let input2 = LiveAudioInput()
        let recognizer = Recognition(worker: nil, store: store, session: store.session, model: model, mode: .learning,
                                     clock: input2.clock, onStatus: { _ in })
        try await recognizer.load(runtime: URL(fileURLWithPath: runtimePath))
        let reader = Task { for await block in input2.stream { try await recognizer.consume(block) }; try await recognizer.finishInput() }
        let origin = ProcessInfo.processInfo.systemUptime
        for offset in stride(from: 0, to: samples.count, by: 320) {
            let end = min(offset + 320, samples.count)
            let remaining = origin + Double(end) / 16000 - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            input2.append(Array(samples[offset..<end]))
            presenter.update(now: ProcessInfo.processInfo.systemUptime) // the app drives this from a 30 Hz timer
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        input2.finish()
        try await reader.value
        for _ in 0..<60 { presenter.update(now: ProcessInfo.processInfo.systemUptime); try await Task.sleep(nanoseconds: 50_000_000) }
        let summary = store.metrics.summary(session: store.session, mode: .learning, model: model.title,
            ultraChunkSeconds: model == .ultra ? RecognitionTuning.ultraChunkSeconds : nil, wordPacing: settings.wordPacing, transcript: nil)
        await recognizer.stop()
        let latency = try XCTUnwrap(summary.displayLatency, "No word was matched to its audio time")
        print(String(format: "METRICS_PROBE %@ chunk=%@ pacing=%@ words=%d timed=%d p50=%.3f p90=%.3f p95=%.3f revised=%d/%d",
                     model.rawValue, String(describing: summary.ultraChunkSeconds), String(settings.wordPacing),
                     summary.finalWords, latency.count, latency.p50, latency.p90, latency.p95, summary.revisedWords, summary.shownWords))
        XCTAssertGreaterThan(Double(latency.count), Double(summary.finalWords) * 0.8, "Most words must map to an audio time")
        XCTAssertGreaterThan(latency.p50, 0.05); XCTAssertLessThan(latency.p95, 3)
    }

    /// Quality comparison only: same ASR on a whole clip, without language gating or phrase resets.
    /// This is deliberately run separately, so it cannot compete with the real-time latency probe.
    func testWholeClipQualityProbe() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCAL_CAPTIONS_PROBE_BATCH"] == "1",
              let path = env["LOCAL_CAPTIONS_PROBE_MANIFEST"],
              let runtimePath = env["LOCAL_CAPTIONS_PROBE_RUNTIME"] else {
            throw XCTSkip("Set LOCAL_CAPTIONS_PROBE_BATCH=1 and probe paths for the whole-clip comparison")
        }
        let manifestURL = URL(fileURLWithPath: path)
        let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: manifestURL))
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
        let choice = RecognitionModel(rawValue: env["LOCAL_CAPTIONS_PROBE_MODEL"] ?? "ultra") ?? .ultra
        let runtime = URL(fileURLWithPath: runtimePath)
        let models = try AsrModels.loadLocal(from: choice.directory(in: runtime), version: .ultra, configuration: configuration)
        let ultra = AsrManager(); try await ultra.loadModels(models)
        struct BatchResult: Codable { let inputID: String; let english: String; let inferenceSeconds: Double }
        var results: [BatchResult] = []
        for input in inputs {
            let samples = try Self.readPCM(input.audioPath)
            let start = ProcessInfo.processInfo.systemUptime
            var state = TdtDecoderState.make(decoderLayers: AsrModelVersion.ultra.decoderLayers)
            let rawText = try await ultra.transcribe(samples, decoderState: &state, language: .english).text
            let text = rawText.replacingOccurrences(of: "<EOU>", with: "")
                .replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(BatchResult(inputID: input.id, english: text,
                inferenceSeconds: ProcessInfo.processInfo.systemUptime - start))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(results).write(to: manifestURL.deletingLastPathComponent().appendingPathComponent("batch.json"), options: .atomic)
            print("BATCH_PROBE \(input.id): \(text)")
        }
        XCTAssertEqual(results.count, inputs.count)
        XCTAssertTrue(results.allSatisfy { !$0.english.isEmpty })
        await ultra.cleanup()
    }

    static func readPCM(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: source.format, to: target)!
        let result = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / source.format.sampleRate) + 64)!
        var supplied = false, error: NSError?
        converter.convert(to: result, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true; status.pointee = .haveData; return source
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
    }
}
