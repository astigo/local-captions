import Foundation
import FluidAudio

enum CaptionMode: String, CaseIterable, Identifiable {
    case translation, transcription, learning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .translation: return "Перевод отдельной дорожкой"
        case .transcription: return "EN+RU transcription"
        case .learning: return "Обучение · EN, перевод по клику"
        }
    }
    static let menuOrder: [CaptionMode] = [.learning, .translation, .transcription]
    var shortTitle: String {
        switch self {
        case .translation: return "Перевод"
        case .transcription: return "EN+RU"
        case .learning: return "Обучение"
        }
    }
    var summary: String {
        switch self {
        case .learning: return "Английская и русская речь без перевода на экране. Клик по слову — перевод на другой язык, двойной клик — перевод фразы. Наведите курсор — строки замрут, эфир пойдёт ниже."
        case .translation: return "Речь как есть сверху, перевод отдельной дорожкой ниже. Распознаёт то же, что обучение: 25 европейских языков."
        case .transcription: return "Русская и английская речь как есть, без перевода."
        }
    }
    var translates: Bool { self != .transcription }
    /// No mode tells the recognizer the language: a hint restricts Ultra to the Latin script,
    /// and Russian, Greek or Bulgarian speech turns into Latin letters and digits. Modes differ
    /// only in how the text is shown.
    var languageHint: Language? { nil }
}
