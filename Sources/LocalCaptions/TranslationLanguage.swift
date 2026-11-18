import Foundation

/// A language HY-MT2 translates into. `name` goes into the model prompt, `title` into the settings.
struct TranslationLanguage: Hashable, Identifiable, Sendable {
    let code: String
    let name: String
    let title: String
    var id: String { code }
    var label: String { code.uppercased() }

    static let russian = TranslationLanguage(code: "ru", name: "Russian", title: "Русский")
    static let english = TranslationLanguage(code: "en", name: "English", title: "Английский")

    /// The languages of the HY-MT2 model card, Russian and English first.
    static let all: [TranslationLanguage] = [russian, english] + [
        ("uk", "Ukrainian", "Украинский"), ("de", "German", "Немецкий"), ("fr", "French", "Французский"),
        ("es", "Spanish", "Испанский"), ("it", "Italian", "Итальянский"), ("pt", "Portuguese", "Португальский"),
        ("pl", "Polish", "Польский"), ("cs", "Czech", "Чешский"), ("nl", "Dutch", "Нидерландский"),
        ("tr", "Turkish", "Турецкий"), ("kk", "Kazakh", "Казахский"), ("zh", "Chinese", "Китайский"),
        ("zh-Hant", "Traditional Chinese", "Китайский традиционный"), ("yue", "Cantonese", "Кантонский"),
        ("ja", "Japanese", "Японский"), ("ko", "Korean", "Корейский"), ("ar", "Arabic", "Арабский"),
        ("he", "Hebrew", "Иврит"), ("fa", "Persian", "Персидский"), ("hi", "Hindi", "Хинди"),
        ("bn", "Bengali", "Бенгальский"), ("ur", "Urdu", "Урду"), ("gu", "Gujarati", "Гуджарати"),
        ("mr", "Marathi", "Маратхи"), ("ta", "Tamil", "Тамильский"), ("te", "Telugu", "Телугу"),
        ("th", "Thai", "Тайский"), ("vi", "Vietnamese", "Вьетнамский"), ("id", "Indonesian", "Индонезийский"),
        ("ms", "Malay", "Малайский"), ("tl", "Filipino", "Филиппинский"), ("km", "Khmer", "Кхмерский"),
        ("my", "Burmese", "Бирманский"), ("mn", "Mongolian", "Монгольский"), ("bo", "Tibetan", "Тибетский"),
        ("ug", "Uyghur", "Уйгурский"),
    ].map { TranslationLanguage(code: $0.0, name: $0.1, title: $0.2) }

    static func named(_ code: String) -> TranslationLanguage? { all.first { $0.code == code } }

    static let defaultsKey = "translationLanguage"
    /// The choice in the settings; read at every translation, so a change applies at once.
    static func stored(_ defaults: UserDefaults = .standard) -> TranslationLanguage {
        named(defaults.string(forKey: defaultsKey) ?? "") ?? russian
    }

    /// Where a phrase goes: into this language, or, when the phrase is already in it, into English
    /// (into Russian when English is chosen). With Russian chosen this is the old EN <-> RU rule.
    func target(for text: String) -> TranslationLanguage {
        guard CaptionLanguage.detect(text).rawValue == code else { return self }
        return self == .english ? .russian : .english
    }

    /// The glossary holds Russian-English pairs, so it applies only to these two targets.
    var glossaryLanguage: CaptionLanguage? { CaptionLanguage(rawValue: code) }
}
