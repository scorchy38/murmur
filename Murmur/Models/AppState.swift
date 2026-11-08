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
    @AppStorage("saveHistory") var saveHistory = true
    @AppStorage("syncEnabled") var syncEnabled = false

    init(shadowPreferences: UserDefaults = .standard) {
        self.shadowPreferences = shadowPreferences
        self.shadowMode = shadowPreferences.bool(forKey: "shadowMode")
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
