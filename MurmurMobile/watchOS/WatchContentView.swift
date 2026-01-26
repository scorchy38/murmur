import SwiftUI
import MurmurKit

struct WatchContentView: View {
    @EnvironmentObject var store: MurmurStore
    @EnvironmentObject var syncService: SyncService
    @StateObject private var recorder = AudioRecorder()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if store.isRecording {
                    HStack(spacing: 2) {
                        ForEach(0..<15, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.red)
                                .frame(width: 3, height: max(3, (i < recorder.audioLevels.count ? recorder.audioLevels[i] : 0) * 30))
                        }
                    }
                    .frame(height: 30)

                    Text("Recording...")
                        .font(.caption2)
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

                // Record button
                Button {
                    Task { await toggleRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(store.isRecording ? .red : .red.opacity(0.3))
                            .frame(width: 60, height: 60)

                        Image(systemName: store.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isTranscribing)

                // History button
                if !store.transcriptions.isEmpty {
                    NavigationLink {
                        WatchHistoryView()
                    } label: {
                        Label("History (\(store.transcriptions.count))", systemImage: "list.bullet")
                            .font(.caption)
                    }
                }
            }
            .padding()
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

            if let data = recorder.stopRecording() {
                do {
                    let text = try await TranscriptionService.shared.transcribe(audioData: data)
                    let processed = TextProcessor.process(text)
                    store.add(processed, device: "Watch")
                    // Send to Mac
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
                error = "Mic access denied"
            }
        }
    }
}

// MARK: - History

struct WatchHistoryView: View {
    @EnvironmentObject var store: MurmurStore

    var body: some View {
        List(store.transcriptions) { item in
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.caption)
                    .lineLimit(5)
                HStack(spacing: 2) {
                    Text(item.timeAgo)
                    Text("·")
                    Text(item.device)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        }
        .listStyle(.plain)
        .navigationTitle("History")
    }
}

#Preview {
    WatchContentView()
        .environmentObject(MurmurStore())
}
