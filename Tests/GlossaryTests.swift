import XCTest
@testable import LocalCaptions

final class GlossaryTests: XCTestCase {
    func testLanguageIsDecidedByScriptAndEnglishTermsDoNotFlipRussian() {
        XCTAssertEqual(CaptionLanguage.detect("Давай проверим retention dashboard по когортам"), .russian)
        XCTAssertEqual(CaptionLanguage.detect("Let's check the retention dashboard"), .english)
        XCTAssertEqual(CaptionLanguage.detect("SQL"), .english)
        XCTAssertEqual(CaptionLanguage.russian.opposite, .english)
    }

    func testTermsMatchRussianCaseFormsAndWorkInBothDirections() {
        let glossary = Glossary(text: Glossary.seed + "\npush the deadline back = сдвинуть дедлайн\n# comment = ignored")
        XCTAssertEqual(glossary.terms.count, 4)
        XCTAssertEqual(glossary.pairs(in: "Скинь ссылку на витрину, я посмотрю после созвона.", target: .english),
                       [["витрину", "data mart"], ["созвона", "call"]])
        XCTAssertEqual(glossary.pairs(in: "The data mart is ready", target: .russian), [["data mart", "витрина"]])
        XCTAssertEqual(glossary.pairs(in: "Предлагаю сдвинуть дедлайн на неделю", target: .english), [["сдвинуть дедлайн", "push the deadline back"]])
        XCTAssertEqual(glossary.word("витрины,", target: .english), "data mart")
        XCTAssertEqual(glossary.word("Dashboard", target: .russian), "дашборд")
        XCTAssertNil(glossary.word("витамин", target: .english), "A different word with a similar start is not a match")
    }

    func testOneWayLinesApplyOnlyFromTheLeftLanguage() {
        let glossary = Glossary(text: "deliverable -> результат\nоценка -> estimate\nвитрина = data mart")
        XCTAssertEqual(glossary.pairs(in: "The main deliverable is a dashboard", target: .russian), [["deliverable", "результат"]])
        XCTAssertTrue(glossary.pairs(in: "Хороший результат", target: .english).isEmpty, "A general Russian word is not forced into the term")
        XCTAssertEqual(glossary.pairs(in: "Дай оценку задачи", target: .english), [["оценку", "estimate"]])
        XCTAssertTrue(glossary.pairs(in: "We need an estimate", target: .russian).isEmpty)
        XCTAssertEqual(glossary.word("витрину", target: .english), "data mart")
        XCTAssertNil(glossary.word("результат", target: .english))
    }

    func testGlossaryFileIsCreatedWithExamplesOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(Glossary.load(transcripts: directory).terms.first, Glossary.Term(russian: "витрина", english: "data mart"))
        try "созвон = meeting".write(to: Glossary.url(in: directory), atomically: true, encoding: .utf8)
        XCTAssertEqual(Glossary.load(transcripts: directory).terms, [Glossary.Term(russian: "созвон", english: "meeting")])
    }
}
