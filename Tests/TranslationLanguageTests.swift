import XCTest
@testable import LocalCaptions

final class TranslationLanguageTests: XCTestCase {
    func testRussianChoiceKeepsTheEnglishRussianPair() {
        let chosen = TranslationLanguage.russian
        XCTAssertEqual(chosen.target(for: "Let's check the retention dashboard"), .russian)
        XCTAssertEqual(chosen.target(for: "Давай проверим витрину по когортам"), .english)
    }

    func testEnglishChoiceSendsEnglishPhrasesToRussian() {
        let chosen = TranslationLanguage.english
        XCTAssertEqual(chosen.target(for: "Давай проверим витрину"), .english)
        XCTAssertEqual(chosen.target(for: "Let's check the dashboard"), .russian)
    }

    func testOtherLanguageTakesEveryPhrase() throws {
        let german = try XCTUnwrap(TranslationLanguage.named("de"))
        XCTAssertEqual(german.target(for: "Let's check the dashboard"), german)
        XCTAssertEqual(german.target(for: "Давай проверим витрину"), german)
        XCTAssertNil(german.glossaryLanguage, "the glossary holds Russian-English pairs only")
        XCTAssertEqual(TranslationLanguage.russian.glossaryLanguage, .russian)
    }

    func testStoredChoiceFallsBackToRussian() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "TranslationLanguageTests"))
        defaults.removePersistentDomain(forName: "TranslationLanguageTests")
        XCTAssertEqual(TranslationLanguage.stored(defaults), .russian)
        defaults.set("ja", forKey: TranslationLanguage.defaultsKey)
        XCTAssertEqual(TranslationLanguage.stored(defaults).name, "Japanese")
        defaults.set("xx", forKey: TranslationLanguage.defaultsKey)
        XCTAssertEqual(TranslationLanguage.stored(defaults), .russian)
    }

    func testListMatchesTheModelCard() {
        XCTAssertEqual(TranslationLanguage.all.count, 38, "33 languages and 5 dialects or minority languages")
        XCTAssertEqual(Set(TranslationLanguage.all.map(\.code)).count, TranslationLanguage.all.count)
        XCTAssertEqual(TranslationLanguage.all.prefix(2).map(\.code), ["ru", "en"])
    }
}
