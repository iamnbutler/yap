import Foundation

/// Notices, while recording, that the mic is giving nothing: a soft-muted
/// input, an input volume of zero, or an app without microphone access all
/// record digital silence rather than failing, and a long dictation was lost
/// to that with no sign until the end.
///
/// Fed each buffer's peak as it arrives. Warns once the input has stayed at
/// digital silence for `patience`, and stops the moment any real signal
/// arrives, so muting midway is caught too.
public struct SilenceWatch: Sendable {
    /// A peak at or below this, in PCM16, is digital silence: about −81 dBFS.
    /// A muted or zero-volume input yields exact zeros, or a stray bit of
    /// converter rounding. A working mic in a quiet room never gets this low:
    /// the built-in mics and USB mics sit around −60 to −75 dBFS RMS of self
    /// noise, and a buffer's peak is several times its RMS, so at least 10 to
    /// 30 in PCM16. Low enough that a quiet room never trips it, high enough
    /// to ignore dither.
    public static let floor: Int16 = 3
    /// Silence for this long before warning. Long enough that the engine
    /// starting up (its first buffers can be zeros) doesn't trip it, short
    /// enough to warn before much has been said.
    public static let patience = 1.5
    /// When the device itself reports it is muted, warn after this instead:
    /// the cause is known, and only a signal arriving anyway (a device whose
    /// mute flag doesn't reach the audio) should hold it back.
    public static let knownMutePatience = 0.3

    /// Seconds of audio at the floor since the last real signal.
    public private(set) var quietFor = 0.0
    /// Seconds of audio seen at all.
    public private(set) var seen = 0.0

    public init() {}

    public mutating func feed(peak: Int16, seconds: Double) {
        seen += seconds
        quietFor = peak > Self.floor ? 0 : quietFor + seconds
    }

    /// What to tell the user, or nil while all is well.
    ///
    /// - Parameters:
    ///   - muted: why the input is muted, when the device or the system says
    ///     so ("Mic is muted"), or nil when nothing says so.
    ///   - elapsed: wall time since recording began. When no audio arrives at
    ///     all, that is how long it has been silent.
    public func warning(muted: String?, elapsed: Double) -> String? {
        let silent = seen > 0 ? quietFor : elapsed
        if let muted, silent >= Self.knownMutePatience { return muted }
        if silent >= Self.patience { return Self.unexplained }
        return nil
    }

    public static let unexplained = "No audio — is your mic muted?"

    /// The largest magnitude among `samples`.
    public static func peak(of samples: UnsafeBufferPointer<Int16>) -> Int16 {
        samples.reduce(0) { max($0, $1 == .min ? .max : abs($1)) }
    }
}
