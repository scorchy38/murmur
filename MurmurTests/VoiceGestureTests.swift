import XCTest
import AppKit
@testable import Murmur
import MurmurKit

@MainActor
final class VoiceGestureTests: XCTestCase {
    private func event(_ type: CGEventType, key: Int64 = 56, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.keyboardEventKeycode, value: key)
        return event
    }

    func testShortShiftAndCapitalTypingDoNotStartRecording() async {
        let manager = HotkeyManager()
        manager.enabled = { true }
        var starts = 0
        manager.onStart = { starts += 1 }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskShift))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged))
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(starts, 0)
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskShift))
        _ = manager.handle(.keyDown, event: event(.keyDown, key: 0, flags: .maskShift))
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(starts, 0)
        manager.reset()
    }

    func testHoldStartsOnceAndReleaseFinishesWithoutInferringRepeats() async {
        let manager = HotkeyManager()
        manager.enabled = { true }
        var starts = 0; var finishes = 0; var warming = false
        manager.onStart = { starts += 1 }
        manager.onFinish = { finishes += 1 }
        manager.onWarmup = { warming = $0 }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskShift))
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(warming)
        XCTAssertEqual(starts, 0)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(starts, 1)
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged))
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(warming)
        manager.reset()
    }

    func testEscapeAndControlCCancelAndAreConsumedBeforeOtherActions() {
        let manager = HotkeyManager()
        manager.canCancel = { true }
        var cancellations = 0
        manager.onCancel = { cancellations += 1 }
        XCTAssertTrue(manager.handle(.keyDown, event: event(.keyDown, key: 53)))
        XCTAssertTrue(manager.handle(.keyDown, event: event(.keyDown, key: 8, flags: .maskControl)))
        XCTAssertEqual(cancellations, 2)
        manager.canCancel = { false }
        XCTAssertFalse(manager.handle(.keyDown, event: event(.keyDown, key: 53)))
    }

    func testModifierShortcutBlocksHoldAdmission() async {
        let manager = HotkeyManager()
        manager.enabled = { true }
        var starts = 0
        manager.onStart = { starts += 1 }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskShift))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, key: 55, flags: [.maskShift, .maskCommand]))
        try? await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(starts, 0)
        manager.reset()
    }
    func testLostEventTapCancelsInsteadOfLeavingTheMicrophoneRunning() {
        let manager = HotkeyManager()
        manager.isActive = { true }
        var cancelled = false
        manager.onCancel = { cancelled = true }
        _ = manager.handle(.tapDisabledByTimeout, event: event(.keyDown))
        XCTAssertTrue(cancelled)
    }

    func testQuestionMarkTypingDoesNotActivateOrFlashWarmup() async {
        let manager = HotkeyManager()
        manager.enabled = { true }
        var starts = 0
        var hints = 0
        manager.onStart = { starts += 1 }
        manager.onWarmup = { if $0 { hints += 1 } }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskShift))
        try? await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(hints, 0)
        _ = manager.handle(.keyDown, event: event(.keyDown, key: 44, flags: .maskShift))
        try? await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(hints, 0)
        manager.reset()
    }

    func testControlOptionStartsImmediatelyAndReleasesOnce() {
        let manager = HotkeyManager(); manager.enabled = { true }; manager.shortcut = { .controlOption }
        var starts = 0; var finishes = 0
        manager.onStart = { starts += 1 }; manager.onFinish = { finishes += 1 }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskControl))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate]))
        XCTAssertEqual(starts, 1)
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate]))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: .maskControl))
        XCTAssertEqual(starts, 1); XCTAssertEqual(finishes, 1)
        manager.reset()
    }
    func testControlSpaceConsumesOnlyItsOwnKeysAndIgnoresRepeats() {
        let manager = HotkeyManager(); manager.enabled = { true }; manager.shortcut = { .controlSpace }
        var starts = 0; var finishes = 0
        manager.onStart = { starts += 1 }; manager.onFinish = { finishes += 1 }
        XCTAssertFalse(manager.handle(.keyDown, event: event(.keyDown, key: 0, flags: .maskControl)))
        XCTAssertTrue(manager.handle(.keyDown, event: event(.keyDown, key: 49, flags: .maskControl)))
        let repeated = event(.keyDown, key: 49, flags: .maskControl)
        repeated.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        XCTAssertTrue(manager.handle(.keyDown, event: repeated))
        XCTAssertTrue(manager.handle(.keyUp, event: event(.keyUp, key: 49, flags: .maskControl)))
        XCTAssertEqual(starts, 1); XCTAssertEqual(finishes, 1)
        manager.reset()
    }
    func testAlternateShortcutRespectsGateAndOtherKeysCancel() {
        let manager = HotkeyManager(); manager.shortcut = { .controlOption }
        var starts = 0; var cancels = 0
        manager.onStart = { starts += 1 }; manager.onCancel = { cancels += 1 }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate]))
        XCTAssertEqual(starts, 0)
        manager.enabled = { true }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate]))
        _ = manager.handle(.keyDown, event: event(.keyDown, key: 0, flags: [.maskControl, .maskAlternate]))
        XCTAssertEqual(starts, 1); XCTAssertEqual(cancels, 1)
        manager.reset()
    }

    func testExtraModifierCancelsAlternateHoldWithoutRestartingOrCommitting() {
        let manager = HotkeyManager(); manager.enabled = { true }; manager.shortcut = { .controlOption }
        var starts = 0; var finishes = 0; var cancels = 0
        manager.onStart = { starts += 1 }; manager.onFinish = { finishes += 1 }; manager.onCancel = { cancels += 1 }
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate]))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate, .maskCommand]))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged, flags: [.maskControl, .maskAlternate]))
        _ = manager.handle(.flagsChanged, event: event(.flagsChanged))
        XCTAssertEqual(starts, 1); XCTAssertEqual(cancels, 1); XCTAssertEqual(finishes, 0)
        manager.reset()
    }

}
