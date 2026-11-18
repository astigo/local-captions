import Foundation
import Combine

struct Caption: Identifiable, Equatable, Codable {
    let id: UUID
    var english: String
    var russian: String?
    var expiresAt: Date?
    var firstSeenAt = Date()
    var finalized = false
    var translationError: String?
    var sources: [AudioSource] = []
    var original: String?
    var channel: String? // nil in legacy files means system audio.
    var audioStartAt: Date?
    var audioEndAt: Date?
    /// Language of `russian`, which holds the translation: "en" for Russian speech in learning mode.
    var translationLanguage: String?
}

@MainActor final class CaptionStore: ObservableObject {
    @Published private(set) var captions: [Caption] = []
    @Published private(set) var history: [Caption] = []
    @Published private(set) var browsingHistory = false
    @Published private(set) var acceptingInput = false
    @Published private(set) var mode: CaptionMode = .translation
    @Published private(set) var revealedTranslations: Set<UUID> = []
    /// The translator is running for this session; the overlay hides translation lanes otherwise.
    @Published var translationActive = false
    static let retentionSeconds: TimeInterval = 5
    let metrics = SessionMetrics()
    /// Audio time (uptime) of the first and last word end of each system phrase.
    private var audioSpans: [UUID: (first: TimeInterval, last: TimeInterval)] = [:]
    private var lastUpdate: [UUID: Date] = [:]
    static let paragraphPause: TimeInterval = 1.0
    static let longPause: TimeInterval = 2.5
    private(set) var session = UUID()
    private var journal: TranscriptJournal?
    private var finishing = false
    private var stoppedAt: Date?
    var currentSources: [AudioSource] = []
    var hasSystemHistory: Bool { history.contains { $0.channel != "microphone" } }
    var shouldShowOverlay: Bool { !captions.isEmpty || (browsingHistory && !history.isEmpty) }

    func begin(mode: CaptionMode = .translation) {
        clear()
        self.mode = mode
        metrics.reset(); audioSpans = [:]; lastUpdate = [:]
        history = []; revealedTranslations = []; currentSources = []; acceptingInput = true; finishing = false; stoppedAt = nil
    }

    func record(to directory: URL, title: String, model: String? = nil, translator: String? = nil, microphone: Bool = false, onError: @escaping @Sendable (String) -> Void) throws {
        journal = try TranscriptJournal(directory: directory, sessionID: session, title: title, model: model, mode: mode, translator: translator, microphone: microphone, onError: onError)
    }

    /// Stop invalidates late model results, but retains the session for explicit history review.
    func clear() {
        prepareToFinish()
        finishJournal()
    }

    func prepareToFinish() {
        guard !finishing else { return }
        finishing = true; stoppedAt = Date()
        if let journal {
            for caption in history where !caption.finalized { journal.write(type: "interrupted_caption", caption: caption, snapshot: history) }
        }
        session = UUID(); captions = []; currentSources = []; acceptingInput = false
        browsingHistory = false
    }

    func finishJournal() {
        journal?.finish(snapshot: history, now: stoppedAt ?? Date()); journal = nil
    }

    var recordingJournal: TranscriptJournal? { journal }

    func addMicrophone(_ caption: Caption) throws {
        guard let journal else { throw CaptionsError.message("Журнал встречи закрыт; аудио микрофона сохранено для повторной обработки") }
        var merged = history.filter { $0.id != caption.id } + [caption]
        merged.sort { ($0.audioStartAt ?? $0.firstSeenAt) < ($1.audioStartAt ?? $1.firstSeenAt) }
        try journal.writeVerified(type: "microphone_transcription", caption: caption, snapshot: merged)
        history = merged
    }

    func showHistory() { guard hasSystemHistory else { return }; browsingHistory = true }
    func returnToLive() { browsingHistory = false }

    func showsTranslation(for id: UUID) -> Bool {
        mode == .translation || (mode == .learning && revealedTranslations.contains(id))
    }

    func toggleTranslation(id: UUID, now: Date = Date()) {
        guard mode == .learning, let index = history.firstIndex(where: { $0.id == id }), history[index].channel != "microphone" else { return }
        if revealedTranslations.remove(id) == nil {
            revealedTranslations.insert(id)
            metrics.phraseTranslationShown()
            if !browsingHistory, history[index].finalized {
                history[index].expiresAt = history[index].russian == nil && history[index].translationError == nil
                    ? nil : max(history[index].expiresAt ?? now, now.addingTimeInterval(Self.retentionSeconds))
                refreshLive(now: now)
            }
        } else if !browsingHistory, history[index].finalized {
            history[index].expiresAt = now.addingTimeInterval(Self.retentionSeconds)
            refreshLive(now: now)
        }
    }

    func partial(id: UUID, text: String, session expected: UUID, now: Date = Date(), wordEnds: [TimeInterval?]? = nil) {
        guard expected == session, !text.isEmpty else { return }
        if let wordEnds {
            metrics.audio(id: id, wordEnds: wordEnds)
            if let first = wordEnds.first ?? nil, let last = wordEnds.last ?? nil { audioSpans[id] = (first, last) }
        }
        lastUpdate[id] = now
        if let index = history.firstIndex(where: { $0.id == id }) {
            guard !history[index].finalized else { return }
            history[index].english = text
            history[index].original = text
            if history[index].sources.isEmpty { history[index].sources = currentSources }
        } else {
            history.append(Caption(id: id, english: text, firstSeenAt: now, sources: currentSources, original: text, channel: "system"))
        }
        refreshLive(now: now)
    }

    func finalized(id: UUID, session expected: UUID, now: Date = Date()) {
        guard expected == session, let index = history.firstIndex(where: { $0.id == id }), !history[index].finalized else { return }
        history[index].finalized = true
        metrics.finalized(id: id, text: history[index].english)
        history[index].expiresAt = mode == .translation || (mode == .learning && revealedTranslations.contains(id))
            ? nil : now.addingTimeInterval(Self.retentionSeconds)
        journal?.write(type: mode.translates ? "english_final" : "transcription_final", caption: history[index], snapshot: history)
        refreshLive(now: now)
    }

    func translated(id: UUID, text: String, session expected: UUID, now: Date = Date(), language: CaptionLanguage = .russian) {
        guard mode.translates, expected == session, let index = history.firstIndex(where: { $0.id == id }) else { return }
        if !history[index].finalized { metrics.finalized(id: id, text: history[index].english) }
        history[index].finalized = true
        history[index].russian = text
        history[index].translationLanguage = language.rawValue
        metrics.translated(id: id)
        // Hidden translations must not keep learning captions on screen indefinitely.
        // A clicked phrase gets a fresh reading interval when its translation arrives.
        if mode == .translation || revealedTranslations.contains(id) || history[index].expiresAt == nil {
            history[index].expiresAt = now.addingTimeInterval(Self.retentionSeconds)
        }
        journal?.write(type: "translation", caption: history[index], snapshot: history)
        refreshLive(now: now)
    }

    func translationFailed(id: UUID, message: String, session expected: UUID, now: Date = Date()) {
        guard expected == session, let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].translationError = message
        if mode == .translation || revealedTranslations.contains(id) || history[index].expiresAt == nil {
            history[index].expiresAt = now.addingTimeInterval(Self.retentionSeconds)
        }
        journal?.write(type: "translation_error", caption: history[index], snapshot: history)
        refreshLive(now: now)
    }

    /// A new paragraph where the speaker paused: after a finished sentence and a pause of
    /// at least a second, or after any long pause. Audio timing is used when known; otherwise
    /// the gap between text updates stands in for it.
    func startsParagraph(_ next: Caption, after previous: Caption) -> Bool {
        let gap: TimeInterval
        if let before = audioSpans[previous.id]?.last, let after = audioSpans[next.id]?.first {
            gap = after - before - 0.3 // the first word's own duration is not a pause
        } else {
            gap = next.firstSeenAt.timeIntervalSince(lastUpdate[previous.id] ?? previous.firstSeenAt)
        }
        let sentenceEnd = previous.english.trimmingCharacters(in: .whitespaces).last.map { ".?!…".contains($0) } ?? false
        return gap >= Self.longPause || (sentenceEnd && gap >= Self.paragraphPause)
    }

    func expire(now: Date = Date()) { refreshLive(now: now) }
    private func refreshLive(now: Date = Date()) {
        guard acceptingInput else { return }
        let live = history.filter { $0.channel != "microphone" && ($0.expiresAt.map { $0 > now } ?? true) }
        if live != captions { captions = live }
    }
}
