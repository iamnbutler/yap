import AppKit
import MetalKit
import SwiftUI

/// What is being heard, while you talk: a panel at the bottom of the screen
/// with a waveform and the transcript so far.
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
        renderer.active = true
        show()
    }

    func update(_ recording: Int, phase: OverlayModel.Phase? = nil, text: String? = nil) {
        guard recording == owner, panel?.isVisible == true else { return }
        if let phase { model.phase = phase }
        if let text { model.text = text }
        renderer.active = model.phase == .listening || model.phase == .handsFree
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
        place(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Bottom centre of the screen you are working on, above the Dock.
    private func place(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 72))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OverlayView.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Sized by its content. The origin is the bottom-left corner, so a
        // longer transcript grows the panel upwards and it stays put.
        let host = NSHostingController(rootView: OverlayView(model: model, renderer: renderer))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        return panel
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
}

struct OverlayView: View {
    static let width: CGFloat = 560
    /// Enough for about four lines; earlier text scrolls off the top.
    private static let shown = 300

    let model: OverlayModel
    let renderer: WaveRenderer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WaveView(renderer: renderer)
                .frame(height: 30)
            if !model.text.isEmpty {
                Text(tail)
                    .font(.system(size: 15))
                    .foregroundStyle(model.phase == .typed ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(status)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.phase == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12)))
        .padding(12)
        .animation(.easeOut(duration: 0.15), value: model.text)
    }

    private var tail: String {
        guard model.text.count > Self.shown else { return model.text }
        return "…" + model.text.suffix(Self.shown)
    }

    private var status: String {
        switch model.phase {
        case .listening: "Listening"
        case .handsFree: "Hands free · tap Right Command to send"
        case .transcribing: "Transcribing the whole clip…"
        case .typed: "Typed"
        case .failed: "Couldn't type it · it's in Recent Transcripts"
        }
    }
}

private struct WaveView: NSViewRepresentable {
    let renderer: WaveRenderer

    func makeNSView(context: Context) -> MTKView {
        renderer.makeView()
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}

/// Matches `Uniforms` in Overlay.metal.
private struct WaveUniforms {
    var time: Float
    var count: Float
    var active: Float
}

/// Draws the waveform in Metal, so it can grow into something nicer than a
/// meter without fighting SwiftUI for frames.
@MainActor
final class WaveRenderer: NSObject, MTKViewDelegate {
    /// A second and a half of level at 60 frames a second.
    private static let history = 90

    var active = true
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
    private let started = ContinuousClock.now

    init(level: @escaping @MainActor () -> Float) {
        self.level = level
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
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
        // Rises at once and falls slowly, so speech reads as a shape rather
        // than flicker.
        let now = active ? level() : 0
        shown = max(now, shown * 0.9)
        levels.removeFirst()
        levels.append(shown)

        guard let pipeline, let queue,
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let elapsed = started.duration(to: .now)
        var uniforms = WaveUniforms(
            time: Float(elapsed.components.seconds) + Float(elapsed.components.attoseconds) / 1e18,
            count: Float(levels.count), active: active ? 1 : 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WaveUniforms>.stride, index: 0)
        levels.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
