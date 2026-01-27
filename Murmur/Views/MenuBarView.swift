import SwiftUI
import MurmurKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var syncService: SyncService
    @State private var copiedItemId: UUID?
    @State private var showingPeers = false

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

            syncIndicator

            if appState.recordingState == .idle {
                MurmurRecordButton(state: .idle, style: .capsule) {
                    NotificationCenter.default.post(name: .startRecording, object: nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Sync Indicator

    private var syncIndicator: some View {
        Button {
            showingPeers.toggle()
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .imageScale(.small)
                .foregroundStyle(syncService.isConnected ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPeers) {
            peerList
        }
    }

    private var peerList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if syncService.connectedPeers.isEmpty {
                Label("No peers connected", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(syncService.connectedPeers, id: \.self) { peer in
                    Label(peer, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .font(.subheadline)
        .padding()
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
                                    Text(entry.timestamp, style: .relative)
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
        .environmentObject(SyncService(deviceName: "Preview"))
}
