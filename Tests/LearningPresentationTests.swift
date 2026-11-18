import XCTest
import SwiftUI
import AppKit
@testable import LocalCaptions

final class LearningPresentationTests: XCTestCase {
    @MainActor func testLearningKeepsBackgroundTranslationHiddenAndRevealExtendsReadingTime() {
        let store = CaptionStore(); store.begin(mode: .learning)
        let id = UUID(), start = Date(timeIntervalSince1970: 100), session = store.session
        store.partial(id: id, text: "We should check the experiment.", session: session, now: start)
        store.finalized(id: id, session: session, now: start)
        store.translated(id: id, text: "Нужно проверить эксперимент.", session: session, now: start.addingTimeInterval(1))
        XCTAssertFalse(store.showsTranslation(for: id))
        XCTAssertEqual(store.history[0].russian, "Нужно проверить эксперимент.")
        store.toggleTranslation(id: id, now: start.addingTimeInterval(4))
        XCTAssertTrue(store.showsTranslation(for: id))
        store.expire(now: start.addingTimeInterval(8.9))
        XCTAssertEqual(store.captions.count, 1)
        store.expire(now: start.addingTimeInterval(9))
        XCTAssertTrue(store.captions.isEmpty)
        store.showHistory()
        store.toggleTranslation(id: id)
        XCTAssertFalse(store.showsTranslation(for: id))
        store.toggleTranslation(id: id)
        XCTAssertTrue(store.showsTranslation(for: id))
        store.returnToLive(); store.expire(now: start.addingTimeInterval(100))
        XCTAssertTrue(store.captions.isEmpty, "Opening a historical translation must not revive it in live captions")
        store.begin(mode: .learning)
        XCTAssertTrue(store.revealedTranslations.isEmpty)
    }

    @MainActor func testClickBeforeTranslationKeepsPhraseUntilResultThenFiveSeconds() {
        let store = CaptionStore(); store.begin(mode: .learning)
        let id = UUID(), start = Date(timeIntervalSince1970: 100), session = store.session
        store.partial(id: id, text: "A pending phrase", session: session, now: start)
        store.toggleTranslation(id: id, now: start)
        store.finalized(id: id, session: session, now: start)
        store.expire(now: start.addingTimeInterval(10))
        XCTAssertEqual(store.captions.count, 1)
        store.translated(id: id, text: "Ожидающая фраза", session: session, now: start.addingTimeInterval(10))
        store.expire(now: start.addingTimeInterval(14.9))
        XCTAssertEqual(store.captions.count, 1)
        store.expire(now: start.addingTimeInterval(15))
        XCTAssertTrue(store.captions.isEmpty)
    }

    @MainActor func testHiddenPendingTranslationDoesNotKeepOrReviveOldLearningCaptions() {
        let store = CaptionStore(); store.begin(mode: .learning)
        let id = UUID(), start = Date(timeIntervalSince1970: 100), session = store.session
        store.partial(id: id, text: "A pending phrase", session: session, now: start)
        store.finalized(id: id, session: session, now: start)
        store.toggleTranslation(id: id, now: start)
        store.toggleTranslation(id: id, now: start.addingTimeInterval(1))
        XCTAssertFalse(store.showsTranslation(for: id))
        store.expire(now: start.addingTimeInterval(6))
        XCTAssertTrue(store.captions.isEmpty)
        store.translated(id: id, text: "Ожидающая фраза", session: session, now: start.addingTimeInterval(20))
        XCTAssertTrue(store.captions.isEmpty)
        XCTAssertEqual(store.history[0].russian, "Ожидающая фраза")
    }

    @MainActor func testLearningModeHearsBothLanguagesAndJournalPreservesHiddenTranslation() throws {
        XCTAssertEqual(CaptionMode.allCases.count, 3)
        XCTAssertTrue(CaptionMode.learning.translates)
        XCTAssertNil(CaptionMode.learning.languageHint, "Learning also transcribes Russian meetings")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptionStore(); store.begin(mode: .learning)
        try store.record(to: directory, title: "Learning") { _ in XCTFail("Journal failure") }
        let id = UUID(), session = store.session
        store.partial(id: id, text: "Source phrase", session: session)
        store.finalized(id: id, session: session)
        store.translated(id: id, text: "Исходная фраза", session: session)
        XCTAssertFalse(store.showsTranslation(for: id))
        store.clear()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let json = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "jsonl" }), encoding: .utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try json.split(separator: "\n").map { try decoder.decode(TranscriptJournal.Event.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.first?.session?.mode, "learning")
        XCTAssertEqual(events.first { $0.type == "translation" }?.caption?.russian, "Исходная фраза")
    }

    @MainActor func testRussianSpeechInLearningIsTranslatedToEnglishAndLabelledInTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("learning-ru-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptionStore(); store.begin(mode: .learning)
        try store.record(to: directory, title: "Встреча") { _ in XCTFail("Journal failure") }
        let ru = UUID(), en = UUID(), session = store.session
        store.partial(id: ru, text: "Скинь ссылку на витрину в канал", session: session)
        store.finalized(id: ru, session: session)
        store.translated(id: ru, text: "Post the data mart link in the channel", session: session, language: .english)
        store.partial(id: en, text: "Let's check the retention dashboard", session: session)
        store.finalized(id: en, session: session)
        store.translated(id: en, text: "Давай проверим дашборд retention", session: session)
        store.clear()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let markdown = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "md" }), encoding: .utf8)
        XCTAssertTrue(markdown.contains("**RU:** Скинь ссылку на витрину в канал"))
        XCTAssertTrue(markdown.contains("**EN:** Post the data mart link in the channel"))
        XCTAssertTrue(markdown.contains("**EN:** Let's check the retention dashboard"))
        XCTAssertTrue(markdown.contains("**RU:** Давай проверим дашборд retention"))
    }

    @MainActor func testNativePanelCanShrinkWithLongBilingualHistory() throws {
        guard ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_UI_PROBE"] == "1" else { throw XCTSkip("Opt-in AppKit layout probe") }
        _ = NSApplication.shared
        let store = CaptionStore(); store.begin()
        let now = Date(), session = store.session
        for n in 0..<60 {
            let id = UUID(), time = now.addingTimeInterval(Double(n - 60) * 15)
            store.partial(id: id, text: String(repeating: "A long English phrase. ", count: 15), session: session, now: time)
            store.translated(id: id, text: String(repeating: "Длинная русская фраза. ", count: 15), session: session, now: time)
        }
        store.expire(now: now)
        XCTAssertFalse(store.browsingHistory)
        store.showHistory()
        let panel = SubtitlePanel(contentRect: NSRect(x: 100, y: 100, width: 840, height: 1000), styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 180)
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "LocalCaptionsUIProbe")!)
        let presenter = LivePresenter(store: store, settings: settings)
        let hosting = TransparentHostingView(rootView: LiveOverlayView(presenter: presenter, settings: settings, store: store))
        panel.contentView = hosting
        defer { panel.contentView = nil; panel.close() }
        XCTAssertTrue(hosting.sizingOptions.isEmpty)
        for size in [NSSize(width: 610, height: 240), NSSize(width: 480, height: 180), NSSize(width: 900, height: 480)] {
            panel.setContentSize(size); hosting.layoutSubtreeIfNeeded()
            XCTAssertEqual(panel.frame.width, size.width, accuracy: 1)
            XCTAssertEqual(panel.frame.height, size.height, accuracy: 1)
            XCTAssertEqual(hosting.bounds.height, size.height, accuracy: 1)
        }
        if let path = ProcessInfo.processInfo.environment["LOCAL_CAPTIONS_SNAPSHOT_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            panel.setContentSize(NSSize(width: 610, height: 360))
            func snapshot(_ name: String) throws {
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            }
            let id = UUID()
            store.returnToLive()
            store.partial(id: id, text: "We should review the experiment results before making a decision.", session: session)
            store.translated(id: id, text: "Нужно рассмотреть результаты эксперимента, прежде чем принимать решение.", session: session)
            try snapshot("ordinary-live")
            store.showHistory(); try snapshot("history")
            store.begin(mode: .learning)
            store.partial(id: id, text: "We should review the experiment results before making a decision.", session: store.session)
            store.translated(id: id, text: "Нужно рассмотреть результаты эксперимента, прежде чем принимать решение.", session: store.session)
            try snapshot("learning-english")
            store.toggleTranslation(id: id); try snapshot("learning-revealed")
        }
    }
}
