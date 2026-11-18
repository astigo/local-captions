import Foundation

/// Maps recognizer sample positions to the moment that audio reached the app.
/// Every sample given to the recognizer must pass through `received`, padding included,
/// or later positions would point at the wrong moment.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var marks: [(samples: Int, uptime: TimeInterval)] = []
    private var total = 0

    func received(_ count: Int, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        total += count
        marks.append((total, uptime))
        // About two minutes of callbacks is far more than any caption stays unfinished.
        if marks.count > 12_000 { marks.removeFirst(marks.count - 10_000) }
    }

    /// Uptime when the sample at this zero-based position had arrived; nil if unknown.
    func uptime(atSample sample: Int) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard sample >= 0, sample < total, let first = marks.first,
              sample >= first.samples - 1_000_000 else { return nil }
        var low = 0, high = marks.count - 1
        while low < high {
            let mid = (low + high) / 2
            if marks[mid].samples > sample { high = mid } else { low = mid + 1 }
        }
        return marks[low].samples > sample ? marks[low].uptime : nil
    }
}

/// Splits recognizer pieces into whitespace words, keeping the end position of each word.
/// The rule matches how transcripts are rendered: a piece starting with "▁" opens a word.
enum WordTimings {
    static func words(pieces: [(text: String, endSample: Int)]) -> [(text: String, endSample: Int)] {
        var words: [(text: String, endSample: Int)] = []
        var current = "", end = 0
        for piece in pieces {
            if piece.text.hasPrefix("▁") || piece.text.hasPrefix(" ") {
                if !current.isEmpty { words.append((current, end)) }
                current = String(piece.text.drop(while: { $0 == "▁" || $0 == " " }))
            } else {
                current += piece.text
            }
            end = piece.endSample
        }
        if !current.isEmpty { words.append((current, end)) }
        return words
    }

    /// End samples for the words of `phrase`, which starts after `prefix` inside `fullText`.
    /// Returns nil when the token words and rendered words disagree, rather than guessing.
    static func slice(_ ends: [Int]?, fullText: String, prefixCharacters: Int, phrase: String) -> [Int]? {
        guard let ends else { return nil }
        let fullCount = fullText.split(whereSeparator: \.isWhitespace).count
        guard fullCount == ends.count else { return nil }
        let offset = fullText.prefix(prefixCharacters).split(whereSeparator: \.isWhitespace).count
        let count = phrase.split(whereSeparator: \.isWhitespace).count
        guard offset + count <= ends.count else { return nil }
        return Array(ends[offset..<(offset + count)])
    }
}

struct Distribution: Codable, Equatable {
    let count: Int
    let p50: Double
    let p90: Double
    let p95: Double
    let max: Double

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func quantile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1)
            let low = Int(position.rounded(.down)), high = Int(position.rounded(.up))
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
        count = sorted.count; p50 = quantile(0.5); p90 = quantile(0.9); p95 = quantile(0.95); max = sorted.last!
    }
}

struct SessionMetricsSummary: Codable, Equatable, Identifiable {
    struct Learning: Codable, Equatable {
        var phrases = 0
        var phrasesTranslated = 0
        var wordLookups = 0
        var vocabularyAdded = 0
        var pauses = 0
        var pausedSeconds = 0.0
    }
    var schemaVersion = 1
    let session: UUID
    let startedAt: Date
    let endedAt: Date
    let mode: String
    let model: String
    let ultraChunkSeconds: Double?
    let wordPacing: Bool
    let transcript: String?
    /// Words in finished system-audio phrases.
    let finalWords: Int
    /// Seconds from the end of a word in the captured audio to the moment its final spelling was on screen.
    let displayLatency: Distribution?
    /// Words whose on-screen spelling changed or disappeared after being shown.
    let revisedWords: Int
    let shownWords: Int
    let translationLatency: Distribution?
    let learning: Learning?
    var id: UUID { session }
    var revisionRate: Double { shownWords == 0 ? 0 : Double(revisedWords) / Double(shownWords) }
}

/// Collects real-use measurements for one session. Times are system uptime seconds.
@MainActor final class SessionMetrics {
    private struct Word {
        var text: String
        var firstShown: TimeInterval
        var correctSince: TimeInterval
        var revised = false
        var paused = false
    }
    private var words: [UUID: [Word]] = [:]
    private var audioEnds: [UUID: [TimeInterval?]] = [:]
    private var finalizedAt: [UUID: TimeInterval] = [:]
    private var finalTexts: [UUID: [String]] = [:]
    private var translationLatencies: [Double] = []
    private var shownWords = 0
    private var revisedWords = 0
    private var pauseStarted: TimeInterval?
    private(set) var learning = SessionMetricsSummary.Learning()
    private(set) var startedAt = Date()

    func reset(now: Date = Date()) {
        words = [:]; audioEnds = [:]; finalizedAt = [:]; finalTexts = [:]; translationLatencies = []
        shownWords = 0; revisedWords = 0; pauseStarted = nil
        learning = .init(); startedAt = now
    }

    func audio(id: UUID, wordEnds: [TimeInterval?]) {
        var known = audioEnds[id] ?? []
        for (index, end) in wordEnds.enumerated() {
            if index < known.count { if let end { known[index] = end } } else { known.append(end) }
        }
        audioEnds[id] = Array(known.prefix(wordEnds.count))
    }

    /// Called with exactly the words that are visible for one phrase, in order.
    func displayed(id: UUID, words visible: [String], paused: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        var states = words[id] ?? []
        for (index, text) in visible.enumerated() {
            if index < states.count {
                guard states[index].text != text else { continue }
                // The last word grows while it is being spoken; that is not a correction.
                let growth = index == states.count - 1 && text.hasPrefix(states[index].text)
                if !growth, !states[index].revised { states[index].revised = true; revisedWords += 1 }
                states[index].text = text; states[index].correctSince = now
            } else {
                states.append(Word(text: text, firstShown: now, correctSince: now, paused: paused))
                shownWords += 1
            }
        }
        if visible.count < states.count {
            for index in visible.count..<states.count where !states[index].revised { revisedWords += 1 }
            states.removeLast(states.count - visible.count)
        }
        words[id] = states
    }

    func finalized(id: UUID, text: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard finalizedAt[id] == nil else { return }
        finalizedAt[id] = now
        finalTexts[id] = text.split(whereSeparator: \.isWhitespace).map(String.init)
        learning.phrases += 1
    }

    func translated(id: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let start = finalizedAt[id] else { return }
        translationLatencies.append(max(0, now - start))
    }

    func phraseTranslationShown() { learning.phrasesTranslated += 1 }
    func wordLookedUp() { learning.wordLookups += 1 }
    func vocabularyAdded() { learning.vocabularyAdded += 1 }

    func setPaused(_ paused: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if paused, pauseStarted == nil { pauseStarted = now; learning.pauses += 1 }
        if !paused, let start = pauseStarted { learning.pausedSeconds += now - start; pauseStarted = nil }
    }

    func summary(session: UUID, mode: CaptionMode, model: String, ultraChunkSeconds: Double?, wordPacing: Bool,
                 transcript: String?, endedAt: Date = Date()) -> SessionMetricsSummary {
        setPaused(false)
        // Words often reach the screen after their phrase is final, so latency is computed at the end.
        var latencies: [Double] = []
        for (id, final) in finalTexts {
            let shown = words[id] ?? [], ends = audioEnds[id] ?? []
            for index in final.indices where index < shown.count && index < ends.count {
                guard let end = ends[index], shown[index].text == final[index], !shown[index].paused else { continue }
                let latency = shown[index].correctSince - end
                if latency > -0.5, latency < 30 { latencies.append(max(0, latency)) }
            }
        }
        let finalWords = finalTexts.values.reduce(0) { $0 + $1.count }
        return SessionMetricsSummary(session: session, startedAt: startedAt, endedAt: endedAt, mode: mode.rawValue,
            model: model, ultraChunkSeconds: ultraChunkSeconds, wordPacing: wordPacing, transcript: transcript,
            finalWords: finalWords, displayLatency: Distribution(latencies), revisedWords: revisedWords,
            shownWords: shownWords, translationLatency: Distribution(translationLatencies),
            learning: mode == .learning ? learning : nil)
    }
}

/// One line per session, so trends survive across meetings and app versions.
enum MetricsLog {
    static func url(in transcripts: URL) -> URL { transcripts.appendingPathComponent("metrics.jsonl") }

    static func append(_ summary: SessionMetricsSummary, transcripts: URL) throws {
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(summary); line.append(10)
        let file = url(in: transcripts)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }

    static func load(transcripts: URL, limit: Int = 30) -> [SessionMetricsSummary] {
        guard let text = try? String(contentsOf: url(in: transcripts), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).compactMap { try? decoder.decode(SessionMetricsSummary.self, from: Data($0.utf8)) }.reversed()
    }
}
