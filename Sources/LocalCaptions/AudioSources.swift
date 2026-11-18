import AppKit
import CoreAudio
import ScreenCaptureKit

struct AudioSource: Codable, Equatable, Hashable {
    let name: String
    let bundleID: String?
    let processID: Int32
    var windowTitles: [String] = []
    /// Browser tab that was playing sound, when tab detection is on. Optional for older files.
    var tab: String?
    /// "Yandex Browser — вкладка «…»" or the app name with its window titles.
    var label: String {
        if let tab { return "\(name) — вкладка «\(tab)»" }
        return windowTitles.isEmpty ? name : name + " — " + windowTitles.joined(separator: "; ")
    }
    init(name: String?, bundleID: String?, processID: Int32, windowTitles: [String] = []) {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBundle = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleID = cleanBundle?.isEmpty == false ? cleanBundle : nil
        self.name = cleanName?.isEmpty == false ? cleanName! : (self.bundleID ?? "Процесс \(processID)")
        self.processID = processID; self.windowTitles = windowTitles
    }
}

/// The system mix has no per-sample process attribution. Preserve candidates, never guess a speaker.
@MainActor final class AudioSourceMonitor {
    private var task: Task<Void, Never>?
    func start(onUpdate: @escaping ([AudioSource]) -> Void) {
        stop()
        task = Task {
            var previous: [AudioSource] = [], titled: [AudioSource] = []
            var lastTitles = Date.distantPast, lastTabs = Date.distantPast
            var tabsFor: [AudioSource] = [], tabs: [Int32: String?] = [:]
            while !Task.isCancelled {
                var sources = Self.outputCandidates()
                // Window titles are optional metadata. Never prompt for screen access
                // when the user granted only system-audio recording.
                if CGPreflightScreenCaptureAccess(), !sources.isEmpty, (sources != previous || Date().timeIntervalSince(lastTitles) >= 5),
                   let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
                    previous = sources; lastTitles = Date()
                    for index in sources.indices {
                        let source = sources[index]
                        let titles = content.windows.filter { window in
                            guard window.windowLayer == 0, let owner = window.owningApplication else { return false }
                            return owner.processID == source.processID || (source.bundleID != nil && owner.bundleIdentifier == source.bundleID)
                        }.compactMap(\.title).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        sources[index].windowTitles = Array(Set(titles)).sorted().prefix(3).map { $0 }
                    }
                    titled = sources
                } else {
                    for index in sources.indices {
                        sources[index].windowTitles = titled.first { $0.processID == sources[index].processID }?.windowTitles ?? []
                    }
                }
                if BrowserTabs.enabled, BrowserTabs.trusted, !sources.isEmpty {
                    if Date().timeIntervalSince(lastTabs) >= 2 || tabsFor.map(\.processID) != sources.map(\.processID) {
                        let bundles = sources.map(\.bundleID)
                        // Accessibility calls block; keep them off the main thread.
                        let found = await Task.detached(priority: .utility) {
                            bundles.map { bundle in bundle.flatMap(BrowserTabs.mainProcess).flatMap { BrowserTabs.playingTabs(pid: $0).first } }
                        }.value
                        lastTabs = Date(); tabsFor = sources
                        for index in sources.indices { sources[index].tab = found[index] }
                        tabs = Dictionary(zip(sources.map(\.processID), found), uniquingKeysWith: { first, _ in first })
                    } else {
                        for index in sources.indices { sources[index].tab = tabs[sources[index].processID] ?? nil }
                    }
                }
                guard !Task.isCancelled else { return }
                onUpdate(sources)
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    static func outputCandidates() -> [AudioSource] {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        var sources: [AudioSource] = []
        for object in objects {
            guard integer(object, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            let pid = Int32(bitPattern: integer(object, kAudioProcessPropertyPID))
            guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            var bundleID = string(object, kAudioProcessPropertyBundleID) ?? running?.bundleIdentifier
            var name = running?.localizedName
            // Browsers play sound from an audio-service helper deep inside their bundle. That
            // helper is not a registered application, so the bundle comes from the process path.
            if let outer = ProcessBundle.outermostApp(pid: pid) {
                bundleID = outer.bundleIdentifier ?? bundleID
                name = (outer.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (outer.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? name
            }
            let source = AudioSource(name: name ?? bundleID ?? "Процесс \(pid)", bundleID: bundleID, processID: pid)
            if !sources.contains(where: { source.bundleID != nil ? $0.bundleID == source.bundleID : $0.processID == pid }) { sources.append(source) }
        }
        return sources.sorted { $0.name < $1.name }
    }
    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = property(selector), value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }
    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector), value: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
