import SwiftUI
import AppKit

/// Rolling captions: a fixed number of lines per lane, newest text at the bottom.
/// Lines above the last one never re-wrap; a new line slides the block up by exactly one line.
struct LiveOverlayView: View {
    @ObservedObject var presenter: LivePresenter
    @ObservedObject var settings: OverlaySettings
    @ObservedObject var store: CaptionStore
    var widthChanged: (Double) -> Void = { _ in }
    @State private var cardHeight: Double = 90
    @State private var plateFrame: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var learning: Bool { store.mode == .learning }
    private var lines: Int { settings.effectiveLines }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            plate
            // Reserved room under the plate: the curtain unrolls into it and rolls back up.
            Color.clear.frame(height: presenter.frozen ? 0 : settings.curtainHeight(mode: store.mode))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: presenter.frozen)
        .coordinateSpace(name: "overlay")
        .overlayPreferenceValue(SelectedWordAnchor.self) { anchor in
            GeometryReader { proxy in
                if let anchor, let selection = presenter.selection {
                    let plateTop = plateFrame?.minY ?? proxy[anchor].minY
                    WordCard(presenter: presenter, selection: selection)
                        .frame(width: 300)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { card in Color.clear.preference(key: HeightKey.self, value: card.size.height) })
                        .onPreferenceChange(HeightKey.self) { cardHeight = $0 }
                        .position(cardPosition(word: proxy[anchor], plateTop: plateTop, in: proxy.size))
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 0) {
            Lane(items: presenter.english, fontSize: settings.fontSize, weight: .medium,
                 lineHeight: settings.lineHeight, lines: lines, interactive: learning) { word, clicks in
                presenter.select(caption: word.caption, index: word.index, clicks: clicks)
            }
            if learning { curtain }
            if store.mode == .translation && store.translationActive {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1).padding(.vertical, 6)
                Lane(items: presenter.russian, fontSize: settings.translationFontSize, weight: .regular,
                     lineHeight: settings.translationLineHeight, lines: settings.translationLines(for: lines),
                     interactive: false, opacity: 0.8) { _, _ in }
            }
        }
        .padding(.horizontal, OverlaySettings.horizontalPadding)
        .padding(.vertical, OverlaySettings.verticalPadding / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(settings.opacity)))
        .background(HoverTracker { presenter.setHovering($0) })
        .overlay(alignment: .leading) { OverlayResizeHandle(left: true, changed: widthChanged).frame(width: 14) }
        .overlay(alignment: .trailing) { OverlayResizeHandle(left: false, changed: widthChanged).frame(width: 14) }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { plateFrame = proxy.frame(in: .named("overlay")) }
                .onChange(of: proxy.frame(in: .named("overlay"))) { _, frame in plateFrame = frame }
        })
        .opacity(presenter.visible ? 1 : 0)
        .animation(.easeOut(duration: 0.5), value: presenter.visible)
    }

    /// Live speech below the held lines while the pointer is over learning captions.
    private var curtain: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("эфир").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Rectangle().fill(.white.opacity(0.14)).frame(height: 1)
            }
            .frame(height: OverlaySettings.laneGap)
            Lane(items: presenter.live, fontSize: settings.fontSize, weight: .medium, lineHeight: settings.lineHeight,
                 lines: OverlaySettings.curtainLines, interactive: true) { word, clicks in
                presenter.select(caption: word.caption, index: word.index, clicks: clicks)
            }
        }
        .frame(height: presenter.frozen ? settings.curtainHeight(mode: store.mode) : 0, alignment: .top)
        .clipped()
    }

    /// The card sits above the plate, in the room kept for it, so it never hides the lines being read.
    /// It stays inside the window; only if that room is too small does it overlap the plate.
    private func cardPosition(word: CGRect, plateTop: CGFloat, in size: CGSize) -> CGPoint {
        let half: CGFloat = 150
        let x = min(max(word.midX, half + 8), size.width - half - 8)
        let above = min(word.minY, plateTop) - 8 - cardHeight / 2
        return CGPoint(x: x, y: max(cardHeight / 2 + 4, above))
    }
}

private struct Lane: View {
    let items: [LivePresenter.Item]
    let fontSize: Double
    let weight: Font.Weight
    let lineHeight: Double
    let lines: Int
    let interactive: Bool
    var opacity: Double = 1
    let tapped: (LivePresenter.Word, Int) -> Void
    @State private var offset: Double = 0
    @State private var contentHeight: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let height = Double(lines) * lineHeight
        WordFlow(lineHeight: lineHeight, spacing: fontSize * 0.22) {
            ForEach(items) { item in
                switch item {
                case .lineBreak:
                    Color.clear.frame(width: 0, height: 0).layoutValue(key: LineBreakKey.self, value: true)
                case .word(let word):
                    WordView(word: word, fontSize: fontSize, weight: weight, lineHeight: lineHeight,
                             opacity: opacity, interactive: interactive) { tapped(word, $0) }
                }
            }
        }
        .background(GeometryReader { proxy in Color.clear.preference(key: HeightKey.self, value: proxy.size.height) })
        .onPreferenceChange(HeightKey.self) { contentHeight in
            self.contentHeight = contentHeight
            // Bottom-anchored: overflow leaves through the top edge, one whole line at a time.
            // Only an ordinary one- or two-line roll slides; first text, catch-up after a pause
            // and font changes jump, so the plate never appears mid-scroll.
            let target = min(0, height - contentHeight)
            if !reduceMotion, abs(target - offset) > 0.5, abs(target - offset) <= 2 * lineHeight + 0.5, offset != 0 || target > -lineHeight - 0.5 {
                withAnimation(.easeOut(duration: 0.28)) { offset = target }
            } else {
                offset = target
            }
        }
        .onChange(of: height) { _, height in offset = min(0, height - contentHeight) }
        .offset(y: offset)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

private struct WordView: View {
    let word: LivePresenter.Word
    let fontSize: Double
    let weight: Font.Weight
    let lineHeight: Double
    let opacity: Double
    let interactive: Bool
    let tapped: (Int) -> Void

    var body: some View {
        let text = Text(word.text).font(.system(size: fontSize, weight: weight))
            .foregroundStyle(.white.opacity(word.tail ? 0.5 : opacity))
            .fixedSize()
            .padding(.horizontal, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(background))
            .overlay(alignment: .bottom) { translationMark }
            .frame(height: lineHeight)
            .anchorPreference(key: SelectedWordAnchor.self, value: .bounds) { word.selected ? $0 : nil }
        if interactive {
            // A button, not a tap gesture: the panel moves by its background, and a plain
            // gesture loses the click to window dragging.
            // The second click of a double click arrives with clickCount 2: the word card is
            // already open, and the phrase translation is added without waiting.
            Button { tapped(NSApp.currentEvent?.clickCount ?? 1) } label: { text.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Клик — перевод слова, двойной клик — перевод фразы")
        } else {
            text
        }
    }

    /// Under a phrase whose translation is ready: faint line; once opened, a blue line.
    @ViewBuilder private var translationMark: some View {
        if word.translationSeen {
            Rectangle().fill(Color(red: 0.47, green: 0.63, blue: 1).opacity(0.6)).frame(height: 1.5).offset(y: -1)
        } else if word.translationReady {
            Rectangle().fill(.white.opacity(0.22)).frame(height: 1).offset(y: -1)
        }
    }

    private var background: Color {
        if word.selected { return Color(red: 0.47, green: 0.63, blue: 1).opacity(0.35) }
        if word.corrected { return Color(red: 1, green: 0.77, blue: 0.35).opacity(0.28) }
        if word.inShownPhrase { return Color(red: 0.47, green: 0.63, blue: 1).opacity(0.16) }
        return .clear
    }
}

private struct WordCard: View {
    @ObservedObject var presenter: LivePresenter
    let selection: LivePresenter.Selection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(selection.word.trimmingCharacters(in: .punctuationCharacters)).fontWeight(.semibold)
                Text("—").foregroundStyle(.secondary)
                Text(selection.gloss ?? (selection.glossFailed
                    ? (presenter.store.translationActive ? "перевод слова недоступен" : "перевод выключен")
                    : "перевожу…"))
                    .foregroundStyle(selection.gloss == nil ? .secondary : .primary)
            }
            if selection.showsPhrase {
                Divider()
                let phrase = presenter.phrase(for: selection.caption)
                // The phrase often starts above the visible lines or continues in the curtain;
                // its original is quoted so the translation can be matched to it.
                Text(phrase?.english ?? "").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .lineLimit(4).truncationMode(.head).fixedSize(horizontal: false, vertical: true)
                Text(phrase?.russian ?? (phrase?.translationError == nil ? "Перевод фразы готовится…" : "Перевод фразы недоступен"))
                    .foregroundStyle(.white.opacity(0.88)).lineLimit(6).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if !selection.showsPhrase {
                    Button("Перевести фразу") { presenter.showPhrase() }.help("Или двойной клик по слову")
                }
                let saved = presenter.vocabulary?.contains(selection.word) ?? false
                Button(saved ? "✓ В словаре" : "★ В словарь") { presenter.toggleVocabulary() }
                    .disabled(selection.gloss == nil && !saved)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.13, green: 0.16, blue: 0.21)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        .background(HoverTracker { presenter.setCardHovering($0) })
    }
}

private struct SelectedWordAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) { value = max(value, nextValue()) }
}

struct LineBreakKey: LayoutValueKey { static let defaultValue = false }

/// Greedy word wrap on a fixed line grid. Appending words only ever changes the last line.
struct WordFlow: Layout {
    let lineHeight: Double
    let spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: Double(rows(subviews, width: width).count) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (row, entries) in rows(subviews, width: bounds.width).enumerated() {
            for entry in entries {
                subviews[entry.index].place(at: CGPoint(x: bounds.minX + entry.x, y: bounds.minY + Double(row) * lineHeight),
                                            proposal: ProposedViewSize(width: entry.width, height: lineHeight))
            }
        }
    }

    private func rows(_ subviews: Subviews, width: Double) -> [[(index: Int, x: Double, width: Double)]] {
        var rows: [[(index: Int, x: Double, width: Double)]] = [[]]
        var x = 0.0
        for index in subviews.indices {
            if subviews[index][LineBreakKey.self] {
                if !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
                continue
            }
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((index, x, size.width))
            x += size.width + spacing
        }
        if rows.count > 1, rows[rows.count - 1].isEmpty { rows.removeLast() }
        return rows[0].isEmpty && rows.count == 1 ? [] : rows
    }
}

/// Hover state for a panel that never becomes key. Does not take clicks.
struct HoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> HoverTrackingView { let view = HoverTrackingView(); view.changed = changed; return view }
    func updateNSView(_ view: HoverTrackingView, context: Context) { view.changed = changed }
}

final class HoverTrackingView: NSView {
    var changed: (Bool) -> Void = { _ in }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { changed(true) }
    override func mouseExited(with event: NSEvent) { changed(false) }
}
