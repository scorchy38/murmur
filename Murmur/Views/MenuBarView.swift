import SwiftUI
import MurmurKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: MurmurStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label {
                    Text("Murmur")
                } icon: {
                    Image("StatusBarIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                    .font(.headline)
                Spacer()
                Circle().fill(appState.voiceEnabled ? (appState.shortcutListening ? Color.green : Color.orange) : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(appState.voiceEnabled ? (appState.shortcutListening ? "Ready" : "Shortcut setup") : "Set up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if appState.isActive {
                Text(appState.isRecording ? "Listening to your prompt." : "Finishing your prompt…")
                    .font(.title3.weight(.medium))
                if !appState.interimTranscript.isEmpty {
                    Text(appState.interimTranscript).lineLimit(3).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel", role: .cancel) { post(.cancelRecording) }
                    Spacer()
                    if appState.isRecording { Button("Finish") { post(.stopRecording) }.buttonStyle(.borderedProminent) }
                }
            } else if appState.voiceEnabled {
                if !appState.shortcutListening {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.accessibilityGranted ? "The Shift shortcut couldn’t start. Check Murmur’s Accessibility access." : "Allow Accessibility access so Murmur can hear the Shift shortcut outside the app.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Allow Shift shortcut") { post(.openShortcutPermissions) }
                            .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 10) {
                    ShortcutBadge()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.mode == .hold ? "Hold Shift. Speak freely." : "Tap Shift. Speak freely.").font(.callout.weight(.medium))
                        Text(appState.shadowMode ? "Shadow Mode · Clipboard only" : "Your words appear where you work.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { post(.startRecording) } label: {
                    Label("Start dictation", systemImage: "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("Less typing.\nMore thinking.")
                    .font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect your speech account, then hold Shift to dictate a prompt.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up Murmur") { post(.openSettings) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if let error = appState.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if let latest = store.transcriptions.first {
                VStack(alignment: .leading, spacing: 7) {
                    Text("LAST PROMPT").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(latest.text)
                        .font(.callout)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, maxHeight: 54, alignment: .topLeading)
                        .clipped()
                    HStack {
                        Text(latest.timestamp, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(latest.text, forType: .string)
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
                Divider()
            }
            HStack {
                Button("Library", systemImage: "text.book.closed") { post(.openLibrary) }
                Spacer()
                Button { post(.openSettings) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                    .help("Settings").accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain)
                    .frame(width: 28, height: 28)
                    .help("Quit Murmur").accessibilityLabel("Quit Murmur")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            CheckForUpdatesButton().buttonStyle(.borderless).font(.callout)
        }
        .padding(22)
        .frame(width: 354)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
    }
    private func post(_ notification: Notification.Name) { NotificationCenter.default.post(name: notification, object: nil) }
}
