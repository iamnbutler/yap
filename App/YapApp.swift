import Core
import SwiftUI

@main
struct YapApp: App {
    @State private var yap = Yap()

    var body: some Scene {
        // The task lives on the label, not the content: the label is drawn at
        // launch and the menu only when opened, and the hotkey has to work
        // from launch.
        MenuBarExtra {
            YapMenu(yap: yap)
        } label: {
            Image(systemName: icon)
                .task { yap.start() }
        }
        // A native menu, not a panel: only a native menu has submenus, and
        // Recent Transcripts is one.
        .menuBarExtraStyle(.menu)
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
        Text(yap.detail)
        if !yap.trusted {
            Button("Accessibility Is Off: Grant It…") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }

        Divider()
        Button("Copy Last Transcript") {
            if let last = yap.recent.first { yap.copy(last) }
        }
        .disabled(yap.recent.isEmpty)
        Menu("Recent Transcripts") {
            if yap.recent.isEmpty {
                Text("None yet")
            }
            ForEach(Array(yap.recent.enumerated()), id: \.offset) { _, transcript in
                Button(Self.label(for: transcript)) { yap.copy(transcript) }
            }
            Divider()
            Button("Open Transcripts Folder") { yap.openTranscriptsFolder() }
        }

        Divider()
        Toggle(
            "Dictate with \(yap.keyName)",
            isOn: Binding(get: { yap.enabled }, set: { yap.enabled = $0 }))
        Toggle(
            "Press Return After Dictating",
            isOn: Binding(get: { yap.submits }, set: { yap.submits = $0 }))
            .disabled(!yap.enabled)
        Toggle(
            "Keep Transcripts (\(yap.config.retentionDays) Days)",
            isOn: Binding(get: { yap.keepsTranscripts }, set: { yap.keepsTranscripts = $0 }))

        Divider()
        Picker(
            "Transcribe With",
            selection: Binding(get: { yap.engine }, set: { yap.engine = $0 })
        ) {
            Text("This Mac\(Self.note(for: yap.speechModel))").tag(Config.Engine.onDevice)
            Text("OpenAI").tag(Config.Engine.openAI)
        }
        // Only on-device transcripts are cleaned up: OpenAI's come back
        // punctuated, so the submenu is off with it.
        Picker(
            "Clean Up With",
            selection: Binding(get: { yap.refines }, set: { yap.refines = $0 })
        ) {
            Text("Apple Intelligence").tag(true)
                .disabled(yap.refinerUnavailable != nil)
            Text("Nothing").tag(false)
            if let reason = yap.refinerUnavailable {
                Divider()
                Text(reason)
            }
        }
        .disabled(yap.engine != .onDevice)

        Divider()
        Button("Edit Dictionary…") { openDictionary() }
        Button("Edit Settings…") { yap.openConfig() }

        Divider()
        Button("Quit Yap") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// What stands between the speech model and dictating, if anything.
    static func note(for model: OnDeviceTranscription.Availability?) -> String {
        switch model {
        case .downloadable: " (Not Downloaded)"
        case .downloading: " (Downloading…)"
        case .unsupported: " (Not for This Language)"
        case .installed, nil: ""
        }
    }

    /// One line: the time, a warning when it never reached its app, and as much
    /// of the text as fits.
    static func label(for transcript: Transcript) -> String {
        let time = transcript.date.formatted(date: .omitted, time: .shortened)
        let text = transcript.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let preview = text.count > 60 ? text.prefix(60) + "…" : Substring(text)
        return "\(time)  \(transcript.typed ? "" : "⚠︎ ")\(preview)"
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
