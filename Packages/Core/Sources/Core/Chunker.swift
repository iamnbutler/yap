import Foundation

/// Where to cut a recording into chunks for the live preview: at pauses, so a
/// chunk boundary never lands mid-word.
///
/// The preview is only for show; the whole clip is transcribed again on send.
/// So this only has to be good enough that chunks read naturally, not exact.
public enum Chunker {
    /// The level is measured over windows this long.
    static let window = 0.02
    /// A chunk shorter than this has too little context to transcribe well.
    static let minimumChunk = 1.2
    /// Quiet for this long is a pause between phrases, not between words.
    static let pause = 0.45
    /// Without a pause, cut anyway, so a fast talker still sees text.
    static let maximumChunk = 10.0
    /// Quieter than this is silence however loud the speech around it was.
    static let floor = 150.0
    /// Quiet is relative to the loudest window: rooms and mics differ.
    static let quietFraction = 0.12

    /// The sample offset of the first cut in `samples`, mono PCM16 at
    /// `sampleRate` starting just after the last cut. Nil while it is too
    /// early to tell.
    ///
    /// The cut goes in the middle of the first pause after `minimumChunk`, or,
    /// past `maximumChunk` with no pause, at the quietest window of the last two
    /// seconds.
    public static func boundary(in samples: Data, sampleRate: Double) -> Int? {
        let size = Int(sampleRate * window)
        let levels: [Double] = samples.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            return stride(from: 0, to: ints.count - size + 1, by: size).map { start in
                let sum = ints[start..<start + size].reduce(0.0) { $0 + Double($1) * Double($1) }
                return (sum / Double(size)).squareRoot()
            }
        }
        guard let loudest = levels.max() else { return nil }
        let quiet = max(floor, loudest * quietFraction)

        let pauseWindows = Int((pause / window).rounded())
        let earliest = Int((minimumChunk / window).rounded())
        var run = 0
        for (index, level) in levels.enumerated() {
            run = level < quiet ? run + 1 : 0
            let cut = index - run + 1 + pauseWindows / 2
            if run >= pauseWindows, cut >= earliest {
                return cut * size
            }
        }

        let latest = Int((maximumChunk / window).rounded())
        guard levels.count >= latest else { return nil }
        let tail = (latest - Int(2 / window))..<latest
        let quietest = tail.min { levels[$0] < levels[$1] } ?? latest - 1
        return (quietest + 1) * size
    }
}
