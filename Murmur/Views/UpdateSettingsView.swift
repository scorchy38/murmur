import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject private var updater = AppUpdater.shared
    @EnvironmentObject var appState: AppState
    var body: some View {
        Section("Keep Murmur up to date") {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: updater.setAutomaticChecks))
            Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticallyInstalls }, set: updater.setAutomaticInstalls))
                .disabled(!updater.automaticallyChecks)
            Text("Murmur checks GitHub releases hourly and at launch. Updates are verified before installation. A recording is allowed to finish before Murmur restarts.")
                .font(.caption).foregroundStyle(.secondary)
            Button(updater.isChecking ? "Checking for updates…" : "Check for Updates…") { updater.check() }
                .buttonStyle(.bordered)
                .disabled(!updater.canRequestCheck || appState.isActive)
            if let last = updater.lastChecked {
                LabeledContent("Last checked", value: last.formatted(date: .abbreviated, time: .shortened))
            }
            if let status = updater.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("View releases on GitHub", destination: URL(string: "https://github.com/scorchy38/murmur/releases")!)
        }
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared
    @EnvironmentObject var appState: AppState
    var body: some View {
        Button(updater.isChecking ? "Checking for updates…" : "Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
            NotificationCenter.default.post(name: .checkForUpdates, object: nil)
        }
        .buttonStyle(.plain)
        .disabled(!updater.canRequestCheck || appState.isActive)
    }
}
