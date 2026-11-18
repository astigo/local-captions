import Foundation
import AVFoundation

struct MicrophoneSegment: Codable, Sendable {
    let id: UUID
    let url: URL
    let startedAt: Date
    let endedAt: Date
    var sidecar: URL { url.appendingPathExtension("json") }
}

/// Only this serial queue touches conversion and files. Long meetings use bounded
/// memory: closed 30-second chunks wait on disk, not in the live ASR audio queue.
final class MicrophoneSpool: @unchecked Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "LocalCaptions.microphone.files", qos: .utility)
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private var current: MicrophoneSegment?
    private var frameCount = 0
    private var hasSignal = false
    private var expectedNext: Date?
    private var ready: [MicrophoneSegment] = []
    private var ended = false
    private var failure: Error?
    private let segmentFrames: Int

    init(directory: URL, journal: URL? = nil, segmentSeconds: Double = 30) throws {
        self.directory = directory; segmentFrames = max(16000, Int(segmentSeconds * 16000))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let journal {
            try JSONEncoder().encode(["journal": journal]).write(to: directory.appendingPathComponent("session.json"), options: .atomic)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at capturedEnd: Date) {
        queue.async { [self] in
            guard !ended, failure == nil else { return }
            do {
                if sourceFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: target); sourceFormat = buffer.format
                }
                guard let converter, let pcm = AVAudioPCMBuffer(pcmFormat: target,
                    frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 32) else {
                    throw CaptionsError.message("Не удалось преобразовать звук микрофона")
                }
                var supplied = false, error: NSError?
                let result = converter.convert(to: pcm, error: &error) { _, status in
                    guard !supplied else { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                if let error { throw error }
                guard result != .error, let samples = pcm.floatChannelData?[0] else { return }
                let values = Array(UnsafeBufferPointer(start: samples, count: Int(pcm.frameLength)))
                try write(values, at: capturedEnd.addingTimeInterval(-Double(values.count) / 16000))
            } catch { failure = error }
        }
    }

    /// Also used by deterministic synthetic-audio integration tests.
    func append(samples: [Float], at startedAt: Date) {
        queue.async { [self] in
            guard !ended, failure == nil else { return }
            do { try write(samples, at: startedAt) } catch { failure = error }
        }
    }

    private func write(_ samples: [Float], at startedAt: Date) throws {
        if let expectedNext, abs(startedAt.timeIntervalSince(expectedNext)) > 0.5 { try seal() }
        var offset = 0
        while offset < samples.count {
            if file == nil {
                let id = UUID(), url = directory.appendingPathComponent(id.uuidString + ".caf")
                let start = startedAt.addingTimeInterval(Double(offset) / 16000)
                current = MicrophoneSegment(id: id, url: url, startedAt: start, endedAt: start)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(current!).write(to: current!.sidecar, options: .atomic)
                file = try AVAudioFile(forWriting: url, settings: target.settings)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                frameCount = 0; hasSignal = false
            }
            let count = min(samples.count - offset, segmentFrames - frameCount)
            let block = Array(samples[offset..<(offset + count)])
            let energy = block.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(count)
            hasSignal = hasSignal || energy >= 0.0000001
            let pcm = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count))!
            pcm.frameLength = pcm.frameCapacity
            block.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
            try file?.write(from: pcm)
            frameCount += count; offset += count
            if frameCount == segmentFrames { try seal() }
        }
        expectedNext = startedAt.addingTimeInterval(Double(samples.count) / 16000)
    }

    private func seal() throws {
        file = nil // Close before handing a segment to ASR.
        guard let current else { return }
        self.current = nil
        if hasSignal, frameCount > 0 {
            let segment = MicrophoneSegment(id: current.id, url: current.url, startedAt: current.startedAt,
                endedAt: current.startedAt.addingTimeInterval(Double(frameCount) / 16000))
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(segment).write(to: segment.sidecar, options: .atomic)
            ready.append(segment)
        } else {
            try FileManager.default.removeItem(at: current.url)
            try FileManager.default.removeItem(at: current.sidecar)
        }
        frameCount = 0; hasSignal = false
    }

    func next() throws -> MicrophoneSegment? {
        try queue.sync { if let failure { throw failure }; return ready.first }
    }
    var count: Int { queue.sync { ready.count } }
    func committed(_ segment: MicrophoneSegment) throws {
        try queue.sync {
            try FileManager.default.removeItem(at: segment.url)
            try FileManager.default.removeItem(at: segment.sidecar)
            ready.removeAll { $0.id == segment.id }
        }
    }
    func finish() throws {
        try queue.sync {
            ended = true
            if let failure { file = nil; throw failure }
            try seal()
        }
    }
}

@MainActor final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var installed = false
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
    func start(spool: MicrophoneSpool) throws {
        let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptionsError.message("Микрофон недоступен") }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            // AVAudioEngine reuses tap buffers; copy before leaving the real-time callback.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            for (source, destination) in zip(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList), UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)) {
                if let sourceData = source.mData, let destinationData = destination.mData {
                    memcpy(destinationData, sourceData, Int(min(source.mDataByteSize, destination.mDataByteSize)))
                }
            }
            spool.append(copy, at: Date())
        }
        installed = true
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
    }
    func stop() {
        engine.stop()
        if installed { engine.inputNode.removeTap(onBus: 0); installed = false }
    }
}

/// A background job only begins after 3 minutes without audible system output.
/// Incoming audio is checked again between chunks, so live ASR keeps priority.
actor MicrophoneTranscription {
    static let quietSeconds: TimeInterval = 180
    private let spool: MicrophoneSpool
    private let recognizer: Recognition
    private let store: CaptionStore
    private let input: LiveAudioInput
    private let status: @Sendable (String) -> Void
    private var task: Task<Void, Never>?
    private var processing = false

    init(spool: MicrophoneSpool, recognizer: Recognition, store: CaptionStore, input: LiveAudioInput,
         status: @escaping @Sendable (String) -> Void) {
        self.spool = spool; self.recognizer = recognizer; self.store = store; self.input = input; self.status = status
    }
    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processIfQuiet()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }
    func processIfQuiet(now: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        guard !processing else { return }
        do {
            if input.signalIdle(now: now) >= Self.quietSeconds, try spool.next() != nil {
                try await processNext()
            } else { status("Микрофон · отложено фрагментов: \(spool.count)") }
        } catch { status("Микрофон: \(error.localizedDescription). Аудио осталось в \(spool.directory.path)") }
    }
    private func processNext() async throws {
        guard let segment = try spool.next() else { return }
        processing = true; defer { processing = false }
        status("Расшифровываю микрофон · осталось: \(spool.count)")
        let caption = try await recognizer.transcribeMicrophone(segment)
        if let caption { try await store.addMicrophone(caption) }
        try spool.committed(segment)
    }
    func finishAndDrain() async throws {
        task?.cancel(); await task?.value; task = nil
        try spool.finish()
        while try spool.next() != nil { try await processNext() }
        status("Микрофон · текст добавлен в транскрипцию")
    }
}
