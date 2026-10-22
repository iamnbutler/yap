import XCTest
@testable import Core

final class ChunkerTests: XCTestCase {
    private let rate = 16000.0

    /// `seconds` of a 220 Hz tone at `amplitude`, standing in for speech.
    private func tone(_ seconds: Double, amplitude: Double = 8000) -> [Int16] {
        (0..<Int(seconds * rate)).map {
            Int16(amplitude * sin(2 * .pi * 220 * Double($0) / rate))
        }
    }

    private func silence(_ seconds: Double) -> [Int16] {
        Array(repeating: 0, count: Int(seconds * rate))
    }

    private func pcm(_ parts: [Int16]...) -> Data {
        Array(parts.joined()).withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testCutsInTheMiddleOfTheFirstLongPause() throws {
        let cut = try XCTUnwrap(
            Chunker.boundary(in: pcm(tone(2), silence(0.6), tone(1)), sampleRate: rate))
        // The pause starts at 2.0s; half of 0.45s in is about 2.22s.
        XCTAssertEqual(Double(cut) / rate, 2.22, accuracy: 0.03)
    }

    func testAPauseBetweenWordsIsNotACut() {
        XCTAssertNil(Chunker.boundary(in: pcm(tone(2), silence(0.2), tone(1)), sampleRate: rate))
    }

    func testTooEarlyAPauseIsNotACut() {
        XCTAssertNil(Chunker.boundary(in: pcm(tone(0.3), silence(0.6)), sampleRate: rate))
    }

    func testNoPauseCutsAtTheQuietestSpotBeforeTheLimit() throws {
        // A dip at 9.0s, inside the last two seconds before the 10s limit.
        let samples = pcm(tone(9), tone(0.1, amplitude: 2000), tone(2))
        let cut = try XCTUnwrap(Chunker.boundary(in: samples, sampleRate: rate))
        XCTAssertEqual(Double(cut) / rate, 9.05, accuracy: 0.06)
    }

    func testStillTalkingWithNoPauseIsTooEarly() {
        XCTAssertNil(Chunker.boundary(in: pcm(tone(5)), sampleRate: rate))
    }

    func testQuietIsRelativeToTheSpeech() throws {
        // Room noise at 600 would be "speech" to an absolute threshold of 500.
        let cut = Chunker.boundary(
            in: pcm(tone(2), tone(0.6, amplitude: 600), tone(1)), sampleRate: rate)
        XCTAssertNotNil(cut)
    }
}
