import XCTest
@testable import Murmur

@MainActor
final class SetupTests: XCTestCase {
    private func preferences() -> (String, UserDefaults) {
        let name = "murmur-setup-tests-\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }
    func testOnlyFinalRecognizedAndCopiedPracticeCompletesSetup() {
        let (name, preferences) = preferences(); defer { preferences.removePersistentDomain(forName: name) }
        let state = AppState(shadowPreferences: preferences)
        state.practiceText = "Manually typed text"
        XCTAssertFalse(state.setupPracticePassed)
        state.practiceSession = true
        state.completePractice(text: "Recovered preview", recovered: true, copied: true)
        XCTAssertFalse(state.setupPracticePassed)
        state.practiceSession = true
        state.completePractice(text: "Final text", recovered: false, copied: false)
        XCTAssertFalse(state.setupPracticePassed)
        state.practiceSession = true
        state.completePractice(text: "Final private text", recovered: false, copied: true)
        XCTAssertTrue(state.setupPracticePassed)
        XCTAssertFalse(state.practiceSession)
        XCTAssertFalse(String(describing: preferences.persistentDomain(forName: name)).contains("Final private text"))
    }
    func testCancelledPracticeCannotBeResurrectedByLateCompletion() {
        let (name, preferences) = preferences(); defer { preferences.removePersistentDomain(forName: name) }
        let state = AppState(shadowPreferences: preferences)
        state.practiceSession = false
        state.completePractice(text: "Late transcript", recovered: false, copied: true)
        XCTAssertFalse(state.setupPracticePassed)
        XCTAssertTrue(state.practiceText.isEmpty)
    }
    func testShortcutAndIndicatorPreferencesPersistWithoutChangingDefaults() {
        let (name, preferences) = preferences(); defer { preferences.removePersistentDomain(forName: name) }
        let first = AppState(shadowPreferences: preferences)
        XCTAssertEqual(first.shortcut, .shift)
        XCTAssertFalse(first.shadowIndicatorEnabled)
        first.voiceShortcutRaw = "controlOption"; first.shadowIndicatorEnabled = true
        let second = AppState(shadowPreferences: preferences)
        XCTAssertEqual(second.shortcut, .controlOption)
        XCTAssertTrue(second.shadowIndicatorEnabled)
        second.voiceShortcutRaw = "invalid"
        XCTAssertEqual(second.shortcut, .shift)
    }
}
