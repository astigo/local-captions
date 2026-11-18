import XCTest
import FluidAudio
@testable import LocalCaptions

final class CaptionStoreTests: XCTestCase {
    func testUltraRevisesOnlyUnstableTail() throws {
        let vocabulary = [0: "▁We", 1: "▁use", 2: "▁neur", 3: "▁neural", 4: "▁networks", 5: "."]
        var text = UltraTranscript(vocabulary: vocabulary)
        let job = UUID()
        func update(_ ordinal: Int, previous: Int, retained: Int, stable: Int, ids: [Int], terminal: Bool = false) -> SlidingWindowTokenUpdate {
            SlidingWindowTokenUpdate(tokens: ids.map {
                TokenTiming(token: vocabulary[$0]!, tokenId: $0, startTime: 0, endTime: 1, confidence: 1)
            }, revision: SlidingWindowTokenRevision(jobID: job, ordinal: ordinal,
                previousTokenCount: previous, retainedTokenCount: retained, stableTokenCount: stable,
                window: 0..<32000, center: 0..<16000, isTerminal: terminal))
        }
        try text.apply(update(1, previous: 0, retained: 0, stable: 2, ids: [0, 1, 2]))
        XCTAssertEqual(text.text, "We use neur")
        XCTAssertEqual(text.stableText, "We use")
        try text.apply(update(2, previous: 3, retained: 2, stable: 3, ids: [3, 4]))
        XCTAssertEqual(text.text, "We use neural networks")
        XCTAssertEqual(text.stableText, "We use neural")
        XCTAssertThrowsError(try text.apply(update(3, previous: 4, retained: 1, stable: 3, ids: [4])))
        XCTAssertEqual(text.text, "We use neural networks", "Invalid revisions must not mutate the transcript")
        try text.apply(update(3, previous: 4, retained: 4, stable: 5, ids: [5], terminal: true))
        XCTAssertEqual(text.stableText, "We use neural networks.")
    }

    func testUltraWaitsForStableSentenceBeforeTranslation() throws {
        let text = "We can review the results tomorrow. Next"
        XCTAssertNil(CaptionChunking.stableBoundary(in: text, stableCharacters: 20))
        let boundary = try XCTUnwrap(CaptionChunking.stableBoundary(in: text, stableCharacters: 35))
        XCTAssertEqual(String(text[..<boundary]), "We can review the results tomorrow.")
        XCTAssertEqual(String(text[boundary...]), " Next")
    }
    func testCaptionBoundaryWaitsForACompleteWordAndPreservesTheTail() {
        XCTAssertNil(CaptionChunking.boundary(in: "neural net", maxWords: 2))
        let text = "  neural\tnetworks  process speech"
        let boundary = CaptionChunking.boundary(in: text, maxWords: 2)!
        XCTAssertEqual(String(text[..<boundary]), "  neural\tnetworks  ")
        XCTAssertEqual(String(text[boundary...]), "process speech")
    }
    @MainActor func testExpiryStartsFiveSecondsAfterTranslationAndIsIndependent() async {
        let store = CaptionStore(); store.begin(); let session = store.session
        let first = UUID(), second = UUID(), start = Date(timeIntervalSince1970: 100)
        store.partial(id: first, text: "Hello", session: session, now: start)
        store.finalized(id: first, session: session, now: start)
        store.partial(id: second, text: "Another phrase", session: session, now: start.addingTimeInterval(2))
        store.finalized(id: second, session: session, now: start.addingTimeInterval(2))
        store.expire(now: start.addingTimeInterval(10))
        XCTAssertEqual(store.captions.count, 2, "Pending English must remain until its translation is ready")
        store.translated(id: first, text: "Привет", session: session, now: start.addingTimeInterval(10))
        store.translated(id: second, text: "Другая фраза", session: session, now: start.addingTimeInterval(12))
        store.expire(now: start.addingTimeInterval(14.9))
        XCTAssertEqual(store.captions.count, 2)
        XCTAssertTrue(store.showsTranslation(for: first), "Ordinary live captions retain automatic translation")
        store.expire(now: start.addingTimeInterval(15))
        XCTAssertEqual(store.captions.map(\.id), [second])
        store.expire(now: start.addingTimeInterval(17))
        XCTAssertTrue(store.captions.isEmpty)
        XCTAssertEqual(store.history.map(\.id), [first, second], "Expiry must only affect the live view")
        store.showHistory()
        XCTAssertTrue(store.browsingHistory)
        XCTAssertTrue(store.shouldShowOverlay)
        store.returnToLive()
        XCTAssertFalse(store.shouldShowOverlay)
    }

    @MainActor func testStopRejectsLateResultsFromPreviousSession() async {
        let store = CaptionStore(); store.begin(); let old = store.session, id = UUID()
        store.partial(id: id, text: "Pending", session: old)
        store.clear(); store.begin()
        store.partial(id: id, text: "Late", session: old)
        store.translated(id: id, text: "Поздно", session: old)
        XCTAssertTrue(store.captions.isEmpty)
    }

    @MainActor func testHistoryCanBeReopenedAfterStopAndNewSessionStartsEmpty() async {
        let store = CaptionStore(); store.begin(); let session = store.session
        store.partial(id: UUID(), text: "Keep this", session: session)
        store.clear()
        store.expire()
        XCTAssertFalse(store.shouldShowOverlay)
        XCTAssertEqual(store.history.count, 1)
        store.showHistory()
        XCTAssertTrue(store.shouldShowOverlay, "Explicit history stays open until returning to live")
        store.returnToLive()
        XCTAssertFalse(store.shouldShowOverlay)
        store.begin()
        XCTAssertTrue(store.history.isEmpty)
    }

    @MainActor func testJournalPreservesFinalTranslationSourcesAndInterruptedTail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("captions-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptionStore(); store.begin(); let session = store.session
        try store.record(to: directory, title: "Review / roadmap", model: "Parakeet Ultra · 600M") { _ in XCTFail("Unexpected write failure") }
        let first = UUID(), tail = UUID()
        store.partial(id: first, text: "Initial draft", session: session)
        store.currentSources = [
            AudioSource(name: "Example Calls", bundleID: "test.calls", processID: 123, windowTitles: ["Weekly review"]),
            AudioSource(name: "", bundleID: "", processID: 456)
        ]
        store.partial(id: first, text: "Final English", session: session)
        store.finalized(id: first, session: session)
        store.translated(id: first, text: "Русский перевод", session: session)
        store.partial(id: tail, text: "Interrupted tail", session: session)
        store.clear()
        // Late translation after Stop must not enter the saved transcript.
        store.translated(id: tail, text: "LATE RESULT", session: session)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let markdown = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "md" }), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Final English"))
        XCTAssertTrue(markdown.contains("Parakeet Ultra · 600M"))
        XCTAssertTrue(markdown.contains("Русский перевод"))
        XCTAssertTrue(markdown.contains("Weekly review"))
        XCTAssertTrue(markdown.contains("Процесс 456"), "A process without an application name needs a readable fallback")
        XCTAssertTrue(markdown.contains("Interrupted tail"))
        XCTAssertFalse(markdown.contains("Initial draft"))
        XCTAssertFalse(markdown.contains("LATE RESULT"))
        let json = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "jsonl" }), encoding: .utf8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let events = try json.split(separator: "\n").map { try decoder.decode(TranscriptJournal.Event.self, from: Data($0.utf8)) }
        XCTAssertEqual(events.map(\.type), ["session_start", "english_final", "translation", "interrupted_caption", "session_end"])
        XCTAssertEqual(events[2].caption?.sources.first?.name, "Example Calls")
        XCTAssertNil(events[2].caption?.sources.last?.bundleID)
        XCTAssertEqual(events[2].caption?.russian, "Русский перевод")
        XCTAssertNotNil(events.last?.session?.endedAt)
        XCTAssertEqual(events.first?.session?.recognitionModel, "Parakeet Ultra · 600M")
    }
}
