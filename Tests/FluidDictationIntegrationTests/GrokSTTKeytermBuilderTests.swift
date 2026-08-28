@testable import FluidVoice_Debug
import XCTest

final class GrokSTTKeytermBuilderTests: XCTestCase {
    func testReplacementsNotTriggersAndVocabularyTextNotAliases() {
        let terms = GrokSTTKeytermBuilder.terms(
            replacementTexts: ["FluidVoice", "ignore-me-trigger-should-not-appear"],
            vocabularyTexts: ["Parakeet"]
        )
        XCTAssertEqual(terms, ["FluidVoice", "ignore-me-trigger-should-not-appear", "Parakeet"])

        let fromEntries = GrokSTTKeytermBuilder.terms(
            replacementTexts: ["Canonical"],
            vocabularyTexts: ["TermText"]
        )
        XCTAssertFalse(fromEntries.contains("trigger"))
        XCTAssertFalse(fromEntries.contains("alias"))
        XCTAssertEqual(fromEntries.first, "Canonical")
        XCTAssertEqual(fromEntries.last, "TermText")
    }

    func testCap100AndDropOver50NotTruncate() {
        let replacements = (0..<120).map { "term-\($0)" }
        let terms = GrokSTTKeytermBuilder.terms(replacementTexts: replacements, vocabularyTexts: [])
        XCTAssertEqual(terms.count, 100)
        XCTAssertEqual(terms.first, "term-0")
        XCTAssertEqual(terms.last, "term-99")

        let tooLong = String(repeating: "a", count: 51)
        let mixed = GrokSTTKeytermBuilder.terms(
            replacementTexts: ["ok", tooLong, "also-ok"],
            vocabularyTexts: []
        )
        XCTAssertEqual(mixed, ["ok", "also-ok"])
        XCTAssertFalse(mixed.contains { $0.count > 50 })
        XCTAssertFalse(mixed.contains(where: { $0.hasPrefix("aaaa") && $0.count == 50 }))
    }

    func testStableOrderAndCaseInsensitiveDedup() {
        let terms = GrokSTTKeytermBuilder.terms(
            replacementTexts: ["Hello", "hello", "World"],
            vocabularyTexts: ["HELLO", "extra"]
        )
        XCTAssertEqual(terms, ["Hello", "World", "extra"])
    }
}
