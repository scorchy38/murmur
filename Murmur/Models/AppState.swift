import SwiftUI
import AVFoundation
import ApplicationServices
import ServiceManagement
import os
import MurmurKit

@MainActor
final class AppState: ObservableObject {
    @Published var recordingState: RecordButtonState = .idle
    @Published var recordingStartDate: Date?
    @Published var audioLevels: [CGFloat] = Array(repeating: 0, count: 16)
    @Published var interimTranscript = ""
    @Published var warmingUp = false
    @Published var lastError: String?
    @Published var notice: String?
    @Published var completedText = ""
    @Published var hasCredential = VoiceCredential.isStored
    @Published var microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var shortcutListening = false
    @Published var voiceEnabled: Bool
    @Published var connectionReady = false
    @Published var isRecoveredText = false
    @Published var currentAttemptCount = 0
    @Published var lastDuration: TimeInterval = 0
    @Published var lastAudioBytes = 0
    @Published var lastUsageTokens: Int?
    @Published var attempts: [VoiceAttemptSummary] = []
    @Published var lastConnectionLatency: TimeInterval?
    @Published var lastFirstTextLatency: TimeInterval?
    @Published var lastFinalizationLatency: TimeInterval?
    @Published var deliveryOutcome = "none"
    @Published var deliveryCanUndo = false
    @Published var deliveryCanRetry = false
    @Published var deliveryMessage = ""
    @Published var setupVisible = false
    @Published var practiceSession = false
    @Published var practiceText = ""
    @Published var practiceMessage = ""
    @Published var practiceHeardSignal = false
    @Published var practiceClipboardVerified = false
    @Published var practiceShortcutVerified = false
    @Published var lastConnectionCheck: Date?
    @Published var setupPracticePassed: Bool { didSet { shadowPreferences.set(setupPracticePassed, forKey: "setupPracticePassed") } }
    @Published var setupExternalPassed: Bool { didSet { shadowPreferences.set(setupExternalPassed, forKey: "setupExternalPassed") } }
    @Published var voiceShortcutRaw: String { didSet { shadowPreferences.set(voiceShortcutRaw, forKey: "voiceShortcut") } }
    @Published var shadowIndicatorEnabled: Bool { didSet { shadowPreferences.set(shadowIndicatorEnabled, forKey: "shadowIndicatorEnabled") } }
    var shortcut: VoiceShortcut { VoiceShortcut(rawValue: voiceShortcutRaw) ?? .shift }
    var shortcutInstruction: String { "\(mode == .hold ? "Hold" : "Tap") \(shortcut.label)" }
    let store = MurmurStore()
    let usageStore = UsageStore()

    @AppStorage("voiceMode") var voiceMode: String = "hold"
    @Published var holdDelay: Double = UserDefaults.standard.object(forKey: "holdDelay") as? Double ?? 2.0 {
        didSet { UserDefaults.standard.set(holdDelay, forKey: "holdDelay") }
    }
    @AppStorage("voiceLanguage") var language: String = "en"
    @AppStorage("voiceVocabulary") var vocabulary: String = ""
    @AppStorage("soundsEnabled") var soundsEnabled = true
    @AppStorage("autoInsertText") var autoInsertText = true
    private let shadowPreferences: UserDefaults
    @Published var shadowMode: Bool {
        didSet { shadowPreferences.set(shadowMode, forKey: "shadowMode") }
    }
    @Published var launchAtLoginRequested = UserDefaults.standard.object(forKey: "launchAtLoginRequested") as? Bool ?? true
    @Published var loginItemStatus = SMAppService.mainApp.status
    @Published var loginItemError: String?
    @AppStorage("clipboardUndoEnabled") var clipboardUndoEnabled = true
    @AppStorage("saveHistory") var saveHistory = true
    @AppStorage("syncEnabled") var syncEnabled = false

    init(shadowPreferences: UserDefaults = .standard) {
        self.shadowPreferences = shadowPreferences
        self.shadowMode = shadowPreferences.bool(forKey: "shadowMode")
        self.setupPracticePassed = shadowPreferences.bool(forKey: "setupPracticePassed")
        self.setupExternalPassed = shadowPreferences.bool(forKey: "setupExternalPassed")
        self.voiceShortcutRaw = shadowPreferences.string(forKey: "voiceShortcut") ?? "shift"
        self.shadowIndicatorEnabled = shadowPreferences.bool(forKey: "shadowIndicatorEnabled")
        let defaults = UserDefaults.standard
        let nested = defaults.dictionary(forKey: "voice")
        voiceEnabled = VoiceSettings.enabled(nested: nested, legacy: defaults.object(forKey: "voiceEnabled"))
    }
    var mode: VoiceMode { VoiceMode(rawValue: voiceMode) ?? .hold }
    var isRecording: Bool { recordingState == .recording }
    var isTranscribing: Bool { recordingState == .transcribing }
    var isActive: Bool { recordingState != .idle }
    var configuredVocabulary: [String] {
        VoiceVocabulary.sanitized(VoiceVocabulary.coding + vocabulary.components(separatedBy: .newlines))
    }
    func completePractice(text: String, recovered: Bool, copied: Bool) {
        guard practiceSession else { return }
        practiceText = text
        practiceClipboardVerified = copied
        setupPracticePassed = !text.isEmpty && !recovered && copied
        practiceMessage = recovered ? "Recovered preview. Try again to verify a complete transcription." : copied ? "Recognized and copied. Now try it in another app." : "Recognized, but the clipboard couldn't be verified. Try copying again."
        practiceSession = false
    }
    func setEnabled(_ enabled: Bool) {
        var nested = UserDefaults.standard.dictionary(forKey: "voice") ?? [:]
        nested["enabled"] = enabled
        UserDefaults.standard.set(nested, forKey: "voice")
        UserDefaults.standard.set(enabled, forKey: "voiceEnabled")
        voiceEnabled = enabled
        Logger(subsystem: "com.murmur", category: "Voice").info("enablement_changed enabled=\(enabled)")
    }
    func refreshPermissions() {
        let credential = VoiceCredential.isStored
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        if hasCredential != credential { hasCredential = credential }
        if microphoneGranted != microphone { microphoneGranted = microphone }
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
    }
    func updateAudioLevels(_ level: Double) {
        audioLevels.removeFirst()
        audioLevels.append(CGFloat(level))
        if practiceSession && level > 0.01 { practiceHeardSignal = true }
    }
    func clearHistory() { store.clear() }
    func configureLoginItem() {
        let status = SMAppService.mainApp.status
        if launchAtLoginRequested && status != .enabled && status != .requiresApproval { setLaunchAtLogin(true) }
        else { refreshLoginItemStatus() }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginRequested = enabled
        UserDefaults.standard.set(enabled, forKey: "launchAtLoginRequested")
        loginItemError = nil
        do {
            if enabled && SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            else if !enabled && SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch {
            loginItemError = enabled ? "Launch at login needs attention. Open Login Items to check Murmur’s access." : "Launch at login could not be turned off. Open Login Items to check Murmur’s access."
        }
        refreshLoginItemStatus()
    }
    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        if loginItemStatus != status { loginItemStatus = status }
    }
}
