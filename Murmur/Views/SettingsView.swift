import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import MurmurKit

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection = "Dictation"
    @State private var apiKey = ""
    @State private var diagnosticsStatus: String?
    @State private var savingError: String?
    @State private var connectionStatus: String?
    @State private var testing = false
    @State private var enabling = false
    @State private var enableGeneration = UUID()
    @State private var credentialTask: Task<Void, Never>?
    @State private var saving = false
    @State private var testStream: (any VoiceStreaming)?
    @State private var enableTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Get started", systemImage: "checklist").tag("Setup")
                Label("Dictation", systemImage: "waveform").tag("Dictation")
                Label("Connection", systemImage: "key").tag("Connection")
                Label("Personalize", systemImage: "character.book.closed").tag("Personalize")
                Label("Usage", systemImage: "chart.bar.xaxis").tag("Usage")
                Label("Privacy", systemImage: "hand.raised").tag("Privacy")
                Label("Updates", systemImage: "arrow.triangle.2.circlepath").tag("Updates")
            }
            .navigationSplitViewColumnWidth(165)
        } detail: {
            Form {
                if selection == "Setup" { SetupView() }
                else if selection == "Updates" { UpdateSettingsView() }
                else if selection == "Connection" { connection }
                else if selection == "Personalize" { PersonalizationView(store: appState.personalization) }
                else if selection == "Usage" { UsageSettingsView(store: appState.usageStore) }
                else if selection == "Privacy" { privacy }
                else { dictation }
            }
            .formStyle(.grouped)
            .navigationTitle(selection == "Setup" ? "Get started" : selection)
        }
        .frame(minWidth: 650, minHeight: 530)
        .onAppear {
            if !appState.hasCredential || !appState.setupPracticePassed { selection = "Setup" }
            appState.setupVisible = selection == "Setup"
        }
        .onChange(of: selection) { _, value in
            appState.setupVisible = value == "Setup"
            if value != "Setup" && appState.practiceSession { NotificationCenter.default.post(name: .cancelRecording, object: nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectWordsSettings)) { _ in selection = "Personalize" }
        .onReceive(NotificationCenter.default.publisher(for: .selectSetupSettings)) { _ in selection = "Setup" }
        .onReceive(NotificationCenter.default.publisher(for: .selectConnectionSettings)) { _ in selection = "Connection" }
        .onReceive(NotificationCenter.default.publisher(for: .selectUpdateSettings)) { _ in selection = "Updates" }
        .onDisappear { appState.setupVisible = false; if appState.practiceSession { NotificationCenter.default.post(name: .cancelRecording, object: nil) }; enableGeneration = UUID(); credentialTask?.cancel(); credentialTask = nil; testStream?.cancel(); testStream = nil; enableTask?.cancel(); enableTask = nil; enabling = false; testing = false; apiKey = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appState.refreshPermissions() }
    }

    private var dictation: some View {
        Group {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A shortcut to your prompts").font(.headline)
                        Text("\(appState.shortcutInstruction), speak, then \(appState.mode == .hold ? "release" : "tap again") to finish your prompt.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutBadge(title: appState.shortcut.symbol)
                }.padding(.vertical, 8)
                Toggle("Enable dictation", isOn: Binding(get: { appState.voiceEnabled }, set: { value in
                    if value { enable() }
                    else { appState.setEnabled(false); changed() }
                }))
                .disabled(enabling)
                if enabling { Text("Checking Keychain, microphone and connection…").font(.caption).foregroundStyle(.secondary) }
                if let savingError { Text(savingError).font(.caption).foregroundStyle(.orange) }
            }
            Section("How you speak") {
                Toggle("Shadow Mode", isOn: $appState.shadowMode)
                    .disabled(appState.isActive)
                    .onChange(of: appState.shadowMode) { _, _ in changed() }
                Text("Dictate without the center-screen overlay. Completed text is copied to your clipboard, ready to paste. The menu bar icon still shows recording and processing; Escape cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if appState.shadowMode {
                    Toggle("Show a small status indicator", isOn: $appState.shadowIndicatorEnabled)
                        .onChange(of: appState.shadowIndicatorEnabled) { _, _ in changed() }
                    Text("An optional pill near the bottom of the screen confirms listening, finishing and completion without taking focus.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Shortcut", selection: $appState.voiceShortcutRaw) {
                    ForEach(VoiceShortcut.allCases, id: \.rawValue) { shortcut in Text(shortcut.label).tag(shortcut.rawValue) }
                }.disabled(appState.isActive)
                    .onChange(of: appState.voiceShortcutRaw) { _, _ in changed() }
                Text(appState.shortcut.conflictAdvice).font(.caption).foregroundStyle(.secondary)
                Picker("Gesture", selection: $appState.voiceMode) {
                    Text("Hold to speak").tag("hold")
                    Text("Tap to start / finish").tag("tap")
                }
                .disabled(appState.isActive)
                .onChange(of: appState.voiceMode) { _, _ in changed() }
                if appState.mode == .hold && appState.shortcut == .shift {
                    Picker("Hold delay", selection: $appState.holdDelay) {
                        Text("1.5 seconds").tag(1.5)
                        Text("2 seconds (default)").tag(2.0)
                        Text("2.5 seconds").tag(2.5)
                        Text("3 seconds").tag(3.0)
                    }
                    .disabled(appState.isActive)
                    Text("A brief Shift press keeps working for capitals and punctuation. Hold Shift alone for the selected delay to start dictation.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if appState.mode == .tap {
                    Text("The tap gesture starts in an empty text field. Tap the shortcut again to finish; your words stay editable.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Language", selection: $appState.language) {
                    Text("Auto · multilingual").tag("auto")
                    ForEach(VoiceLanguage.supported, id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
                .disabled(appState.isActive)
                Toggle("Insert into the original text field", isOn: $appState.autoInsertText)
                    .disabled(appState.shadowMode)
                Text(appState.shadowMode ? "Shadow Mode sends completed text to the clipboard. Your insertion preference is saved for when Shadow Mode is off." : "Murmur inserts only if the original field and selection are unchanged. Otherwise, review and copy the result. Dictation never sends a message for you.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Play start and finish sounds", isOn: $appState.soundsEnabled)
            }
            Section("Permissions") {
                permissionRow("Microphone", granted: appState.microphoneGranted, path: "Privacy_Microphone")
                permissionRow("Accessibility", granted: appState.accessibilityGranted, path: "Privacy_Accessibility")
                if appState.voiceEnabled && !appState.shortcutListening {
                    Text("Your shortcut is waiting for Accessibility access. After granting it, Murmur reconnects the shortcut automatically. If Murmur is already allowed after replacing the app, turn its Accessibility switch off and on again.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Accessibility enables global shortcuts and safe text insertion. You can also record from the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { appState.launchAtLoginRequested }, set: appState.setLaunchAtLogin))
                LabeledContent("Login status", value: appState.loginItemStatus == .enabled ? "Enabled" : appState.loginItemStatus == .requiresApproval ? "Awaiting approval" : "Not enabled")
                if appState.loginItemStatus == .requiresApproval {
                    Text("Allow Murmur in Login Items to finish enabling launch at login.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error = appState.loginItemError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
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
                    Button(saving ? "Saving…" : "Save key") { saveKey() }.accessibilityLabel("Save key").accessibilityIdentifier("connection.save").disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || appState.isActive || saving || testing || enabling)
                    Button(testing ? "Checking…" : "Test connection") { testConnection() }
                        .accessibilityLabel(testing ? "Checking connection" : "Test connection")
                        .accessibilityIdentifier("connection.test")
                        .disabled(!appState.hasCredential || testing || saving || enabling || appState.isActive)
                    Spacer()
                    Link("Get an API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
                }
                if testing || enabling {
                    Button("Cancel check", role: .cancel) {
                        enableGeneration = UUID()
                        credentialTask?.cancel(); credentialTask = nil
                        enableTask?.cancel(); enableTask = nil
                        testStream?.cancel(); testStream = nil
                        testing = false; enabling = false
                        connectionStatus = "Check cancelled. If macOS is still asking for Keychain approval, dismiss that dialog too."
                    }
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
            Section("Make it yours") {
                Button("Personal words, phrases and writing styles") { selection = "Personalize" }
                Text("Your saved words are prioritized as recognition hints. Up to 100 hints are sent per session; your local spelling rules stay available even with a larger library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if appState.hasCredential {
                Section {
                    Button("Remove saved key", role: .destructive) {
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do {
                                try await VoiceCredential.deleteAsync()
                                appState.lastConnectionCheck = nil; appState.setupPracticePassed = false
                                appState.credentialNeedsApproval = false
                                appState.refreshPermissions(); appState.setEnabled(false)
                                connectionStatus = "Key removed. Dictation is off."; changed()
                            } catch { savingError = error.localizedDescription }
                        }
                    }
                    .disabled(appState.isActive || testing || enabling || saving)
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
            Section("Undo and your clipboard") {
                Toggle("Allow temporary clipboard restoration", isOn: $appState.clipboardUndoEnabled)
                    .onChange(of: appState.clipboardUndoEnabled) { _, _ in changed() }
                Text("For up to 60 seconds after dictation, Murmur can keep the previous clipboard in memory so Undo can restore it. Clipboard data marked private or larger than 1 MB is skipped. Another app's copy is never overwritten by Undo. Turning this off immediately forgets the retained clipboard; safe text insertion undo still works.")
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
                if let value = appState.lastConnectionLatency { LabeledContent("Connection ready", value: String(format: "%.2f seconds", value)) }
                if let value = appState.lastFirstTextLatency { LabeledContent("First text", value: String(format: "%.2f seconds", value)) }
                if let value = appState.lastFinalizationLatency { LabeledContent("Finishing", value: String(format: "%.2f seconds", value)) }
                Button("Export diagnostics…") { exportDiagnostics() }
                if let diagnosticsStatus { Text(diagnosticsStatus).font(.caption).foregroundStyle(.secondary) }
                Text("The export contains counts, timings, permission states and bounded outcomes. No audio, prompt text, API key, vocabulary or field contents.")
                    .font(.caption).foregroundStyle(.secondary)
                if let tokens = appState.lastUsageTokens { LabeledContent("Reported usage", value: "\(tokens) tokens") }
                Text("Each connection or recovery attempt may incur usage, even if you cancel or no text is inserted. Operational logs contain counts and outcomes, not recorded speech.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Murmur-diagnostics.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VoiceDiagnostics(state: appState).data().write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            diagnosticsStatus = "Diagnostics saved. You choose whether to share the file."
        } catch { diagnosticsStatus = "Diagnostics could not be saved. Choose another location and try again." }
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
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !appState.isActive, !saving else { return }
        let value = apiKey; apiKey = ""; saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await VoiceCredential.saveAsync(value)
                appState.lastConnectionCheck = nil; appState.setupPracticePassed = false
                appState.credentialNeedsApproval = false
                savingError = nil; appState.refreshPermissions()
                connectionStatus = "Saved securely. Test the connection, then enable dictation."
                changed()
            } catch { savingError = error.localizedDescription }
        }
    }
    private func testConnection() {
        guard !testing, !enabling, !saving, !appState.isActive else { return }
        testing = true
        connectionStatus = "Waiting for Keychain access. Approve macOS’s prompt for Murmur if it appears."
        credentialTask = Task { @MainActor in
            let credential = await VoiceCredential.readAsync()
            guard !Task.isCancelled else { return }
            guard let key = credential else {
                testing = false; appState.credentialNeedsApproval = appState.hasCredential
                connectionStatus = (appState.hasCredential ? VoiceFailure.keychain : .credentials).localizedDescription
                return
            }
            connectionStatus = "Checking the speech connection…"
            let stream = NativeVoiceStream(credential: key, language: VoiceLanguage.resolve(appState.language).code, vocabulary: [], keepaliveEnabled: false)
            testStream = stream
            stream.onEvent = { event in
                switch event {
                case .ready:
                    appState.lastConnectionCheck = Date(); appState.credentialNeedsApproval = false
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
    }
    private func enable() {
        guard !enabling, !testing, !saving, !appState.isActive else { return }
        savingError = nil
        enabling = true
        let owner = UUID(); enableGeneration = owner
        enableTask = Task { @MainActor in
            defer { if enableGeneration == owner { enabling = false } }
            let credential = await VoiceCredential.readAsync()
            guard !Task.isCancelled else { return }
            guard let key = credential else {
                appState.credentialNeedsApproval = appState.hasCredential
                savingError = (appState.hasCredential ? VoiceFailure.keychain : .credentials).localizedDescription
                return
            }
            let permission = AVCaptureDevice.authorizationStatus(for: .audio)
            let allowed = permission == .authorized ? true : await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled else { return }
            guard allowed else { savingError = VoiceFailure.permission.localizedDescription; return }
            do {
                try await AudioRecorder.probe()
                try await NativeVoiceStream.check(credential: key, language: VoiceLanguage.resolve(appState.language).code)
                appState.lastConnectionCheck = Date()
                try Task.checkCancellation()
                appState.refreshPermissions()
                appState.setEnabled(true)
                connectionStatus = "You’re ready. \(appState.shortcutInstruction) to speak. Try Get started to verify delivery."
                changed()
            } catch {
                if !Task.isCancelled { savingError = error.localizedDescription }
            }
        }
    }
    private func changed() { NotificationCenter.default.post(name: .voiceSettingsChanged, object: nil) }
}
