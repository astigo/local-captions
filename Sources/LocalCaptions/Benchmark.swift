import Foundation
@preconcurrency import AVFoundation
import FluidAudio

/// Runs the real offline models on a supplied test file; no system-audio permissions needed.
enum Benchmark {
    static func run(audioPath: String, runtimePath: String) async {
        do {
            let runtime = URL(fileURLWithPath: runtimePath)
            let worker = LocalWorker()
            let script = runtime.deletingLastPathComponent().appendingPathComponent("backend/worker.py")
            try await worker.start(runtime: runtime, script: script)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
            let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: source)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let converter = AVAudioConverter(from: file.processingFormat, to: format)!
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 64)!
            var supplied = false; var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true; status.pointee = .haveData; return source
            }
            let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            let store = await MainActor.run { CaptionStore() }
            await store.begin()
            let session = await store.session
            // The selected recognizer through the live pipeline; compare models by passing another `model:`.
            let pipeline = Recognition(worker: worker, store: store, session: session, model: .ultra, onStatus: { _ in })
            try await pipeline.load(runtime: URL(fileURLWithPath: runtimePath))
            let startPipeline = Date()
            for offset in stride(from: 0, to: samples.count, by: 15360) {
                let start = Date()
                try await pipeline.consume(Array(samples[offset..<min(offset + 15360, samples.count)]))
                let captions = await store.captions
                print("Window \(offset / 15360): \(Date().timeIntervalSince(start)) s · \(captions.last?.english ?? "—")")
            }
            try await pipeline.finishInput()
            let captions = await store.captions
            print("Pipeline: \(Date().timeIntervalSince(startPipeline)) s for \(Double(samples.count)/16000) s audio")
            for caption in captions { print("PAIR: \(caption.english) → \(caption.russian ?? "MISSING")") }
            await pipeline.stop()
            await worker.stop()
        } catch { print("ERROR: \(error)"); exit(1) }
    }
}
