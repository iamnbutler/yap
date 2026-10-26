import XCTest
@testable import Core

final class RefinerTests: XCTestCase {
    func testAcceptsACleanup() {
        XCTAssertTrue(Refiner.accepts(
            raw: "um so I ran lane check and then uh lane push",
            refined: "So I ran lane check, and then lane push."))
    }

    func testAcceptsAKeptCorrection() {
        XCTAssertTrue(Refiner.accepts(
            raw: "open the PR for next cloud no wait I mean for Parade and tag the issue",
            refined: "Open the PR for Parade, and tag the issue."))
    }

    func testAcceptsADictionarySpelling() {
        XCTAssertTrue(Refiner.accepts(
            raw: "wrangler couldn't find PG light so I switched",
            refined: "Wrangler couldn't find PGlite, so I switched.",
            terms: ["PGlite"]))
    }

    func testRejectsAnAnswer() {
        XCTAssertFalse(Refiner.accepts(
            raw: "What's the capital of France?",
            refined: "The capital of France is Paris."))
    }

    func testRejectsDoingWhatWasAsked() {
        XCTAssertFalse(Refiner.accepts(
            raw: "write me a function that sorts a list of numbers in Swift",
            refined: "func sorted(_ numbers: [Int]) -> [Int] { numbers.sorted() }"))
    }

    func testRejectsASummary() {
        XCTAssertFalse(Refiner.accepts(
            raw: "so the build broke again because wrangler couldn't find the package and I spent an hour on it",
            refined: "The build broke."))
    }

    func testRejectsEmptyForSpeech() {
        XCTAssertFalse(Refiner.accepts(raw: "hello there", refined: ""))
    }

    func testChunksAtSentencesNearTheLimit() {
        let sentence = Array(repeating: "word", count: 9).joined(separator: " ") + " end."
        let text = Array(repeating: sentence, count: 10).joined(separator: " ")
        let chunks = Refiner.chunks(of: text, limit: 30)
        // Cut at the first sentence end past two thirds of the limit.
        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.hasSuffix("end.") })
        XCTAssertEqual(chunks.joined(separator: " "), text)
    }

    func testChunksTextWithoutSentencesAtTheLimit() {
        let text = Array(repeating: "word", count: 70).joined(separator: " ")
        XCTAssertEqual(Refiner.chunks(of: text, limit: 30).map { Refiner.words($0).count }, [30, 30, 10])
    }

    func testConfigReadsTheEngineAndFallsBackFromAnUnknownOne() throws {
        let decoder = JSONDecoder()
        let openAI = try decoder.decode(Config.self, from: Data(#"{"engine":"openAI","refine":false}"#.utf8))
        XCTAssertEqual(openAI.engine, .openAI)
        XCTAssertFalse(openAI.refine)
        let unknown = try decoder.decode(Config.self, from: Data(#"{"engine":"whisper"}"#.utf8))
        XCTAssertEqual(unknown.engine, .onDevice)
        XCTAssertTrue(unknown.refine)
    }
}
