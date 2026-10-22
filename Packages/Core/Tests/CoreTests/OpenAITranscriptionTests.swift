import XCTest
@testable import Core

/// Dictation's request is assembled by hand, so the container and the form
/// encoding are checked without the network.
final class OpenAITranscriptionTests: XCTestCase {
    func testWAVHeaderDescribesTheSamples() {
        let samples = Data(repeating: 0, count: 3200)
        let wav = WAV.pcm16(samples, sampleRate: 16000)

        XCTAssertEqual(wav.count, 44 + 3200)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.uint32(at: 4), 36 + 3200)
        XCTAssertEqual(wav.uint32(at: 24), 16000)
        XCTAssertEqual(wav.uint32(at: 28), 32000)
        XCTAssertEqual(wav.uint32(at: 40), 3200)
    }

    func testBodyCarriesModelPromptAndFile() {
        let client = OpenAITranscription(apiKey: "k", model: "m", prompt: "Hob, lane")
        let body = String(
            decoding: client.body(wav: Data("AUDIO".utf8), boundary: "B"), as: UTF8.self)

        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nm\r\n"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nHob, lane\r\n"))
        XCTAssertTrue(
            body.contains("filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\nAUDIO\r\n"))
        XCTAssertTrue(body.hasSuffix("--B--\r\n"))
    }

    func testBodyOmitsAnEmptyPrompt() {
        let client = OpenAITranscription(apiKey: "k", prompt: "")
        let body = String(decoding: client.body(wav: Data(), boundary: "B"), as: UTF8.self)
        XCTAssertFalse(body.contains("name=\"prompt\""))
    }

    func testDecodesTextAndErrors() throws {
        XCTAssertEqual(
            try OpenAITranscription.decode(Data(#"{"text":"hello"}"#.utf8), status: 200), "hello")

        XCTAssertThrowsError(
            try OpenAITranscription.decode(
                Data(#"{"error":{"message":"bad key","type":"x"}}"#.utf8), status: 401)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "OpenAI 401: bad key")
        }
    }
}

extension Data {
    fileprivate func uint32(at offset: Int) -> UInt32 {
        self[offset..<offset + 4].enumerated().reduce(0) {
            $0 | UInt32($1.element) << (8 * $1.offset)
        }
    }
}
