import Foundation
import FluidAudio

enum CaptionMode: String, CaseIterable, Identifiable {
    case translation, transcription, learning
    var id: String { rawValue }
    var title: String {
        switch self {
        case .translation: return "EN -> RU translate"
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
        case .translation: return "Английский сверху, русский перевод отдельной дорожкой ниже."
        case .transcription: return "Русская и английская речь как есть, без перевода."
        }
    }
    var translates: Bool { self != .transcription }
    /// Only the translation mode is English-only; learning and EN+RU hear both languages.
    var languageHint: Language? { self == .translation ? .english : nil }
}
