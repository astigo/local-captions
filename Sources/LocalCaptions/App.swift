import AppKit
import SwiftUI
import Combine

@main struct LocalCaptionsApp {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--benchmark"), let index = CommandLine.arguments.firstIndex(of: "--benchmark"), CommandLine.arguments.count > index + 2 {
            await Benchmark.run(audioPath: CommandLine.arguments[index + 1], runtimePath: CommandLine.arguments[index + 2])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Caption/history content never owns the panel's native dimensions.
        sizingOptions = []
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = CaptionEngine()
    private lazy var settings = OverlaySettings()
    private lazy var presenter = LivePresenter(store: engine.store, settings: settings)
    private lazy var vocabulary = Vocabulary(directory: engine.transcriptsDirectory)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var panel: SubtitlePanel!
    private var settingsWindow: NSWindow?
    private var controlsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var timer: Timer?
    private var widthBinding: OverlayWidthBinding?
    private var subscriptions = Set<AnyCancellable>()
    private var demoTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let applicationMenu = NSMenu()
        let rootItem = NSMenuItem(); applicationMenu.addItem(rootItem)
        let submenu = NSMenu()
        let controlsItem = NSMenuItem(title: "Управление", action: #selector(showControlsAction), keyEquivalent: "l")
        controlsItem.target = self; submenu.addItem(controlsItem)
        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(showSettingsAction), keyEquivalent: ",")
        settingsItem.target = self; submenu.addItem(settingsItem)
        let historyItem = NSMenuItem(title: "История сеанса", action: #selector(showHistoryAction), keyEquivalent: "h")
        historyItem.keyEquivalentModifierMask = [.command, .shift]
        historyItem.target = self; submenu.addItem(historyItem)
        let quitItem = NSMenuItem(title: "Завершить Local Captions", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; submenu.addItem(quitItem); rootItem.submenu = submenu
        NSApplication.shared.mainMenu = applicationMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ControlPopover(engine: engine, store: engine.store,
            openHistory: { [weak self] in self?.showHistory() },
            openSettings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.quit() }))
        updateStatus()
        engine.$active.combineLatest(engine.$busy).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        engine.$error.combineLatest(engine.$saveError).sink { [weak self] error, saveError in
            guard error != nil || saveError != nil else { return }
            DispatchQueue.main.async { self?.showControls() }
        }.store(in: &subscriptions)

        presenter.vocabulary = vocabulary
        presenter.translateWord = { [weak engine] word, context in
            guard let engine else { throw CaptionsError.message("Переводчик не запущен") }
            return try await engine.translateWord(word, context: context)
        }
        panel = SubtitlePanel(contentRect: NSRect(x: 0, y: 0, width: settings.width, height: 200),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.title = "Субтитры · Local Captions"
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.isMovableByWindowBackground = true
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.contentView = TransparentHostingView(rootView: LiveOverlayView(presenter: presenter, settings: settings,
            store: engine.store, widthChanged: { [weak self] in self?.settings.width = $0 }))
        _ = panel.setFrameAutosaveName("LocalCaptionsOverlay")
        if !panel.setFrameUsingName("LocalCaptionsOverlay") { place(settings.placement) }
        layoutPanel()

        widthBinding = OverlayWidthBinding(currentWidth: { [weak self] in self?.settings.width ?? 840 },
            apply: { [weak self] _ in self?.layoutPanel() })
        settings.$width.dropFirst().sink { [weak self] _ in self?.widthBinding?.settingsChanged() }.store(in: &subscriptions)
        settings.$placement.dropFirst().sink { [weak self] placement in
            DispatchQueue.main.async { self?.place(placement) }
        }.store(in: &subscriptions)
        Publishers.MergeMany(settings.$fontSize.map { _ in () }.eraseToAnyPublisher(),
                             settings.$lines.map { _ in () }.eraseToAnyPublisher(),
                             settings.$lineSpacing.map { _ in () }.eraseToAnyPublisher(),
                             engine.store.$mode.map { _ in () }.eraseToAnyPublisher(),
                             engine.store.$translationActive.map { _ in () }.eraseToAnyPublisher())
            .dropFirst(5)
            .sink { [weak self] in DispatchQueue.main.async { self?.layoutPanel() } }
            .store(in: &subscriptions)
        // Hidden subtitles keep recording; the panel simply stays off screen.
        presenter.$visible.combineLatest(engine.$subtitlesVisible).map { $0 && $1 }.removeDuplicates().sink { [weak self] visible in
            DispatchQueue.main.async {
                guard let self else { return }
                // A faded plate stays ordered briefly so the fade is visible, then leaves the screen.
                if visible { self.panel.orderFrontRegardless() }
                else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if !(self.presenter.visible && self.engine.subtitlesVisible) { self.panel.orderOut(nil) }
                    }
                }
            }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.engine.store.expire() }
        }
        // The menu bar icon can be hidden behind the notch when the bar is full,
        // so controls never depend on it: a small window opens at launch and on reopen.
        showControls()
        if CommandLine.arguments.contains("--demo") { demo() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await engine.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }

    private func updateStatus() {
        statusItem.button?.title = ""
        statusItem.button?.image = Self.statusImage(dot: engine.active ? .systemRed : (engine.busy ? .systemOrange : nil))
        statusItem.button?.toolTip = engine.active ? "Local Captions · идёт запись" : (engine.busy ? "Local Captions · запуск…" : "Local Captions · остановлено")
    }

    /// The captions bubble alone; a red dot while recording, an orange one while starting or stopping.
    static func statusImage(dot: NSColor?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "Local Captions")?
            .withSymbolConfiguration(configuration) else { return nil }
        guard let dot else { symbol.isTemplate = true; return symbol }
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            // Drawn at display time, so the bubble follows the menu bar's light or dark appearance.
            let bubble = NSRect(x: 0, y: 0, width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: bubble)
            NSColor.labelColor.set()
            bubble.fill(using: .sourceAtop)
            let radius: CGFloat = 3.5
            let center = NSPoint(x: rect.maxX - radius - 0.5, y: rect.maxY - radius - 0.5)
            // A clear ring separates the dot from the bubble outline.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: center.x - radius - 1.5, y: center.y - radius - 1.5, width: (radius + 1.5) * 2, height: (radius + 1.5) * 2)).fill()
            NSGraphicsContext.restoreGraphicsState()
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Local Captions"
        return image
    }

    @objc private func togglePopover() {
        if controlsWindow?.isVisible == true { controlsWindow?.orderOut(nil) }
        popover.isShown ? popover.performClose(nil) : showPopover()
    }
    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    private func showControls() {
        popover.performClose(nil)
        if controlsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ControlPopover(engine: engine, store: engine.store,
                openHistory: { [weak self] in self?.showHistory() },
                openSettings: { [weak self] in self?.showSettings() },
                quit: { [weak self] in self?.quit() })))
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.title = "Local Captions"
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("LocalCaptionsControls")
            if window.frame.origin == .zero { window.center() }
            controlsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func showControlsAction() { showControls() }
    @objc private func showHistoryAction() { showHistory() }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            // The hosting controller sizes the window to the SwiftUI content, so nothing is clipped.
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(engine: engine, settings: settings,
                demo: { [weak self] in self?.demo() }, openTranscripts: { [weak self] in self?.openTranscripts() })))
            window.styleMask = [.titled, .closable]
            window.title = "Настройки Local Captions"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showHistory() {
        popover.performClose(nil)
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "История сеанса"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HistoryView(store: engine.store, vocabulary: vocabulary))
            window.setFrameAutosaveName("LocalCaptionsHistory")
            if window.frame.origin == .zero { window.center() }
            historyWindow = window
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    private func openTranscripts() {
        do {
            try FileManager.default.createDirectory(at: engine.transcriptsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(engine.transcriptsDirectory)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Overlay geometry

    /// The panel is as tall as the plate needs, plus room for the word card in learning mode.
    private func layoutPanel() {
        guard let panel, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let mode = engine.store.mode
        let lines = settings.placement == .right
            ? settings.fillingLines(mode: mode, available: screen.height - 40, translationLane: mode == .translation && engine.store.translationActive)
            : settings.lines
        if settings.effectiveLines != lines { settings.effectiveLines = lines }
        let height = settings.panelHeight(mode: mode, lines: lines, translationLane: mode == .translation && engine.store.translationActive)
        let frame = OverlayGeometry.fittedFrame(panel.frame, width: settings.width, height: height, screen: screen)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func place(_ placement: OverlayPlacement) {
        guard let panel, let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        if placement == .right, settings.width > 560 { settings.width = 440 }
        if placement == .bottom, settings.width < 560 { settings.width = 840 }
        let width = min(settings.width, screen.width - 40)
        let x = placement == .bottom ? screen.midX - width / 2 : screen.maxX - width - 20
        let y = placement == .bottom ? screen.minY + 65 : screen.minY + 20
        panel.setFrame(NSRect(x: x, y: y, width: width, height: panel.frame.height), display: true)
        layoutPanel()
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        widthBinding?.windowResized(to: window.frame.width) { width in
            if abs(settings.width - width) > 0.5 { settings.width = width }
        }
    }

    // MARK: Demo

    @objc private func demo() {
        guard !engine.active, !engine.busy else { return }
        demoTask?.cancel()
        let store = engine.store, mode = engine.selectedMode
        store.begin(mode: mode)
        let session = store.session
        let script: [(String, String)] = mode == .transcription ? [
            ("Давай быстро пройдёмся по дашборду retention за прошлую неделю.", ""),
            ("I think it's related to the new onboarding flow.", ""),
            ("Да, давай проверим воронку по когортам.", "")
        ] : [
            ("And they'll ask you something easy, like give me the total amount of orders all time.",
             "И вас попросят о чём-то простом: например, показать общую сумму заказов за всё время."),
            ("Then as they increase in difficulty, it'll be something like give me the top five orders created last week.",
             "Потом вопросы усложнятся: скажем, вывести пять крупнейших заказов за прошлую неделю."),
            ("So remember to practice your SQL.", "Так что не забудьте потренировать SQL.")
        ]
        demoTask = Task { @MainActor in
            for (english, russian) in script {
                let id = UUID(), words = english.split(separator: " ")
                var shown = 0
                while shown < words.count {
                    shown = min(words.count, shown + 3)
                    store.partial(id: id, text: words.prefix(shown).joined(separator: " "), session: session)
                    try? await Task.sleep(for: .seconds(0.96))
                    if Task.isCancelled { return }
                }
                store.finalized(id: id, session: session)
                if mode.translates, !russian.isEmpty {
                    try? await Task.sleep(for: .seconds(0.6))
                    store.translated(id: id, text: russian, session: session)
                }
                try? await Task.sleep(for: .seconds(0.4))
            }
        }
    }
}
