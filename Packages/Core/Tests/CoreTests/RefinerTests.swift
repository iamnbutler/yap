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
        let openAI = try decoder.decode(Config.self, from: Data(#"{"engine":"openAI","cleanup":"openAIFast"}"#.utf8))
        XCTAssertEqual(openAI.engine, .openAI)
        XCTAssertEqual(openAI.cleanup, .openAIFast)
        let unknown = try decoder.decode(Config.self, from: Data(#"{"engine":"whisper","cleanup":"gemini"}"#.utf8))
        XCTAssertEqual(unknown.engine, .onDevice)
        XCTAssertEqual(unknown.cleanup, .appleIntelligence)
    }

    func testConfigTurnsTheOldRefineOffIntoNoCleanup() throws {
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(Config.self, from: Data(#"{"refine":false}"#.utf8)).cleanup, .off)
        XCTAssertEqual(try decoder.decode(Config.self, from: Data(#"{"refine":true}"#.utf8)).cleanup, .appleIntelligence)
    }

    func testOpenAICleanupRequestsStructuredText() throws {
        let fast = try XCTUnwrap(OpenAICleanup(.openAIFast, apiKey: "k"))
        let body = try JSONSerialization.jsonObject(
            with: fast.body(chunk: "um hi", instructions: "Clean up.")) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "gpt-6-luna")
        XCTAssertEqual((body?["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        XCTAssertEqual(body?["input"] as? String, "<dictation>\num hi\n</dictation>")
        let format = (body?["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertNil(OpenAICleanup(.appleIntelligence, apiKey: "k"))
    }

    func testOpenAICleanupReadsTheTextAndTheError() throws {
        let ok = Data(#"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"{\"text\":\"Hi.\"}"}]}]}"#.utf8)
        XCTAssertEqual(try OpenAICleanup.decode(ok, status: 200), "Hi.")
        let error = Data(#"{"error":{"message":"bad key"}}"#.utf8)
        XCTAssertThrowsError(try OpenAICleanup.decode(error, status: 401)) {
            XCTAssertEqual($0.localizedDescription, "OpenAI 401: bad key")
        }
    }
}
