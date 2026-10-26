import AppKit
import MetalKit
import SwiftUI

/// What is being heard, while you talk: a panel in the top-right corner, where
/// notifications show, with a waveform and the transcript so far.
///
/// The live text comes from chunks transcribed at each pause. On send, the
/// whole clip is transcribed again and replaces it, so the preview can be
/// rough without the typed text being so.
///
/// The panel never takes focus or clicks. Typing goes to the app that was in
/// front when the key went down, and a panel that became key would be that app.
@MainActor
final class Overlay {
    let model = OverlayModel()
    private let renderer: WaveRenderer
    private var panel: NSPanel?
    /// The recording the panel is showing. A transcript can land after the
    /// next recording has begun, and must not overwrite it or hide it.
    private var owner = 0
    private var hiding: Task<Void, Never>?

    init(level: @escaping @MainActor () -> Float) {
        renderer = WaveRenderer(level: level)
    }

    func begin(_ recording: Int) {
        owner = recording
        hiding?.cancel()
        model.text = ""
        model.phase = .listening
        model.started = .now
        model.stopped = nil
        renderer.reset()
        renderer.active = true
        renderer.tint = model.tint
        show()
    }

    func update(_ recording: Int, phase: OverlayModel.Phase? = nil, text: String? = nil) {
        guard recording == owner, panel?.isVisible == true else { return }
        if let phase { model.phase = phase }
        if let text { model.text = text }
        renderer.active = model.phase == .listening || model.phase == .handsFree
        renderer.tint = model.tint
        if !renderer.active, model.stopped == nil { model.stopped = .now }
    }

    /// A chunk was cut `seconds` into the recording: an orange mark on the tape.
    func mark(_ recording: Int, at seconds: Double) {
        guard recording == owner else { return }
        renderer.mark(Float(seconds))
    }

    /// Hides now, or after `delay` so a final transcript can be read.
    func hide(_ recording: Int, after delay: Duration = .zero) {
        guard recording == owner else { return }
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, recording == owner, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled, recording == owner else { return }
            panel.orderOut(nil)
            renderer.paused = true
        }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        renderer.paused = false
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let screen { place(panel, on: screen) }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Top right of the screen the pointer is on, under the menu bar, where
    /// notification banners sit. Only when shown: the panel never changes
    /// size, so nothing moves it while it is up.
    private func place(_ panel: NSPanel, on screen: NSScreen) {
        let area = screen.visibleFrame
        // The card sits `OverlayView.margin` inside the panel, which leaves
        // room for its shadow; measure the corner gap from the card.
        let shift = OverlayView.margin - Self.corner
        let frame = NSRect(
            x: area.maxX - Self.size.width + shift, y: area.maxY - Self.size.height + shift,
            width: Self.size.width, height: Self.size.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// Fixed, and tall enough for the card at its longest: a header, the
    /// waveform and about five lines of text. A panel sized to its content
    /// resized on every new line, and AppKit moved it before `place` could
    /// put it back, so the top edge bobbed. The card is drawn at the top and
    /// grows down inside it; the rest is transparent, and the panel ignores
    /// the mouse, so it covers nothing.
    private static let size = NSSize(width: OverlayView.width + OverlayView.margin * 2, height: 400)

    /// The gap between the card and the screen's corner, as banners have.
    /// More than `OverlayView.margin`, so the panel stays inside the screen:
    /// a panel touching the right edge drew its Metal view black, on a Studio
    /// Display with the built-in display reaching past its right edge.
    private static let corner: CGFloat = 20

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // The content never sizes the window: the card is pinned to the top
        // of a fixed panel and grows downwards.
        let host = NSHostingController(
            rootView: OverlayView(model: model, renderer: renderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setContentSize(Self.size)
        return panel
    }
}

extension Overlay {
    /// The overlay on a loop: listening with cuts landing, hands free,
    /// transcribing, typed. The level is a made-up voice: syllables, with a
    /// pause every few seconds.
    static func demo() -> Overlay {
        let started = ContinuousClock.now
        let overlay = Overlay {
            let d = started.duration(to: .now)
            let t = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            let phrase = t.truncatingRemainder(dividingBy: 3.2)
            guard phrase < 2.5 else { return 0.02 }
            let syllables = abs(sin(t * 9)) * (0.55 + 0.45 * sin(t * 1.7))
            return Float(min(1, 0.15 + syllables * 0.8))
        }
        let words = [
            "So the overlay should feel like a little tape machine,",
            "with the reel turning while I talk",
            "and an orange mark on the tape wherever a phrase was cut.",
        ]
        Task { @MainActor in
            var run = 0
            while true {
                run += 1
                overlay.begin(run)
                var heard: [String] = []
                for (index, phrase) in words.enumerated() {
                    try? await Task.sleep(for: .seconds(3.2))
                    heard.append(phrase)
                    overlay.mark(run, at: 2.75 + Double(index) * 3.2)
                    overlay.update(run, text: heard.joined(separator: " "))
                    if index == 1 { overlay.update(run, phase: .handsFree) }
                }
                try? await Task.sleep(for: .seconds(1))
                overlay.update(run, phase: .transcribing)
                try? await Task.sleep(for: .seconds(3))
                overlay.update(
                    run, phase: .typed,
                    text: "So the overlay should feel like a little tape machine, with the reel turning "
                        + "while I talk, and an orange mark on the tape wherever a phrase was cut.")
                try? await Task.sleep(for: .seconds(4))
            }
        }
        return overlay
    }
}

@MainActor
@Observable
final class OverlayModel {
    enum Phase {
        case listening, handsFree, transcribing, typed, failed
    }

    var phase = Phase.listening
    var text = ""
    var started = Date.now
    /// When the recording ended; the clock stops there.
    var stopped: Date?

    var tint: Color {
        switch phase {
        case .listening, .failed: Palette.red
        case .handsFree: Palette.orange
        case .transcribing: Palette.blue
        case .typed: Palette.cream
        }
    }
}

/// Teenage Engineering's display colours, more or less. Matches the constants
/// in Overlay.metal.
enum Palette {
    static let cream = Color(red: 0.93, green: 0.91, blue: 0.86)
    static let blue = Color(red: 0.38, green: 0.60, blue: 1.00)
    static let orange = Color(red: 1.00, green: 0.62, blue: 0.20)
    static let red = Color(red: 1.00, green: 0.30, blue: 0.18)
    static let edge = Color(white: 0.17)
}

struct OverlayView: View {
    static let width: CGFloat = 440
    /// Room around the card for its shadow.
    static let margin: CGFloat = 18
    /// Enough for about four lines; earlier text scrolls off the top.
    private static let shown = 280

    let model: OverlayModel
    let renderer: WaveRenderer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 7) {
                Circle()
                    .fill(model.tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: model.tint.opacity(0.8), radius: 3)
                Text(label)
                    .font(.system(size: 10, weight: .semibold).width(.expanded))
                    .tracking(1.4)
                    .foregroundStyle(model.tint)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    Text(clock(at: context.date))
                        .font(.system(size: 22, weight: .thin).width(.expanded).monospacedDigit())
                        .foregroundStyle(Palette.cream)
                }
            }
            WaveView(renderer: renderer)
                .frame(height: 58)
            if !model.text.isEmpty {
                Rectangle()
                    .fill(Palette.edge)
                    .frame(height: 1)
                Text(tail)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Palette.cream.opacity(model.phase == .typed ? 1 : 0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .background(.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Palette.edge, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .padding(Self.margin)
        .animation(.easeOut(duration: 0.15), value: model.text)
    }

    private var tail: String {
        guard model.text.count > Self.shown else { return model.text }
        return "…" + model.text.suffix(Self.shown)
    }

    private var label: String {
        switch model.phase {
        case .listening: "REC"
        case .handsFree: "REC · HANDS FREE · TAP AGAIN TO SEND"
        case .transcribing: "TRANSCRIBING"
        case .typed: "TYPED"
        case .failed: "NOT TYPED · IN RECENT TRANSCRIPTS"
        }
    }

    private func clock(at now: Date) -> String {
        let seconds = Int((model.stopped ?? now).timeIntervalSince(model.started))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct WaveView: NSViewRepresentable {
    let renderer: WaveRenderer

    func makeNSView(context: Context) -> MTKView {
        renderer.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Matches `Uniforms` in Overlay.metal, field for field.
private struct WaveUniforms {
    var tint: SIMD4<Float>
    var size: SIMD2<Float>
    var time: Float
    var count: Float
    var active: Float
    var elapsed: Float
    var cutCount: Float
    var scale: Float
}

/// Draws the display in Metal, so it can keep growing without fighting
/// SwiftUI for frames.
@MainActor
final class WaveRenderer: NSObject, MTKViewDelegate {
    /// About two seconds of level at 60 frames a second.
    private static let history = 120
    /// The shader takes a fixed-size array; older cuts have scrolled off.
    private static let maximumCuts = 32

    var active = true
    var tint = Palette.red
    var paused = true {
        didSet { view?.isPaused = paused }
    }

    private let level: @MainActor () -> Float
    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private weak var view: MTKView?
    private var levels = [Float](repeating: 0, count: WaveRenderer.history)
    private var shown: Float = 0
    private var cuts: [Float] = []
    /// Seconds of tape: advances only while recording, so the ruler and the
    /// reel stop when you do.
    private var elapsed: Float = 0
    private var lastFrame = ContinuousClock.now
    private let started = ContinuousClock.now

    init(level: @escaping @MainActor () -> Float) {
        self.level = level
    }

    func reset() {
        elapsed = 0
        cuts = []
        shown = 0
        levels = [Float](repeating: 0, count: Self.history)
        lastFrame = .now
    }

    func mark(_ seconds: Float) {
        cuts.append(seconds)
        if cuts.count > Self.maximumCuts { cuts.removeFirst() }
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.isPaused = paused
        view.delegate = self
        self.view = view

        if let device, let library = device.makeDefaultLibrary() {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "overlayVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "overlayFragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
            queue = device.makeCommandQueue()
        }
        return view
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        let now = ContinuousClock.now
        if active { elapsed += Self.seconds(lastFrame.duration(to: now)) }
        lastFrame = now

        // Rises at once and falls slowly, so speech reads as a shape rather
        // than flicker.
        shown = max(active ? level() : 0, shown * 0.9)
        levels.removeFirst()
        levels.append(shown)

        guard let pipeline, let queue,
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let resolved = NSColor(tint).usingColorSpace(.sRGB) ?? .white
        var uniforms = WaveUniforms(
            tint: SIMD4(
                Float(resolved.redComponent), Float(resolved.greenComponent),
                Float(resolved.blueComponent), 1),
            size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: Self.seconds(started.duration(to: now)),
            count: Float(levels.count),
            active: active ? 1 : 0,
            elapsed: elapsed,
            cutCount: Float(cuts.count),
            scale: Float(view.window?.backingScaleFactor ?? 2))
        var cutBuffer = cuts + [Float](repeating: 0, count: Self.maximumCuts - cuts.count)

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaveUniforms>.stride, index: 0)
        levels.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        cutBuffer.withUnsafeMutableBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static func seconds(_ duration: Duration) -> Float {
        Float(duration.components.seconds) + Float(duration.components.attoseconds) / 1e18
    }
}
