import XCTest
import AppKit
import CoreFoundation
@testable import LocalCaptions

final class InteractionRegressionTests: XCTestCase {
    @MainActor func testManualResizeDoesNotScheduleWindowFeedback() {
        var width = 840.0, queued: [AppRunLoop.Action] = []
        let binding = OverlayWidthBinding(currentWidth: { width }, apply: { _ in XCTFail("Manual resize must not resize again") },
            schedule: { queued.append($0) })
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        var frame = NSRect(x: 400, y: 100, width: 840, height: 200)
        let leftEdge = frame.minX
        for delta in stride(from: 0.0, through: 300, by: 3) {
            frame = OverlayGeometry.dragFrame(NSRect(x: 400, y: 100, width: 840, height: 200), delta: delta, left: false, screen: screen)
            binding.windowResized(to: frame.width) { value in
                binding.settingsChanged() // @Published sends before the stored value changes.
                width = value
            }
            XCTAssertEqual(frame.minX, leftEdge)
        }
        XCTAssertTrue(queued.isEmpty, "101 drag events must not leave 101 deferred frame changes")
    }

    @MainActor func testPendingSliderRequestCannotReplayAnOldWidthAfterDragging() {
        var width = 840.0, queued: [AppRunLoop.Action] = [], applied = 0
        let screen = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        var frame = NSRect(x: 400, y: 100, width: 840, height: 200)
        var binding: OverlayWidthBinding!
        binding = OverlayWidthBinding(currentWidth: { width }, apply: { value in
            applied += 1
            if abs(frame.width - value) > 0.5 {
                frame = OverlayGeometry.widthFrame(frame, width: value, screen: screen)
                binding.windowResized(to: frame.width) { newWidth in binding.settingsChanged(); width = newWidth }
            }
        }, schedule: { queued.append($0) })
        for requested in [900.0, 800, 1000, 700] { binding.settingsChanged(); width = requested }
        XCTAssertEqual(queued.count, 1)
        // The user changes the right edge before the deferred slider work can run.
        frame.size.width = 712
        binding.windowResized(to: 712) { binding.settingsChanged(); width = $0 }
        let actions = queued; queued.removeAll(); actions.forEach { $0() }
        XCTAssertEqual(frame.minX, 400)
        XCTAssertEqual(frame.width, 712)
        XCTAssertEqual(applied, 1)
        XCTAssertTrue(queued.isEmpty, "Applying a saved width must not start an endless echo")
    }

    func testThousandsOfSmallCapturePacketsPreserveOrderWithoutFalseOverrun() async {
        let input = LiveAudioInput()
        let expected = (0..<(LiveAudioInput.blockSize * 40)).map(Float.init)
        for offset in stride(from: 0, to: expected.count, by: 80) {
            XCTAssertTrue(input.append(Array(expected[offset..<min(offset + 80, expected.count)])))
        }
        input.finish()
        var actual: [Float] = []
        for await block in input.stream { actual += block; XCTAssertEqual(block.count, LiveAudioInput.blockSize) }
        XCTAssertEqual(actual, expected, "12.8 seconds must fit regardless of callback packet size")
    }

    func testRealOverrunIsBoundedAndReportedOnce() async {
        let input = LiveAudioInput(), block = [Float](repeating: 0.5, count: LiveAudioInput.blockSize)
        for _ in 0..<LiveAudioInput.bufferedBlocks { XCTAssertTrue(input.append(block)) }
        XCTAssertFalse(input.append(block))
        XCTAssertTrue(input.append(block), "Do not flood the UI with the same error per callback")
        var count = 0
        for await chunk in input.stream { count += chunk.count }
        XCTAssertEqual(count, LiveAudioInput.bufferedBlocks * LiveAudioInput.blockSize)
    }

    func testIdlePaddingDoesNotPretendToBeCapturedAudio() {
        let input = LiveAudioInput()
        XCTAssertTrue(input.append([Float](repeating: 0.5, count: 100), now: 10))
        XCTAssertTrue(input.padIfIdle(now: 12))
        XCTAssertTrue(input.activity(now: 12).seen)
        XCTAssertEqual(input.activity(now: 12).idle, 2)
        input.finish()
        XCTAssertTrue(input.append([1, 2, 3], now: 20))
        XCTAssertEqual(input.activity(now: 20).idle, 10)
    }

    @MainActor func testCaptionDeliveryRunsInTrackingModeAndOnlyOnce() {
        let mode = RunLoop.Mode.eventTracking
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
        var delivered = 0
        AppRunLoop.perform { delivered += 1 }
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: mode)
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(1)
        while delivered == 0, Date() < deadline { RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(delivered, 1, "An open menu must not prevent captions from being delivered")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(delivered, 1, "Dispatch fallback must not duplicate the caption")
    }

    @MainActor static func runTracking(for seconds: TimeInterval) {
        let mode = RunLoop.Mode.eventTracking
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: mode)
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02)) }
    }
}
