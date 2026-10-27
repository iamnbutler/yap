import Foundation
import Testing

@testable import Core

@Suite struct MicCheckTests {
    /// Words: 300 ms of a buzzy vowel-ish tone, then 400 ms of pause, over a
    /// faint hiss. `rt60` adds a room: after each word, noise starting `wet`
    /// dB under it and falling 60 dB over `rt60` seconds, which is what a
    /// room's reverberation looks like frame by frame.
    static func talk(
        seconds: Double = 8, loudness: Float = 0.1, hiss: Float = 0.0005,
        rt60: Double = 0, wet: Double = -6, clip: Bool = false
    ) -> [Float] {
        let rate = MicCheck.sampleRate
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            let since = t.truncatingRemainder(dividingBy: 0.7)
            var s: Float = 0
            if since < 0.3 {
                // A 140 Hz voice with harmonics, so both bands get energy.
                for h in 1...30 { s += Float(sin(2 * .pi * 140 * Double(h) * t)) / Float(h) }
                s *= loudness * 0.5
            } else if rt60 > 0 {
                let decay = wet - 60 * (since - 0.3) / rt60
                s = Float.random(in: -1...1, using: &rng) * loudness * Float(pow(10, decay / 20))
            }
            s += Float.random(in: -1...1, using: &rng) * hiss
            return clip ? max(-1, min(1, s * 20)) : s
        }
    }

    static func report(_ samples: [Float]) -> MicCheck.Report {
        var check = MicCheck()
        // In 2048-sample buffers, as the tap delivers them.
        for start in stride(from: 0, to: samples.count, by: 2048) {
            check.append([Array(samples[start..<min(start + 2048, samples.count)])])
        }
        return check.report
    }

    @Test func closeAndDryIsGood() {
        let report = Self.report(Self.talk())
        #expect(report.gain.grade == .good)
        #expect(report.distance.grade == .good)
        #expect(report.room.grade == .good)
        #expect((report.fall ?? 0) > MicCheck.roomyFall)
    }

    @Test func roomReverbReadsAsFar() {
        let report = Self.report(Self.talk(rt60: 0.6))
        #expect(report.distance.grade == .poor)
        #expect((report.fall ?? 99) < MicCheck.farFall)
    }

    @Test func quietButCloseAsksForGain() {
        let report = Self.report(Self.talk(loudness: 0.004, hiss: 0.00002))
        #expect(report.gain.grade == .poor)
        #expect(report.gain.advice.contains("Turn the input volume up"))
        #expect(report.distance.grade == .good)
    }

    @Test func clippingSaysTurnDown() {
        let report = Self.report(Self.talk(clip: true))
        #expect(report.clipped > 0)
        #expect(report.gain.grade == .poor)
    }

    @Test func noiseNearTheVoiceIsPoor() {
        let report = Self.report(Self.talk(loudness: 0.02, hiss: 0.02))
        #expect(report.room.grade == .poor)
    }

    @Test func silenceGivesNoVerdicts() {
        let report = Self.report([Float](repeating: 0.0001, count: 16000 * 4))
        #expect(report.speech == nil)
        #expect(report.gain.grade == .unknown)
    }

    @Test func secondChannelGivesDirection() {
        let voice = Self.talk()
        // Right is 9 dB down and 6 samples late.
        let right = [Float](repeating: 0, count: 6) + voice.dropLast(6).map { $0 * 0.35 }
        var check = MicCheck(channels: 2)
        for start in stride(from: 0, to: voice.count, by: 2048) {
            let end = min(start + 2048, voice.count)
            check.append([Array(voice[start..<end]), Array(right[start..<end])])
        }
        let report = check.report
        #expect(abs((report.balance ?? 0) - 9.1) < 0.5)
        #expect(abs((report.lead ?? 0) - 0.375) < 0.01)
        #expect(report.direction?.advice.contains("left") == true)
    }
}
