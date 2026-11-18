import XCTest
import FluidAudio
@testable import LocalCaptions

final class RollingOverlayTests: XCTestCase {
    func testAudioClockMapsSamplesToArrivalAndPaddingKeepsPositions() {
        let clock = AudioClock()
        clock.received(5120, at: 10)
        clock.received(5120, at: 10.32)
        clock.received(15360, at: 12) // idle padding is still recognizer input
        XCTAssertEqual(clock.uptime(atSample: 0), 10)
        XCTAssertEqual(clock.uptime(atSample: 5119), 10)
        XCTAssertEqual(clock.uptime(atSample: 5120), 10.32)
        XCTAssertEqual(clock.uptime(atSample: 10240), 12)
        XCTAssertNil(clock.uptime(atSample: 25600), "A position not yet received has no arrival time")
    }

    func testLiveInputStampsEverySampleIncludingIdlePadding() {
        let input = LiveAudioInput()
        input.append([Float](repeating: 0.1, count: 1000), now: 5)
        XCTAssertTrue(input.padIfIdle(now: 7))
        XCTAssertEqual(input.clock.uptime(atSample: 999), 5)
        XCTAssertEqual(input.clock.uptime(atSample: 1000), 7)
        input.finish()
    }

    func testWordTimingsFollowRenderedWordsAndRefuseMismatches() {
        let words = WordTimings.words(pieces: [("▁give", 100), ("▁me", 200), ("▁the", 300), ("▁to", 400), ("tal", 500), (".", 520)])
        XCTAssertEqual(words.map(\.text), ["give", "me", "the", "total."])
        XCTAssertEqual(words.map(\.endSample), [100, 200, 300, 520])
        let full = "give me the total."
        XCTAssertEqual(WordTimings.slice(words.map(\.endSample), fullText: full, prefixCharacters: 8, phrase: "the total."), [300, 520])
        XCTAssertNil(WordTimings.slice([1, 2], fullText: full, prefixCharacters: 0, phrase: full))
    }

    func testUltraTranscriptKeepsEndTimesThroughRevisions() throws {
        var transcript = UltraTranscript(vocabulary: [1: "▁we", 2: "▁need", 3: "▁move", 4: "▁knead"])
        let job = UUID()
        func timing(_ id: Int, _ end: Double) -> TokenTiming { TokenTiming(token: "", tokenId: id, startTime: end - 0.1, endTime: end, confidence: 1) }
        try transcript.apply(SlidingWindowTokenUpdate(tokens: [timing(1, 0.2), timing(4, 0.5)], revision: SlidingWindowTokenRevision(
            jobID: job, ordinal: 1, previousTokenCount: 0, retainedTokenCount: 0, stableTokenCount: 1, window: 0..<1, center: 0..<1, isTerminal: false)))
        try transcript.apply(SlidingWindowTokenUpdate(tokens: [timing(2, 0.55), timing(3, 0.9)], revision: SlidingWindowTokenRevision(
            jobID: job, ordinal: 2, previousTokenCount: 2, retainedTokenCount: 1, stableTokenCount: 2, window: 0..<1, center: 0..<1, isTerminal: false)))
        XCTAssertEqual(transcript.text, "we need move")
        XCTAssertEqual(transcript.wordEnds(baseSample: 16000), [16000 + 3200, 16000 + 8800, 16000 + 14400])
    }

    @MainActor func testMetricsSeparateCorrectionsFromGrowthAndMeasureFinalSpelling() {
        let metrics = SessionMetrics()
        let id = UUID()
        metrics.audio(id: id, wordEnds: [10, 10.4, 10.8])
        metrics.displayed(id: id, words: ["we"], now: 10.5)
        metrics.displayed(id: id, words: ["we", "kn"], now: 10.9)
        metrics.displayed(id: id, words: ["we", "knead"], now: 11.0) // growth of the last word
        metrics.displayed(id: id, words: ["we", "need", "it"], now: 11.6) // a real correction
        metrics.finalized(id: id, text: "we need it")
        let summary = metrics.summary(session: UUID(), mode: .translation, model: "Ultra", ultraChunkSeconds: 0.64, wordPacing: true, transcript: nil)
        XCTAssertEqual(summary.finalWords, 3)
        XCTAssertEqual(summary.shownWords, 3)
        XCTAssertEqual(summary.revisedWords, 1)
        let latency = try? XCTUnwrap(summary.displayLatency)
        XCTAssertEqual(latency?.count, 3)
        XCTAssertEqual(latency?.max ?? 0, 1.2, accuracy: 0.001, "The corrected word counts from when its final spelling appeared")
        XCTAssertEqual(latency?.p50 ?? 0, 0.8, accuracy: 0.001)
    }

    @MainActor func testWordsHeldByALearningPauseAreNotCountedAsDelay() {
        let metrics = SessionMetrics()
        let id = UUID()
        metrics.audio(id: id, wordEnds: [1, 2])
        metrics.displayed(id: id, words: ["one"], now: 1.5)
        metrics.displayed(id: id, words: ["one", "two"], paused: true, now: 30)
        metrics.finalized(id: id, text: "one two")
        let summary = metrics.summary(session: UUID(), mode: .learning, model: "Ultra", ultraChunkSeconds: 0.64, wordPacing: true, transcript: nil)
        XCTAssertEqual(summary.displayLatency?.count, 1)
        XCTAssertNotNil(summary.learning)
    }

    func testMetricsLogAppendsAndReadsNewestFirst() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for words in [10, 20] {
            try MetricsLog.append(SessionMetricsSummary(session: UUID(), startedAt: Date(), endedAt: Date(), mode: "learning",
                model: "Ultra", ultraChunkSeconds: 0.64, wordPacing: true, transcript: nil, finalWords: words,
                displayLatency: Distribution([0.3, 0.5]), revisedWords: 1, shownWords: words, translationLatency: nil, learning: nil),
                transcripts: directory)
        }
        let loaded = MetricsLog.load(transcripts: directory)
        XCTAssertEqual(loaded.map(\.finalWords), [20, 10])
        XCTAssertEqual(loaded[0].revisionRate, 0.05, accuracy: 0.0001)
    }

    @MainActor func testPlateHeightFollowsLinesAndTranslationLane() {
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.fontSize = 20; settings.lineSpacing = 1.4
        XCTAssertEqual(settings.lineHeight, 28)
        XCTAssertEqual(settings.plateHeight(mode: .learning, lines: 3), 22 + 84)
        XCTAssertEqual(settings.plateHeight(mode: .translation, lines: 3), 22 + 84 + 13 + 2 * settings.translationLineHeight)
        XCTAssertEqual(settings.fillingLines(mode: .transcription, available: 22 + 28 * 9 + 5), 9)
    }

    @MainActor func testPresenterRevealsWordsOneByOneAndMarksTheUnsettledTail() {
        var now = 100.0
        let store = CaptionStore(); store.begin(mode: .translation)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.wordPacing = true
        let presenter = LivePresenter(store: store, settings: settings, clock: { now })
        let id = UUID()
        store.partial(id: id, text: "give me the top five", session: store.session)
        XCTAssertEqual(words(presenter).count, 1, "A burst of five words is spread out")
        for _ in 0..<10 { now += 0.25; presenter.update(now: now) }
        XCTAssertEqual(words(presenter).map(\.text), ["give", "me", "the", "top", "five"])
        XCTAssertEqual(words(presenter).filter(\.tail).map(\.text), ["top", "five"])
        store.partial(id: id, text: "give me the top five orders", session: store.session)
        store.finalized(id: id, session: store.session)
        for _ in 0..<4 { now += 0.25; presenter.update(now: now) }
        XCTAssertTrue(words(presenter).allSatisfy { !$0.tail })
        XCTAssertTrue(presenter.visible)
        now += LivePresenter.silenceSeconds + 1; presenter.update(now: now)
        XCTAssertFalse(presenter.visible, "The plate fades as a whole after silence")
    }

    @MainActor func testPresenterHighlightsCorrectionsAndStartsParagraphAfterPause() {
        var now = 100.0
        let store = CaptionStore(); store.begin(mode: .learning)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.wordPacing = false
        let presenter = LivePresenter(store: store, settings: settings, clock: { now })
        let first = UUID()
        store.partial(id: first, text: "practice your sequel", session: store.session)
        now += 0.5
        store.partial(id: first, text: "practice your SQL", session: store.session)
        XCTAssertEqual(words(presenter).first { $0.text == "SQL" }?.corrected, true)
        now += LivePresenter.correctionSeconds + 0.1; presenter.update(now: now)
        XCTAssertEqual(words(presenter).first { $0.text == "SQL" }?.corrected, false)
        store.finalized(id: first, session: store.session)
        now += 4
        store.partial(id: UUID(), text: "next topic", session: store.session, now: Date().addingTimeInterval(4))
        XCTAssertTrue(presenter.english.contains { if case .lineBreak = $0 { return true }; return false })
    }

    @MainActor func testParagraphNeedsASentenceEndAndASecondOfSilenceInTheAudio() {
        let store = CaptionStore(); store.begin(mode: .learning)
        let t = Date(), a = UUID(), b = UUID(), c = UUID(), d = UUID()
        store.partial(id: a, text: "We shipped it.", session: store.session, now: t, wordEnds: [10, 10.3, 10.6])
        store.partial(id: b, text: "Then we waited", session: store.session, now: t, wordEnds: [11.0, 11.3, 11.6]) // 0.1 s pause
        store.partial(id: c, text: "for the review.", session: store.session, now: t, wordEnds: [14.5, 14.7, 15.0]) // 2.6 s pause, no full stop
        store.partial(id: d, text: "Next question.", session: store.session, now: t, wordEnds: [16.4, 16.7]) // 1.1 s after a full stop
        let h = store.history
        XCTAssertFalse(store.startsParagraph(h[1], after: h[0]), "A short breath after a sentence is not a paragraph")
        XCTAssertTrue(store.startsParagraph(h[2], after: h[1]), "A long pause breaks even mid-sentence")
        XCTAssertTrue(store.startsParagraph(h[3], after: h[2]))
        for id in [a, b, c, d] { store.finalized(id: id, session: store.session) }
        XCTAssertEqual(CaptionParagraph.make(store.history, startsParagraph: store.startsParagraph).map(\.captions.count), [2, 1, 1])
    }

    @MainActor func testDoubleClickOpensPhraseAndLeavingClosesTheCard() {
        var now = 100.0
        let store = CaptionStore(); store.begin(mode: .learning)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.wordPacing = false
        let presenter = LivePresenter(store: store, settings: settings, clock: { now })
        let id = UUID()
        store.partial(id: id, text: "leadership principles matter", session: store.session)
        presenter.setHovering(true)
        presenter.select(caption: id, index: 0, clicks: 1)
        XCTAssertEqual(presenter.selection?.showsPhrase, false)
        presenter.select(caption: id, index: 0, clicks: 2)
        XCTAssertEqual(presenter.selection?.showsPhrase, true, "The second click of a double click keeps the card and adds the phrase")
        XCTAssertTrue(words(presenter).allSatisfy(\.inShownPhrase), "The translated phrase is marked on screen")
        presenter.setHovering(false); presenter.setCardHovering(true)
        now += 1; presenter.update(now: now)
        XCTAssertNotNil(presenter.selection, "Moving onto the card keeps it open")
        presenter.setCardHovering(false)
        now += LivePresenter.cardGrace + 0.05; presenter.update(now: now)
        XCTAssertNil(presenter.selection)
        XCTAssertFalse(presenter.frozen)
    }

    @MainActor func testCurtainHoldsLinesAndShowsNewSpeechBelow() {
        var now = 100.0
        let store = CaptionStore(); store.begin(mode: .learning)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.wordPacing = false; settings.hoverPause = true
        let presenter = LivePresenter(store: store, settings: settings, clock: { now })
        let first = UUID()
        store.partial(id: first, text: "first words", session: store.session)
        presenter.setHovering(true)
        XCTAssertTrue(presenter.frozen)
        store.partial(id: first, text: "first words grow", session: store.session)
        store.partial(id: UUID(), text: "three more words", session: store.session)
        XCTAssertEqual(words(presenter).map(\.text), ["first", "words"], "Held lines do not move under the pointer")
        XCTAssertEqual(live(presenter).map(\.text), ["grow", "three", "more", "words"], "New speech continues in the curtain")
        presenter.setHovering(false)
        now += 0.1; presenter.update(now: now)
        XCTAssertEqual(words(presenter).count, 6)
        XCTAssertTrue(presenter.live.isEmpty, "The curtain rolls back up")
        XCTAssertEqual(store.metrics.learning.pauses, 1)
    }

    @MainActor func testPanelReservesCurtainRoomOnlyInLearning() {
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.fontSize = 20; settings.lineSpacing = 1.4
        XCTAssertEqual(settings.curtainHeight(mode: .learning), 13 + 3 * 28)
        XCTAssertEqual(settings.curtainHeight(mode: .translation), 0)
        XCTAssertEqual(settings.panelHeight(mode: .learning, lines: 3),
                       settings.plateHeight(mode: .learning, lines: 3) + OverlaySettings.learningHeadroom + 13 + 84)
    }

    @MainActor func testClickDuringPauseSelectsWordAndTranslationMarksUpdate() {
        var now = 100.0
        let store = CaptionStore(); store.begin(mode: .learning)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        settings.wordPacing = false; settings.hoverPause = true
        let presenter = LivePresenter(store: store, settings: settings, clock: { now })
        let id = UUID()
        store.partial(id: id, text: "practice your SQL", session: store.session)
        store.finalized(id: id, session: store.session)
        XCTAssertFalse(words(presenter).contains { $0.translationReady })
        presenter.setHovering(true)
        store.partial(id: UUID(), text: "new words arrive", session: store.session)
        presenter.select(caption: id, index: 2)
        XCTAssertEqual(presenter.selection?.word, "SQL")
        XCTAssertEqual(words(presenter).filter(\.selected).map(\.text), ["SQL"], "The clicked word is highlighted while paused")
        XCTAssertEqual(words(presenter).count, 3, "Paused text does not grow")
        store.translated(id: id, text: "тренируйте SQL", session: store.session)
        now += 0.1; presenter.update(now: now)
        XCTAssertTrue(words(presenter).allSatisfy { $0.translationReady && !$0.translationSeen })
        presenter.showPhrase()
        XCTAssertTrue(words(presenter).allSatisfy(\.translationSeen))
        XCTAssertEqual(store.metrics.learning.phrasesTranslated, 1)
        presenter.setHovering(false)
        now += LivePresenter.cardGrace + 0.1; presenter.update(now: now)
        XCTAssertNil(presenter.selection, "Leaving the subtitles closes the card")
        XCTAssertEqual(words(presenter).count, 6)
    }

    @MainActor func testTranslationModeHasNoHoverPause() {
        let store = CaptionStore(); store.begin(mode: .translation)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "RollingOverlayTests-\(UUID())")!)
        let presenter = LivePresenter(store: store, settings: settings, clock: { 100 })
        store.partial(id: UUID(), text: "hello", session: store.session)
        presenter.setHovering(true)
        XCTAssertFalse(presenter.frozen)
    }

    @MainActor private func live(_ presenter: LivePresenter) -> [LivePresenter.Word] {
        presenter.live.compactMap { if case .word(let word) = $0 { return word }; return nil }
    }

    @MainActor private func words(_ presenter: LivePresenter) -> [LivePresenter.Word] {
        presenter.english.compactMap { if case .word(let word) = $0 { return word }; return nil }
    }
}
