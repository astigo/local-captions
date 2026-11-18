import XCTest
@testable import LocalCaptions

final class SourceAttributionTests: XCTestCase {
    func testAudioHelperMapsToTheOutermostBrowserBundle() {
        let helper = "/Applications/Yandex.app/Contents/Frameworks/Yandex Framework.framework/Versions/26.10.0.1877/Helpers/Yandex Helper.app/Contents/MacOS/Yandex Helper"
        XCTAssertEqual(ProcessBundle.outermostApp(path: helper)?.path, "/Applications/Yandex.app")
        XCTAssertEqual(ProcessBundle.outermostApp(path: "/Applications/Zoom.app")?.path, "/Applications/Zoom.app")
        XCTAssertNil(ProcessBundle.outermostApp(path: "/usr/bin/afplay"))
    }

    func testOwnProcessPathIsReadable() {
        XCTAssertNotNil(ProcessBundle.executablePath(pid: ProcessInfo.processInfo.processIdentifier))
    }

    func testPlayingTabLabelsInBothLanguagesAndMutedTabsAreIgnored() {
        XCTAssertEqual(BrowserTabs.playingTitle(from: "Amazon BI Engineer Interview - YouTube - Audio playing"), "Amazon BI Engineer Interview - YouTube")
        XCTAssertEqual(BrowserTabs.playingTitle(from: "Созвон по retention – воспроизводится аудио"), "Созвон по retention")
        XCTAssertEqual(BrowserTabs.playingTitle(from: "Lecture, playing audio"), "Lecture")
        XCTAssertNil(BrowserTabs.playingTitle(from: "Music - Audio muted"))
        XCTAssertNil(BrowserTabs.playingTitle(from: "Видео — звук отключён"))
        XCTAssertNil(BrowserTabs.playingTitle(from: "Ordinary tab"))
    }

    func testSourceLabelPrefersTheTabAndOldFilesStillDecode() throws {
        var source = AudioSource(name: "Yandex Browser", bundleID: "ru.yandex.desktop.yandex-browser", processID: 1, windowTitles: ["Window"])
        XCTAssertEqual(source.label, "Yandex Browser — Window")
        source.tab = "Interview - YouTube"
        XCTAssertEqual(source.label, "Yandex Browser — вкладка «Interview - YouTube»")
        let legacy = #"{"name":"Zoom","bundleID":"us.zoom.xos","processID":7,"windowTitles":[]}"#
        XCTAssertNil(try JSONDecoder().decode(AudioSource.self, from: Data(legacy.utf8)).tab)
    }
}
