import Core
import SwiftUI

@main
struct YapApp: App {
    @State private var yap = Yap()

    var body: some Scene {
        // The task lives on the label, not the content: MenuBarExtra does not
        // render its content until the menu is first opened, and the hotkey
        // has to work from launch.
        MenuBarExtra {
            YapMenu(yap: yap)
        } label: {
            Image(systemName: icon)
                .task { yap.start() }
        }
        .menuBarExtraStyle(.window)
    }

    private var icon: String {
        switch yap.state {
        case .idle: return "waveform"
        case .recording: return "mic.fill"
        case .transcribing: return "text.bubble"
        }
    }
}

struct YapMenu: View {
    let yap: Yap

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Yap").font(.headline)

            if !yap.trusted {
                Button("Accessibility is off: Yap can't hear the key or type") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Toggle(
                "Dictate with Right Command",
                isOn: Binding(get: { yap.enabled }, set: { yap.enabled = $0 })
            )
            .help("Hold Right Command and speak, or tap it to record hands free and tap again to send.")
            Toggle(
                "Press Return after dictating",
                isOn: Binding(get: { yap.submits }, set: { yap.submits = $0 })
            )
            .disabled(!yap.enabled)

            Text(yap.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Divider()
            HStack {
                Button("Edit dictionary") { openDictionary() }
                    .help(DictationDictionary.file.path)
                Spacer()
                Button("Quit Yap") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 320)
        .onAppear { yap.refreshTrust() }
    }

    /// Creates an empty, commented dictionary on first use, so there is always
    /// something to open.
    private func openDictionary() {
        let file = DictationDictionary.file
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(
                at: Paths.support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? """
                # Yap dictionary. One term per line; only the first 25 are sent.
                # "heard => written" fixes a mishearing after transcription.

                """.write(to: file, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(file)
    }
}
