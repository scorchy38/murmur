import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import MurmurKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = "Dictation"
    @State private var apiKey = ""
    @State private var savingError: String?
    @State private var connectionStatus: String?
    @State private var testing = false
    @State private var enabling = false
    @State private var testStream: (any VoiceStreaming)?
    @State private var enableTask: Task<Void, Never>?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dictation", systemImage: "waveform").tag("Dictation")
                Label("Connection", systemImage: "key").tag("Connection")
                Label("Privacy", systemImage: "hand.raised").tag("Privacy")
                Label("Updates", systemImage: "arrow.triangle.2.circlepath").tag("Updates")
            }
            .navigationSplitViewColumnWidth(165)
        } detail: {
            Form {
                if selection == "Updates" { UpdateSettingsView() }
                else if selection == "Connection" { connection }
                else if selection == "Privacy" { privacy }
                else { dictation }
            }
            .formStyle(.grouped)
            .navigationTitle(selection)
        }
        .frame(minWidth: 650, minHeight: 530)
        .onAppear { if !appState.hasCredential { selection = "Connection" } }
        .onDisappear { testStream?.cancel(); testStream = nil; enableTask?.cancel(); enableTask = nil; enabling = false; testing = false; apiKey = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appState.refreshPermissions() }
    }

    private var dictation: some View {
        Group {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A shortcut to your thoughts").font(.headline)
                        Text("Hold Shift, speak, then release. Your words take shape in a live preview.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutBadge()
                }.padding(.vertical, 8)
                Toggle("Enable dictation", isOn: Binding(get: { appState.voiceEnabled }, set: { value in
                    if value { enable() }
                    else { appState.setEnabled(false); changed() }
                }))
                .disabled(enabling)
                if enabling { Text("Checking microphone and connection…").font(.caption).foregroundStyle(.secondary) }
                if let savingError { Text(savingError).font(.caption).foregroundStyle(.orange) }
            }
            Section("How you speak") {
                Picker("Gesture", selection: $appState.voiceMode) {
                    Text("Hold Shift").tag("hold")
                    Text("Tap Shift to start / finish").tag("tap")
                }
                .disabled(appState.isActive)
                if appState.mode == .tap {
                    Text("The tap gesture starts in an empty text field. Tap Shift again to finish; your words stay editable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Language", selection: $appState.language) {
                    ForEach(VoiceLanguage.supported, id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
                .disabled(appState.isActive)
                Toggle("Insert into the original text field", isOn: $appState.autoInsertText)
                Text("Murmur inserts only if the original field and selection are unchanged. Otherwise, review and copy the result. Dictation never sends a message for you.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play start and finish sounds", isOn: $appState.soundsEnabled)
            }
            Section("Permissions") {
                permissionRow("Microphone", granted: appState.microphoneGranted, path: "Privacy_Microphone")
                permissionRow("Accessibility", granted: appState.accessibilityGranted, path: "Privacy_Accessibility")
                Text("Accessibility enables the Shift gesture and safe text insertion. You can also record from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch { savingError = "Launch at login could not be updated."; launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
    }

    private var connection: some View {
        Group {
            Section("Your speech connection") {
                Text("Connect with your own API key. It stays in this Mac’s Keychain and is used only to authenticate speech sessions.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField(appState.hasCredential ? "New API key (one is already saved)" : "API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveKey() }
                HStack {
                    Button("Save key") { saveKey() }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isActive)
                    Button(testing ? "Checking…" : "Test connection") { testConnection() }
                        .disabled(!appState.hasCredential || testing || appState.isActive)
                    Spacer()
                    Link("Get an API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                }
                if let connectionStatus { Label(connectionStatus, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                if let savingError { Text(savingError).font(.caption).foregroundStyle(.orange) }
                if appState.hasCredential && !appState.voiceEnabled {
                    Button(enabling ? "Checking setup…" : "Enable dictation") { enable() }
                        .buttonStyle(.borderedProminent)
                        .disabled(enabling || testing)
                }
                Text("A connection check opens a speech session without recording audio. Your speech account’s pricing and quota apply to dictation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Words you use") {
                Text("Add a name, product, or technical term on each line. These hints are sent with your audio. Common coding terms are already included.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $appState.vocabulary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 95)
                    .accessibilityLabel("Custom recognition vocabulary, one term per line")
                Text("Up to 50 unique terms, within 1,024 characters. No files are scanned.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            if appState.hasCredential {
                Section {
                    Button("Remove saved key", role: .destructive) {
                        do {
                            try VoiceCredential.delete()
                            appState.refreshPermissions()
                            appState.setEnabled(false)
                            connectionStatus = "Key removed. Dictation is off."
                            changed()
                        } catch { savingError = error.localizedDescription }
                    }
                    .disabled(appState.isActive || testing)
                }
            }
        }
    }

    private var privacy: some View {
        Group {
            Section("You choose what stays") {
                Toggle("Save transcription history on this Mac", isOn: $appState.saveHistory)
                Text("Up to 50 completed transcriptions are saved. Turning this off stops future saves; existing history remains until you delete it from the Library.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Sync completed text on the local network", isOn: $appState.syncEnabled)
                    .onChange(of: appState.syncEnabled) { _, _ in changed() }
                Text("When enabled, saved transcriptions are shared with Murmur peers on your local network. Use this only on a trusted private network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("While you dictate") {
                Label("Audio streams only during an intentional recording.", systemImage: "mic")
                Label("Recording audio stays in memory and is cleared after completion or cancellation.", systemImage: "memorychip")
                Label("Escape cancels. Recognized words never send a message or run an action.", systemImage: "escape")
                Text("Audio and vocabulary are sent directly to your speech service for recognition. Processing and retention at the service follow your speech account’s terms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Last recording") {
                LabeledContent("Duration", value: String(format: "%.1f seconds", appState.lastDuration))
                LabeledContent("Connection attempts", value: "\(appState.currentAttemptCount)")
                LabeledContent("Audio", value: ByteCountFormatter.string(fromByteCount: Int64(appState.lastAudioBytes), countStyle: .file))
                if let tokens = appState.lastUsageTokens { LabeledContent("Reported usage", value: "\(tokens) tokens") }
                Text("Each connection or recovery attempt may incur usage, even if you cancel or no text is inserted. Operational logs contain counts and outcomes, not recorded speech.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool, path: String) -> some View {
        HStack {
            Label(name, systemImage: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.primary : Color.secondary)
            Spacer()
            if granted { Text("Allowed").font(.caption).foregroundStyle(.secondary) }
            else {
                Button("Open Settings") {
                    if path == "Privacy_Accessibility" {
                        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    }
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(path)") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
    private func saveKey() {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !appState.isActive else { return }
        do {
            try VoiceCredential.save(apiKey)
            apiKey = ""
            savingError = nil
            appState.refreshPermissions()
            connectionStatus = "Saved securely. Test the connection, then enable dictation."
            changed()
        } catch { savingError = error.localizedDescription }
    }
    private func testConnection() {
        guard let key = VoiceCredential.read() else { return }
        testing = true
        connectionStatus = nil
        let stream = NativeVoiceStream(credential: key, language: VoiceLanguage.resolve(appState.language).code, vocabulary: [])
        testStream = stream
        stream.onEvent = { event in
            switch event {
            case .ready:
                connectionStatus = "Connection ready. You can enable dictation."
                testing = false; testStream?.cancel(); testStream = nil
            case .failure(let failure):
                connectionStatus = failure.localizedDescription
                testing = false; testStream?.cancel(); testStream = nil
            default: break
            }
        }
        stream.start()
    }
    private func enable() {
        savingError = nil
        guard let key = VoiceCredential.read() else { savingError = "Save your API key in Connection first."; return }
        enabling = true
        enableTask = Task { @MainActor in
            defer { enabling = false }
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed = permission == .authorized ? true : await AVCaptureDevice.requestAccess(for: .audio)
            guard allowed else { savingError = VoiceFailure.permission.localizedDescription; return }
            do {
                try await AudioRecorder.probe()
                try await NativeVoiceStream.check(credential: key, language: VoiceLanguage.resolve(appState.language).code)
                try Task.checkCancellation()
                appState.refreshPermissions()
                appState.setEnabled(true)
                connectionStatus = "You’re ready. Hold Shift to speak."
                changed()
            } catch {
                if !Task.isCancelled { savingError = error.localizedDescription }
            }
        }
    }
    private func changed() { NotificationCenter.default.post(name: .voiceSettingsChanged, object: nil) }
}
