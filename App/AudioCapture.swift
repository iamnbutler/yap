@preconcurrency import AVFoundation

/// Mic capture for the duration of a key hold.
///
/// Voice-processing IO (echo cancellation) is deliberately not enabled: Yap
/// never plays audio back, so there is no echo to cancel, and it colours the
/// input.
@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// Starts capture, converting to `format` and handing buffers to `onInput`.
    /// `onInput` is called on the realtime audio thread — keep it cheap.
    func start(
        format: AVAudioFormat,
        onInput: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) throws {
        guard !isRunning else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: inputFormat, to: format)
        self.converter = converter

        // @Sendable is load-bearing. Without it this closure inherits the class's
        // @MainActor isolation (non-Sendable closures inherit their context's actor),
        // and Swift emits a runtime isolation assertion at its entry. AVAudioEngine
        // calls the tap on a realtime audio thread, so that assertion trapped on the
        // first buffer. It produced no compile-time warning — the check is emitted,
        // not diagnosed.
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) {
            @Sendable buffer, _ in
            guard let converter else {
                onInput(buffer)
                return
            }
            guard let converted = Self.convert(buffer, using: converter, to: format) else {
                return
            }
            onInput(converted)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter?.reset()
        isRunning = false
    }

    /// `nonisolated` for the same reason the tap closure is `@Sendable`: static
    /// members of a @MainActor class are themselves main-actor isolated, and this
    /// runs on the audio thread.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }

        let supplier = OneShotInput(buffer)
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            guard let next = supplier.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// Hands a buffer to AVAudioConverter exactly once.
///
/// `convert(to:error:withInputFrom:)` invokes its input block synchronously on the
/// calling thread and nothing escapes, so this is single-threaded in practice.
/// `@unchecked Sendable` records that the SDK's block type simply isn't annotated
/// to say so — it is not a claim that this is thread-safe in general.
private final class OneShotInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
