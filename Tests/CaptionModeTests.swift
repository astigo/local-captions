import XCTest
import AppKit
@testable import LocalCaptions

final class CaptionModeTests: XCTestCase {
    @MainActor func testTranscriptionExpiresWithoutTranslationAndRetainsHistory() {
        let store = CaptionStore(); store.begin(mode: .transcription)
        let id = UUID(), session = store.session, now = Date()
        store.partial(id: id, text: "Результаты эксперимента и conversion rate", session: session)
        store.finalized(id: id, session: session, now: now)
        store.translated(id: id, text: "Unexpected translation", session: session)
        XCTAssertNil(store.history.first?.russian)
        store.expire(now: now.addingTimeInterval(4.9))
        XCTAssertEqual(store.captions.count, 1)
        store.expire(now: now.addingTimeInterval(5))
        XCTAssertTrue(store.captions.isEmpty)
        XCTAssertEqual(store.history.first?.original, "Результаты эксперимента и conversion rate")
        store.clear(); store.showHistory()
        XCTAssertTrue(store.shouldShowOverlay)
        XCTAssertEqual(store.mode, .transcription)
    }

    @MainActor func testModeSelectsAMultilingualModelAndRemovesScriptRestriction() {
        let defaults = UserDefaults.standard
        let mode = defaults.object(forKey: "captionMode"), model = defaults.object(forKey: "recognitionModel")
        defer { defaults.set(mode, forKey: "captionMode"); defaults.set(model, forKey: "recognitionModel") }
        let engine = CaptionEngine()
        engine.selectMode(.transcription)
        XCTAssertEqual(engine.selectedMode, .transcription)
        XCTAssertEqual(engine.selectedModel, .ultra)
        XCTAssertNil(engine.selectedMode.languageHint)
        engine.selectMode(.translation)
        XCTAssertTrue(engine.selectedMode.translates)
        XCTAssertNotNil(engine.selectedMode.languageHint)
    }

    @MainActor func testBilingualJournalHasOriginalTextAndNoMissingTranslationMessage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("captions-modes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptionStore(); store.begin(mode: .transcription)
        try store.record(to: directory, title: "Русский и English", model: "Parakeet Ultra · 600M") { _ in XCTFail("Journal error") }
        let id = UUID()
        store.partial(id: id, text: "Обсудим retention и качество данных", session: store.session)
        store.finalized(id: id, session: store.session)
        store.clear()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let markdown = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "md" }), encoding: .utf8)
        XCTAssertTrue(markdown.contains("**Текст:** Обсудим retention и качество данных"))
        XCTAssertFalse(markdown.contains("Перевод не завершён"))
        XCTAssertFalse(markdown.contains("**EN:**"))
        let json = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "jsonl" }), encoding: .utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try json.split(separator: "\n").map { try decoder.decode(TranscriptJournal.Event.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.map(\.type), ["session_start", "transcription_final", "session_end"])
        XCTAssertEqual(events.first?.session?.mode, "transcription")
        XCTAssertEqual(events[1].caption?.original, "Обсудим retention и качество данных")
        XCTAssertEqual(events[1].schemaVersion, 3)
    }

    func testResizingKeepsTheOppositeEdgeAndStaysOnScreen() {
        let screen = NSRect(x: -1500, y: 0, width: 1500, height: 900)
        let frame = NSRect(x: -1300, y: 120, width: 840, height: 200)
        let left = OverlayGeometry.dragFrame(frame, delta: -200, left: true, screen: screen)
        XCTAssertEqual(left.maxX, frame.maxX)
        XCTAssertEqual(left.width, 1040)
        let right = OverlayGeometry.dragFrame(frame, delta: 900, left: false, screen: screen)
        XCTAssertEqual(right.minX, frame.minX)
        XCTAssertEqual(right.maxX, screen.maxX)
        let narrow = OverlayGeometry.dragFrame(frame, delta: -900, left: false, screen: screen)
        XCTAssertEqual(narrow.width, 360, "The right-hand column may be narrower than the bottom plate")
        let slider = OverlayGeometry.widthFrame(frame, width: 2000, screen: screen)
        XCTAssertEqual(slider.width, 1500)
        XCTAssertEqual(slider.minY, frame.minY)
        XCTAssertEqual(slider.height, frame.height)
    }
}
