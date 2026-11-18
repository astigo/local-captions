import Foundation
import Combine

enum OverlayPlacement: String, CaseIterable, Identifiable {
    case bottom, right
    var id: String { rawValue }
    var title: String { self == .bottom ? "Снизу по центру" : "Справа колонкой" }
}

/// Appearance of the live overlay. The panel height is derived from these values;
/// nothing stores a height of its own.
@MainActor final class OverlaySettings: ObservableObject {
    static let widthRange: ClosedRange<Double> = 360...1600
    static let lineRange = 2...6
    static let horizontalPadding: Double = 22
    static let verticalPadding: Double = 22
    static let laneGap: Double = 13
    /// Room above the plate for the word card and the pause badge in learning mode.
    static let learningHeadroom: Double = 200
    /// Lines of live text the curtain unrolls below the held lines in learning mode.
    static let curtainLines = 3

    private let defaults: UserDefaults
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "captionFontSize") } }
    @Published var width: Double { didSet { defaults.set(width, forKey: "captionOverlayWidth") } }
    @Published var lines: Int { didSet { defaults.set(lines, forKey: "captionLines") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "captionBackdrop") } }
    @Published var lineSpacing: Double { didSet { defaults.set(lineSpacing, forKey: "captionLineSpacing") } }
    @Published var placement: OverlayPlacement { didSet { defaults.set(placement.rawValue, forKey: "captionPlacement") } }
    @Published var hoverPause: Bool { didSet { defaults.set(hoverPause, forKey: "learningHoverPause") } }
    @Published var wordPacing: Bool { didSet { defaults.set(wordPacing, forKey: "wordPacing") } }
    /// Lines that currently fit; equals `lines` unless the right column fills the screen height.
    @Published var effectiveLines: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func number(_ key: String) -> Double? { let value = defaults.double(forKey: key); return value == 0 ? nil : value }
        fontSize = min(44, max(16, number("captionFontSize") ?? 22))
        width = min(Self.widthRange.upperBound, max(Self.widthRange.lowerBound, number("captionOverlayWidth") ?? 840))
        let storedLines = defaults.integer(forKey: "captionLines")
        lines = Self.lineRange.contains(storedLines) ? storedLines : 3
        opacity = min(0.95, max(0.4, number("captionBackdrop") ?? 0.74))
        lineSpacing = min(1.7, max(1.2, number("captionLineSpacing") ?? 1.36))
        placement = OverlayPlacement(rawValue: defaults.string(forKey: "captionPlacement") ?? "") ?? .bottom
        hoverPause = defaults.object(forKey: "learningHoverPause") as? Bool ?? true
        wordPacing = defaults.object(forKey: "wordPacing") as? Bool ?? true
        effectiveLines = Self.lineRange.contains(storedLines) ? storedLines : 3
    }

    var lineHeight: Double { (fontSize * lineSpacing).rounded() }
    var translationFontSize: Double { (fontSize * 0.78).rounded() }
    var translationLineHeight: Double { (translationFontSize * lineSpacing).rounded() }

    func translationLines(for lines: Int) -> Int { max(2, lines - 1) }

    /// `translationLane` is off when the translator is switched off, even in the translation mode.
    func plateHeight(mode: CaptionMode, lines: Int, translationLane: Bool? = nil) -> Double {
        var height = Self.verticalPadding + Double(lines) * lineHeight
        if translationLane ?? (mode == .translation) { height += Self.laneGap + Double(translationLines(for: lines)) * translationLineHeight }
        return height
    }

    func headroom(mode: CaptionMode) -> Double { mode == .learning ? Self.learningHeadroom : 0 }

    /// Room kept free under the plate so the curtain can unroll without moving the text above it.
    func curtainHeight(mode: CaptionMode) -> Double {
        mode == .learning ? Self.laneGap + Double(Self.curtainLines) * lineHeight : 0
    }

    /// Plate, the word card's room above it and the curtain's room below it.
    func panelHeight(mode: CaptionMode, lines: Int, translationLane: Bool? = nil) -> Double {
        plateHeight(mode: mode, lines: lines, translationLane: translationLane) + headroom(mode: mode) + curtainHeight(mode: mode)
    }

    /// Lines for a plate that should fill `available` points of height.
    func fillingLines(mode: CaptionMode, available: Double, translationLane: Bool? = nil) -> Int {
        var best = Self.lineRange.lowerBound
        for candidate in Self.lineRange.lowerBound...14 where panelHeight(mode: mode, lines: candidate, translationLane: translationLane) <= available {
            best = candidate
        }
        return best
    }
}

struct VocabularyEntry: Codable, Equatable, Identifiable {
    let word: String
    let translation: String
    let context: String
    let addedAt: Date
    var id: String { word.lowercased() }
}

/// Words saved from learning mode. A small JSON file next to the transcripts.
@MainActor final class Vocabulary: ObservableObject {
    @Published private(set) var entries: [VocabularyEntry] = []
    private let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("vocabulary.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let saved = try? decoder.decode([VocabularyEntry].self, from: data) { entries = saved }
    }

    func contains(_ word: String) -> Bool { entries.contains { $0.id == Self.key(word) } }

    @discardableResult func toggle(word: String, translation: String, context: String) -> Bool {
        let key = Self.key(word)
        if let index = entries.firstIndex(where: { $0.id == key }) { entries.remove(at: index); save(); return false }
        entries.insert(VocabularyEntry(word: key, translation: translation, context: context, addedAt: Date()), at: 0)
        save(); return true
    }

    func remove(_ entry: VocabularyEntry) { entries.removeAll { $0.id == entry.id }; save() }

    static func key(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'-")).inverted)
    }

    private func save() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("Local Captions: vocabulary not saved: \(error.localizedDescription)")
        }
    }
}
