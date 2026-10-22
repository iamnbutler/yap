@preconcurrency import AVFoundation
import AppKit
import Core
import Observation
import Synchronization

/// Hold Right Command, speak, release: OpenAI transcribes the clip and Yap
/// types the text into whatever app was frontmost when the key went down.
///
/// Or tap it: a press shorter than `tapLimit` latches the recording on, hands
/// free, and the next tap sends it. Holding a key through a long thought is
/// tiring, and one key with two gestures needs no mode setting.
///
/// OpenAI rather than on-device SpeechAnalyzer: a round trip of under a second
/// buys accuracy on technical speech, and a misheard word here is typed
/// straight into someone's prompt.
@MainActor
@Observable
final class Yap {
    enum State: String {
        case idle, recording, transcribing
    }

    private(set) var state: State = .idle
    private(set) var detail = Yap.ready
    /// Recording hands free, after a tap, rather than for as long as the key
    /// is held.
    private(set) var latched = false

    private static let ready = "Hold Right Command to dictate, or tap to start and tap to send"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if !enabled { cancel() }
        }
    }

    /// Press Return after typing, so the dictation is sent rather than left to
    /// review.
    var submits: Bool {
        didSet { UserDefaults.standard.set(submits, forKey: Self.submitsKey) }
    }

    private static let enabledKey = "enabled"
    private static let submitsKey = "submits"
    /// Overrides the model: `defaults write dev.yap.Yap model ...`. Spellings
    /// live in `DictationDictionary.file`, not here.
    private static let modelKey = "model"

    /// 16 kHz mono PCM16 is what the transcription models resample to anyway;
    /// sending more is upload time for nothing.
    private static let sampleRate = 16000.0
    /// A press shorter than this is a tap, which latches the recording on.
    private static let tapLimit = Duration.milliseconds(300)
    /// Shorter than this is not worth a round trip.
    private static let minimumSeconds = 0.3
    /// A latched recording sends itself after this. Ten minutes of 16 kHz
    /// PCM16 is about 19 MB, under the endpoint's 25 MB limit, and a latch
    /// that is still on after that long was most likely forgotten.
    private static let latchLimit = Duration.seconds(600)
    /// Peak below this is a room with nobody talking. Transcription models fill
    /// silence with stock phrases ("Thank you."), and typing one into a prompt
    /// is worse than typing nothing.
    private static let silencePeak: Int16 = 500

    @ObservationIgnored private let key = PushToTalk()
    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let recorder = PCMRecorder()
    @ObservationIgnored private var target: NSRunningApplication?
    @ObservationIgnored private var chorded = false
    @ObservationIgnored private var pressedAt = ContinuousClock.now
    /// Bumped by every recording, so the latch limit never ends a newer one.
    @ObservationIgnored private var recording = 0
    /// Bumped by a cancel, so a transcript already in flight is dropped
    /// instead of typed. Not by a new press: dictating again while the last
    /// clip is still transcribing must not lose it.
    @ObservationIgnored private var turn = 0

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Self.enabledKey: true, Self.submitsKey: false])
        enabled = defaults.bool(forKey: Self.enabledKey)
        submits = defaults.bool(forKey: Self.submitsKey)
    }

    /// Without Accessibility the key monitor hears nothing and typing is
    /// refused, so the menu says so rather than looking merely inert.
    private(set) var trusted = false

    func start() {
        trusted = PushToTalk.ensureAccessibilityPermission()
        key.onDown = { [weak self] in self?.begin() }
        key.onUp = { [weak self] in self?.end() }
        key.onChord = { [weak self] in self?.chorded = true }
        key.start()
    }

    /// Re-measured when the menu opens: you have often just come back from
    /// System Settings.
    func refreshTrust() {
        trusted = PushToTalk.ensureAccessibilityPermission(prompt: false)
    }

    private func begin() {
        guard enabled else { return }
        chorded = false
        pressedAt = .now
        // The press that will end a latched recording; key-up does the rest.
        guard state != .recording else { return }

        recording += 1
        target = NSWorkspace.shared.frontmostApplication
        recorder.reset()

        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1,
                interleaved: true)
        else { return }
        do {
            try capture.start(format: format) { [recorder] buffer in
                recorder.append(buffer)
            }
            state = .recording
            detail = "Listening…"
        } catch {
            detail = "Microphone failed: \(error.localizedDescription)"
            state = .idle
        }
    }

    private func end() {
        guard state == .recording else { return }
        if chorded {
            // A shortcut. Mid-latch it is just you using the keyboard, and the
            // recording carries on; otherwise there was never a dictation.
            if latched { return }
            capture.stop()
            recorder.reset()
            return finish(Self.ready)
        }
        if !latched, pressedAt.duration(to: .now) < Self.tapLimit {
            latched = true
            detail = "Recording hands free. Tap Right Command to send."
            NSSound(named: "Tink")?.play()
            let recording = recording
            Task {
                try? await Task.sleep(for: Self.latchLimit)
                guard recording == self.recording, latched, state == .recording else { return }
                send()
            }
            return
        }
        send()
    }

    private func send() {
        if latched {
            latched = false
            NSSound(named: "Pop")?.play()
        }
        capture.stop()
        state = .idle
        let samples = recorder.take()
        let seconds = Double(samples.count) / 2 / Self.sampleRate

        guard seconds >= Self.minimumSeconds else { return finish("Too short to send") }
        guard PCMRecorder.peak(of: samples) >= Self.silencePeak else {
            return finish("Heard nothing")
        }
        guard let pid = target?.processIdentifier else { return finish("No app to type into") }

        state = .transcribing
        detail = "Transcribing \(String(format: "%.1f", seconds))s…"
        let turn = turn
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: Self.modelKey) ?? OpenAITranscription.defaultModel
        // Read per clip, like the key, so an edit applies to the next dictation.
        let dictionary = DictationDictionary.load()
        let submits = submits

        Task {
            do {
                // Read per clip, so a key changed in secrets.env needs no relaunch.
                let client = OpenAITranscription(
                    apiKey: try Secrets.openAIAPIKey(), model: model, prompt: dictionary.prompt)
                let started = ContinuousClock.now
                let heard = try await client.transcribe(
                    wav: WAV.pcm16(samples, sampleRate: Int(Self.sampleRate)))
                let text = dictionary.apply(to: heard)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsed = started.duration(to: .now)
                guard turn == self.turn else { return }
                guard !text.isEmpty else { return finish("Heard nothing") }

                // A trailing space so the next dictation does not fuse onto
                // this one's last word.
                try await TextInjector.type(submits ? text : text + " ", into: pid, submit: submits)
                finish("Typed \(text.count) characters (\(Self.format(elapsed)) round trip)")
            } catch {
                guard turn == self.turn else { return }
                finish(error.localizedDescription)
            }
        }
    }

    private func cancel() {
        turn += 1
        latched = false
        if state == .recording { capture.stop() }
        state = .idle
        detail = Self.ready
    }

    /// Ends a clip. A transcript can land after the next recording has
    /// started, and must not knock that one back to idle.
    private func finish(_ detail: String) {
        self.detail = detail
        if state != .recording { state = .idle }
    }

    private static func format(_ duration: Duration) -> String {
        let ms = duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return "\(ms)ms"
    }
}

/// Collects PCM16 from the realtime audio thread.
///
/// A class of its own rather than state on `Yap`, because the tap closure
/// runs off the main actor and must not touch it. The mutex is uncontended
/// except at the hand-off at key-up.
private final class PCMRecorder: Sendable {
    private let data = Mutex(Data())

    func reset() {
        data.withLock { $0 = Data() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData else { return }
        let bytes = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        let start = UnsafeRawPointer(channel[0]).assumingMemoryBound(to: UInt8.self)
        data.withLock { $0.append(start, count: bytes) }
    }

    func take() -> Data {
        data.withLock { data in
            defer { data = Data() }
            return data
        }
    }

    static func peak(of samples: Data) -> Int16 {
        samples.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).reduce(0) { max($0, $1 == .min ? .max : abs($1)) }
        }
    }
}
