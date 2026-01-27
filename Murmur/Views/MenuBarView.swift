import SwiftUI
import MurmurKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var copiedItemId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            Group {
                if appState.isRecording || appState.isTranscribing {
                    RecordingView()
                } else {
                    transcriptionList
                }
            }
            .animation(MurmurTokens.Anim.stateTransition, value: appState.recordingState)

            Divider()

            footerSection
        }
        .frame(width: 340, height: 420)
        .background(.regularMaterial)
    }

    // MARK: - Copy

    private func copyText(_ text: String, itemId: UUID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedItemId = itemId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedItemId == itemId {
                copiedItemId = nil
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: MurmurTokens.Symbol.appIcon)
                    .font(.title3)
                    .foregroundStyle(MurmurTokens.accent)

                Text("Murmur")
                    .font(.headline)
            }

            Spacer()

            if appState.recordingState == .idle {
                MurmurRecordButton(state: .idle, style: .capsule) {
                    NotificationCenter.default.post(name: .startRecording, object: nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Transcription List

    private var transcriptionList: some View {
        Group {
            if appState.store.transcriptions.isEmpty {
                MurmurEmptyStateView()
            } else {
                List {
                    ForEach(appState.store.transcriptions) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.text)
                                .font(.body)
                                .lineLimit(3)

                            HStack(spacing: 4) {
                                if copiedItemId == entry.id {
                                    Image(systemName: "checkmark")
                                    Text("Copied")
                                } else {
                                    Text(entry.timeAgo)
                                    Text("\u{00B7}")
                                    Text(entry.device)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(copiedItemId == entry.id ? MurmurTokens.accent : Color.secondary.opacity(0.6))
                            .animation(.easeInOut(duration: 0.2), value: copiedItemId)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            copyText(entry.text, itemId: entry.id)
                        }
                        .contextMenu {
                            Button {
                                copyText(entry.text, itemId: entry.id)
                            } label: {
                                Label("Copy", systemImage: MurmurTokens.Symbol.copy)
                            }
                            Divider()
                            Button(role: .destructive) {
                                appState.store.delete(id: entry.id)
                            } label: {
                                Label("Delete", systemImage: MurmurTokens.Symbol.delete)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Murmur")

            Spacer()

            Text("Control-Space to record")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: MurmurTokens.Symbol.settings)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
