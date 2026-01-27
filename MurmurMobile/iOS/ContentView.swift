import SwiftUI
import MurmurKit

struct ContentView: View {
    @EnvironmentObject var store: MurmurStore
    @EnvironmentObject var syncService: SyncService
    @StateObject private var recorder = AudioRecorder()
    @State private var error: String?
    @State private var recordingStartDate: Date?
    @State private var copiedItemId: UUID?
    @State private var showingPeers = false

    private var buttonState: RecordButtonState {
        if store.isTranscribing { return .transcribing }
        if store.isRecording { return .recording }
        return .idle
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.transcriptions.isEmpty && !store.isRecording && !store.isTranscribing {
                    ContentUnavailableView {
                        Label("No Transcriptions", systemImage: MurmurTokens.Symbol.emptyState)
                    } description: {
                        Text("Tap the microphone to start recording")
                    }
                } else {
                    List {
                        if store.isRecording {
                            Section {
                                VStack(spacing: 12) {
                                    MurmurRecordingIndicator(startDate: recordingStartDate)
                                    MurmurWaveformView(levels: recorder.audioLevels)
                                        .frame(height: 44)
                                }
                                .listRowSeparator(.hidden)
                            }
                        }

                        if !store.transcriptions.isEmpty {
                            Section {
                                ForEach(store.transcriptions) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.text)
                                            .font(.body)

                                        metadataRow(for: item)
                                    }
                                    .contextMenu {
                                        Button {
                                            copyText(item.text, itemId: item.id)
                                        } label: {
                                            Label("Copy", systemImage: MurmurTokens.Symbol.copy)
                                        }
                                        ShareLink(item: item.text)
                                        Divider()
                                        Button(role: .destructive) {
                                            store.delete(id: item.id)
                                        } label: {
                                            Label("Delete", systemImage: MurmurTokens.Symbol.delete)
                                        }
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            store.delete(id: item.id)
                                        } label: {
                                            Label("Delete", systemImage: MurmurTokens.Symbol.delete)
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            copyText(item.text, itemId: item.id)
                                        } label: {
                                            Label("Copy", systemImage: MurmurTokens.Symbol.copy)
                                        }
                                        .tint(MurmurTokens.accent)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .animation(MurmurTokens.Anim.stateTransition, value: store.isRecording)
                }
            }
            .sensoryFeedback(.success, trigger: copiedItemId)
            .safeAreaInset(edge: .bottom) {
                recordBar
            }
            .navigationTitle("Murmur")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    syncIndicator
                }
            }
            .onAppear {
                syncService.start { [weak store] transcription in
                    store?.addTranscription(transcription)
                } onConnected: { [weak store, weak syncService] in
                    if let history = store?.transcriptions {
                        syncService?.sendAll(history)
                    }
                }
                Task { await TranscriptionService.shared.syncKeyToAppGroup() }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
        .tint(MurmurTokens.accent)
    }

    // MARK: - Copy

    private func copyText(_ text: String, itemId: UUID) {
        UIPasteboard.general.string = text
        copiedItemId = itemId
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedItemId == itemId {
                copiedItemId = nil
            }
        }
    }

    // MARK: - Metadata Row

    @ViewBuilder
    private func metadataRow(for item: Transcription) -> some View {
        HStack(spacing: 4) {
            if copiedItemId == item.id {
                Image(systemName: "checkmark")
                Text("Copied")
            } else {
                Text(item.timestamp, style: .relative)
                Text("\u{00B7}")
                Text(item.device)
            }
        }
        .font(.caption2)
        .foregroundStyle(copiedItemId == item.id ? MurmurTokens.accent : Color.secondary.opacity(0.6))
        .animation(.easeInOut(duration: 0.2), value: copiedItemId)
    }

    // MARK: - Bottom Record Bar

    private var recordBar: some View {
        VStack(spacing: 6) {
            MurmurRecordButton(state: buttonState, style: .circle) {
                Task { await toggleRecording() }
            }

            if store.isTranscribing {
                Text("Transcribing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .shadow(color: .black.opacity(0.06), radius: 8, y: -4)
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
        .popover(isPresented: $showingPeers) {
            peerList
                .presentationCompactAdaptation(.popover)
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

    // MARK: - Recording

    private func toggleRecording() async {
        if store.isRecording {
            store.isRecording = false
            store.isTranscribing = true
            recordingStartDate = nil

            if let data = recorder.stopRecording() {
                do {
                    let text = try await TranscriptionService.shared.transcribe(audioData: data)
                    let processed = TextProcessor.process(text)
                    store.add(processed, device: "iPhone")
                    UIPasteboard.general.string = processed
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
                error = "Could not start recording. Check microphone permission."
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(MurmurStore())
}
