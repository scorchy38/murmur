import SwiftUI
import MurmurKit

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var hoveredEntryId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header with record button
            headerSection

            Divider()

            // Main content area
            if appState.isRecording || appState.isTranscribing {
                RecordingView()
            } else {
                transcriptionList
            }

            Divider()

            // Footer
            footerSection
        }
        .frame(width: 340, height: 420)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 12) {
            // App icon and name
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(.primary)

                Text("Murmur")
                    .font(.headline)
            }

            Spacer()

            // Record button (only when idle)
            if appState.recordingState == .idle {
                Button {
                    NotificationCenter.default.post(name: .startRecording, object: nil)
                } label: {
                    Label("Record", systemImage: "mic.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Start recording (⌃Space)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Transcription List

    private var transcriptionList: some View {
        Group {
            if appState.store.transcriptions.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(appState.store.transcriptions) { entry in
                            TranscriptionRow(
                                entry: entry,
                                isHovered: hoveredEntryId == entry.id
                            )
                            .onHover { isHovered in
                                hoveredEntryId = isHovered ? entry.id : nil
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            VStack(spacing: 6) {
                Text("No transcriptions yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("Hold **⌃Space** or click Record")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            // Quit button
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Murmur")

            Spacer()

            // Hotkey hint
            Text("⌃Space to record")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Spacer()

            // Settings button
            Button {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            } label: {
                Image(systemName: "gear")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Transcription Row

struct TranscriptionRow: View {
    let entry: Transcription
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .font(.system(.body))
                .lineLimit(3)

            HStack(spacing: 4) {
                Text(entry.timeAgo)
                Text("·")
                Text(entry.device)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
        }
        .help("Click to copy")
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
