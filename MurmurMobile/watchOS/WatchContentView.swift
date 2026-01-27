import SwiftUI
import MurmurKit

struct WatchContentView: View {
    @EnvironmentObject var store: MurmurStore
    @EnvironmentObject var syncService: SyncService
    @StateObject private var recorder = AudioRecorder()
    @State private var error: String?
    @State private var recordingStartDate: Date?

    private var buttonState: RecordButtonState {
        if store.isTranscribing { return .transcribing }
        if store.isRecording { return .recording }
        return .idle
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if store.isRecording {
                    MurmurRecordingIndicator(startDate: recordingStartDate)

                    MurmurWaveformView(levels: recorder.audioLevels)
                        .frame(height: 28)
                        .transition(.opacity)

                } else if store.isTranscribing {
                    ProgressView()
                    Text("Transcribing...")
                        .font(.caption2)

                } else if let last = store.transcriptions.first {
                    Text(last.text)
                        .font(.caption)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                MurmurRecordButton(state: buttonState, style: .circle) {
                    Task { await toggleRecording() }
                }

                if !store.transcriptions.isEmpty {
                    NavigationLink {
                        WatchHistoryView()
                    } label: {
                        Text("\(store.transcriptions.count) items")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .animation(MurmurTokens.Anim.stateTransition, value: buttonState)
        }
        .onAppear {
            syncService.start { [weak store] transcription in
                store?.addTranscription(transcription)
            } onConnected: { [weak store, weak syncService] in
                if let history = store?.transcriptions {
                    syncService?.sendAll(history)
                }
            }
        }
        .alert("Error", isPresented: .constant(error != nil)) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func toggleRecording() async {
        if store.isRecording {
            store.isRecording = false
            store.isTranscribing = true
            recordingStartDate = nil

            if let data = recorder.stopRecording() {
                do {
                    let text = try await TranscriptionService.shared.transcribe(audioData: data)
                    let processed = TextProcessor.process(text)
                    store.add(processed, device: "Watch")
                    if let latest = store.transcriptions.first {
                        syncService.send(latest)
                    }
                } catch {
                    self.error = error.localizedDescription
                }
            }

            store.isTranscribing = false
        } else {
            let started = await recorder.startRecording()
            if started {
                store.isRecording = true
                recordingStartDate = Date()
            } else {
                error = "Mic access denied"
            }
        }
    }
}

// MARK: - History

struct WatchHistoryView: View {
    @EnvironmentObject var store: MurmurStore
    @State private var copiedItemId: UUID?

    var body: some View {
        List {
            ForEach(store.transcriptions) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text)
                        .font(.caption)
                        .lineLimit(5)

                    HStack(spacing: 4) {
                        if copiedItemId == item.id {
                            Image(systemName: "checkmark")
                            Text("Copied")
                        } else {
                            Text(item.timeAgo)
                            Text("\u{00B7}")
                            Text(item.device)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(copiedItemId == item.id ? MurmurTokens.accent : Color.secondary.opacity(0.6))
                    .animation(.easeInOut(duration: 0.2), value: copiedItemId)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        store.delete(id: item.id)
                    } label: {
                        Label("Delete", systemImage: MurmurTokens.Symbol.delete)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        copyItem(item)
                    } label: {
                        Label("Copy", systemImage: MurmurTokens.Symbol.copy)
                    }
                    .tint(MurmurTokens.accent)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
    }

    private func copyItem(_ item: Transcription) {
        // watchOS has no general pasteboard but we show visual confirmation
        copiedItemId = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedItemId == item.id {
                copiedItemId = nil
            }
        }
    }
}

#Preview {
    WatchContentView()
        .environmentObject(MurmurStore())
}
