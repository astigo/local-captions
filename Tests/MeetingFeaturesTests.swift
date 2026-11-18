import XCTest
import AppKit
import AVFoundation
@testable import LocalCaptions

final class MeetingFeaturesTests: XCTestCase {
    func testDerivedHeightKeepsBottomEdgeAndCentreOnScreen() {
        let screen = NSRect(x: -1500, y: -100, width: 1500, height: 900)
        let frame = NSRect(x: -1000, y: 50, width: 712, height: 360)
        let taller = OverlayGeometry.fittedFrame(frame, width: 712, height: 500, screen: screen)
        XCTAssertEqual(taller.minY, frame.minY); XCTAssertEqual(taller.midX, frame.midX); XCTAssertEqual(taller.height, 500)
        let huge = OverlayGeometry.fittedFrame(frame, width: 2000, height: 2000, screen: screen)
        XCTAssertEqual(huge, screen)
        let nearTop = OverlayGeometry.fittedFrame(NSRect(x: -1000, y: 700, width: 712, height: 100), width: 712, height: 300, screen: screen)
        XCTAssertEqual(nearTop.maxY, screen.maxY)
    }

    func testHistoryParagraphsAlignTranslationsAndKeepStableIDs() {
        let start = Date(timeIntervalSince1970: 100)
        let a = Caption(id: UUID(), english: "We will review", russian: "Мы рассмотрим", firstSeenAt: start, finalized: true)
        let b = Caption(id: UUID(), english: "the experiment results.", russian: "результаты эксперимента.", firstSeenAt: start.addingTimeInterval(5), finalized: true)
        let c = Caption(id: UUID(), english: "Another topic.", firstSeenAt: start.addingTimeInterval(25), finalized: true)
        let mic = Caption(id: UUID(), english: "Личная реплика", finalized: true, channel: "microphone")
        let paragraphs = CaptionParagraph.make([a, b, mic, c])
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].id, a.id)
        XCTAssertEqual(paragraphs[0].original, "We will review the experiment results.")
        XCTAssertEqual(paragraphs[0].translation, "Мы рассмотрим результаты эксперимента.")
        var translated = c; translated.russian = "Другая тема."
        XCTAssertEqual(CaptionParagraph.make([a, b, translated]).map(\.id), paragraphs.map(\.id))
    }

    func testSilenceCounterUsesSignalRatherThanCallbackArrival() {
        let input = LiveAudioInput()
        input.append([Float](repeating: 0.1, count: 80), now: 100)
        input.append([Float](repeating: 0, count: 80), now: 279)
        XCTAssertEqual(input.signalIdle(now: 279), 179)
        XCTAssertEqual(input.signalIdle(now: 280), MicrophoneTranscription.quietSeconds)
        input.append([Float](repeating: 0.1, count: 80), now: 281)
        XCTAssertEqual(input.signalIdle(now: 282), 1)
        input.finish()
    }

    func testMicrophoneSpoolHasBoundedChunksWithCaptureTimesAndKeepsUncommittedAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("microphone-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = try MicrophoneSpool(directory: directory, segmentSeconds: 2)
        let start = Date(timeIntervalSince1970: 1000)
        spool.append(samples: [Float](repeating: 0.1, count: 80000), at: start)
        try spool.finish()
        XCTAssertEqual(spool.count, 3)
        let first = try XCTUnwrap(spool.next())
        XCTAssertEqual(first.startedAt, start); XCTAssertEqual(first.endedAt, start.addingTimeInterval(2))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.sidecar.path))
        let file = try AVAudioFile(forReading: first.url)
        XCTAssertEqual(file.length, 32000)
        // Taking a job must not erase the source before journal commit.
        XCTAssertEqual(try spool.next()?.id, first.id)
        try spool.committed(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try spool.next()?.startedAt, start.addingTimeInterval(2))
    }

    @MainActor func testDelayedMicrophoneTextMergesAfterStopWithoutAppearingOnOverlay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("microphone-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptionStore(); store.begin(mode: .translation)
        try store.record(to: directory, title: "Channels", translator: "HY-MT2", microphone: true) { _ in XCTFail("Write failure") }
        let start = Date()
        let remote = UUID(); store.partial(id: remote, text: "Remote speech", session: store.session, now: start.addingTimeInterval(2))
        store.finalized(id: remote, session: store.session)
        store.prepareToFinish()
        let me = Caption(id: UUID(), english: "Моя реплика", firstSeenAt: start.addingTimeInterval(600), finalized: true,
            original: "Моя реплика", channel: "microphone", audioStartAt: start, audioEndAt: start.addingTimeInterval(1))
        try store.addMicrophone(me)
        XCTAssertEqual(store.history.first?.id, me.id)
        XCTAssertTrue(store.captions.isEmpty)
        store.finishJournal()
        XCTAssertThrowsError(try store.addMicrophone(me))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let markdown = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "md" }), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Я · микрофон")); XCTAssertTrue(markdown.contains("Моя реплика"))
        XCTAssertTrue(markdown.contains("HY-MT2"))
        XCTAssertLessThan(try XCTUnwrap(markdown.range(of: "Моя реплика")).lowerBound,
                          try XCTUnwrap(markdown.range(of: "Remote speech")).lowerBound)
        let events = try String(contentsOf: XCTUnwrap(files.first { $0.pathExtension == "jsonl" }), encoding: .utf8)
        XCTAssertTrue(events.contains("microphone_transcription")); XCTAssertTrue(events.contains("audioStartAt"))
    }

    @MainActor func testMicrophoneUsesUltraAndCanBeTurnedOff() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: "microphoneEnabled"), model = defaults.object(forKey: "recognitionModel")
        defer { defaults.set(enabled, forKey: "microphoneEnabled"); defaults.set(model, forKey: "recognitionModel") }
        let engine = CaptionEngine(); engine.setMicrophoneEnabled(true)
        XCTAssertTrue(engine.microphoneEnabled); XCTAssertEqual(engine.selectedModel, .ultra)
        engine.setMicrophoneEnabled(false)
        XCTAssertFalse(engine.microphoneEnabled)
    }
}
