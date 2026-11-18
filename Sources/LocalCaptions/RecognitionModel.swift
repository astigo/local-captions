import Foundation
import FluidAudio

enum RecognitionModel: String, CaseIterable, Identifiable {
    // Recognizers to choose from; add a case here (with its loading in Recognition.load) to compare another one.
    case ultra
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ultra: return "Parakeet Ultra · 600M"
        }
    }
    var detail: String {
        switch self {
        case .ultra: return "Многоязычная: английский и русский. Задержка зависит от окна."
        }
    }
    func directory(in runtime: URL) -> URL {
        switch self {
        case .ultra: return runtime.appendingPathComponent("models/parakeet-ultra")
        }
    }
}

/// Recognition settings that trade delay for stability. Changing them applies on the next start.
enum RecognitionTuning {
    static let ultraChunkChoices: [Double] = [0.48, 0.64, 0.96, 1.28, 2.0]
    /// Ultra decodes once per chunk: a word waits on average half a chunk plus right context.
    /// English alone is accurate at 0.64 s; Russian needs about 0.96 s for half the errors,
    /// so the bilingual modes have their own window.
    static func ultraChunkSeconds(for mode: CaptionMode) -> Double {
        if let override = ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_ULTRA_CHUNK"].flatMap(Double.init),
           (0.32...2.56).contains(override) { return override }
        let stored = UserDefaults.standard.double(forKey: key(for: mode))
        return ultraChunkChoices.contains(stored) ? stored : (mode == .translation ? 0.64 : 0.96)
    }
    static func setUltraChunkSeconds(_ value: Double, for mode: CaptionMode) {
        UserDefaults.standard.set(value, forKey: key(for: mode))
    }
    static var ultraChunkSeconds: Double { ultraChunkSeconds(for: .translation) }
    private static func key(for mode: CaptionMode) -> String { mode == .translation ? "ultraChunkSeconds" : "ultraChunkSecondsBilingual" }
    /// Reveal words one at a time between recognizer updates instead of in bursts (set in OverlaySettings).
    static var wordPacing: Bool { UserDefaults.standard.object(forKey: "wordPacing") as? Bool ?? true }
}

/// Applies native token revisions without allowing edits to an irrevocable prefix.
/// Translation may consume only stable text; the changing tail is shown immediately.
struct UltraTranscript {
    let vocabulary: [Int: String]
    private(set) var tokens: [Int] = []
    /// Token end times in seconds from the start of this recognizer job, aligned with `tokens`.
    private(set) var endTimes: [Double] = []
    private(set) var stableCount = 0
    private var jobID: UUID?
    private var ordinal = 0

    init(vocabulary: [Int: String]) { self.vocabulary = vocabulary }

    mutating func apply(_ update: SlidingWindowTokenUpdate) throws {
        let r = update.revision
        guard (jobID == nil || jobID == r.jobID), r.ordinal == ordinal + 1,
              r.previousTokenCount == tokens.count,
              r.retainedTokenCount >= stableCount, r.retainedTokenCount <= tokens.count,
              r.stableTokenCount >= stableCount,
              r.stableTokenCount <= r.retainedTokenCount + update.tokens.count else {
            throw CaptionsError.message("Нарушена последовательность текста Ultra. Повторите запуск.")
        }
        tokens.removeSubrange(r.retainedTokenCount...)
        tokens.append(contentsOf: update.tokens.map(\.tokenId))
        endTimes.removeSubrange(min(r.retainedTokenCount, endTimes.count)...)
        endTimes.append(contentsOf: update.tokens.map(\.endTime))
        stableCount = r.stableTokenCount; jobID = r.jobID; ordinal = r.ordinal
    }
    var text: String { render(tokens[...]) }
    /// End sample of each rendered word, offset by where this job started in the session.
    func wordEnds(baseSample: Int) -> [Int] {
        guard endTimes.count == tokens.count else { return [] }
        let pieces = zip(tokens, endTimes).compactMap { id, end -> (text: String, endSample: Int)? in
            guard let piece = vocabulary[id], piece != "<unk>" else { return nil }
            return (piece, baseSample + Int(end * 16000))
        }
        return WordTimings.words(pieces: pieces).map(\.endSample)
    }
    var stableText: String { render(tokens.prefix(stableCount)) }
    private func render(_ ids: ArraySlice<Int>) -> String {
        ids.compactMap { vocabulary[$0] }.filter { $0 != "<unk>" }.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
