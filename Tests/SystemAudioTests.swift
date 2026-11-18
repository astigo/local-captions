import XCTest
import AVFoundation
@testable import LocalCaptions

final class SystemAudioTests: XCTestCase {
    func testStereoLayoutsAndRatesReachMono16kWithoutReadingOnlyOneChannel() throws {
        for rate in [44100.0, 48000.0] {
            for interleaved in [false, true] {
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: interleaved)!
                var output: [Float] = []
                let reader = try TapAudioReader(format: format, onAudio: { output += $0 }, onError: { XCTFail($0.localizedDescription) })
                // Opposite channels must cancel when downmixed, not alternate or
                // accidentally use one side of an interleaved stream as mono.
                feed(reader, format: format, opposite: true)
                XCTAssertGreaterThan(output.count, 15800)
                XCTAssertLessThanOrEqual(output.count, 16000)
                XCTAssertLessThan(rms(output), 0.0001)
                output.removeAll()
                feed(reader, format: format, opposite: false)
                XCTAssertGreaterThan(output.count, 15800)
                XCTAssertTrue(output.allSatisfy(\.isFinite))
                XCTAssertGreaterThan(rms(Array(output.dropFirst(300))), 0.2)
                XCTAssertLessThan(rms(output), 0.5)
            }
        }
    }

    func testReaderAcceptsChangedDeviceFormatAndSkipsIncompatibleOldBuffer() throws {
        let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        var count = 0
        let reader = try TapAudioReader(format: stereo, onAudio: { count += $0.count }, onError: { XCTFail($0.localizedDescription) })
        feed(reader, format: stereo, opposite: false)
        XCTAssertGreaterThan(count, 15800)
        try reader.setFormat(mono)
        count = 0
        let stale = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 512)!
        stale.frameLength = 512
        reader.consume(stale.audioBufferList)
        XCTAssertEqual(count, 0)
        feed(reader, format: mono, opposite: false)
        XCTAssertEqual(count, 16000)
    }

    func testEmptyCallbacksAndDuplicateErrorsDoNotReachAudioConsumer() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        var errors = 0, count = 0
        let reader = try TapAudioReader(format: format, onAudio: { count += $0.count }, onError: { _ in errors += 1 })
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        reader.consume(empty.audioBufferList)
        XCTAssertEqual(count, 0)
        reader.report(NSError(domain: "test", code: 1))
        reader.report(NSError(domain: "test", code: 2))
        feed(reader, format: format, opposite: false)
        XCTAssertEqual(errors, 1); XCTAssertEqual(count, 0)
    }

    private func feed(_ reader: TapAudioReader, format: AVAudioFormat, opposite: Bool) {
        let total = Int(format.sampleRate)
        for offset in stride(from: 0, to: total, by: 512) {
            let frames = min(512, total - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = buffer.frameCapacity
            for frame in 0..<frames {
                let value = Float(0.4 * sin(2 * Double.pi * 440 * Double(offset + frame) / format.sampleRate))
                for channel in 0..<Int(format.channelCount) {
                    let amplitude = channel == 1 && opposite ? -value : value
                    if format.isInterleaved { buffer.floatChannelData![0][frame * Int(format.channelCount) + channel] = amplitude }
                    else { buffer.floatChannelData![channel][frame] = amplitude }
                }
            }
            reader.consume(buffer.audioBufferList)
        }
    }
    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }
}
