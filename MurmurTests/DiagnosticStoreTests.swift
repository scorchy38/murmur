import XCTest
import MurmurKit
@testable import Murmur

@MainActor
final class DiagnosticStoreTests: XCTestCase {
    func testTimelineSurvivesRestartWithIDsOrderAndPrivatePermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = 100.0
        let store = DiagnosticStore(clock: { now }); store.open(at: root)
        let id = UUID(), attempt = UUID()
        store.record(.recordingRequested, id: id, force: true)
        now += 12
        store.record(.transportProgress, id: id, attempt: attempt, values: .init(capturedBytes: 32000), force: true)
        now += 15
        store.record(.transcriptProgress, id: id, attempt: attempt, values: .init(textCharacters: 42, textChanged: true), force: true)
        await store.flush()
        let reopened = DiagnosticStore(); reopened.open(at: root)
        let session = try XCTUnwrap(reopened.sessions.first)
        XCTAssertEqual(session.id, id)
        XCTAssertEqual(session.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(session.events.map(\.elapsedSeconds), [0, 12, 27])
        XCTAssertEqual(session.events.last?.attemptID, attempt)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(id.uuidString + ".json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
    func testBoundedRetentionReportsTruncationAndRotatesOldSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticStore(maxSessions: 2, maxEvents: 3); store.open(at: root)
        let old = UUID()
        store.record(.recordingRequested, id: old, force: true)
        store.record(.recordingRequested, id: UUID(), force: true)
        let recent = UUID()
        for _ in 0..<7 { store.record(.transportProgress, id: recent, force: true) }
        await store.flush()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertFalse(store.sessions.contains { $0.id == old })
        let last = try XCTUnwrap(store.sessions.first { $0.id == recent })
        XCTAssertEqual(last.events.map(\.sequence), [5, 6, 7])
        XCTAssertEqual(last.droppedEvents, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(old.uuidString + ".json").path))
    }
    func testCoalescingKeepsBoundedSamplesAndAlwaysKeepsTerminalEvents() {
        var now = 0.0
        let store = DiagnosticStore(clock: { now }), id = UUID()
        for _ in 0..<50 { store.record(.transportProgress, id: id, coalesce: 1) }
        now = 1
        store.record(.transportProgress, id: id, coalesce: 1)
        store.record(.completed, id: id, force: true)
        XCTAssertEqual(store.sessions.first?.events.map(\.kind), [.transportProgress, .transportProgress, .completed])
    }
    func testStorageFailureLeavesMemoryDiagnosticsAvailableAndClearOnlyDeletesOurFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("user-note.txt")
        try Data("keep".utf8).write(to: unrelated)
        let store = DiagnosticStore(); store.open(at: root)
        store.record(.recordingRequested, id: UUID(), force: true)
        await store.flush(); store.clear(); await store.flush()
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
        let bad = DiagnosticStore(); bad.open(at: unrelated)
        bad.record(.failed, id: UUID(), values: .init(failure: .connection), force: true)
        XCTAssertEqual(bad.storageIssue, .directoryUnavailable)
        XCTAssertEqual(bad.sessions.first?.events.count, 1)
    }
    func testExportIncludesPersistedCountersAndTimelineButNoPrivateStrings() throws {
        let state = AppState(), id = UUID()
        let secret = "private-prompt-api-key-should-never-be-exported"
        state.completedText = secret; state.interimTranscript = secret; state.lastError = secret
        state.deliveryMessage = secret
        state.diagnosticRecordingID = id
        var attempt = VoiceAttemptSummary(), progress = VoiceStreamProgress()
        progress.sentAudioBytes = 64000; progress.receivedMessages = 10
        progress.lastTranscriptChangeSeconds = 4; progress.largestTranscriptChangeGapSeconds = 15
        attempt.streamProgress = progress; attempt.outcome = secret
        state.usageStore.record(VoiceUsageSession(id: id, startedAt: Date(), duration: 5, words: 7, outcome: secret, attempts: [attempt]))
        state.diagnostics.record(.transportProgress, id: id, attempt: attempt.id, values: .init(progress: progress))
        let data = try VoiceDiagnostics(state: state).data()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        let decoded = try JSONDecoder().decode(VoiceDiagnostics.self, from: data)
        XCTAssertEqual(decoded.recentRecordings.first?.id, decoded.timelines.first?.id)
        XCTAssertEqual(decoded.recentRecordings.first?.attempts.first?.outcome, "unknown")
        XCTAssertEqual(decoded.timelines.first?.events.first?.values.progress?.largestTranscriptChangeGapSeconds, 15)
        XCTAssertEqual(decoded.recentRecordings.first?.attempts.first?.streamProgress?.sentAudioBytes, 64000)
    }
}
