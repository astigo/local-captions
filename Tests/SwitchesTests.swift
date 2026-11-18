import XCTest
@testable import LocalCaptions

final class SwitchesTests: XCTestCase {
    private let keys = ["captionMode", "translationEnabled", "subtitlesVisible", "microphoneEnabled", "recognitionModel",
                        "ultraChunkSeconds", "ultraChunkSecondsBilingual"]
    private var saved: [String: Any] = [:]
    override func setUp() { for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) } }
    override func tearDown() {
        for key in keys { if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    }

    func testBilingualModesGetTheirOwnLongerWindow() {
        UserDefaults.standard.removeObject(forKey: "ultraChunkSeconds"); UserDefaults.standard.removeObject(forKey: "ultraChunkSecondsBilingual")
        XCTAssertEqual(RecognitionTuning.ultraChunkSeconds(for: .translation), 0.64)
        XCTAssertEqual(RecognitionTuning.ultraChunkSeconds(for: .learning), 0.96, "Russian needs a longer window")
        XCTAssertEqual(RecognitionTuning.ultraChunkSeconds(for: .transcription), 0.96)
        RecognitionTuning.setUltraChunkSeconds(1.28, for: .learning)
        XCTAssertEqual(RecognitionTuning.ultraChunkSeconds(for: .learning), 1.28)
        XCTAssertEqual(RecognitionTuning.ultraChunkSeconds(for: .translation), 0.64)
    }

    @MainActor func testOldEnRuModeBecomesLearningWithoutTranslation() {
        UserDefaults.standard.set("transcription", forKey: "captionMode")
        UserDefaults.standard.set(true, forKey: "translationEnabled")
        let engine = CaptionEngine()
        XCTAssertEqual(engine.selectedMode, .learning)
        XCTAssertFalse(engine.translationEnabled)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "captionMode"), "learning")
    }

    @MainActor func testSwitchesWorkWhileStoppedAndAreRemembered() {
        let engine = CaptionEngine()
        engine.setSubtitlesVisible(false)
        engine.setTranslationEnabled(!engine.translationEnabled)
        let translation = engine.translationEnabled
        engine.setMicrophoneEnabled(true)
        let again = CaptionEngine()
        XCTAssertFalse(again.subtitlesVisible)
        XCTAssertEqual(again.translationEnabled, translation)
        XCTAssertTrue(again.microphoneEnabled)
        XCTAssertEqual(again.selectedModel, .ultra)
    }

    @MainActor func testTranslationLaneDisappearsWhenTranslationIsOff() {
        let settings = OverlaySettings(defaults: UserDefaults(suiteName: "SwitchesTests-\(UUID())")!)
        XCTAssertGreaterThan(settings.plateHeight(mode: .translation, lines: 3), settings.plateHeight(mode: .translation, lines: 3, translationLane: false))
        XCTAssertEqual(settings.plateHeight(mode: .translation, lines: 3, translationLane: false), settings.plateHeight(mode: .learning, lines: 3))
    }

    @MainActor func testStatusIconShowsTheDotOnlyWhileRecording() {
        let idle = AppDelegate.statusImage(dot: nil)
        XCTAssertEqual(idle?.isTemplate, true)
        let recording = AppDelegate.statusImage(dot: .systemRed)
        XCTAssertEqual(recording?.isTemplate, false)
        XCTAssertGreaterThan(recording?.size.width ?? 0, idle?.size.width ?? 0)
    }
}
