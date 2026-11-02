import Foundation

/// Listens to a few seconds of you talking and says what is wrong with how the
/// mic hears you: the gain, how far away you are, the room's noise, and
/// whether you are talking into it.
///
/// One mic can't measure distance or direction directly, so each verdict
/// reads it from something that changes with it:
///
/// - **Gain**: how loud speech is, in dB of full scale, and whether it clips.
/// - **Distance**: the room. Up close, a word's end falls straight to silence;
///   far away, the room keeps ringing after it, so words fall less in the
///   100 ms after they end. Turning the gain up raises both you and the room,
///   so it can't fix this.
/// - **Noise**: speech against the room's level between words.
/// - **Aim**: talking past a mic, or into one through a hand or a screen,
///   loses the treble first. Presence (2 to 5 kHz) against body (150 to
///   400 Hz) falls as you turn away.
/// - **Direction**, only from a mic with two channels or more: which side is
///   louder, and which hears you first.
///
/// Feed it 16 kHz samples; it works in 20 ms frames and keeps the last 15 s.
public struct MicCheck: Sendable {
    public static let sampleRate = 16000.0
    static let frameLength = 320
    static let history = 750

    public enum Grade: Sendable, Equatable {
        /// Not enough speech heard to say.
        case unknown
        case good, fair, poor
    }

    public struct Verdict: Sendable, Equatable {
        public var grade: Grade
        public var advice: String

        public init(grade: Grade, advice: String) {
            self.grade = grade
            self.advice = advice
        }
    }

    public struct Report: Sendable {
        /// The newest frame's level, dBFS.
        public var level: Double = -120
        /// Recent frame levels, oldest first, dBFS.
        public var levels: [Double] = []
        /// The loudest sample in the last few seconds, dBFS.
        public var peak: Double = -120
        /// The room between words: a low percentile of frame levels, dBFS.
        public var noise: Double?
        /// Typical speech: the power mean of frames well above the noise, dBFS.
        public var speech: Double?
        /// Seconds of speech heard.
        public var spoken: Double = 0
        /// Samples at full scale.
        public var clipped = 0
        /// How far words fall 100 ms after they end, dB.
        public var fall: Double?
        /// Presence against body over speech, dB.
        public var tone: Double?
        /// Left minus right over speech, dB; nil for one channel.
        public var balance: Double?
        /// How much sooner the left channel hears you, ms; nil for one channel.
        public var lead: Double?

        public var gain = Verdict(grade: .unknown, advice: "Talk to hear the level.")
        public var distance = Verdict(grade: .unknown, advice: "Talk, with a few pauses.")
        public var room = Verdict(grade: .unknown, advice: "Listening to the room.")
        public var aim = Verdict(grade: .unknown, advice: "Talk to hear the tone.")
        public var direction: Verdict?

        public init() {}

        public var signalToNoise: Double? {
            guard let speech, let noise else { return nil }
            return speech - noise
        }
    }

    struct Frame {
        var level: Double
        var peak: Float
        var clipped: Int
        var body: Double
        var presence: Double
        var left: Double
        var right: Double
        var lead: Double?
    }

    public let channels: Int
    private var frames: [Frame] = []
    private var pending: [[Float]]
    private var body: [Biquad]
    private var presence: [Biquad]

    public init(channels: Int = 1) {
        self.channels = max(1, channels)
        pending = Array(repeating: [], count: self.channels)
        body = Array(repeating: .bandPass(low: 150, high: 400, sampleRate: Self.sampleRate), count: 1)
        presence = Array(repeating: .bandPass(low: 2000, high: 5000, sampleRate: Self.sampleRate), count: 1)
    }

    /// Adds samples, one array per channel, all the same length.
    public mutating func append(_ samples: [[Float]]) {
        guard samples.count == channels else { return }
        for c in 0..<channels { pending[c].append(contentsOf: samples[c]) }
        let length = Self.frameLength
        while pending[0].count >= length {
            let frame = (0..<channels).map { Array(pending[$0].prefix(length)) }
            for c in 0..<channels { pending[c].removeFirst(length) }
            frames.append(analyze(frame))
        }
        if frames.count > Self.history { frames.removeFirst(frames.count - Self.history) }
    }

    public mutating func reset() {
        self = MicCheck(channels: channels)
    }

    private mutating func analyze(_ frame: [[Float]]) -> Frame {
        let n = Self.frameLength
        var mono = [Float](repeating: 0, count: n)
        var peak: Float = 0
        var clipped = 0
        var power = [Double](repeating: 0, count: channels)
        for c in 0..<channels {
            for i in 0..<n {
                let s = frame[c][i]
                mono[i] += s / Float(channels)
                let a = abs(s)
                peak = max(peak, a)
                if a >= 0.989 { clipped += 1 }
                power[c] += Double(s * s)
            }
        }
        var sum = 0.0, low = 0.0, high = 0.0
        for s in mono {
            sum += Double(s * s)
            let b = body[0].process(s), p = presence[0].process(s)
            low += Double(b * b)
            high += Double(p * p)
        }
        return Frame(
            level: Self.decibels(sum / Double(n)),
            peak: peak, clipped: clipped,
            body: low / Double(n), presence: high / Double(n),
            left: power[0] / Double(n), right: power[channels > 1 ? 1 : 0] / Double(n),
            lead: channels > 1 ? Self.lead(frame[0], frame[1]) : nil)
    }

    /// The lag, in ms, at which the second channel best matches the first:
    /// positive when the first hears it sooner. Within ±1 ms, which spans
    /// any mic array narrower than about 34 cm.
    static func lead(_ a: [Float], _ b: [Float]) -> Double? {
        let span = Int(sampleRate / 1000)
        var best = 0, bestScore = -Float.infinity
        for lag in -span...span {
            var score: Float = 0
            for i in span..<(a.count - span) { score += a[i] * b[i + lag] }
            if score > bestScore { (best, bestScore) = (lag, score) }
        }
        return bestScore > 0 ? Double(best) * 1000 / sampleRate : nil
    }

    // MARK: Reading the frames

    public var report: Report {
        var report = Report()
        guard let last = frames.last else { return report }
        report.level = last.level
        report.levels = frames.map(\.level)
        report.peak = Self.decibels(Double(frames.suffix(250).map(\.peak).max() ?? 0).squared)
        report.clipped = frames.reduce(0) { $0 + $1.clipped }

        // Under 2 s, the room hasn't been heard between enough words.
        guard frames.count >= 100 else { return report }
        let sorted = frames.map(\.level).sorted()
        let noise = sorted[sorted.count / 10]
        report.noise = noise

        let threshold = max(noise + 12, -65)
        let voiced = frames.indices.filter { frames[$0].level > threshold }
        report.spoken = Double(voiced.count) * Double(Self.frameLength) / Self.sampleRate
        report.room = room(noise: noise, speech: nil)
        guard report.spoken >= 1.5 else { return report }

        let speech = Self.decibels(voiced.map { Self.power(frames[$0].level) }.reduce(0, +) / Double(voiced.count))
        report.speech = speech
        report.room = room(noise: noise, speech: speech)

        // Only the loud half of speech for tone, so quiet consonants and room
        // sound don't count.
        let loud = voiced.filter { frames[$0].level > speech - 6 }
        let presence = loud.map { frames[$0].presence }.reduce(0, +)
        let bodyPower = loud.map { frames[$0].body }.reduce(0, +)
        if bodyPower > 0, presence > 0 { report.tone = 10 * log10(presence / bodyPower) }

        report.fall = fall(speech: speech)
        report.gain = gain(speech: speech, peak: report.peak, clipped: report.clipped, fall: report.fall)
        report.distance = distance(fall: report.fall, signalToNoise: speech - noise)
        report.aim = aim(tone: report.tone, fall: report.fall)

        if channels > 1 {
            let left = loud.map { frames[$0].left }.reduce(0, +)
            let right = loud.map { frames[$0].right }.reduce(0, +)
            if left > 0, right > 0 { report.balance = 10 * log10(left / right) }
            let leads = loud.compactMap { frames[$0].lead }.sorted()
            if !leads.isEmpty { report.lead = leads[leads.count / 2] }
            report.direction = direction(balance: report.balance, lead: report.lead)
        }
        return report
    }

    /// How far, in dB, words fall in the 100 ms after they end: the 90th
    /// percentile over every frame where a loud stretch starts to fall.
    ///
    /// When you stop, the sound straight from your mouth stops at once, and
    /// what is left is the room, which decays at its own rate: about 60 dB
    /// over its reverberation time, so 12 dB in 100 ms for a typical room.
    /// Close up, you are much louder than the room and the fall is deep;
    /// far away, the room is nearly as loud as you and words smear into it.
    /// Most word ends run into the next word, so only the deepest count.
    ///
    /// It can't fall below the noise, so `distance` only judges a fall that
    /// stopped well short of it.
    ///
    /// Thresholds from macOS's voices, dry and through simulated rooms: dry
    /// fell 23 to 26 dB, a small damped room 20 to 22, a living room 11 to
    /// 18, and a long reverb 8 or 9.
    func fall(speech: Double) -> Double? {
        var falls: [Double] = []
        for i in 0..<(frames.count - 6) {
            let level = frames[i].level
            guard level > speech - 10, frames[i + 1].level < level else { continue }
            let after = (frames[i + 4].level + frames[i + 5].level + frames[i + 6].level) / 3
            falls.append(level - after)
        }
        guard falls.count >= 5 else { return nil }
        return falls.sorted()[falls.count * 9 / 10]
    }

    // MARK: Verdicts

    static let farFall = 13.0
    static let roomyFall = 19.0

    func gain(speech: Double, peak: Double, clipped: Int, fall: Double?) -> Verdict {
        let far = (fall ?? 99) < Self.farFall
        if clipped > 0 || peak > -1 {
            return Verdict(grade: .poor, advice: "Clipping. Turn the input volume down, or sit back a little.")
        }
        if speech > -10 {
            return Verdict(grade: .fair, advice: "Hot. A little less input volume leaves room for a laugh.")
        }
        if speech < -42 {
            return Verdict(
                grade: .poor,
                advice: far ? "Very quiet, and far. Move closer before turning it up." : "Very quiet. Turn the input volume up.")
        }
        if speech < -34 {
            return Verdict(
                grade: .fair, advice: far ? "Quiet. Moving closer fixes this and the echo." : "A little quiet. Turn the input volume up.")
        }
        return Verdict(grade: .good, advice: "Good level.")
    }

    func distance(fall: Double?, signalToNoise: Double) -> Verdict {
        guard let fall else {
            return Verdict(grade: .unknown, advice: "Pause between sentences to measure the room.")
        }
        // Fell as far as the noise allowed: the noise is what stopped it.
        if fall > signalToNoise - 6 {
            if fall < Self.roomyFall {
                return Verdict(grade: .unknown, advice: "Too noisy to hear the room. Quiet it, or move closer.")
            }
            return Verdict(grade: .good, advice: "Close enough. Words end cleanly.")
        }
        if fall < Self.farFall {
            return Verdict(
                grade: .poor,
                advice: "Far. The room is nearly as loud as you. Move closer; turning it up won't help.")
        }
        if fall < Self.roomyFall {
            return Verdict(grade: .fair, advice: "A bit far, or a live room. Closer will sound drier.")
        }
        return Verdict(grade: .good, advice: "Close enough. Words end cleanly.")
    }

    func room(noise: Double, speech: Double?) -> Verdict {
        guard let speech else {
            if noise > -45 { return Verdict(grade: .poor, advice: "Loud room, before you've said anything.") }
            return Verdict(grade: .unknown, advice: "Room is quiet. Now talk.")
        }
        let ratio = speech - noise
        if ratio < 15 { return Verdict(grade: .poor, advice: "Noise is close to your voice. Find the source, or move closer.") }
        if ratio < 25 { return Verdict(grade: .fair, advice: "Some background noise. Fine for dictation.") }
        return Verdict(grade: .good, advice: "Quiet room.")
    }

    /// Voices differ more than aim does: macOS's voices, dry and on axis, sat
    /// at −10 and −16 dB, and cutting the treble above 700 Hz took off only 4
    /// more. So it is lenient, and most useful watched live while turning
    /// your head.
    func aim(tone: Double?, fall: Double?) -> Verdict {
        guard let tone else { return Verdict(grade: .unknown, advice: "Talk to hear the tone.") }
        if tone < -27 {
            return Verdict(grade: .poor, advice: "Muffled. Face the mic, and clear anything between you.")
        }
        if tone < -21 {
            return Verdict(
                grade: .fair,
                advice: (fall ?? 99) < Self.roomyFall
                    ? "Dull. Probably distance; closer will brighten it." : "Dull. You may be talking past the mic.")
        }
        return Verdict(grade: .good, advice: "Clear. You're talking into it.")
    }

    func direction(balance: Double?, lead: Double?) -> Verdict? {
        guard let balance else { return nil }
        let side = balance > 0 ? "left" : "right"
        if abs(balance) > 6 {
            return Verdict(grade: .fair, advice: "Off to the \(side) channel by \(Int(abs(balance).rounded())) dB. Centre yourself, or pick one channel.")
        }
        if let lead, abs(lead) > 0.25 {
            let first = lead > 0 ? "left" : "right"
            return Verdict(grade: .good, advice: "Reaching the \(first) channel first. Slightly off centre.")
        }
        return Verdict(grade: .good, advice: "Centred between the channels.")
    }

    // MARK: Units

    static func decibels(_ power: Double) -> Double {
        power > 1e-12 ? 10 * log10(power) : -120
    }

    static func power(_ decibels: Double) -> Double {
        pow(10, decibels / 10)
    }
}

extension Double {
    fileprivate var squared: Double { self * self }
}

/// A second-order filter, after Robert Bristow-Johnson's cookbook.
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    /// Constant peak gain, centred on the geometric mean of the edges.
    static func bandPass(low: Double, high: Double, sampleRate: Double) -> Biquad {
        let centre = (low * high).squareRoot()
        let q = centre / (high - low)
        let w = 2 * Double.pi * centre / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float(alpha / a0), b1: 0, b2: Float(-alpha / a0),
            a1: Float(-2 * cos(w) / a0), a2: Float((1 - alpha) / a0))
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        (x2, x1, y2, y1) = (x1, x, y1, y)
        return y
    }
}
