import XCTest
import MurmurKit
@testable import Murmur

@MainActor
final class ShadowModeTests: XCTestCase {
    func testShadowModeNeverCreatesOverlayForAnyRecordingState() {
        let name = "murmur-shadow-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let state = AppState(shadowPreferences: preferences)
        XCTAssertFalse(state.shadowMode)
        state.shadowMode = true
        let overlay = OverlayController(state: state)
        for phase in [MurmurKit.RecordButtonState.idle, .recording, .transcribing] {
            state.recordingState = phase
            state.warmingUp = true
            state.completedText = "A completed prompt"
            state.lastError = "A recoverable error"
            overlay.show()
            XCTAssertFalse(overlay.isVisible)
        }
        XCTAssertTrue(AppState(shadowPreferences: preferences).shadowMode)
    }
}
