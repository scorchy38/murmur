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
                Circle().fill(appState.voiceEnabled ? (appState.shortcutListening && !appState.credentialNeedsApproval ? Color.green : Color.orange) : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                Text(appState.voiceEnabled ? (appState.credentialNeedsApproval ? "Unlock key" : appState.shortcutListening ? "Ready" : "Shortcut setup") : "Set up")
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
                        Text(appState.accessibilityGranted ? "The shortcut couldn’t start. Check Murmur’s Accessibility access." : "Allow Accessibility access so your shortcut works outside Murmur.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Allow shortcut") { post(.openShortcutPermissions) }
                            .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 10) {
                    ShortcutBadge(title: appState.shortcut.symbol)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.shortcutInstruction + ". Speak freely.").font(.callout.weight(.medium))
                        Text(appState.shadowMode ? "Shadow Mode · Clipboard only" : "Your words appear where you work.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                WritingContextView(store: appState.personalization)
                Button { post(appState.credentialNeedsApproval ? .showConnectionSettings : .startRecording) } label: {
                    Label(appState.credentialNeedsApproval ? "Unlock speech key" : "Start dictation", systemImage: appState.credentialNeedsApproval ? "key" : "mic.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("Less typing.\nMore thinking.")
                    .font(.system(size: 28, weight: .medium, design: .rounded)).tracking(-0.6)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Connect your speech account, then use your shortcut to dictate a prompt.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up Murmur") { post(.openSettings) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if appState.credentialNeedsApproval && !appState.voiceEnabled {
                Button("Unlock speech key", systemImage: "key") { post(.showConnectionSettings) }
                    .buttonStyle(.borderedProminent)
            }
            if let error = appState.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let suggestion = appState.suggestedCorrection, !appState.isActive {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(suggestion.spoken) → \(suggestion.written)").font(.caption).lineLimit(2)
                    HStack {
                        Button("Remember spelling") {
                            do { try appState.personalization.addWord(written: suggestion.written, spoken: suggestion.spoken); appState.suggestedCorrection = nil; appState.deliveryMessage = "Remembered as a recognition hint." }
                            catch { appState.deliveryMessage = error.localizedDescription }
                        }
                        Button("Dismiss") { appState.suggestedCorrection = nil }
                    }.font(.caption).buttonStyle(.borderless)
                }
            }
            if !appState.isActive && !appState.completedText.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if !appState.deliveryMessage.isEmpty { Text(appState.deliveryMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if !appState.personalizationNotice.isEmpty { Text(appState.personalizationNotice).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Copy again") { post(.copyLastResult) }
                        Button("Review") { post(.reviewLastResult) }
                        Button("Teach") { post(.showWordsSettings) }
                        if appState.deliveryCanUndo { Button("Undo") { post(.undoLastDelivery) }.help("Undo Murmur's unchanged insertion or restore its previous clipboard, within 60 seconds") }
                    }.buttonStyle(.borderless).font(.caption)
                    if appState.deliveryCanRetry { Button("Try original field again") { post(.retryLastInsertion) }.font(.caption) }
                }
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
