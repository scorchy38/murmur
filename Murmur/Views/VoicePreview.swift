#if DEBUG
import AppKit
import SwiftUI
import MurmurKit

/// Development-only fixture renderer. No microphone, network, keys, or persistence.
@MainActor
func showVoicePreview(_ scenario: String, state: AppState) -> NSWindow {
    state.voiceEnabled = true
    let sample = "Rename cash manager to CacheManager.\nActually, keep the public interface exactly as it is."
    state.recordingState = .recording
    state.recordingStartDate = Date()
    state.interimTranscript = sample
    state.audioLevels = [0.1, 0.2, 0.4, 0.3, 0.6, 0.85, 0.5, 0.35, 0.7, 0.9, 0.65, 0.4, 0.2, 0.15, 0.3, 0.55]
    switch scenario {
    case "processing": state.recordingState = .transcribing
    case "long": state.interimTranscript = Array(repeating: sample, count: 15).joined(separator: "\n\n")
    case "warmup": state.recordingState = .idle; state.warmingUp = true
    case "result":
        state.recordingState = .idle
        state.completedText = "Rename CacheManager. Keep the public interface exactly as it is."
        state.notice = "Copied to your clipboard. Edit here or paste when you’re ready."
    case "error": state.recordingState = .idle; state.interimTranscript = ""; state.lastError = VoiceFailure.connection.localizedDescription
    default: break
    }
    let root: AnyView
    let size: NSSize
    if scenario == "library" {
        state.store.transcriptions = [
            Transcription(text: "Rename CacheManager. Keep the public interface exactly as it is.", device: "Mac"),
            Transcription(text: "Three things for tomorrow: finish the prototype, share it with the team, and make time to think.", timestamp: Date().addingTimeInterval(-3600), device: "Mac"),
            Transcription(text: "The best tools make room for a thought before it disappears.", timestamp: Date().addingTimeInterval(-7200), device: "iPhone")
        ]
        root = AnyView(LibraryView(store: state.store).environmentObject(state))
        size = NSSize(width: 980, height: 680)
    } else if scenario == "settings" {
        root = AnyView(SettingsView().environmentObject(state))
        size = NSSize(width: 700, height: 600)
    } else if scenario == "menu" {
        state.recordingState = .idle
        root = AnyView(MenuBarView(store: state.store).environmentObject(state))
        size = NSSize(width: 354, height: 430)
    } else {
        root = AnyView(RecordingView(availableHeight: 800).environmentObject(state))
        size = NSSize(width: 1200, height: 800)
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Murmur · \(scenario.capitalized) Preview"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
    window.center()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    FileHandle.standardOutput.write(Data("MURMUR_PREVIEW_WINDOW=\(window.windowNumber) PID=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
    return window
}
#endif
