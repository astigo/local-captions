import XCTest
import AppKit
import CoreFoundation
@testable import LocalCaptions

final class ModesIntegrationTests: XCTestCase {
    @MainActor func testRussianEnglishRussianTranscriptionWithoutAWorker() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCAL_CAPTIONS_MODES_PROBE"] == "1", let path = env["LOCAL_CAPTIONS_PROBE_RUNTIME"] else {
            throw XCTSkip("Opt-in bilingual audio probe")
        }
        let runtime = URL(fileURLWithPath: path)
        let ru = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("test-modes-ru.aiff").path)
        let en = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("test-modes-en.aiff").path)
        let silence = [Float](repeating: 0, count: 25600)
        let samples = ru + silence + en + silence + ru + silence
        let directory = runtime.appendingPathComponent("modes-probe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CaptionStore(); store.begin(mode: .transcription)
        try store.record(to: directory, title: "Bilingual synthesis test", model: "Parakeet Ultra · 600M") { _ in XCTFail("Journal error") }
        // nil worker deliberately proves the transcription path needs no translator process.
        let recognizer = Recognition(worker: nil, store: store, session: store.session, model: .ultra, mode: .transcription, onStatus: { _ in })
        try await recognizer.load(runtime: runtime)
        let input = LiveAudioInput()
        let reader = Task.detached(priority: .userInitiated) {
            for await block in input.stream { try await recognizer.consume(block) }
            try await recognizer.finishInput()
        }
        let producer = Task.detached {
            let origin = ProcessInfo.processInfo.systemUptime
            // 5 ms packets: much smaller than the former 200-packet queue expected.
            for offset in stride(from: 0, to: samples.count, by: 80) {
                let end = min(offset + 80, samples.count)
                let remaining = origin + Double(end) / 16000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                guard input.append(Array(samples[offset..<end])) else { throw CaptionsError.message("Audio input overrun") }
            }
            input.finish()
        }
        // Deliberately keep the UI executor in AppKit's tracking mode for 8 seconds.
        // Both background consumption and caption delivery must continue during it.
        InteractionRegressionTests.runTracking(for: 8)
        XCTAssertFalse(store.history.isEmpty, "Captions must arrive before menu/window tracking ends")
        try await producer.value
        try await reader.value
        let text = store.history.map(\.english).joined(separator: " ")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("результат"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("данн"), text)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("experiment"), text)
        XCTAssertTrue(store.history.allSatisfy { $0.russian == nil && $0.finalized })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(store.history).write(to: directory.appendingPathComponent("captions.json"), options: .atomic)
        store.clear(); await recognizer.stop()
        print("BILINGUAL_PROBE \(Double(samples.count) / 16000) s: \(text)")
    }
}
