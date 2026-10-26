@preconcurrency import AVFoundation
import Synchronization

/// Collects PCM16 from the realtime audio thread.
///
/// A class of its own rather than state on `Yap`, because the tap closure
/// runs off the main actor and must not touch it. The mutex is uncontended
/// except at the hand-off at key-up.
final class PCMRecorder: Sendable {
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
