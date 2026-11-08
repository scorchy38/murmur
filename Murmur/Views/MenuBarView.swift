import SwiftUI
import MurmurKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store: MurmurStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Murmur", systemImage: "waveform")
                    .font(.headline)
                Spacer()
                Circle().fill(appState.voiceEnabled ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(appState.voiceEnabled ? "Ready" : "Set up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if appState.isActive {
                Text(appState.isRecording ? "Listening to your next thought." : "Finishing your thought…")
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
                HStack(spacing: 10) {
                    ShortcutBadge()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.mode == .hold ? "Hold Shift. Speak freely." : "Tap Shift. Speak freely.").font(.callout.weight(.medium))
                        Text("Your words appear where you work.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { post(.startRecording) } label: {
                    Label("Start dictation", systemImage: "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("Less typing.\nMore thinking.")
                    .font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
                Text("Connect your speech account, then hold Shift to turn a thought into text.")
                    .font(.callout).foregroundStyle(.secondary)
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
                    Text("LAST THOUGHT").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Text(latest.text).font(.callout).lineLimit(3).textSelection(.enabled)
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
                    .help("Settings").accessibilityLabel("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Murmur").accessibilityLabel("Quit Murmur")
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 354)
        .background(.regularMaterial)
    }
    private func post(_ notification: Notification.Name) { NotificationCenter.default.post(name: notification, object: nil) }
}
