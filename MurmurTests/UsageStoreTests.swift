import XCTest
@testable import Murmur
import MurmurKit

@MainActor
final class UsageStoreTests: XCTestCase {
    func testSnapshotReplacementPersistenceAndCrashRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let store = UsageStore(); store.open(at: url)
        var attempt = VoiceAttemptSummary()
        attempt.usage = VoiceUsage(inputTokens: 100, outputTokens: 20)
        var session = VoiceUsageSession(duration: 3, words: 0, outcome: "active", attempts: [attempt])
        store.record(session)
        session.attempts[0].usage = VoiceUsage(inputTokens: 200, outputTokens: 40)
        store.record(session)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(VoiceUsageTotals(sessions: store.sessions).inputTokens, 200)
        let reopened = UsageStore(); reopened.open(at: url)
        XCTAssertEqual(reopened.sessions.count, 1)
        XCTAssertEqual(reopened.sessions[0].outcome, "interrupted")
        XCTAssertEqual(VoiceUsageTotals(sessions: reopened.sessions).estimatedCost, Decimal(string: "0.00154"))
        XCTAssertNil(reopened.storageError)
    }
    func testCorruptLedgerIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.json")
        let original = Data("invalid ledger".utf8)
        try original.write(to: url)
        let store = UsageStore(); store.open(at: url)
        store.record(.init(duration: 1, words: 1, outcome: "completed", attempts: []))
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
