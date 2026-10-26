@preconcurrency import AVFoundation
import Core
import Observation
import Synchronization
import UIKit

/// The app's half of iOS dictation: holds the microphone open for a session,
/// records when the keyboard asks, and leaves the transcript for it to insert.
///
/// Why the app and not the keyboard: see `Bridge`. In short, a keyboard gets
/// no microphone, and the app can keep recording in the background but can't
/// start there. So a session opens the microphone once, in the foreground,
/// and keeps it open, throwing audio away until a dictation starts. The
/// orange microphone dot stays on for as long as that lasts, which is why a
/// session ends on its own after `minutes` without a dictation.
@MainActor
@Observable
final class Session {
    private(set) var phase: Bridge.State.Phase = .off
    /// What has been heard so far, while recording.
    private(set) var preview = ""
    private(set) var message: String?
    private(set) var expires: Date?
    /// The newest transcripts, newest first.
    private(set) var recent: [Transcript] = []
    /// Whether Apple's speech model is on the phone, or nil until checked.
    private(set) var speechModel: OnDeviceTranscription.Availability?

    /// How long a session stays open after its last dictation.
    var minutes: Int {
        didSet {
            UserDefaults.standard.set(minutes, forKey: Self.minutesKey)
            if phase == .ready { extend() }
        }
    }

    /// Re-read before every clip, like the Mac app, so the settings screen
    /// and a synced file both apply at the next dictation.
    private(set) var config = Config()

    private static let minutesKey = "sessionMinutes"
    private static let modelKey = "model"
    static let recentLimit = 20

    /// The same as the Mac: 16 kHz mono PCM16 is what the models resample to.
    private static let sampleRate = 16000.0
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private static let minimumSeconds = 0.3
    private static let silencePeak: Int16 = 500
    /// A recording sends itself after this. Ten minutes is about 19 MB, under
    /// the endpoint's 25 MB limit.
    private static let recordingLimit = Duration.seconds(600)

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let recorder = PCMRecorder()
    @ObservationIgnored private let gate = Gate()
    @ObservationIgnored private let log = TranscriptLog()
    @ObservationIgnored private var observers: [Bridge.Observer] = []
    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private var clip: OnDeviceClip?
    @ObservationIgnored private var installing = false
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// Bumped by every recording, so a timer never ends a newer one.
    @ObservationIgnored private var recording = 0
    /// Bumped by a cancel, so a transcript already in flight is dropped.
    @ObservationIgnored private var turn = 0

    init() {
        UserDefaults.standard.register(defaults: [Self.minutesKey: 15])
        minutes = UserDefaults.standard.integer(forKey: Self.minutesKey)
        reloadConfig()
        if config.keepTranscripts {
            log.prune(keepingDays: config.retentionDays)
            recent = log.recent(Self.recentLimit)
        }

        observers = [
            Bridge.observe(.start) { Task { @MainActor in self.begin() } },
            Bridge.observe(.stop) { Task { @MainActor in self.send() } },
            Bridge.observe(.cancel) { Task { @MainActor in self.cancel() } },
            // Answering is the proof of life: the keyboard can't tell a state
            // file this process wrote from one a dead process left behind.
            Bridge.observe(.ping) { Task { @MainActor in self.publish() } },
        ]

        let center = NotificationCenter.default
        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { note in
            let began =
                (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .began
            guard began else { return }
            // A call takes the microphone, and the engine doesn't get it back
            // by itself. Ending says so honestly; the next tap starts afresh.
            Task { @MainActor in self.end("A call or another app took the microphone.") }
        }
        center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in self.end("The audio system restarted.") }
        }

        // Launching means no session survived: the last process is gone.
        publish()
        prepareSpeechModel()
    }

    /// Downloads Apple's speech model if it isn't on the phone. From the
    /// foreground: a download can't start from a keyboard's background turn.
    func prepareSpeechModel() {
        guard !installing else { return }
        installing = true
        Task {
            defer { installing = false }
            speechModel = await OnDeviceTranscription.availability()
            guard speechModel == .downloadable || speechModel == .downloading else { return }
            speechModel = .downloading
            do {
                try await OnDeviceTranscription.install()
            } catch {
                message = "Couldn't download the speech model: \(error.localizedDescription)"
            }
            speechModel = await OnDeviceTranscription.availability()
        }
    }

    // MARK: The session

    /// Opens the microphone. Only works with the app in front; iOS refuses
    /// to start recording from the background.
    func start(thenRecord: Bool = false) async {
        if phase != .off {
            if thenRecord { begin() }
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Yap needs the microphone. Turn it on in Settings."
            return publish()
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            // Mixing, so music keeps playing through a session. Not Bluetooth
            // input: taking an AirPods microphone drops their playback to call
            // quality for the whole session.
            try audio.setCategory(
                .playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
            try audio.setActive(true)
            try capture.start(format: Self.format) { [recorder, gate] buffer in
                guard gate.isOpen else { return }
                recorder.append(buffer)
            }
        } catch {
            message = "The microphone wouldn't start: \(error.localizedDescription)"
            return publish()
        }

        phase = .ready
        message = nil
        extend()
        publish()
        prepareSpeechModel()
        if thenRecord { begin() }
    }

    /// Closes the microphone, which lets iOS suspend the app.
    func end(_ reason: String? = nil) {
        guard phase != .off else { return }
        turn += 1
        gate.isOpen = false
        live?.cancel()
        clip?.cancel()
        clip = nil
        expiry?.cancel()
        capture.stop()
        recorder.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .off
        preview = ""
        expires = nil
        message = reason
        publish()
    }

    /// Pushes the end of the session back to `minutes` from now.
    private func extend() {
        expiry?.cancel()
        let deadline = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        expires = deadline
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow))
            guard !Task.isCancelled, let self, self.phase == .ready else { return }
            self.end("The session ended after \(self.minutes) minutes without a dictation.")
        }
    }

    // MARK: Dictation

    func begin() {
        guard phase == .ready else { return }
        reloadConfig()
        recording += 1
        recorder.reset()
        gate.isOpen = true
        phase = .recording
        preview = ""
        message = nil
        expiry?.cancel()
        publish()
        if config.engine == .onDevice {
            let shown = recording
            let showing = config.overlay
            clip = OnDeviceClip(
                recorder: recorder, format: Self.format, terms: DictationDictionary.load().terms
            ) { [weak self] text in
                guard showing, let self, self.recording == shown, self.phase == .recording else { return }
                self.preview = text
                self.publish()
            }
        } else if config.overlay {
            startLive()
        }

        let recording = recording
        Task {
            try? await Task.sleep(for: Self.recordingLimit)
            guard recording == self.recording, self.phase == .recording else { return }
            self.send()
        }
    }

    func cancel() {
        guard phase == .recording || phase == .transcribing else { return }
        turn += 1
        gate.isOpen = false
        live?.cancel()
        clip?.cancel()
        clip = nil
        recorder.reset()
        phase = .ready
        preview = ""
        extend()
        publish()
    }

    func send() {
        guard phase == .recording else { return }
        gate.isOpen = false
        live?.cancel()
        live = nil
        let clip = clip
        self.clip = nil
        let samples = recorder.take()
        let seconds = Double(samples.count) / 2 / Self.sampleRate

        guard seconds >= Self.minimumSeconds else {
            clip?.cancel()
            return finish("Too short to send.")
        }
        guard PCMRecorder.peak(of: samples) >= Self.silencePeak else {
            clip?.cancel()
            return finish("Heard nothing.")
        }

        phase = .transcribing
        publish()
        let turn = turn
        let config = config
        let dictionary = DictationDictionary.load()

        let onDevice = { () async throws -> String in
            let heard =
                if let clip {
                    try await clip.finish(samples)
                } else {
                    try await OnDeviceTranscription.transcribe(
                        pcm16: samples, sampleRate: Self.sampleRate, terms: dictionary.terms)
                }
            return dictionary.apply(to: heard)
        }
        let openAI = { () async throws -> String in
            guard let apiKey = APIKey.read() else { throw SendFailure.noKey }
            let model = UserDefaults.standard.string(forKey: Self.modelKey)
                ?? OpenAITranscription.defaultModel
            let client = OpenAITranscription(apiKey: apiKey, model: model, prompt: dictionary.prompt)
            let heard = try await client.transcribe(
                wav: WAV.pcm16(samples, sampleRate: Int(Self.sampleRate)))
            return dictionary.apply(to: heard)
        }
        // The chosen engine, then the other: the clip was loud enough to be
        // speech, so an empty result is a failure worth a second opinion.
        let engines: [(Config.Engine, () async throws -> String)] =
            config.engine == .onDevice
            ? [(.onDevice, onDevice), (.openAI, openAI)] : [(.openAI, openAI), (.onDevice, onDevice)]

        Task {
            var failure: (any Error)?
            var text = ""
            var used = config.engine
            for (engine, transcribe) in engines {
                do {
                    text = try await transcribe().trimmingCharacters(in: .whitespacesAndNewlines)
                    used = engine
                    if !text.isEmpty { break }
                } catch {
                    if failure == nil { failure = error }
                }
            }
            guard turn == self.turn else { return }
            guard !text.isEmpty else { return finish(failure?.localizedDescription ?? "Heard nothing.") }
            if config.cleanup != .off {
                let refined = await Refiner.refine(
                    text, terms: dictionary.terms, with: config.cleanup, apiKey: APIKey.read())
                // Fixes again after: the refiner may respell a word they fix.
                text = dictionary.apply(to: refined).trimmingCharacters(in: .whitespacesAndNewlines)
                guard turn == self.turn else { return }
            }

            // Kept first, so text that never reaches a field isn't lost.
            remember(Transcript(text: text))
            do {
                try Bridge.deliver(Bridge.Result(text: text))
                finish(used == config.engine ? nil : Self.fellBack(to: used, after: failure))
            } catch {
                finish(error.localizedDescription)
            }
        }
    }

    private static func fellBack(to engine: Config.Engine, after failure: (any Error)?) -> String {
        let reason = failure.map { " (\($0.localizedDescription))" } ?? ""
        return switch engine {
        case .openAI: "Transcribed by OpenAI: on-device didn't work\(reason)."
        case .onDevice: "Transcribed on device: OpenAI didn't work\(reason)."
        }
    }

    private enum SendFailure: LocalizedError {
        case noKey
        var errorDescription: String? { "No OpenAI key." }
    }

    /// Ends a clip. A session that ended meanwhile stays ended.
    private func finish(_ message: String?) {
        self.message = message
        preview = ""
        if phase == .recording || phase == .transcribing {
            phase = .ready
            extend()
        }
        publish()
    }

    /// The Mac app's live preview, written to the bridge instead of an
    /// overlay: at each pause, the last phrase is transcribed and added.
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
                guard let self, self.recording == shown, self.phase == .recording else { return }

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
                    let apiKey = APIKey.read()
                else { continue }

                var prompt = dictionary.prompt
                if !heard.isEmpty {
                    let context = "Continues from: \"" + heard.joined(separator: " ").suffix(200) + "\""
                    prompt = [prompt, context].compactMap { $0 }.joined(separator: " ")
                }
                let client = OpenAITranscription(apiKey: apiKey, model: model, prompt: prompt)
                guard
                    let text = try? await client.transcribe(
                        wav: WAV.pcm16(Data(chunk), sampleRate: Int(Self.sampleRate)))
                else { continue }
                let fixed = dictionary.apply(to: text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !Task.isCancelled, self.recording == shown, self.phase == .recording,
                    !fixed.isEmpty
                else { continue }
                heard.append(fixed)
                self.preview = heard.joined(separator: " ")
                self.publish()
            }
        }
    }

    // MARK: Settings and transcripts

    func reloadConfig() {
        if let loaded = try? Config.load() { config = loaded }
    }

    func update(_ change: (inout Config) -> Void) {
        reloadConfig()
        change(&config)
        do {
            try config.save()
        } catch {
            message = "Couldn't save settings: \(error.localizedDescription)"
        }
    }

    private func remember(_ transcript: Transcript) {
        recent.insert(transcript, at: 0)
        recent = Array(recent.prefix(Self.recentLimit))
        guard config.keepTranscripts else { return }
        try? log.append(transcript)
        log.prune(keepingDays: config.retentionDays)
    }

    /// Tells every keyboard what changed. Written before it is announced, so
    /// a keyboard that hears the signal reads the new state.
    private func publish() {
        let state = Bridge.State(phase: phase, preview: preview, message: message, expires: expires)
        try? state.write()
        Bridge.post(.changed)
    }
}

/// Whether the audio thread keeps what it hears. Atomic, because it is read
/// on every buffer from the realtime thread and set from the main actor.
private final class Gate: Sendable {
    private let open = Atomic(false)

    var isOpen: Bool {
        get { open.load(ordering: .relaxed) }
        set { open.store(newValue, ordering: .relaxed) }
    }
}
