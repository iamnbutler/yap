import XCTest
@testable import Core

final class SilenceWatchTests: XCTestCase {
    /// A buffer of 2048 frames at 48 kHz converted to 16 kHz: about 43 ms.
    private let buffer = 2048.0 / 48000

    private func feed(_ watch: inout SilenceWatch, peak: Int16, for seconds: Double) {
        var fed = 0.0
        while fed < seconds {
            watch.feed(peak: peak, seconds: buffer)
            fed += buffer
        }
    }

    func testExactZerosWarnAfterPatience() {
        var watch = SilenceWatch()
        feed(&watch, peak: 0, for: 1.0)
        XCTAssertNil(watch.warning(muted: nil, elapsed: 1.0))
        feed(&watch, peak: 0, for: 0.6)
        XCTAssertEqual(watch.warning(muted: nil, elapsed: 1.6), SilenceWatch.unexplained)
    }

    func testRoundingNoiseStillCountsAsSilence() {
        var watch = SilenceWatch()
        feed(&watch, peak: SilenceWatch.floor, for: 2)
        XCTAssertNotNil(watch.warning(muted: nil, elapsed: 2))
    }

    func testAQuietRoomDoesNotWarn() {
        // A working mic's self-noise at about −70 dBFS RMS peaks around 30.
        var watch = SilenceWatch()
        feed(&watch, peak: 30, for: 5)
        XCTAssertNil(watch.warning(muted: nil, elapsed: 5))
    }

    func testSignalClearsTheWarningAtOnce() {
        var watch = SilenceWatch()
        feed(&watch, peak: 0, for: 3)
        XCTAssertNotNil(watch.warning(muted: nil, elapsed: 3))
        watch.feed(peak: 2000, seconds: buffer)
        XCTAssertNil(watch.warning(muted: nil, elapsed: 3.05))
    }

    func testMutingMidwayWarnsAgain() {
        var watch = SilenceWatch()
        feed(&watch, peak: 4000, for: 10)
        feed(&watch, peak: 0, for: 1)
        XCTAssertNil(watch.warning(muted: nil, elapsed: 11))
        feed(&watch, peak: 0, for: 0.6)
        XCTAssertNotNil(watch.warning(muted: nil, elapsed: 11.6))
    }

    func testAKnownMuteIsNamedAndSoonerThanAGuess() {
        var watch = SilenceWatch()
        feed(&watch, peak: 0, for: 0.4)
        XCTAssertEqual(watch.warning(muted: "Mic is muted", elapsed: 0.4), "Mic is muted")
        XCTAssertNil(watch.warning(muted: nil, elapsed: 0.4))
    }

    func testSignalDespiteAMuteFlagIsTrusted() {
        // A device whose mute flag doesn't reach the audio: don't nag.
        var watch = SilenceWatch()
        feed(&watch, peak: 3000, for: 2)
        XCTAssertNil(watch.warning(muted: "Mic is muted", elapsed: 2))
    }

    func testNoBuffersAtAllCountsAsSilence() {
        let watch = SilenceWatch()
        XCTAssertNil(watch.warning(muted: nil, elapsed: 1))
        XCTAssertEqual(watch.warning(muted: nil, elapsed: 2), SilenceWatch.unexplained)
    }

    func testPeak() {
        let samples: [Int16] = [0, -5, 3, .min, 12]
        samples.withUnsafeBufferPointer { XCTAssertEqual(SilenceWatch.peak(of: $0), .max) }
        let quiet: [Int16] = [0, -2, 1]
        quiet.withUnsafeBufferPointer { XCTAssertEqual(SilenceWatch.peak(of: $0), 2) }
    }
}
