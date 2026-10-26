@preconcurrency import AVFoundation
import Foundation
import Speech
import Synchronization

/// Transcribes on the device, with Apple's speech model: no key, no network,
/// nothing leaves the device.
///
/// Live, like the overlay: feed it audio as it is recorded with `append`, and
/// `preview` follows along (what is settled, then the guess at what is still
/// being said). `finish` settles the rest and returns the whole text, which is
/// quick because most of it was transcribed while you talked.
///
/// Uses `SpeechTranscriber`, the long-form model, where the device has it, and
/// the system dictation model (`DictationTranscriber`) where it doesn't.
public final class OnDeviceTranscription: Sendable {
    public enum Failure: LocalizedError {
        case unsupportedLocale
        case notInstalled

        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale: "On-device transcription doesn't support this language."
            case .notInstalled: "The on-device speech model isn't downloaded yet. Open Yap to get it."
            }
        }
    }

    /// Whether the model for `locale` is on the device, can be downloaded,
    /// or isn't offered at all.
    public enum Availability: Sendable, Equatable {
        case installed, downloadable, downloading, unsupported
    }

    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let reader: Task<String, any Error>
    private let converter: Mutex<Converter>
    /// What has been heard so far, each time it changes.
    public let preview: AsyncStream<String>

    private struct Heard {
        var settled = ""
        var pending = ""
        var joined: String { Self.join(settled, pending) }

        static func join(_ a: String, _ b: String) -> String {
            [a, b].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }

    /// Starts listening. `terms` are words to expect, such as the dictionary's.
    /// Throws when the model isn't installed: call `install` first, in the
    /// foreground, since it may download.
    public init(locale: Locale = .current, terms: [String] = [], inputFormat: AVAudioFormat) async throws {
        let module = try await Self.module(for: locale, vocabulary: !terms.isEmpty)
        guard await AssetInventory.status(forModules: [module.module]) == .installed else {
            throw Failure.notInstalled
        }

        analyzer = SpeechAnalyzer(modules: [module.module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module.module], considering: inputFormat) ?? inputFormat
        converter = Mutex(try Converter(from: inputFormat, to: format))
        try await analyzer.prepareToAnalyze(in: format)
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        let (preview, show) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        self.preview = preview

        reader = Task {
            defer { show.finish() }
            var heard = Heard()
            for try await (text, isFinal) in module.results() {
                if isFinal {
                    heard.settled = Heard.join(heard.settled, text)
                    heard.pending = ""
                } else {
                    heard.pending = text
                }
                show.yield(heard.joined)
            }
            return heard.settled
        }
        try await analyzer.start(inputSequence: stream)
    }

    /// Adds recorded audio. Safe from the audio thread.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.withLock({ $0.convert(buffer) }) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Settles what is still pending and returns everything heard.
    public func finish() async throws -> String {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await reader.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops without a result.
    public func cancel() async {
        input.finish()
        reader.cancel()
        await analyzer.cancelAndFinishNow()
    }

    /// Transcribes a finished recording: 16-bit mono PCM, as `PCMRecorder`
    /// keeps it. The fallback for a clip the live transcription missed.
    public static func transcribe(
        pcm16 samples: Data, sampleRate: Double, locale: Locale = .current, terms: [String] = []
    ) async throws -> String {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count / 2))
        else { throw Failure.unsupportedLocale }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(
                from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(buffer.frameLength))
        }
        let live = try await OnDeviceTranscription(locale: locale, terms: terms, inputFormat: format)
        live.append(buffer)
        return try await live.finish()
    }

    // MARK: The model

    public static func availability(locale: Locale = .current) async -> Availability {
        let modules = await modules(for: locale)
        guard !modules.isEmpty else { return .unsupported }
        switch await AssetInventory.status(forModules: modules) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .downloadable
        default: return .unsupported
        }
    }

    /// Downloads the models for `locale` that aren't on the device yet.
    public static func install(locale: Locale = .current) async throws {
        let modules = await modules(for: locale)
        guard !modules.isEmpty else { throw Failure.unsupportedLocale }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
    }

    /// A transcriber module, with its results reduced to text and whether
    /// they are final, since the two kinds have no common result type.
    private struct Module: Sendable {
        let module: any SpeechModule
        /// Started only for the module in use: reading starts a task that
        /// would wait forever on a module no analyzer runs.
        let results: @Sendable () -> AsyncThrowingStream<(String, Bool), any Error>
    }

    /// The model to listen with. With vocabulary, the dictation model: it is
    /// the one that uses expected words. Measured on synthetic speech, it got
    /// autoblog, Tailscale, next-cloud, Parade and Coolify right with the
    /// dictionary's terms and wrong without, while `SpeechTranscriber` ignored
    /// them. Without vocabulary, `SpeechTranscriber`, which punctuates better.
    private static func module(for locale: Locale, vocabulary: Bool) async throws -> Module {
        if !vocabulary, SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        {
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            return Module(module: module, results: { texts(of: module.results) { $0.text } })
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure.unsupportedLocale
        }
        let module = DictationTranscriber(
            locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        return Module(module: module, results: { texts(of: module.results) { $0.text } })
    }

    /// Both models, so changing the dictionary never needs a download.
    private static func modules(for locale: Locale) async -> [any SpeechModule] {
        var modules: [any SpeechModule] = []
        for vocabulary in [true, false] {
            if let module = try? await module(for: locale, vocabulary: vocabulary).module,
                !modules.contains(where: { type(of: $0) == type(of: module) })
            {
                modules.append(module)
            }
        }
        return modules
    }

    private static func texts<S: AsyncSequence & Sendable>(
        of results: S, _ text: @escaping @Sendable (S.Element) -> AttributedString
    ) -> AsyncThrowingStream<(String, Bool), any Error> where S.Element: SpeechModuleResult {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await result in results {
                        continuation.yield((String(text(result).characters), result.isFinal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Converts recorded buffers to the analyzer's format, when they differ.
private struct Converter: ~Copyable {
    let converter: AVAudioConverter?
    let format: AVAudioFormat

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        format = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
