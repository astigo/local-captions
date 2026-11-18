import AppKit
import SwiftUI

/// Window -> setting changes must never become setting -> window commands.
/// Coalesce slider requests and read the current width only when applying them.
@MainActor final class OverlayWidthBinding {
    private var reflectingWindow = false
    private var scheduled = false
    private let currentWidth: () -> Double
    private let apply: (Double) -> Void
    private let schedule: (@escaping AppRunLoop.Action) -> Void

    init(currentWidth: @escaping () -> Double, apply: @escaping (Double) -> Void,
         schedule: @escaping (@escaping AppRunLoop.Action) -> Void = AppRunLoop.perform) {
        self.currentWidth = currentWidth; self.apply = apply; self.schedule = schedule
    }

    func settingsChanged() {
        guard !reflectingWindow, !scheduled else { return }
        scheduled = true
        schedule { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.apply(self.currentWidth())
        }
    }

    func windowResized(to width: Double, save: (Double) -> Void) {
        reflectingWindow = true
        defer { reflectingWindow = false }
        save(width)
    }
}

enum OverlayGeometry {
    /// Keeps the bottom edge and the horizontal centre, clamped to the visible screen.
    static func fittedFrame(_ frame: NSRect, width: Double, height: Double, screen: NSRect) -> NSRect {
        let width = min(width, screen.width), height = min(height, screen.height)
        let x = max(screen.minX, min(frame.midX - width / 2, screen.maxX - width))
        let y = max(screen.minY, min(frame.minY, screen.maxY - height))
        return NSRect(x: x, y: y, width: width, height: height)
    }
    static func widthFrame(_ frame: NSRect, width: Double, screen: NSRect) -> NSRect {
        let width = min(max(width, min(360, screen.width)), min(1600, screen.width))
        let x = max(screen.minX, min(frame.midX - width / 2, screen.maxX - width))
        return NSRect(x: x, y: frame.minY, width: width, height: frame.height)
    }
    static func dragFrame(_ frame: NSRect, delta: Double, left: Bool, screen: NSRect) -> NSRect {
        let available = left ? frame.maxX - screen.minX : screen.maxX - frame.minX
        let limit = min(1600, max(0, available))
        let width = max(min(360, limit), min(limit, frame.width + (left ? -delta : delta)))
        return NSRect(x: left ? frame.maxX - width : frame.minX, y: frame.minY, width: width, height: frame.height)
    }
}

struct OverlayResizeHandle: NSViewRepresentable {
    let left: Bool
    let changed: (Double) -> Void
    func makeNSView(context: Context) -> WidthHandleView {
        let view = WidthHandleView(); view.left = left; view.changed = changed
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(left ? "Левый край: изменить ширину субтитров" : "Правый край: изменить ширину субтитров")
        return view
    }
    func updateNSView(_ view: WidthHandleView, context: Context) { view.changed = changed }
}

final class WidthHandleView: NSView {
    var left = false
    var changed: (Double) -> Void = { _ in }
    private var startX: CGFloat = 0
    private var startFrame = NSRect.zero
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    private var hovered = false { didSet { needsDisplay = true } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func draw(_ dirtyRect: NSRect) {
        // The grip appears only under the pointer, so it never competes with the text.
        guard hovered else { return }
        NSColor.white.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 1.5, y: bounds.midY - 17, width: 3, height: 34), xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func mouseDown(with event: NSEvent) { startX = NSEvent.mouseLocation.x; startFrame = window?.frame ?? .zero }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let frame = OverlayGeometry.dragFrame(startFrame, delta: NSEvent.mouseLocation.x - startX, left: left, screen: screen.visibleFrame)
        window.setFrame(frame, display: true)
        changed(frame.width)
    }
}
