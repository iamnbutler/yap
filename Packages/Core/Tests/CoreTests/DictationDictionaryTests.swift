import XCTest
@testable import Core

final class DictationDictionaryTests: XCTestCase {
    func testParsesTermsFixesAndComments() {
        let dictionary = DictationDictionary.parse(
            """
            # people and projects
            Hob

              gpuiTunes
            auto blog => autoblog
            => nothing heard
            """)

        XCTAssertEqual(dictionary.terms, ["Hob", "gpuiTunes"])
        XCTAssertEqual(dictionary.fixes.count, 1)
        XCTAssertEqual(dictionary.fixes.first?.heard, "auto blog")
        XCTAssertEqual(dictionary.fixes.first?.written, "autoblog")
    }

    func testPromptListsTheTermsOrIsAbsent() {
        XCTAssertNil(DictationDictionary().prompt)
        XCTAssertEqual(
            DictationDictionary(terms: ["Hob", "lane"]).prompt,
            "Dictated into a Claude Code terminal session. Vocabulary: Hob, lane.")
    }

    func testPromptSendsOnlyTheTopTerms() {
        let terms = (1...40).map { "term\($0)" }
        let prompt = DictationDictionary(terms: terms).prompt ?? ""
        XCTAssertTrue(prompt.contains("term25."))
        XCTAssertFalse(prompt.contains("term26"))
    }

    func testFixesMatchWholeWordsIgnoringCase() {
        let dictionary = DictationDictionary(fixes: [
            ("auto blog", "autoblog"), ("PG Lite", "PGlite"), ("Quasar", "Qwasar"),
        ])

        XCTAssertEqual(
            dictionary.apply(to: "Read the Auto Blog note on pg lite and Quasar."),
            "Read the autoblog note on PGlite and Qwasar.")
        // Not inside a longer word or a hyphenated name.
        XCTAssertEqual(dictionary.apply(to: "Quasars and quasar-ui"), "Quasars and quasar-ui")
    }

    func testReplacementIsLiteral() {
        let dictionary = DictationDictionary(fixes: [("dollar one", "$1")])
        XCTAssertEqual(dictionary.apply(to: "costs dollar one"), "costs $1")
    }

    func testAMissingFileIsAnEmptyDictionary() {
        let missing = URL(fileURLWithPath: "/nonexistent/dictionary.txt")
        XCTAssertEqual(DictationDictionary.load(from: missing), DictationDictionary())
    }
}
