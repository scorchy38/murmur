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
    if scenario == "library" || scenario == "library-small" {
        state.store.transcriptions = [
            Transcription(text: Array(repeating: "Write a clear implementation plan for the next release. Preserve existing behavior, describe the risks, and include the validation needed before publishing.", count: 8).joined(separator: "\n\n"), device: "Mac"),
            Transcription(text: "Three things for tomorrow: finish the prototype, share it with the team, and make time to think.", timestamp: Date().addingTimeInterval(-3600), device: "Mac"),
            Transcription(text: "The best tools make room for a thought before it disappears.", timestamp: Date().addingTimeInterval(-7200), device: "iPhone")
        ]
        root = AnyView(LibraryView(store: state.store).environmentObject(state))
        size = scenario == "library-small" ? NSSize(width: 900, height: 580) : NSSize(width: 1080, height: 720)
    } else if scenario == "personal" {
        state.recordingState = .idle
        state.writingAppID = "com.example.editor"; state.writingAppName = "Codex"
        try? state.personalization.addWord(written: "CacheManager", spoken: "cash manager; cache manager")
        root = AnyView(Form { PersonalizationView(store: state.personalization) }.formStyle(.grouped).environmentObject(state))
        size = NSSize(width: 560, height: 720)
    } else if scenario == "personal-menu" {
        state.recordingState = .idle; state.shortcutListening = true
        state.writingAppID = "com.example.editor"; state.writingAppName = "Codex"
        state.store.transcriptions = [Transcription(text: "Please update CacheManager. Do not change the public interface.", device: "Mac")]
        root = AnyView(MenuBarView(store: state.store).environmentObject(state))
        size = NSSize(width: 354, height: 560)
    } else if scenario == "setup" {
        state.recordingState = .idle
        state.hasCredential = true; state.microphoneGranted = true
        state.practiceText = "Murmur is ready for my next idea."
        state.practiceMessage = "Recognized and copied. Now try it in another app."
        state.practiceHeardSignal = true
        root = AnyView(Form { SetupView() }.formStyle(.grouped).environmentObject(state))
        size = NSSize(width: 540, height: 680)
    } else if scenario == "shadow-indicator" {
        root = AnyView(ShadowStatusView().environmentObject(state))
        size = NSSize(width: 280, height: 85)
    } else if scenario == "recovery" {
        state.recordingState = .idle
        state.store.transcriptions = []
        state.shortcutListening = true
        state.completedText = sample
        state.deliveryMessage = "Your field or cursor changed. Copied instead; try again or review the result."
        state.deliveryCanRetry = true; state.deliveryCanUndo = true
        root = AnyView(MenuBarView(store: state.store).environmentObject(state))
        size = NSSize(width: 354, height: 600)
    } else if scenario == "usage" {
        for offset in 0..<7 {
            var attempt = VoiceAttemptSummary()
            attempt.usage = VoiceUsage(totalTokens: 1600, inputTokens: 1500, outputTokens: 100)
            attempt.outcome = "completed"
            state.usageStore.record(VoiceUsageSession(startedAt: Date().addingTimeInterval(Double(-offset * 86400)), duration: 60, words: 140 + offset * 12, outcome: "completed", attempts: [attempt]))
        }
        root = AnyView(Form { UsageSettingsView(store: state.usageStore) }.formStyle(.grouped))
        size = NSSize(width: 520, height: 650)
    } else if scenario == "settings" {
        root = AnyView(SettingsView().environmentObject(state))
        size = NSSize(width: 700, height: 600)
    } else if scenario == "menu" || scenario == "menu-long" {
        state.recordingState = .idle
        state.shortcutListening = true
        if scenario == "menu-long" {
            state.store.transcriptions = [Transcription(text: String(repeating: "This is a long dictated prompt that should stay inside its preview and never overlap the timestamp or the menu controls. ", count: 12), device: "Mac")]
        }
        root = AnyView(MenuBarView(store: state.store).environmentObject(state))
        size = NSSize(width: 354, height: 460)
    } else {
        root = AnyView(RecordingView(availableHeight: 800).environmentObject(state))
        size = NSSize(width: 1200, height: 800)
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = "Murmur · \(scenario.capitalized) Preview"
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    let content = NSHostingView(rootView: root.background(Color(nsColor: .windowBackgroundColor)))
    content.sizingOptions = []
    content.autoresizingMask = [.width, .height]
    window.contentView = content
    window.setContentSize(size)
    window.center()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    FileHandle.standardOutput.write(Data("MURMUR_PREVIEW_WINDOW=\(window.windowNumber) PID=\(ProcessInfo.processInfo.processIdentifier)\n".utf8))
    return window
}
#endif
