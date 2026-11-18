import Foundation
import Combine

/// Turns the caption store into what the rolling overlay shows: one continuous stream of
/// words, revealed one at a time, with the unsettled tail and fresh corrections marked.
/// The store keeps its own expiry rules for history and files; this layer only presents.
@MainActor final class LivePresenter: ObservableObject {
    struct Word: Identifiable, Equatable {
        let id: String
        let caption: UUID
        let index: Int
        let text: String
        var tail = false
        var corrected = false
        var selected = false
        /// Learning mode: the phrase translation is ready, and whether it was already opened.
        var translationReady = false
        var translationSeen = false
        /// Part of the phrase whose translation the card is showing.
        var inShownPhrase = false
    }
    enum Item: Identifiable, Equatable {
        case word(Word)
        case lineBreak(String)
        var id: String {
            switch self { case .word(let word): return word.id; case .lineBreak(let id): return id }
        }
    }
    struct Selection: Equatable {
        let caption: UUID
        let index: Int
        let word: String
        var gloss: String?
        var glossFailed = false
        var showsPhrase = false
    }

    @Published private(set) var english: [Item] = []
    @Published private(set) var russian: [Item] = []
    @Published private(set) var visible = false
    /// Learning mode under the pointer: the lines above stay put and the curtain below shows the live stream.
    @Published private(set) var frozen = false
    /// Words that arrived after the curtain opened, shown below the held lines.
    @Published private(set) var live: [Item] = []
    @Published private(set) var selection: Selection?

    static let silenceSeconds: TimeInterval = 6
    static let correctionSeconds: TimeInterval = 1.2
    static let maxCaptions = 10

    let store: CaptionStore
    let settings: OverlaySettings
    var vocabulary: Vocabulary?
    var translateWord: ((String, String) async throws -> String)?

    private var captions: [Caption] = []
    /// Text as it was when the curtain opened; styling still updates, these words do not move.
    private var frozenCaptions: [Caption]?
    private var frozenRevealed: [UUID: Int] = [:]
    private var revealed: [UUID: Int] = [:]
    private var reported: [UUID: [String]] = [:]
    private var correctedUntil: [UUID: [Int: TimeInterval]] = [:]
    private var firstSeen: [UUID: TimeInterval] = [:]
    private var lastChange: [UUID: TimeInterval] = [:]
    private var knownText: [UUID: String] = [:]
    private var knownRussian: [UUID: Bool] = [:]
    private var lastActivity: TimeInterval = 0
    private var nextReveal: TimeInterval = 0
    private var hovering = false
    private var cardHovering = false
    static let cardGrace: TimeInterval = 0.35
    private var leftAt: TimeInterval = 0
    private var glossCache: [String: String] = [:]
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let clock: () -> TimeInterval

    init(store: CaptionStore, settings: OverlaySettings, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.store = store; self.settings = settings; self.clock = clock
        store.$history.sink { [weak self] history in self?.ingest(history) }.store(in: &subscriptions)
        store.$acceptingInput.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        settings.$wordPacing.dropFirst().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
    }

    // MARK: Input

    private func ingest(_ history: [Caption]) {
        let now = clock()
        let system = history.filter { $0.channel != "microphone" }
        if system.isEmpty || (captions.first.map { first in !system.contains { $0.id == first.id } } ?? false) {
            resetSession()
        }
        for caption in system {
            if firstSeen[caption.id] == nil { firstSeen[caption.id] = now }
            if knownText[caption.id] != caption.english {
                knownText[caption.id] = caption.english; lastChange[caption.id] = now; lastActivity = now
            }
            let hasRussian = caption.russian != nil || caption.translationError != nil
            if knownRussian[caption.id] != hasRussian { knownRussian[caption.id] = hasRussian; if hasRussian { lastActivity = now } }
        }
        captions = Array(system.suffix(Self.maxCaptions))
        if let selection, let caption = system.first(where: { $0.id == selection.caption }),
           words(caption).count <= selection.index { self.selection = nil }
        update(now: now)
        schedule()
    }

    private func resetSession() {
        revealed = [:]; reported = [:]; correctedUntil = [:]; firstSeen = [:]; lastChange = [:]
        knownText = [:]; knownRussian = [:]; selection = nil; captions = []
        english = []; russian = []; live = []; lastActivity = 0
        frozenCaptions = nil; frozenRevealed = [:]
        if frozen { frozen = false; store.metrics.setPaused(false) }
    }

    // MARK: Interaction

    func setHovering(_ value: Bool) {
        hovering = value
        if !value { leftAt = clock() }
        update(now: clock()); schedule()
    }

    /// The word card sits above the plate; moving onto it does not close it.
    func setCardHovering(_ value: Bool) {
        cardHovering = value
        if !value { leftAt = clock() }
        update(now: clock()); schedule()
    }

    /// One click translates the word; a double click also opens the phrase translation.
    func select(caption: UUID, index: Int, clicks: Int = 1) {
        guard store.mode == .learning,
              let item = captions.first(where: { $0.id == caption }) ?? frozenCaptions?.first(where: { $0.id == caption }) else { return }
        let all = words(item)
        guard index < all.count else { return }
        if selection?.caption == caption, selection?.index == index {
            if clicks >= 2 { showPhrase() } else { selection = nil; update(now: clock()) }
            return
        }
        let word = all[index], key = Vocabulary.key(word), cacheKey = key + "|" + caption.uuidString
        selection = Selection(caption: caption, index: index, word: word, gloss: glossCache[cacheKey])
        store.metrics.wordLookedUp()
        if clicks >= 2 { showPhrase() }
        update(now: clock())
        guard glossCache[cacheKey] == nil, !key.isEmpty else { return }
        guard let translateWord else { selection?.glossFailed = true; return }
        let context = item.english
        Task { [weak self] in
            // The same word means different things in different phrases, so the phrase goes along.
            let result = try? await translateWord(word.trimmingCharacters(in: .punctuationCharacters), context)
            guard let self else { return }
            if let result { self.glossCache[cacheKey] = result }
            guard self.selection?.caption == caption, self.selection?.index == index else { return }
            if let result { self.selection?.gloss = result } else { self.selection?.glossFailed = true }
        }
    }

    func showPhrase() {
        guard let id = selection?.caption else { return }
        selection?.showsPhrase = true
        if !store.revealedTranslations.contains(id) { store.toggleTranslation(id: id) }
        publish(now: clock())
    }

    func clearSelection() { selection = nil; update(now: clock()); schedule() }

    func toggleVocabulary() {
        guard let selection, let vocabulary else { return }
        let context = captions.first { $0.id == selection.caption }?.english ?? ""
        if vocabulary.toggle(word: selection.word, translation: selection.gloss ?? "", context: context) {
            store.metrics.vocabularyAdded()
        }
        objectWillChange.send()
    }

    func phrase(for id: UUID) -> Caption? { store.history.first { $0.id == id } }

    // MARK: Presentation

    private func words(_ caption: Caption) -> [String] { caption.english.split(whereSeparator: \.isWhitespace).map(String.init) }

    private func schedule() {
        let needed = visible || frozen || captions.contains { (revealed[$0.id] ?? 0) < words($0).count }
        if needed, timer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed {
            timer?.invalidate(); timer = nil
        }
    }

    private func tick() { update(now: clock()); schedule() }

    /// Advances word reveal, then publishes. Exposed for tests with an injected clock.
    func update(now: TimeInterval) {
        if selection != nil, !hovering, !cardHovering, leftAt > 0, now - leftAt > Self.cardGrace { selection = nil }
        let shouldFreeze = store.mode == .learning && ((settings.hoverPause && hovering) || selection != nil)
        if shouldFreeze != frozen {
            frozen = shouldFreeze
            store.metrics.setPaused(shouldFreeze, now: now)
            frozenCaptions = shouldFreeze ? captions : nil
            frozenRevealed = shouldFreeze ? revealed : [:]
        }
        // Words keep arriving while the curtain is open; they go below the held lines.
        reveal(now: now)
        publish(now: now)
        let pending = captions.contains { !$0.finalized || (revealed[$0.id] ?? 0) < words($0).count }
        let show = store.acceptingInput && !captions.isEmpty
            && (pending || frozen || selection != nil || now - lastActivity < Self.silenceSeconds)
        if show != visible { visible = show }
    }

    private func reveal(now: TimeInterval) {
        var pending = 0
        for caption in captions { pending += max(0, words(caption).count - (revealed[caption.id] ?? 0)) }
        for caption in captions where (revealed[caption.id] ?? 0) > words(caption).count { revealed[caption.id] = words(caption).count }
        guard pending > 0 else { return }
        guard settings.wordPacing else {
            for caption in captions { revealed[caption.id] = words(caption).count }
            return
        }
        guard now >= nextReveal, let caption = captions.first(where: { (revealed[$0.id] ?? 0) < words($0).count }) else { return }
        revealed[caption.id, default: 0] += 1
        // Spread a burst over less than one recognizer update (0.64 s for Ultra), so pacing smooths
        // without adding much delay; catch up quickly after a backlog.
        let interval = pending > 8 ? 0.04 : min(0.15, max(0.06, 0.45 / Double(pending)))
        nextReveal = now + interval
    }

    private func publish(now: TimeInterval) {
        var english: [Item] = [], russian: [Item] = [], live: [Item] = []
        var previous: Caption?, previousLive: Caption?
        let current = Dictionary(captions.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for caption in captions {
            let all = words(caption)
            let count = min(revealed[caption.id] ?? 0, all.count)
            if count > 0 { report(caption, Array(all.prefix(count)), now: now) }
        }
        // Held lines: the snapshot while the curtain is open, otherwise the live stream itself.
        for held in frozenCaptions ?? captions {
            // Translation state is always current, even for held words.
            var caption = held
            if let latest = current[caption.id] { caption.russian = latest.russian; caption.translationError = latest.translationError }
            let all = words(caption)
            let count = min((frozenCaptions == nil ? revealed : frozenRevealed)[caption.id] ?? 0, all.count)
            guard count > 0 else { continue }
            if let previous, startsParagraph(caption, after: previous) {
                english.append(.lineBreak("br-\(caption.id)"))
                russian.append(.lineBreak("br-\(caption.id)"))
            }
            english += items(caption, words: all, range: 0..<count, now: now)
            if store.mode == .translation {
                let text = caption.russian ?? (caption.translationError == nil ? nil : "[перевод недоступен]")
                for (index, word) in (text ?? "").split(whereSeparator: \.isWhitespace).enumerated() {
                    russian.append(.word(Word(id: "ru-\(caption.id)-\(index)", caption: caption.id, index: index, text: String(word))))
                }
            }
            previous = caption
        }
        if frozenCaptions != nil {
            for caption in captions {
                let all = words(caption)
                let start = min(frozenRevealed[caption.id] ?? 0, all.count), end = min(revealed[caption.id] ?? 0, all.count)
                guard end > start else { continue }
                if let previousLive, startsParagraph(caption, after: previousLive) { live.append(.lineBreak("br-\(caption.id)")) }
                live += items(caption, words: all, range: start..<end, now: now)
                previousLive = caption
            }
        }
        if english != self.english { self.english = english }
        if russian != self.russian { self.russian = russian }
        if live != self.live { self.live = live }
    }

    private func items(_ caption: Caption, words all: [String], range: Range<Int>, now: TimeInterval) -> [Item] {
        let ready = store.mode == .learning && caption.russian != nil
        let seen = ready && (store.revealedTranslations.contains(caption.id) || (selection?.caption == caption.id && selection?.showsPhrase == true))
        let complete = range.upperBound == all.count
        let shown = selection?.caption == caption.id && selection?.showsPhrase == true
        return range.map { index in
            let corrected = (correctedUntil[caption.id]?[index]).map { $0 > now } ?? false
            return .word(Word(id: "\(caption.id)-\(index)", caption: caption.id, index: index, text: all[index],
                tail: !caption.finalized && index >= all.count - 2, corrected: corrected,
                selected: selection?.caption == caption.id && selection?.index == index,
                translationReady: ready && complete, translationSeen: seen && complete, inShownPhrase: shown))
        }
    }

    private func startsParagraph(_ caption: Caption, after previous: Caption) -> Bool {
        store.startsParagraph(caption, after: previous)
    }

    /// Keeps metrics on what is actually on screen and marks corrected words.
    private func report(_ caption: Caption, _ visibleWords: [String], now: TimeInterval) {
        let old = reported[caption.id] ?? []
        guard old != visibleWords else { return }
        for index in visibleWords.indices where index < old.count && old[index] != visibleWords[index] {
            let growth = index == old.count - 1 && visibleWords[index].hasPrefix(old[index])
            if !growth { correctedUntil[caption.id, default: [:]][index] = now + Self.correctionSeconds }
        }
        store.metrics.displayed(id: caption.id, words: visibleWords, now: now)
        reported[caption.id] = visibleWords
    }
}
