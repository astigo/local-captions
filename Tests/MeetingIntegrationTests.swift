import XCTest
@testable import LocalCaptions

final class MeetingIntegrationTests: XCTestCase {
    @MainActor func testLearningRecognizesEnglishAndRevealsCachedHyTranslation() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_MEETING_PROBE"] == "1",
              let path = ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_PROBE_RUNTIME"] else { throw XCTSkip("Opt-in learning integration") }
        let runtime = URL(fileURLWithPath: path), worker = LocalWorker()
        let store = CaptionStore(); store.begin(mode: .learning)
        let recognizer = Recognition(worker: worker, store: store, session: store.session, model: .ultra, mode: .learning, onStatus: { _ in })
        do {
            try await worker.start(runtime: runtime, script: runtime.deletingLastPathComponent().appendingPathComponent("backend/worker.py"), model: .hymt)
            try await recognizer.load(runtime: runtime)
            let samples = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("test-modes-en.aiff").path)
            for offset in stride(from: 0, to: samples.count, by: 5120) {
                try await recognizer.consume(Array(samples[offset..<min(offset + 5120, samples.count)]))
            }
            try await recognizer.finishInput()
            let caption = try XCTUnwrap(store.history.first { $0.russian?.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil })
            XCTAssertTrue(store.history.map(\.english).joined(separator: " ").localizedCaseInsensitiveContains("experiment"))
            XCTAssertTrue(store.history.allSatisfy { !store.showsTranslation(for: $0.id) })
            store.toggleTranslation(id: caption.id)
            XCTAssertTrue(store.showsTranslation(for: caption.id))
            XCTAssertTrue(store.history.filter { $0.id != caption.id }.allSatisfy { !store.showsTranslation(for: $0.id) })
        } catch {
            store.clear(); await recognizer.stop(); await worker.stop(); throw error
        }
        store.clear(); await recognizer.stop(); await worker.stop()
    }

    @MainActor func testMicrophoneWaitsForSilenceThenMergesAndDeletesOnlyCommittedAudio() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_MEETING_PROBE"] == "1",
              let path = ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_PROBE_RUNTIME"] else { throw XCTSkip("Opt-in meeting integration") }
        let runtime = URL(fileURLWithPath: path)
        let directory = runtime.appendingPathComponent("meeting-probe/\(UUID())")
        let store = CaptionStore(); store.begin(mode: .transcription)
        try store.record(to: directory, title: "Synthetic microphone", microphone: true) { _ in XCTFail("Write failure") }
        let recognizer = Recognition(worker: nil, store: store, session: store.session, model: .ultra, mode: .transcription, onStatus: { _ in })
        try await recognizer.load(runtime: runtime)
        let raw = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("test-modes-ru.aiff").path)
        let duration = ceil(Double(raw.count) / 16000)
        let padded = raw + [Float](repeating: 0, count: Int(duration * 16000) - raw.count)
        let spool = try MicrophoneSpool(directory: directory.appendingPathComponent("audio"), segmentSeconds: duration)
        let start = Date(); spool.append(samples: padded + padded, at: start)
        XCTAssertEqual(spool.count, 2)
        let input = LiveAudioInput(); input.append([0.1], now: 100)
        let background = MicrophoneTranscription(spool: spool, recognizer: recognizer, store: store, input: input, status: { _ in })
        await background.processIfQuiet(now: 279)
        XCTAssertEqual(spool.count, 2); XCTAssertTrue(store.history.isEmpty)
        let microphoneJob = Task { await background.processIfQuiet(now: 281) }
        // Both channels use the same loaded Ultra MLModels with independent decoders.
        let english = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("test-modes-en.aiff").path)
        for offset in stride(from: 0, to: english.count, by: 5120) {
            try await recognizer.consume(Array(english[offset..<min(offset + 5120, english.count)]))
        }
        try await recognizer.consume([Float](repeating: 0, count: 25600))
        await microphoneJob.value
        XCTAssertEqual(spool.count, 1)
        XCTAssertTrue(store.history.contains { $0.channel == "microphone" && $0.english.localizedCaseInsensitiveContains("результат") })
        XCTAssertTrue(store.history.contains { $0.channel != "microphone" && $0.english.localizedCaseInsensitiveContains("experiment") })
        XCTAssertTrue(store.captions.allSatisfy { $0.channel != "microphone" })
        input.append([0.1], now: 282)
        await background.processIfQuiet(now: 283)
        XCTAssertEqual(spool.count, 1, "New system audio pauses further microphone jobs")
        store.prepareToFinish()
        try await background.finishAndDrain()
        XCTAssertEqual(spool.count, 0); XCTAssertEqual(store.history.filter { $0.channel == "microphone" }.count, 2)
        store.finishJournal(); input.finish(); await recognizer.stop()
    }

    @MainActor func testHyTranslationAlongsideLiveUltraAndShutdown() async throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_MEETING_PROBE"] == "1",
              let path = ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_PROBE_RUNTIME"] else { throw XCTSkip("Opt-in meeting integration") }
        let runtime = URL(fileURLWithPath: path), worker = LocalWorker()
        try await worker.start(runtime: runtime, script: runtime.deletingLastPathComponent().appendingPathComponent("backend/worker.py"), model: .hymt)
        let store = CaptionStore(); store.begin()
        let recognizer = Recognition(worker: worker, store: store, session: store.session, model: .ultra, onStatus: { _ in })
        try await recognizer.load(runtime: runtime)
        let samples = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("test-modes-en.aiff").path)
        let origin = ProcessInfo.processInfo.systemUptime
        for offset in stride(from: 0, to: samples.count, by: 320) {
            let end = min(offset + 320, samples.count)
            let remaining = origin + Double(end) / 16000 - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            try await recognizer.consume(Array(samples[offset..<end]))
        }
        try await recognizer.finishInput()
        XCTAssertTrue(store.history.contains { $0.russian?.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil })
        XCTAssertTrue(store.history.map(\.english).joined(separator: " ").localizedCaseInsensitiveContains("experiment"))
        store.clear(); await recognizer.stop(); await worker.stop()
    }
}
