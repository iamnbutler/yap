@preconcurrency import AVFoundation
import Core
import Foundation

/// One recording, transcribed on the device as it is recorded.
///
/// Fed from the recorder on a short timer rather than from the audio thread:
/// the transcriber takes a moment to start, and the recorder already has
/// every sample from the first one, so nothing said before it was ready is
/// lost, and nothing runs on the realtime thread.
@MainActor
final class OnDeviceClip {
    private let ready: Task<OnDeviceTranscription, any Error>
    private let format: AVAudioFormat
    private var feeding: Task<Void, Never>?
    private var showing: Task<Void, Never>?
    /// Bytes of the recording already handed to the transcriber.
    private var fed = 0

    /// Starts transcribing what `recorder` records. `show` gets what has been
    /// heard so far, each time it changes.
    init(
        recorder: PCMRecorder, format: AVAudioFormat, terms: [String],
        show: @escaping @MainActor (String) -> Void
    ) {
        self.format = format
        ready = Task { try await OnDeviceTranscription(terms: terms, inputFormat: format) }
        feeding = Task { [weak self] in
            guard let transcriber = try? await self?.ready.value else { return }
            self?.showing = Task {
                for await text in transcriber.preview { show(text) }
            }
            while !Task.isCancelled, let self {
                self.feed(recorder.recorded(after: self.fed), to: transcriber)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// The whole clip's text. `samples` is the full recording, as the
    /// recorder hands it over at the end; the part not yet fed goes in first.
    func finish(_ samples: Data) async throws -> String {
        feeding?.cancel()
        let transcriber = try await ready.value
        if fed < samples.count {
            feed(samples.subdata(in: fed..<samples.count), to: transcriber)
        }
        return try await transcriber.finish()
    }

    func cancel() {
        feeding?.cancel()
        showing?.cancel()
        let ready = ready
        Task { try? await ready.value.cancel() }
    }

    private func feed(_ data: Data, to transcriber: OnDeviceTranscription) {
        let frames = data.count / 2
        guard frames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            buffer.int16ChannelData![0].update(
                from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        transcriber.append(buffer)
        fed += frames * 2
    }
}
