import XCTest
import Darwin
@testable import LocalCaptions

enum ProbeMemory {
    /// Current Swift test process only; the separate translator process is excluded.
    static func footprintMB() -> Double {
        snapshot().footprint
    }
    static func snapshot() -> (footprint: Double, resident: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS
            ? (Double(info.phys_footprint) / 1_048_576, Double(info.resident_size) / 1_048_576)
            : (-1, -1)
    }
}

final class ModelSwitchTests: XCTestCase {
    @MainActor func testBothModelsTranslateRepeatedShortUtterancesAfterPauses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCAL_CAPTIONS_MEMORY_PROBE"] == "1", let path = env["LOCAL_CAPTIONS_PROBE_RUNTIME"] else {
            throw XCTSkip("Opt-in model integration probe")
        }
        let runtime = URL(fileURLWithPath: path)
        let worker = LocalWorker()
        try await worker.start(runtime: runtime, script: runtime.deletingLastPathComponent().appendingPathComponent("backend/worker.py"))
        let raw = try LatencyProbeTests.readPCM(runtime.appendingPathComponent("accent-benchmark/clips/us-jennifer-ai.wav").path)
        for choice in RecognitionModel.allCases {
            let store = CaptionStore(); store.begin()
            let recognizer = Recognition(worker: worker, store: store, session: store.session, model: choice, onStatus: { _ in })
            try await recognizer.load(runtime: runtime)
            for _ in 0..<2 {
                let before = store.history.filter { $0.russian != nil }.count
                for offset in stride(from: 0, to: 80000, by: 5120) {
                    try await recognizer.consume(Array(raw[offset..<min(offset + 5120, 80000)]))
                }
                try await recognizer.consume([Float](repeating: 0, count: 25600))
                for _ in 0..<40 {
                    if store.history.filter({ $0.russian != nil }).count > before { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertGreaterThan(store.history.filter { $0.russian != nil }.count, before,
                    "\(choice): pause must translate each short utterance before EOF or the next speaker")
            }
            await recognizer.stop()
        }
        await worker.stop()
    }

    @MainActor func testSequentialLoadAndUnload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LOCAL_CAPTIONS_MEMORY_PROBE"] == "1", let path = env["LOCAL_CAPTIONS_PROBE_RUNTIME"] else {
            throw XCTSkip("Opt-in model memory probe")
        }
        let runtime = URL(fileURLWithPath: path)
        let worker = LocalWorker()
        try await worker.start(runtime: runtime, script: runtime.deletingLastPathComponent().appendingPathComponent("backend/worker.py"))
        struct Sample: Codable {
            let model: String
            let beforeMB: Double; let loadedMB: Double; let stoppedMB: Double
            let beforeResidentMB: Double; let loadedResidentMB: Double; let stoppedResidentMB: Double
        }
        var samples: [Sample] = []
        // Every available recognizer, twice: memory must return after each unload.
        for choice in RecognitionModel.allCases + RecognitionModel.allCases {
            let before = ProbeMemory.snapshot()
            let store = CaptionStore(); store.begin()
            var recognizer: Recognition? = Recognition(worker: worker, store: store, session: store.session, model: choice, onStatus: { _ in })
            weak var released = recognizer
            try await recognizer!.load(runtime: runtime)
            let loaded = ProbeMemory.snapshot()
            await recognizer!.stop()
            recognizer = nil
            // Give completed tasks and framework releases a chance to run.
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertNil(released, "A stopped recognizer must not be retained by its streaming task")
            let stopped = ProbeMemory.snapshot()
            samples.append(Sample(model: choice.rawValue, beforeMB: before.footprint, loadedMB: loaded.footprint, stoppedMB: stopped.footprint,
                beforeResidentMB: before.resident, loadedResidentMB: loaded.resident, stoppedResidentMB: stopped.resident))
            print("MODEL_MEMORY \(choice.rawValue): before=\(before), loaded=\(loaded), stopped=\(stopped) MiB")
        }
        await worker.stop()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: runtime.appendingPathComponent("model-memory.json"), options: .atomic)
    }
}
