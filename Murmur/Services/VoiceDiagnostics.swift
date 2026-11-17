import Foundation
import MurmurKit

/// Export only typed metadata; never transcript/error strings or field values.
struct VoiceDiagnostics: Codable {
    struct Attempt: Codable {
        let id: UUID
        let audioBytes: Int
        let outcome: String
        let reportedTokens: Int?
        let streamProgress: VoiceStreamProgress?
        let transportFailure: VoiceTransportFailure?
        let transcriptEvents: Int?
        let finalizedSegments: Int?
        let lastTextAudioSeconds: Double?
        let finalizationSeconds: Double?
        init(_ value: VoiceAttemptSummary) {
            id = value.id; audioBytes = value.queuedAudioBytes
            outcome = VoiceDiagnostics.outcome(value.outcome)
            reportedTokens = value.reportedTokens; streamProgress = value.streamProgress
            transportFailure = value.transportFailure; transcriptEvents = value.transcriptEvents
            finalizedSegments = value.finalizedSegments; lastTextAudioSeconds = value.lastTextAudioSeconds
            finalizationSeconds = value.finalizationSeconds
        }
    }
    struct Recording: Codable {
        let id: UUID
        let startedAt: Date
        let durationSeconds: Double
        let outcome: String
        let attempts: [Attempt]
    }
    let schemaVersion: Int
    let exportedAt: Date
    let version: String
    let build: String
    let microphoneAllowed: Bool
    let accessibilityAllowed: Bool
    let shortcutListening: Bool
    let shortcut: String
    let mode: String
    let shadowMode: Bool
    let currentRecordingID: UUID?
    let durationSeconds: Double
    let connectionSeconds: Double?
    let firstTextSeconds: Double?
    let finalizationSeconds: Double?
    let delivery: String
    let attempts: [Attempt]
    let recentRecordings: [Recording]
    let timelines: [DiagnosticSession]
    let diagnosticStorageIssue: DiagnosticStore.StorageIssue?
    let retentionDays: Int

    static func outcome(_ value: String) -> String {
        ["active", "early_failure", "no_data", "error", "salvaged", "completed", "cancelled", "disposed", "interrupted", "empty", "diagnostic"].contains(value) ? value : "unknown"
    }
    @MainActor init(state: AppState) {
        schemaVersion = 2; exportedAt = Date()
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        microphoneAllowed = state.microphoneGranted; accessibilityAllowed = state.accessibilityGranted
        shortcutListening = state.shortcutListening
        shortcut = state.shortcut.rawValue; mode = state.mode.rawValue
        currentRecordingID = state.diagnosticRecordingID
        shadowMode = state.shadowMode; durationSeconds = state.lastDuration
        connectionSeconds = state.lastConnectionLatency; firstTextSeconds = state.lastFirstTextLatency
        finalizationSeconds = state.lastFinalizationLatency
        delivery = DeliveryController.Status(rawValue: state.deliveryOutcome)?.rawValue ?? "unknown"
        attempts = state.attempts.map(Attempt.init)
        recentRecordings = state.usageStore.sessions.suffix(50).map {
            Recording(id: $0.id, startedAt: $0.startedAt, durationSeconds: $0.duration, outcome: Self.outcome($0.outcome), attempts: $0.attempts.map(Attempt.init))
        }
        timelines = state.diagnostics.sessions
        diagnosticStorageIssue = state.diagnostics.storageIssue
        retentionDays = state.diagnostics.retentionDays
    }
    func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
