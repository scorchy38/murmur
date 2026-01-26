import SwiftUI
import MurmurKit

struct ContentView: View {
    @EnvironmentObject var store: MurmurStore
    @EnvironmentObject var syncService: SyncService
    @StateObject private var recorder = AudioRecorder()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Transcription list
                if store.transcriptions.isEmpty {
                    emptyState
                } else {
                    transcriptionList
                }

                Divider()

                // Record button
                recordSection
            }
            .navigationTitle("Murmur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(syncService.isConnected ? .green : .orange)
                            .frame(width: 8, height: 8)
                        Text(syncService.isConnected ? syncService.connectedPeers.joined(separator: ", ") : "No peers")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                syncService.start { [weak store] transcription in
                    store?.addTranscription(transcription)
                } onConnected: { [weak store, weak syncService] in
                    // Send iPhone's history to Mac on connect
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
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("No transcriptions yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap the mic button to start")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    private var transcriptionList: some View {
        List(store.transcriptions) { item in
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.body)
                HStack {
                    Text(item.timeAgo)
                    Text("•")
                    Text(item.device)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                UIPasteboard.general.string = item.text
            }
        }
        .listStyle(.plain)
    }

    private var recordSection: some View {
        VStack(spacing: 12) {
            if store.isRecording {
                // Waveform
                HStack(spacing: 2) {
                    ForEach(0..<recorder.audioLevels.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red)
                            .frame(width: 4, height: max(4, recorder.audioLevels[i] * 40))
                    }
                }
                .frame(height: 40)
                .padding(.horizontal)
            }

            // Button
            Button {
                Task { await toggleRecording() }
            } label: {
                ZStack {
                    Circle()
                        .fill(store.isRecording ? .red.opacity(0.2) : .red.opacity(0.1))
                        .frame(width: 80, height: 80)

                    Circle()
                        .fill(store.isRecording ? .red : .red)
                        .frame(width: 64, height: 64)

                    if store.isTranscribing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: store.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                }
            }
            .disabled(store.isTranscribing)

            Text(store.isRecording ? "Tap to stop" : (store.isTranscribing ? "Transcribing..." : "Tap to record"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 20)
        .background(.bar)
    }

    private func toggleRecording() async {
        if store.isRecording {
            store.isRecording = false
            store.isTranscribing = true

            if let data = recorder.stopRecording() {
                do {
                    let text = try await TranscriptionService.shared.transcribe(audioData: data)
                    let processed = TextProcessor.process(text)
                    store.add(processed, device: "iPhone")
                    UIPasteboard.general.string = processed
                    // Send to Mac over local network
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
