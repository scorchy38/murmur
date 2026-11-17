import XCTest
@testable import Murmur

@MainActor
final class RecoveryTests: XCTestCase {
    func testInterruptedDraftSurvivesRelaunchAndUsesPrivateFilePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        let store = RecoveryStore(); store.open(at: url)
        store.checkpoint(id: UUID(), text: "Paragraph one. Do not lose this tail.", interrupted: true, persist: true, force: true)
        let reopened = RecoveryStore(); reopened.open(at: url)
        XCTAssertEqual(reopened.draft?.text, "Paragraph one. Do not lose this tail.")
        XCTAssertTrue(reopened.draft?.interrupted == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        reopened.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testHistoryOffKeepsMemoryRecoveryButRemovesAnyExistingDiskDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("draft.json")
        let store = RecoveryStore(); store.open(at: url)
        store.checkpoint(id: UUID(), text: "Before", persist: true, force: true)
        store.checkpoint(id: UUID(), text: "Private draft", interrupted: true, persist: false, force: true)
        XCTAssertEqual(store.draft?.text, "Private draft")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
