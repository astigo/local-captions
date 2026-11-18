import AppKit
import ApplicationServices
import Darwin

/// Maps any process, including unregistered helpers, to the application bundle that contains it.
enum ProcessBundle {
    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The outermost `.app` in the path: a browser's audio helper lives deep inside the browser bundle.
    static func outermostApp(path: String) -> URL? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app")
    }

    static func outermostApp(pid: Int32) -> Bundle? {
        guard let path = executablePath(pid: pid), let url = outermostApp(path: path) else { return nil }
        return Bundle(url: url)
    }
}

/// Finds the browser tab that is playing sound through the Accessibility tree.
/// Chromium browsers and Safari mark such a tab in its accessible name; the exact wording
/// differs by browser and language, so matching is deliberately broad and testable.
enum BrowserTabs {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "detectBrowserTab") }
        set { UserDefaults.standard.set(newValue, forKey: "detectBrowserTab") }
    }
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds the app to Accessibility.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static let playingMarkers = ["audio playing", "playing audio", "воспроизводится", "воспроизведение звука", "звук воспроизвод"]
    static let mutedMarkers = ["muted", "отключ", "выключ", "без звука"]

    /// The tab title without the audio marker, or nil if the label does not say the tab is playing.
    static func playingTitle(from label: String) -> String? {
        let lower = label.lowercased()
        guard playingMarkers.contains(where: lower.contains), !mutedMarkers.contains(where: lower.contains) else { return nil }
        var title = label
        for separator in [" - ", " – ", " — ", ", "] {
            if let range = title.range(of: separator, options: .backwards),
               playingMarkers.contains(where: title[range.upperBound...].lowercased().contains) {
                title = String(title[..<range.lowerBound]); break
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    struct Tab { let label: String; let role: String }

    /// Tab-like elements of every window of the application, with all their text attributes joined.
    static func tabs(pid: Int32, budget: Int = 3000) -> [Tab] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var queue: [(AXUIElement, Int)] = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, 0) }
        var result: [Tab] = [], visited = 0
        while !queue.isEmpty, visited < budget {
            let (element, depth) = queue.removeFirst(); visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
            if role == "AXTab" || subrole == "AXTabButton" || (role == kAXRadioButtonRole as String && isInTabGroup(element)) {
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
                    .compactMap { attribute(element, $0) as? String }.filter { !$0.isEmpty }
                var seen = Set<String>()
                let joined = label.filter { seen.insert($0).inserted }.joined(separator: " | ")
                if !joined.isEmpty { result.append(Tab(label: joined, role: role + (subrole.isEmpty ? "" : "/" + subrole))) }
                continue
            }
            guard depth < 14 else { continue }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] { queue.append((child, depth + 1)) }
        }
        return result
    }

    static func playingTabs(pid: Int32) -> [String] {
        var titles: [String] = []
        for tab in tabs(pid: pid) {
            for part in tab.label.components(separatedBy: " | ") {
                if let title = playingTitle(from: part), !titles.contains(title) { titles.append(title); break }
            }
        }
        return titles
    }

    /// Main application process for a bundle id; tabs live there, not in the audio helper.
    static func mainProcess(bundleID: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { $0.activationPolicy == .regular }?.processIdentifier
    }

    /// A plain-text report of every tab label, for tuning the matcher on a new browser.
    static func diagnostic() -> String {
        var lines = ["Local Captions · вкладки через Универсальный доступ", "Доступ: \(trusted ? "есть" : "нет")", ""]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let tabs = tabs(pid: app.processIdentifier)
            guard !tabs.isEmpty else { continue }
            lines.append("## \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?"))")
            for tab in tabs {
                let mark = tab.label.components(separatedBy: " | ").contains { playingTitle(from: $0) != nil } ? "▶︎ " : "  "
                lines.append("\(mark)[\(tab.role)] \(tab.label)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func isInTabGroup(_ element: AXUIElement) -> Bool {
        guard let parent = attribute(element, kAXParentAttribute) else { return false }
        return (attribute(parent as! AXUIElement, kAXRoleAttribute) as? String) == kAXTabGroupRole as String
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
