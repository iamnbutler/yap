import Core
import SwiftUI
import UIKit

struct KeyboardView: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            Text(status)
                .font(.subheadline)
                .foregroundStyle(model.phase == .recording && !(model.state?.preview.isEmpty ?? true) ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .center)
                .padding(.horizontal, 12)

            ZStack {
                MicrophoneButton(phase: model.phase) { model.tapMicrophone() }
                if model.phase == .recording || model.phase == .transcribing {
                    HStack {
                        Spacer()
                        Button("Cancel", systemImage: "xmark") { model.cancel() }
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(Key.special))
                            .foregroundStyle(.primary)
                    }
                    .padding(.trailing, 28)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if model.needsGlobe {
                    NextKeyboardKey()
                        .frame(width: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Key.special))
                }
                Button { model.space() } label: {
                    Text("space").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(KeyStyle(fill: Key.letter))
                Image(systemName: "delete.left")
                    .frame(width: 56)
                    .frame(maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Key.special))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in model.startDeleting() }
                            .onEnded { _ in model.stopDeleting() })
                    .accessibilityLabel("Delete")
                    .accessibilityAddTraits(.isButton)
                Button { model.enter() } label: {
                    Text(model.returnTitle).frame(width: 88).frame(maxHeight: .infinity)
                }
                .buttonStyle(KeyStyle(fill: Key.special))
            }
            .frame(height: 44)
            .font(.system(size: 16))
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var status: String {
        if let note = model.note { return note }
        guard model.hasFullAccess else {
            return "Yap needs Full Access to reach its app: Settings › Apps › Yap › Keyboards."
        }
        switch model.phase {
        case .off:
            return "Tap to dictate. Yap opens to turn on the microphone; come back with ◀ in the corner."
        case .ready:
            return model.state?.message ?? "Tap to dictate."
        case .recording:
            let preview = model.state?.preview ?? ""
            return preview.isEmpty ? "Listening… tap ✓ to insert." : preview
        case .transcribing:
            return "Transcribing…"
        }
    }
}

private struct MicrophoneButton: View {
    let phase: Bridge.State.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(phase == .recording ? Color.red : Key.accent)
                switch phase {
                case .transcribing:
                    ProgressView().tint(.white)
                case .recording:
                    Image(systemName: "checkmark")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                default:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 84, height: 84)
            .overlay {
                if phase == .recording {
                    Circle().stroke(Color.red.opacity(0.35), lineWidth: 6).scaleEffect(1.15)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .transcribing)
        .accessibilityLabel(phase == .recording ? "Insert" : "Dictate")
    }
}

private enum Key {
    /// The app's accent. An extension doesn't get the app's asset catalog.
    static let accent = Color(red: 0.91, green: 0.33, blue: 0.34)
    static let letter = Color(uiColor: .secondarySystemGroupedBackground)
    static let special = Color(uiColor: .systemGray4)
}

private struct KeyStyle: ButtonStyle {
    let fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Key.special : fill))
    }
}

/// The globe key. A UIKit button, because the system's next-keyboard menu
/// (`handleInputModeList(from:with:)`) needs the real touch events, which a
/// SwiftUI button doesn't hand over.
private struct NextKeyboardKey: UIViewRepresentable {
    func makeUIView(context: Context) -> GlobeButton {
        let button = GlobeButton(type: .system)
        button.setImage(UIImage(systemName: "globe"), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = "Next keyboard"
        return button
    }

    func updateUIView(_ uiView: GlobeButton, context: Context) {}
}

/// Wires itself to its keyboard once it is in the window, the first point at
/// which its responder chain reaches the controller.
private final class GlobeButton: UIButton {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var next: UIResponder? = self
        while let current = next, !(current is UIInputViewController) { next = current.next }
        guard let controller = next as? UIInputViewController else { return }
        removeTarget(nil, action: nil, for: .allEvents)
        addTarget(
            controller, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
            for: .allTouchEvents)
    }
}
