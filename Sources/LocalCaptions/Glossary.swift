import Foundation

enum CaptionLanguage: String, Codable {
    case russian = "ru", english = "en"

    /// By script: the phrase is Russian when it has more Cyrillic letters than Latin ones.
    /// English terms inside Russian speech do not flip it.
    static func detect(_ text: String) -> CaptionLanguage {
        var cyrillic = 0, latin = 0
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 } else if scalar.isASCII { latin += 1 }
        }
        return cyrillic > latin ? .russian : .english
    }

    var opposite: CaptionLanguage { self == .russian ? .english : .russian }
    var label: String { self == .russian ? "RU" : "EN" }
}

/// User terms for translation, `Transcripts/glossary.txt`, one per line. "витрина = data mart" works
/// both ways; "deliverable -> результат" only from the left language to the right one, for words
/// that are ambiguous the other way. Russian terms also match their case forms.
struct Glossary {
    struct Term: Equatable {
        let russian: String
        let english: String
        /// nil: both directions.
        var only: CaptionLanguage? = nil
        func applies(to target: CaptionLanguage) -> Bool { only == nil || only == target }
    }
    let terms: [Term]

    static let seed = """
    # Термины для перевода, по одному на строку; русские слова находятся и в других падежах.
    # «витрина = data mart» работает в обе стороны,
    # «deliverable -> результат» — только с левого языка на правый.
    витрина = data mart
    дашборд = dashboard
    созвон = call
    """

    static func url(in transcripts: URL) -> URL { transcripts.appendingPathComponent("glossary.txt") }

    /// Reads the file, creating it with a few examples the first time.
    static func load(transcripts: URL) -> Glossary {
        let url = url(in: transcripts)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
            try? seed.write(to: url, atomically: true, encoding: .utf8)
        }
        return Glossary(text: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    init(text: String) {
        terms = text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let range = line.range(of: "->") ?? line.range(of: "=") else { return nil }
            let oneWay = line[range] == "->"
            let left = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty else { return nil }
            // Either order is accepted; the Cyrillic side is the Russian term.
            let leftLanguage = CaptionLanguage.detect(left)
            let term = leftLanguage == .russian ? Term(russian: left, english: right) : Term(russian: right, english: left)
            return oneWay ? Term(russian: term.russian, english: term.english, only: leftLanguage.opposite) : term
        }
    }

    /// Pairs to pass to the translator for `text` translated into `target`, using the forms found in the text.
    func pairs(in text: String, target: CaptionLanguage) -> [[String]] {
        let words = text.split(whereSeparator: { $0.isWhitespace || ",.;:!?()«»\"".contains($0) }).map(String.init)
        return terms.compactMap { term in
            guard term.applies(to: target) else { return nil }
            if target == .english {
                guard let found = Self.russianMatch(term.russian, in: words) else { return nil }
                return [found, term.english]
            }
            return text.lowercased().contains(term.english.lowercased()) ? [term.english, term.russian] : nil
        }
    }

    /// A direct answer for one clicked word, when the glossary has it.
    func word(_ word: String, target: CaptionLanguage) -> String? {
        let clean = word.trimmingCharacters(in: .punctuationCharacters)
        for term in terms where term.applies(to: target) {
            if target == .english, !term.russian.contains(" "), Self.russianMatch(term.russian, in: [clean]) != nil { return term.english }
            if target == .russian, clean.lowercased() == term.english.lowercased() { return term.russian }
        }
        return nil
    }

    /// Russian words match their other forms by stem; a phrase matches word by word, in order.
    static func russianMatch(_ term: String, in words: [String]) -> String? {
        let parts = term.lowercased().split(separator: " ").map(String.init)
        guard !parts.isEmpty, words.count >= parts.count else { return nil }
        func fits(_ word: String, _ part: String) -> Bool {
            let stem = String(part.prefix(max(3, part.count - (part.count >= 5 ? 2 : 1))))
            return word.lowercased().hasPrefix(stem) && word.count <= part.count + 3
        }
        for start in 0...(words.count - parts.count) where parts.indices.allSatisfy({ fits(words[start + $0], parts[$0]) }) {
            return words[start..<(start + parts.count)].joined(separator: " ")
        }
        return nil
    }
}
