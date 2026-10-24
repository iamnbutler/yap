@preconcurrency import AVFoundation
import Core
import SwiftUI

struct ContentView: View {
    let session: Session

    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardSeen = Bridge.keyboardSeen()
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var maskedKey = APIKey.masked
    @State private var trial = ""

    var body: some View {
        NavigationStack {
            List {
                sessionSection
                if keyboardSeen == nil || microphone != .granted || maskedKey == nil {
                    setupSection
                }
                Section("Try It") {
                    TextField("Switch to the Yap keyboard and dictate here", text: $trial, axis: .vertical)
                        .lineLimit(3...8)
                }
                settingsSection
                recentSection
            }
            .navigationTitle("Yap")
        }
        .onChange(of: scenePhase) {
            guard scenePhase == .active else { return }
            keyboardSeen = Bridge.keyboardSeen()
            microphone = AVAudioApplication.shared.recordPermission
            session.reloadConfig()
        }
    }

    // MARK: Session

    @ViewBuilder private var sessionSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(session.phase == .off ? Color.secondary : Color.accentColor)
                    .symbolEffect(.pulse, isActive: session.phase == .recording)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let expires = session.expires, session.phase == .ready {
                        Text("Ends \(expires, style: .relative)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if session.phase == .recording || session.phase == .transcribing {
                // Arrived from the keyboard: the way back is the system's
                // "◀ App" in the corner; iOS has no API to go back for you.
                Label(
                    "Go back with ◀ in the top-left corner and keep talking. Tap ✓ on the keyboard when you're done.",
                    systemImage: "arrow.uturn.backward"
                )
                .font(.callout)
                if !session.preview.isEmpty {
                    Text(session.preview).foregroundStyle(.secondary)
                }
            }
            if let message = session.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            switch session.phase {
            case .off:
                Button("Start Session") { Task { await session.start() } }
            case .ready:
                Button("End Session", role: .destructive) { session.end() }
            case .recording:
                Button("Stop and Insert") { session.send() }
                Button("Cancel", role: .destructive) { session.cancel() }
            case .transcribing:
                Button("Cancel", role: .destructive) { session.cancel() }
            }
        } footer: {
            Text(
                "A session keeps the microphone open in the background, so the keyboard can dictate without opening Yap each time. Nothing is kept or sent until you tap the microphone."
            )
        }
    }

    private var icon: String {
        switch session.phase {
        case .off: "mic.slash"
        case .ready: "mic"
        case .recording: "waveform"
        case .transcribing: "text.bubble"
        }
    }

    private var title: String {
        switch session.phase {
        case .off: "No session"
        case .ready: "Ready to dictate"
        case .recording: "Listening…"
        case .transcribing: "Transcribing…"
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section("Set Up") {
            SetupRow(
                done: keyboardSeen != nil, title: "Add the Yap keyboard",
                detail: "Settings › Apps › Yap › Keyboards: turn on Yap and Allow Full Access. Then open the keyboard once."
            ) {
                Button("Open Settings") {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                }
            }
            SetupRow(
                done: microphone == .granted, title: "Allow the microphone",
                detail: microphone == .denied
                    ? "It was turned off. Turn it on in Settings › Apps › Yap."
                    : "Asked the first time you start a session."
            ) {
                if microphone == .undetermined {
                    Button("Allow") {
                        Task {
                            _ = await AVAudioApplication.requestRecordPermission()
                            microphone = AVAudioApplication.shared.recordPermission
                        }
                    }
                }
            }
            SetupRow(
                done: maskedKey != nil, title: "Add an OpenAI key",
                detail: "Yap sends each clip to OpenAI to transcribe it."
            ) {
                NavigationLink("Add Key") { KeyView(maskedKey: $maskedKey) }
            }
        }
    }

    // MARK: Settings

    private var settingsSection: some View {
        Section("Settings") {
            NavigationLink {
                DictionaryView()
            } label: {
                LabeledContent("Dictionary", value: dictionarySummary)
            }
            NavigationLink {
                KeyView(maskedKey: $maskedKey)
            } label: {
                LabeledContent("OpenAI Key", value: maskedKey ?? "Not set")
            }
            Picker("Session Length", selection: Binding(get: { session.minutes }, set: { session.minutes = $0 })) {
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("1 hour").tag(60)
                Text("4 hours").tag(240)
            }
            Toggle(
                "Live Preview",
                isOn: Binding(get: { session.config.overlay }, set: { on in session.update { $0.overlay = on } }))
            Toggle(
                "Keep Transcripts (\(session.config.retentionDays) Days)",
                isOn: Binding(
                    get: { session.config.keepTranscripts },
                    set: { on in session.update { $0.keepTranscripts = on } }))
        }
    }

    private var dictionarySummary: String {
        let dictionary = DictationDictionary.load()
        return "\(dictionary.terms.count) terms, \(dictionary.fixes.count) fixes"
    }

    // MARK: Transcripts

    @ViewBuilder private var recentSection: some View {
        if !session.recent.isEmpty {
            Section {
                ForEach(Array(session.recent.enumerated()), id: \.offset) { _, transcript in
                    Button {
                        UIPasteboard.general.string = transcript.text
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(transcript.text).foregroundStyle(.primary).lineLimit(3)
                            Text(transcript.date, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Recent")
            } footer: {
                Text("Tap one to copy it.")
            }
        }
    }
}

private struct SetupRow<Action: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !done {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    action.buttonStyle(.bordered).padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct KeyView: View {
    @Binding var maskedKey: String?
    @State private var key = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                SecureField("sk-…", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text(
                    "Kept in this iPhone's Keychain, where only the Yap app can read it. The keyboard never sees it."
                )
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if maskedKey != nil {
                Button("Remove Key", role: .destructive) {
                    try? APIKey.save("")
                    maskedKey = nil
                    dismiss()
                }
            }
        }
        .navigationTitle("OpenAI Key")
        .toolbar {
            Button("Save") {
                do {
                    try APIKey.save(key)
                    maskedKey = APIKey.masked
                    dismiss()
                } catch {
                    self.error = "Couldn't save it: \(error.localizedDescription)"
                }
            }
            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}

/// `dictionary.txt`, in the same format as on the Mac.
struct DictionaryView: View {
    @State private var text = ""
    @State private var loaded = false

    private static let template = """
        # One term per line; only the first 25 are sent.
        # "heard => written" fixes a mishearing after transcription.

        """

    var body: some View {
        let dictionary = DictationDictionary.parse(text)
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 8)
            Text(summary(dictionary))
                .font(.footnote)
                .foregroundStyle(dictionary.terms.count > DictationDictionary.promptLimit ? .orange : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.bar)
        }
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = (try? String(contentsOf: DictationDictionary.file, encoding: .utf8)) ?? Self.template
        }
        // Saved as you type: it's read fresh for every clip anyway.
        .onChange(of: text) { save() }
    }

    private func summary(_ dictionary: DictationDictionary) -> String {
        let terms = dictionary.terms.count
        let sent = min(terms, DictationDictionary.promptLimit)
        var line = "\(terms) terms (\(sent) sent), \(dictionary.fixes.count) fixes."
        if terms > DictationDictionary.promptLimit {
            line += " More terms measured worse, not better: keep the list short and use fixes for the rest."
        }
        return line
    }

    private func save() {
        guard loaded else { return }
        try? FileManager.default.createDirectory(
            at: Paths.support, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? text.write(to: DictationDictionary.file, atomically: true, encoding: .utf8)
    }
}
