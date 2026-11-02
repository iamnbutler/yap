@preconcurrency import AVFoundation
import CoreAudio
import Core
import Observation
import Synchronization
import SwiftUI

/// The Mic Check window: what the mic hears of you, and what to change. It
/// listens through the same input and at the same rate as dictation, so it
/// hears what the transcription model would.
struct MicCheckView: View {
    static let id = "mic-check"

    @State private var model = MicCheckModel()

    var body: some View {
        let report = model.report
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 7) {
                Circle()
                    .fill(model.listening ? Palette.red : Palette.edge)
                    .frame(width: 7, height: 7)
                    .shadow(color: Palette.red.opacity(model.listening ? 0.8 : 0), radius: 3)
                Text("MIC CHECK")
                    .font(MicCheckView.caps)
                    .tracking(1.4)
                    .foregroundStyle(Palette.red)
                Spacer()
                Text(String(format: "%.1f s", report.spoken))
                    .font(.system(size: 22, weight: .thin).width(.expanded).monospacedDigit())
                    .foregroundStyle(Palette.cream)
            }
            Text(model.device.name.uppercased())
                .font(MicCheckView.caps)
                .tracking(1.2)
                .foregroundStyle(Palette.cream.opacity(0.5))
                .lineLimit(1)

            LevelHistory(report: report)
                .frame(height: 96)

            HStack(spacing: 0) {
                Readout(label: "SPEECH", value: report.speech, unit: "dB")
                Readout(label: "NOISE", value: report.noise, unit: "dB")
                Readout(label: "S/N", value: report.signalToNoise, unit: "dB")
                Readout(label: "FALL", value: report.fall, unit: "dB")
                Readout(label: "TONE", value: report.tone, unit: "dB")
            }

            Rule()
            VStack(alignment: .leading, spacing: 9) {
                Row(label: "GAIN", verdict: report.gain)
                Row(label: "DISTANCE", verdict: report.distance)
                Row(label: "ROOM", verdict: report.room)
                Row(label: "AIM", verdict: report.aim)
                Row(
                    label: "DIRECTION",
                    verdict: report.direction
                        ?? .init(grade: .unknown, advice: "One channel: a single mic can't hear direction."))
            }

            Rule()
            VolumeControl(model: model)

            Rule()
            Text("Talk as you would to dictate, pausing between sentences. Try:")
                .font(.system(size: 11))
                .foregroundStyle(Palette.cream.opacity(0.5))
            Text(MicCheckView.passage)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(Palette.cream.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if let problem = model.problem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.red)
                }
                Spacer()
                Button("START OVER") { model.reset() }
                    .buttonStyle(KeyButton())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: 460)
        .background(.black)
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    static let caps = Font.system(size: 10, weight: .semibold).width(.expanded)

    private static let passage = """
        Set the reel turning. Read this at your usual pace, then stop for a beat. \
        Now turn your head away, and back again, and watch the tone.
        """
}

// MARK: Pieces

private struct Rule: View {
    var body: some View {
        Rectangle().fill(Palette.edge).frame(height: 1)
    }
}

private struct Readout: View {
    let label: String
    let value: Double?
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold).width(.expanded))
                .tracking(1.2)
                .foregroundStyle(Palette.cream.opacity(0.45))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map { String(format: "%.0f", $0) } ?? "–")
                    .font(.system(size: 20, weight: .thin).width(.expanded).monospacedDigit())
                    .foregroundStyle(Palette.cream)
                Text(unit)
                    .font(.system(size: 9).width(.expanded))
                    .foregroundStyle(Palette.cream.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Row: View {
    let label: String
    let verdict: MicCheck.Verdict

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(verdict.grade == .unknown ? 0 : 0.8), radius: 3)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(label)
                .font(MicCheckView.caps)
                .tracking(1.2)
                .foregroundStyle(color == Palette.edge ? Palette.cream.opacity(0.45) : color)
                .frame(width: 82, alignment: .leading)
            Text(verdict.advice)
                .font(.system(size: 13))
                .foregroundStyle(Palette.cream.opacity(verdict.grade == .unknown ? 0.5 : 0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeOut(duration: 0.2), value: verdict)
    }

    private var color: Color {
        switch verdict.grade {
        case .unknown: Palette.edge
        case .good: Palette.blue
        case .fair: Palette.orange
        case .poor: Palette.red
        }
    }
}

private struct VolumeControl: View {
    let model: MicCheckModel

    var body: some View {
        HStack(spacing: 12) {
            Text("INPUT VOLUME")
                .font(MicCheckView.caps)
                .tracking(1.2)
                .foregroundStyle(Palette.cream.opacity(0.45))
            if let volume = model.device.volume {
                if model.device.volumeSettable {
                    Slider(value: Binding(get: { Double(volume) }, set: { model.setVolume(Float($0)) }), in: 0...1)
                        .tint(Palette.cream)
                        .controlSize(.small)
                } else {
                    Spacer()
                }
                Text("\(Int((volume * 100).rounded()))%")
                    .font(.system(size: 13, weight: .light).width(.expanded).monospacedDigit())
                    .foregroundStyle(Palette.cream)
                    .frame(width: 44, alignment: .trailing)
            } else {
                Spacer()
                Text("SET BY THE DEVICE")
                    .font(MicCheckView.caps)
                    .tracking(1.2)
                    .foregroundStyle(Palette.cream.opacity(0.45))
            }
        }
    }
}

private struct KeyButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(MicCheckView.caps)
            .tracking(1.2)
            .foregroundStyle(Palette.cream.opacity(configuration.isPressed ? 0.5 : 0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// Fifteen seconds of frame levels on a −70 to 0 dBFS scale, with the band
/// speech should sit in, the noise floor in blue and typical speech in cream.
private struct LevelHistory: View {
    let report: MicCheck.Report

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            func y(_ db: Double) -> CGFloat { h * CGFloat(min(1, max(0, db / -70))) }

            // Speech belongs between −34 and −10 dBFS.
            context.fill(
                Path(CGRect(x: 0, y: y(-10), width: w, height: y(-34) - y(-10))),
                with: .color(Palette.blue.opacity(0.07)))
            for db in stride(from: -60.0, through: -10, by: 10) {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: w, y: y(db)))
                context.stroke(line, with: .color(Palette.edge), lineWidth: 1)
            }

            let levels = report.levels
            let count = 750
            if !levels.isEmpty {
                let step = w / CGFloat(count - 1)
                let start = CGFloat(count - levels.count) * step
                var fill = Path()
                fill.move(to: CGPoint(x: start, y: h))
                for (i, level) in levels.enumerated() {
                    fill.addLine(to: CGPoint(x: start + CGFloat(i) * step, y: y(level)))
                }
                fill.addLine(to: CGPoint(x: w, y: h))
                fill.closeSubpath()
                context.fill(fill, with: .color(Palette.cream.opacity(0.12)))
                var trace = Path()
                for (i, level) in levels.enumerated() {
                    let point = CGPoint(x: start + CGFloat(i) * step, y: y(level))
                    if i == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                }
                context.stroke(trace, with: .color(Palette.cream.opacity(0.8)), lineWidth: 1)
            }

            func guide(_ db: Double?, _ color: Color) {
                guard let db else { return }
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y(db)))
                line.addLine(to: CGPoint(x: w, y: y(db)))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [3.5, 3.5]))
            }
            guide(report.noise, Palette.blue)
            guide(report.speech, Palette.cream)

            // The peak, as a tick on the right; red when it clips.
            let clipping = report.clipped > 0 || report.peak > -1
            var peak = Path()
            peak.move(to: CGPoint(x: w - 10, y: y(report.peak)))
            peak.addLine(to: CGPoint(x: w, y: y(report.peak)))
            context.stroke(peak, with: .color(clipping ? Palette.red : Palette.orange), lineWidth: 2)

            for db in stride(from: -60.0, through: -10, by: 10) {
                context.draw(
                    Text("\(Int(db))").font(.system(size: 8).width(.expanded)).foregroundStyle(Palette.cream.opacity(0.35)),
                    at: CGPoint(x: 2, y: y(db) - 1), anchor: .bottomLeading)
            }
        }
        .background(.black)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.edge))
    }
}

// MARK: Listening

@MainActor
@Observable
final class MicCheckModel {
    private(set) var report = MicCheck.Report()
    private(set) var device = InputDevice.current()
    private(set) var listening = false
    private(set) var problem: String?

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private let inbox = SampleInbox()
    @ObservationIgnored private var check = MicCheck()
    @ObservationIgnored private var loop: Task<Void, Never>?

    func start() {
        guard !listening else { return }
        device = InputDevice.current()
        let channels = min(2, max(1, device.channels))
        check = MicCheck(channels: channels)
        inbox.reset()
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: MicCheck.sampleRate,
                channels: AVAudioChannelCount(channels), interleaved: false)
        else { return }
        do {
            try capture.start(format: format) { [inbox] buffer in inbox.append(buffer) }
            listening = true
            problem = nil
        } catch {
            problem = "Microphone failed: \(error.localizedDescription)"
            return
        }
        loop = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.drain()
                ticks += 1
                // A plugged-in mic or a changed volume shows within a second.
                if ticks % 20 == 0 { self.refreshDevice() }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        capture.stop()
        listening = false
    }

    func reset() {
        stop()
        report = MicCheck.Report()
        start()
    }

    func setVolume(_ volume: Float) {
        device.setVolume(volume)
        device = InputDevice.current()
    }

    private func drain() {
        let samples = inbox.take()
        guard !samples.isEmpty, samples.count == check.channels else { return }
        check.append(samples)
        report = check.report
    }

    private func refreshDevice() {
        let now = InputDevice.current()
        if now.id != device.id {
            // A new default input: start over on it.
            reset()
        } else if now != device {
            device = now
        }
    }
}

/// Samples from the realtime audio thread, per channel, until the main actor
/// takes them.
private final class SampleInbox: Sendable {
    private let samples = Mutex([[Float]]())

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        samples.withLock { samples in
            if samples.count != channels { samples = Array(repeating: [], count: channels) }
            for c in 0..<channels { samples[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: frames)) }
        }
    }

    func take() -> [[Float]] {
        samples.withLock { samples in
            defer { samples = samples.map { _ in [] } }
            return samples
        }
    }

    func reset() {
        samples.withLock { $0 = [] }
    }
}

/// The default input, as Core Audio describes it: what dictation records.
struct InputDevice: Equatable {
    var id = AudioObjectID(kAudioObjectUnknown)
    var name = "No input"
    var channels = 0
    /// The input volume, 0 to 1, if the device has one.
    var volume: Float?
    var volumeSettable = false
    /// The elements that hold the volume: the main one, or each channel.
    private var elements: [AudioObjectPropertyElement] = []

    static func current() -> InputDevice {
        var device = InputDevice()
        var id = AudioObjectID(kAudioObjectUnknown)
        guard
            get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, &id),
            id != kAudioObjectUnknown
        else { return device }
        device.id = id

        var name: Unmanaged<CFString>?
        if get(id, kAudioObjectPropertyName, &name), let name {
            device.name = name.takeRetainedValue() as String
        }
        device.channels = channels(of: id)

        let candidates = [kAudioObjectPropertyElementMain] + (0..<device.channels).map { UInt32($0 + 1) }
        for element in candidates {
            var volume: Float32 = 0
            guard get(id, kAudioDevicePropertyVolumeScalar, &volume, scope: kAudioDevicePropertyScopeInput, element: element)
            else { continue }
            device.volume = device.volume ?? volume
            device.elements.append(element)
            var settable: DarwinBoolean = false
            var address = address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
            if AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue {
                device.volumeSettable = true
            }
            // The main element covers every channel.
            if element == kAudioObjectPropertyElementMain { break }
        }
        return device
    }

    func setVolume(_ volume: Float) {
        for element in elements {
            var value = Float32(min(1, max(0, volume)))
            var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, element)
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
    }

    private static func channels(of id: AudioObjectID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func get<T: BitwiseCopyable>(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
    }
}
