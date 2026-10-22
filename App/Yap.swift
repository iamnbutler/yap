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

    /// The newest transcripts, newest first, whether or not they are kept on
    /// disk. What the menu copies from.
    private(set) var recent: [Transcript] = []
    static let recentLimit = 5

    /// Re-read before every clip, so a hand edit to config.json applies to the
    /// next dictation; the menu writes it back through `keepsTranscripts`.
    private(set) var config: Config

    var keepsTranscripts: Bool {
        get { config.keepTranscripts }
        set {
            config.keepTranscripts = newValue
            do { try config.save() } catch { detail = "Couldn't save settings: \(error.localizedDescription)" }
        }
    }

    @ObservationIgnored private let log = TranscriptLog()

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
    @ObservationIgnored private lazy var overlay = Overlay { [recorder] in recorder.level }
    /// Transcribes chunks for the overlay while recording. Display only: the
    /// typed text always comes from the whole clip.
    @ObservationIgnored private var live: Task<Void, Never>?
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

        do {
            config = try Config.load()
        } catch {
            config = Config()
            detail = "config.json won't parse, using defaults: \(error.localizedDescription)"
        }
        if config.keepTranscripts {
            log.prune(keepingDays: config.retentionDays)
            recent = log.recent(Self.recentLimit)
        }
    }

    func copy(_ transcript: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript.text, forType: .string)
    }

    func openTranscriptsFolder() {
        try? FileManager.default.createDirectory(
            at: log.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(log.directory)
    }

    /// Writes the defaults out first if there is no file yet, so there is
    /// always something to edit.
    func openConfig() {
        if !FileManager.default.fileExists(atPath: Config.file.path) {
            try? config.save()
        }
        NSWorkspace.shared.open(Config.file)
    }

    /// Kept before anything else can go wrong with it. Typing is the step that
    /// fails (a focus change, an app that will not come forward), and a long
    /// dictation lost to that is the reason this exists.
    private func remember(_ transcript: Transcript) {
        recent.insert(transcript, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        guard config.keepTranscripts else { return }
        do {
            try log.append(transcript)
            log.prune(keepingDays: config.retentionDays)
        } catch {
            detail = "Couldn't save the transcript: \(error.localizedDescription)"
        }
    }

    /// Without Accessibility the key monitor hears nothing and typing is
    /// refused, so the menu says so rather than looking merely inert.
    private(set) var trusted = false

    func start() {
        trusted = PushToTalk.ensureAccessibilityPermission()
        // A native menu has no "on open" hook to re-measure from, so poll
        // until the grant lands; the warning item disappears when it does.
        if !trusted {
            Task {
                while !trusted {
                    try? await Task.sleep(for: .seconds(2))
                    refreshTrust()
                }
            }
        }
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
        if let reloaded = try? Config.load() { config = reloaded }

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
            if config.overlay {
                overlay.begin(recording)
                startLive()
            }
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
            stopLive()
            return finish(Self.ready)
        }
        if !latched, pressedAt.duration(to: .now) < Self.tapLimit {
            latched = true
            detail = "Recording hands free. Tap Right Command to send."
            NSSound(named: "Tink")?.play()
            overlay.update(recording, phase: .handsFree)
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
        live?.cancel()
        live = nil
        state = .idle
        let samples = recorder.take()
        let seconds = Double(samples.count) / 2 / Self.sampleRate
        let shown = recording
        let overlay = overlay

        guard seconds >= Self.minimumSeconds else {
            overlay.hide(shown)
            return finish("Too short to send")
        }
        guard PCMRecorder.peak(of: samples) >= Self.silencePeak else {
            overlay.hide(shown)
            return finish("Heard nothing")
        }
        guard let pid = target?.processIdentifier else {
            overlay.hide(shown)
            return finish("No app to type into")
        }

        state = .transcribing
        overlay.update(shown, phase: .transcribing)
        detail = "Transcribing \(String(format: "%.1f", seconds))s…"
        let turn = turn
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: Self.modelKey) ?? OpenAITranscription.defaultModel
        // Read per clip, like the key, so an edit applies to the next dictation.
        let dictionary = DictationDictionary.load()
        let submits = submits
        let app = target?.localizedName

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
                guard !text.isEmpty else {
                    overlay.hide(shown)
                    return finish("Heard nothing")
                }

                var transcript = Transcript(text: text, app: app)
                // Cancelled while in flight: not typed, but still kept.
                guard turn == self.turn else { return remember(transcript) }
                overlay.update(shown, text: text)
                do {
                    // A trailing space so the next dictation does not fuse
                    // onto this one's last word.
                    try await TextInjector.type(
                        submits ? text : text + " ", into: pid, submit: submits)
                    transcript.typed = true
                    overlay.update(shown, phase: .typed)
                    overlay.hide(shown, after: .seconds(1.5))
                    finish("Typed \(text.count) characters (\(Self.format(elapsed)) round trip)")
                } catch {
                    NSSound(named: "Basso")?.play()
                    overlay.update(shown, phase: .failed)
                    overlay.hide(shown, after: .seconds(4))
                    finish("Couldn't type it (\(error.localizedDescription)). It's in Recent Transcripts.")
                }
                remember(transcript)
            } catch {
                overlay.hide(shown)
                guard turn == self.turn else { return }
                finish(error.localizedDescription)
            }
        }
    }

    /// Every quarter second, cuts what has been said since the last cut at a
    /// pause and transcribes it, appending to the overlay's text.
    ///
    /// One chunk at a time, so they arrive in order. If one is slow, the next
    /// takes everything since, up to the longest chunk, which is also better
    /// context for the model.
    private func startLive() {
        live?.cancel()
        let shown = recording
        let model = UserDefaults.standard.string(forKey: Self.modelKey)
            ?? OpenAITranscription.defaultModel
        let dictionary = DictationDictionary.load()
        live = Task { [weak self] in
            var offset = 0
            var heard: [String] = []
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.recording == shown, self.state == .recording else { return }

                var pending = self.recorder.recorded(after: offset)
                var taken = 0
                while let cut = Chunker.boundary(in: pending, sampleRate: Self.sampleRate) {
                    taken += cut * 2
                    pending = pending.subdata(in: cut * 2..<pending.count)
                }
                guard taken > 0 else { continue }
                let chunk = self.recorder.recorded(after: offset).prefix(taken)
                offset += taken
                guard PCMRecorder.peak(of: chunk) >= Self.silencePeak,
                    let apiKey = try? Secrets.openAIAPIKey()
                else { continue }

                let client = OpenAITranscription(
                    apiKey: apiKey, model: model,
                    prompt: Self.livePrompt(dictionary, after: heard.joined(separator: " ")))
                guard
                    let text = try? await client.transcribe(
                        wav: WAV.pcm16(Data(chunk), sampleRate: Int(Self.sampleRate)))
                else { continue }
                let fixed = dictionary.apply(to: text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, self.recording == shown, !fixed.isEmpty else { continue }
                heard.append(fixed)
                self.overlay.update(shown, text: heard.joined(separator: " "))
            }
        }
    }

    private func stopLive() {
        live?.cancel()
        live = nil
        overlay.hide(recording)
    }

    /// The dictionary prompt plus the end of what came before, so a chunk
    /// that starts mid-sentence is read as the rest of it.
    private static func livePrompt(_ dictionary: DictationDictionary, after previous: String)
        -> String?
    {
        guard !previous.isEmpty else { return dictionary.prompt }
        let context = "Continues from: \"" + previous.suffix(200) + "\""
        return [dictionary.prompt, context].compactMap { $0 }.joined(separator: " ")
    }

    private func cancel() {
        turn += 1
        latched = false
        if state == .recording { capture.stop() }
        stopLive()
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
    private let loudness = Mutex(Float(0))

    /// The latest buffer's loudness, 0 to 1, for the overlay's waveform.
    var level: Float { loudness.withLock { $0 } }

    func reset() {
        data.withLock { $0 = Data() }
        loudness.withLock { $0 = 0 }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData else { return }
        let frames = Int(buffer.frameLength)
        let bytes = frames * MemoryLayout<Int16>.size
        let start = UnsafeRawPointer(channel[0]).assumingMemoryBound(to: UInt8.self)
        data.withLock { $0.append(start, count: bytes) }

        // RMS, square-rooted again so that speech, which sits around 0.02 to
        // 0.1 of full scale, fills the range instead of the bottom of it.
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames {
            let sample = Float(channel[0][i]) / Float(Int16.max)
            sum += sample * sample
        }
        let rms = (sum / Float(frames)).squareRoot()
        loudness.withLock { $0 = min(1, (rms * 6).squareRoot()) }
    }

    /// Everything recorded after the first `offset` bytes, without taking it.
    func recorded(after offset: Int) -> Data {
        data.withLock { $0.count > offset ? $0.subdata(in: offset..<$0.count) : Data() }
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
