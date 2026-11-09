import Foundation

/// An explicit allowlist: no transcript, vocabulary, audio, credentials or field values.
struct VoiceDiagnostics: Codable {
    struct Attempt: Codable {
        let audioBytes: Int
        let outcome: String
        let reportedTokens: Int?
    }
    let version: String
    let build: String
    let microphoneAllowed: Bool
    let accessibilityAllowed: Bool
    let shortcutListening: Bool
    let shortcut: String
    let mode: String
    let shadowMode: Bool
    let durationSeconds: Double
    let connectionSeconds: Double?
    let firstTextSeconds: Double?
    let finalizationSeconds: Double?
    let delivery: String
    let attempts: [Attempt]

    @MainActor init(state: AppState) {
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        microphoneAllowed = state.microphoneGranted
        accessibilityAllowed = state.accessibilityGranted
        shortcutListening = state.shortcutListening
        shortcut = state.shortcut.rawValue; mode = state.mode.rawValue
        shadowMode = state.shadowMode; durationSeconds = state.lastDuration
        connectionSeconds = state.lastConnectionLatency
        firstTextSeconds = state.lastFirstTextLatency
        finalizationSeconds = state.lastFinalizationLatency
        delivery = DeliveryController.Status(rawValue: state.deliveryOutcome)?.rawValue ?? "unknown"
        attempts = state.attempts.map { Attempt(audioBytes: $0.queuedAudioBytes, outcome: ["active", "early_failure", "no_data", "error", "salvaged", "completed", "cancelled", "disposed", "interrupted"].contains($0.outcome) ? $0.outcome : "unknown", reportedTokens: $0.reportedTokens) }
    }
    func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
