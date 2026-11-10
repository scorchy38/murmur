import XCTest
import MurmurKit
@testable import Murmur

@MainActor
final class PersonalizationStoreTests: XCTestCase {
    func testWordsRoundTripAndUpdateBuiltinAliasWithoutDuplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let store = PersonalizationStore(); store.open(at: url)
        let count = store.library.words.count
        try store.addWord(written: "CacheManager", spoken: "cash manager")
        XCTAssertEqual(store.library.words.count, count)
        let reopened = PersonalizationStore(); reopened.open(at: url)
        XCTAssertEqual(reopened.library.words.first { $0.written == "CacheManager" }?.spoken, "cash manager")
        XCTAssertEqual(try reopened.exportData(), try store.exportData())
    }
    func testAmbiguousHistoryDoesNotPreventContextualHintsAndMalformedImportIsRejected() throws {
        let store = PersonalizationStore()
        try store.addWord(written: "ProjectOne", spoken: "project name")
        XCTAssertNoThrow(try store.addWord(written: "ProjectTwo", spoken: "project name"))
        XCTAssertTrue(store.library.hints(for: nil).contains("ProjectTwo"))
        XCTAssertThrowsError(try PersonalizationStore.decodeImport(Data("invalid".utf8)))
        XCTAssertThrowsError(try PersonalizationStore.decodeImport(Data(repeating: 32, count: 3_000_001)))
    }
    func testScopedStylesAndImportPreserveExistingPreferences() throws {
        let store = PersonalizationStore()
        try store.setStyle(.chat, app: "test.chat", name: "Test Chat")
        var incoming = VoicePersonalization()
        incoming.words = [.init(written: "ProjectOne")]
        incoming.snippets = [.init(trigger: "signature", text: "My signature")]
        incoming.appStyles = [.init(bundleID: "test.chat", name: "Test Chat", style: .literal)]
        XCTAssertEqual(try store.merge(incoming), 2)
        XCTAssertEqual(store.library.style(for: "test.chat"), .chat)
        XCTAssertEqual(store.library.style(for: "other"), .natural)
        XCTAssertEqual(try store.merge(incoming), 0)
    }
    func testRenamingEditsTheOriginalEntry() throws {
        let store = PersonalizationStore()
        let word = try XCTUnwrap(store.library.words.first)
        let count = store.library.words.count
        try store.addWord(written: "NewName", spoken: "new name", replacing: word.id)
        XCTAssertEqual(store.library.words.count, count)
        XCTAssertEqual(store.library.words.first { $0.id == word.id }?.written, "NewName")
    }
    func testCorruptFileIsPreservedAndCannotBeOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("library.json")
        let original = Data("invalid".utf8); try original.write(to: url)
        let store = PersonalizationStore(); store.open(at: url)
        XCTAssertNotNil(store.storageError)
        XCTAssertThrowsError(try store.addWord(written: "NewName"))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testLearningAccumulatesAliasesAndLegacyMigrationIsIdempotent() throws {
        let store = PersonalizationStore()
        try store.addWord(written: "CacheManager", spoken: "cash manager")
        try store.addWord(written: "CacheManager", spoken: "cache manager")
        let word = try XCTUnwrap(store.library.words.first { $0.written == "CacheManager" })
        XCTAssertTrue(word.aliases.contains("cash manager"))
        XCTAssertTrue(word.aliases.contains("cache manager"))
        try store.migrateLegacyVocabulary("ProjectName\nशुभ")
        let count = store.library.words.count
        try store.migrateLegacyVocabulary("ProjectName\nशुभ")
        XCTAssertEqual(store.library.words.count, count)
    }

    func testEditsInMurmurLearnOnlyDesiredSpellingsAndRespectSetting() {
        let prefs = UserDefaults(suiteName: "murmur-review-learning-\(UUID().uuidString)")!
        let state = AppState(shadowPreferences: prefs)
        XCTAssertTrue(state.learnFromReview)
        XCTAssertEqual(state.learnReviewedSpellings(original: "use clode and cash store", edited: "use Claude and CacheStore"), 2)
        XCTAssertEqual(state.personalization.library.words.first { $0.written == "Claude" }?.spoken, "")
        XCTAssertEqual(state.learnReviewedSpellings(original: "use clode", edited: "use Claude"), 0)
        state.learnFromReview = false
        XCTAssertEqual(state.learnReviewedSpellings(original: "use racoon", edited: "use Raccoon"), 0)
        XCTAssertFalse(state.personalization.library.words.contains { $0.written == "Raccoon" })
    }

}
