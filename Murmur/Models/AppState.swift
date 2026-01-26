import SwiftUI
import Combine
import MurmurKit

enum RecordingState: Equatable {
    case idle
    case recording
    case transcribing
}

@MainActor
class AppState: ObservableObject {
    @Published var recordingState: RecordingState = .idle
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 50)
    @Published var lastError: String?

    // Shared store for persistent + synced transcription history
    let store = MurmurStore()

    // Settings
    @AppStorage("groqApiKey") var groqApiKey: String = ""
    @AppStorage("hotkeyEnabled") var hotkeyEnabled: Bool = true
    @AppStorage("soundsEnabled") var soundsEnabled: Bool = true
    @AppStorage("autoInsertText") var autoInsertText: Bool = true
    @AppStorage("removeFillerWords") var removeFillerWords: Bool = true

    var isRecording: Bool {
        recordingState == .recording
    }

    var isTranscribing: Bool {
        recordingState == .transcribing
    }

    func addTranscription(_ text: String) {
        store.add(text, device: "Mac")
    }

    func updateAudioLevels(_ level: CGFloat) {
        audioLevels.removeFirst()
        audioLevels.append(level)
    }

    func clearHistory() {
        store.clear()
    }
}
