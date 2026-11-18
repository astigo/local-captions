import Foundation

/// SCK callback sizes vary. Bound the queue in seconds of audio, not callback count.
/// This object stays off the UI thread; only an actual overrun reports an error there.
final class LiveAudioInput: @unchecked Sendable {
    static let blockSize = 5120 // 320 ms at 16 kHz, matching Recognition's input blocks.
    static let bufferedBlocks = 48 // 15.36 s, under 1 MiB of Float samples.
    let stream: AsyncStream<[Float]>
    let clock = AudioClock()
    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var pending: [Float] = []
    private var ended = false
    private var overrun = false
    private var lastAudio: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var seenAudio = false
    private var lastSignal: TimeInterval = ProcessInfo.processInfo.systemUptime

    init() {
        let pair = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingOldest(Self.bufferedBlocks))
        stream = pair.stream; continuation = pair.continuation
    }

    /// False once on the first overflow; later callbacks are ignored until shutdown.
    @discardableResult func append(_ samples: [Float], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, !overrun else { return true }
        guard !samples.isEmpty else { return true }
        lastAudio = now; seenAudio = true
        let energy = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        if energy >= 0.0000001 { lastSignal = now }
        return enqueue(samples, now: now)
    }

    func signalIdle(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(0, now - lastSignal)
    }

    func activity(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> (seen: Bool, idle: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (seenAudio, max(0, now - lastAudio))
    }

    @discardableResult func padIfIdle(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !ended, !overrun, seenAudio, now - lastAudio > 1 else { return true }
        // Deliberately leave lastAudio unchanged: padding is not captured sound.
        return enqueue([Float](repeating: 0, count: 15360), now: now)
    }

    private func enqueue(_ samples: [Float], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        clock.received(samples.count, at: now)
        pending.append(contentsOf: samples)
        while pending.count >= Self.blockSize {
            let block = Array(pending.prefix(Self.blockSize)); pending.removeFirst(Self.blockSize)
            if case .dropped = continuation.yield(block) {
                overrun = true; pending.removeAll(); continuation.finish()
                return false
            }
        }
        return true
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        ended = true; pending.removeAll(); continuation.finish()
    }
}
