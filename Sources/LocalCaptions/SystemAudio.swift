import Foundation
import AVFoundation
import CoreAudio

/// A private, unmuted global process tap. Requires system-audio permission only;
/// never enumerates displays/windows or changes the user's default audio device.
final class SystemAudio: @unchecked Sendable {
    private let control = DispatchQueue(label: "LocalCaptions.audio.lifecycle", qos: .userInitiated)
    private let queue = DispatchQueue(label: "LocalCaptions.audio", qos: .userInitiated)
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var formatListener: AudioObjectPropertyListenerBlock?
    var onAudio: (@Sendable ([Float]) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    func start() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            control.async { [self] in
                do { try createCapture(); continuation.resume() }
                catch { destroyCapture(); continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            control.async { [self] in destroyCapture(); continuation.resume() }
        }
    }

    private func createCapture() throws {
        guard device == kAudioObjectUnknown, tap == kAudioObjectUnknown else { return }
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = Self.property(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
        let excluded = status == noErr && ownProcess != kAudioObjectUnknown ? [ownProcess] : []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Local Captions · system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "создать аудиозахват")

        let reader = try TapAudioReader(format: Self.tapFormat(tap), onAudio: { [weak self] in self?.onAudio?($0) },
            onError: { [weak self] in self?.onError?($0) })
        let tapID = tap
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            do { try reader.setFormat(Self.tapFormat(tapID)) }
            catch { reader.report(error) }
        }
        address = Self.property(kAudioTapPropertyFormat)
        try Self.check(AudioObjectAddPropertyListenerBlock(tap, &address, queue, listener), "наблюдать формат аудио")
        formatListener = listener

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Local Captions · private audio input",
            kAudioAggregateDeviceUIDKey: "local.localcaptions.audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "создать аудиовход")
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, input, _, _, _ in
            reader.consume(input)
        }, "подключить аудиовход")
        try Self.check(AudioDeviceStart(device, ioProc), "запустить системный звук")
    }

    private func destroyCapture() {
        if device != kAudioObjectUnknown {
            if let ioProc {
                AudioDeviceStop(device, ioProc)
                AudioDeviceDestroyIOProcID(device, ioProc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown {
            if let formatListener {
                var address = Self.property(kAudioTapPropertyFormat)
                AudioObjectRemovePropertyListenerBlock(tap, &address, queue, formatListener)
            }
            // Finish already enqueued callbacks before destroying the tap they read.
            queue.sync {}
            AudioHardwareDestroyProcessTap(tap)
        }
        ioProc = nil; formatListener = nil
        device = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func tapFormat(_ tap: AudioObjectID) throws -> AVAudioFormat {
        var address = property(kAudioTapPropertyFormat), asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), "прочитать формат аудио")
        guard let format = AVAudioFormat(streamDescription: &asbd), format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptionsError.message("Неизвестный формат системного звука")
        }
        return format
    }
    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw CaptionsError.message("Не удалось \(operation) (Core Audio \(status)). Проверьте разрешение Local Captions «Только запись системного звука» в настройках macOS.")
        }
    }
}

/// Confined to the audio queue. HAL owns input memory, so conversion and delivery
/// finish inside the callback; no unsafe buffer pointers escape it.
final class TapAudioReader {
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let onAudio: ([Float]) -> Void
    private let onError: (Error) -> Void
    private var failed = false

    init(format: AVAudioFormat, onAudio: @escaping ([Float]) -> Void, onError: @escaping (Error) -> Void) throws {
        self.onAudio = onAudio; self.onError = onError
        try setFormat(format)
    }
    func setFormat(_ next: AVAudioFormat) throws {
        guard next != format else { return }
        guard let converter = AVAudioConverter(from: next, to: target) else {
            throw CaptionsError.message("Не удалось преобразовать системный звук в 16 кГц")
        }
        converter.downmix = true
        self.converter = converter; format = next
    }
    func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard !failed, let format, let converter else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let expectedBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let channelsPerBuffer: UInt32 = format.isInterleaved ? format.channelCount : 1
        // A format-change notification may meet the last buffer of the old layout.
        // Drop that packet instead of passing incompatible memory into AVFoundation.
        guard buffers.count == expectedBuffers,
              buffers.allSatisfy({ $0.mNumberChannels == channelsPerBuffer && $0.mData != nil && $0.mDataByteSize > 0 }),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil), pcm.frameLength > 0,
              let result = AVAudioPCMBuffer(pcmFormat: target,
                frameCapacity: AVAudioFrameCount(ceil(Double(pcm.frameLength) * 16000 / format.sampleRate)) + 32) else { return }
        var supplied = false, error: NSError?
        let status = converter.convert(to: result, error: &error) { _, state in
            guard !supplied else { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return pcm
        }
        if let error { report(error); return }
        guard status != .error else { report(CaptionsError.message("Ошибка преобразования системного звука")); return }
        guard result.frameLength > 0, let data = result.floatChannelData?[0] else { return }
        onAudio(Array(UnsafeBufferPointer(start: data, count: Int(result.frameLength))))
    }
    func report(_ error: Error) {
        guard !failed else { return }
        failed = true; onError(error)
    }
}
