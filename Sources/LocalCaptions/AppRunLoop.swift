import Foundation
import CoreFoundation

/// AppKit menus and window tracking run a nested event loop. Keep caption delivery
/// available in those modes, rather than waiting for the default-mode main queue.
enum AppRunLoop {
    typealias Action = @MainActor @Sendable () -> Void

    static func perform(_ action: @escaping Action) {
        let once = Once(action)
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { once.run() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        // Command-line benchmarks use dispatchMain rather than AppKit's run loop.
        // Whichever path is serviced first wins; never deliver a caption twice.
        DispatchQueue.main.async { once.run() }
    }

    static func update(_ action: @escaping Action) async {
        await withCheckedContinuation { continuation in
            perform { action(); continuation.resume() }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var action: Action?
        init(_ action: @escaping Action) { self.action = action }
        @MainActor func run() {
            lock.lock(); let work = action; action = nil; lock.unlock()
            work?()
        }
    }
}
