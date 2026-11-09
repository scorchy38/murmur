import XCTest
import AppKit
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
    func testOptionalIndicatorIsSmallAndCannotStealKeyboardFocus() {
        let name = "murmur-shadow-tests-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        let state = AppState(shadowPreferences: preferences)
        state.shadowMode = true; state.shadowIndicatorEnabled = true
        state.recordingState = .recording
        let keyWindow = NSApp.keyWindow
        let existing = Set(NSApp.windows.map(\.windowNumber))
        let overlay = OverlayController(state: state)
        defer { overlay.hide() }
        overlay.show()
        XCTAssertTrue(overlay.isVisible)
        let panel = NSApp.windows.first { !existing.contains($0.windowNumber) && $0.frame.width == 280 }
        XCTAssertNotNil(panel)
        XCTAssertEqual(panel?.frame.height, 58)
        XCTAssertFalse(panel?.canBecomeKey ?? true)
        XCTAssertTrue(panel?.ignoresMouseEvents ?? false)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
    }

}
