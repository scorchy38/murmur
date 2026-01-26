import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingAPIKey = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            apiTab
                .tabItem { Label("API", systemImage: "key") }

            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420, height: 280)
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Hotkey") {
                Toggle("Enable global hotkey", isOn: $appState.hotkeyEnabled)
                Text("Hold **⌃Space** anywhere to record")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Play sounds", isOn: $appState.soundsEnabled)
                Toggle("Auto-paste at cursor", isOn: $appState.autoInsertText)
                Toggle("Remove filler words", isOn: $appState.removeFillerWords)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[Murmur] Launch at login error: \(error)")
            launchAtLogin = !enabled // Revert
        }
    }

    // MARK: - API Tab

    private var apiTab: some View {
        Form {
            Section("Groq API Key") {
                HStack {
                    Group {
                        if showingAPIKey {
                            TextField("API Key", text: $appState.groqApiKey)
                        } else {
                            SecureField("API Key", text: $appState.groqApiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        showingAPIKey.toggle()
                    } label: {
                        Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }

                Link("Get API key from console.groq.com",
                     destination: URL(string: "https://console.groq.com")!)
                    .font(.caption)
            }

            Section("Model") {
                HStack {
                    Text("whisper-large-v3-turbo")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("100+ languages")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    // MARK: - About Tab

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.primary)

            VStack(spacing: 4) {
                Text("Murmur")
                    .font(.title2.weight(.semibold))

                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Voice dictation for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 12) {
                Button("Clear History") {
                    appState.clearHistory()
                }

                Button("Open Input Monitoring") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
