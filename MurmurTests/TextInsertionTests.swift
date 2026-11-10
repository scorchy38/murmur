import XCTest
import AppKit
import ApplicationServices
@testable import Murmur

@MainActor
private final class InsertionPlatform: TextInsertionEnvironment {
    var trusted = true
    var frontmostPID: pid_t? = 12345
    var secureInput = false
    let element = AXUIElementCreateApplication(12345)
    var focusChanged = false
    var value: String? = "draft "
    var range: NSRange? = NSRange(location: 6, length: 0)
    var password = false
    var editable = true
    var preferPaste = false
    var settable = false
    var result = AXError.success
    var writes = 0
    var pastes: [String] = []
    var clipboardMatches = true
    var simulateUnreadableWrite = false
    func focused(in process: pid_t) -> AXUIElement? { focusChanged ? AXUIElementCreateApplication(54321) : element }
    func text(_ element: AXUIElement) -> String? { value }
    func selection(_ element: AXUIElement) -> NSRange? { range }
    func secure(_ element: AXUIElement) -> Bool { password }
    func pasteable(_ element: AXUIElement) -> Bool { editable }
    func prefersPaste(_ element: AXUIElement) -> Bool { preferPaste }
    func selectedTextSettable(_ element: AXUIElement) -> Bool { settable }
    func replace(_ element: AXUIElement, text: String) -> AXError {
        writes += 1
        if result == .success, let value, let range {
            self.value = simulateUnreadableWrite ? nil : (value as NSString).replacingCharacters(in: range, with: text)
        }
        return result
    }
    func select(_ element: AXUIElement, range: NSRange) -> Bool { self.range = range; return true }
    func paste(text: String, process: pid_t) -> Bool {
        guard clipboardMatches else { return false }
        pastes.append(text); return true
    }
}

@MainActor
final class TextInsertionTests: XCTestCase {
    func testTerminalWithoutValueOrSelectionUsesGuardedPaste() {
        let platform = InsertionPlatform(); platform.value = nil; platform.range = nil
        let inserter = TextInserter(environment: platform)
        inserter.capture()
        XCTAssertEqual(inserter.insert("a multiline\nprompt"), .pasted)
        XCTAssertEqual(platform.pastes, ["a multiline\nprompt"])
        XCTAssertEqual(platform.writes, 0)
        XCTAssertFalse(inserter.undo(), "Dispatched paste has no verified AX undo receipt")
    }
    func testBrowserWithNonsettableSelectedTextUsesPaste() {
        let platform = InsertionPlatform()
        let inserter = TextInserter(environment: platform)
        inserter.capture()
        XCTAssertEqual(inserter.insert("prompt"), .pasted)
        XCTAssertEqual(platform.pastes, ["prompt"])
    }
    func testChangedAppFieldContentsOrCursorNeverReceivesPaste() {
        for mutation in 0..<4 {
            let platform = InsertionPlatform()
            let inserter = TextInserter(environment: platform)
            inserter.capture()
            switch mutation {
            case 0: platform.frontmostPID = 54321
            case 1: platform.focusChanged = true
            case 2: platform.value = "I edited this"
            default: platform.range = NSRange(location: 0, length: 0)
            }
            XCTAssertEqual(inserter.insert("prompt"), .changed)
            XCTAssertTrue(platform.pastes.isEmpty)
        }
    }
    func testPasswordsSecureInputAndNoneditorsNeverReceivePaste() {
        for mutation in 0..<3 {
            let platform = InsertionPlatform()
            let inserter = TextInserter(environment: platform)
            inserter.capture()
            switch mutation {
            case 0: platform.password = true
            case 1: platform.secureInput = true
            default: platform.editable = false
            }
            XCTAssertEqual(inserter.insert("prompt"), .unavailable)
            XCTAssertTrue(platform.pastes.isEmpty)
        }
    }
    func testWebEditorBypassesMisleadingWritableAXAttribute() {
        let platform = InsertionPlatform(); platform.settable = true; platform.preferPaste = true
        let inserter = TextInserter(environment: platform)
        inserter.capture()
        XCTAssertEqual(inserter.insert("prompt"), .pasted)
        XCTAssertEqual(platform.writes, 0)
        XCTAssertEqual(platform.pastes, ["prompt"])
    }
    func testSuccessfulAXWriteDoesNotAlsoPaste() {
        let platform = InsertionPlatform(); platform.settable = true
        let inserter = TextInserter(environment: platform)
        inserter.capture()
        XCTAssertEqual(inserter.insert("prompt"), .inserted)
        XCTAssertEqual(platform.value, "draft prompt")
        XCTAssertEqual(platform.writes, 1)
        XCTAssertTrue(platform.pastes.isEmpty)
    }
    func testAmbiguousWriteFailureNeverRisksDuplicatePaste() {
        for unreadable in [false, true] {
            let platform = InsertionPlatform(); platform.settable = true
            platform.result = unreadable ? .success : .cannotComplete
            platform.simulateUnreadableWrite = unreadable
            let inserter = TextInserter(environment: platform)
            inserter.capture()
            XCTAssertEqual(inserter.insert("prompt"), .unavailable)
            XCTAssertTrue(platform.pastes.isEmpty)
        }
    }
    func testExplicitUnsupportedAXWriteCanFallbackAndClipboardRaceCannotPaste() {
        let platform = InsertionPlatform(); platform.settable = true; platform.result = .attributeUnsupported
        let inserter = TextInserter(environment: platform)
        inserter.capture()
        XCTAssertEqual(inserter.insert("prompt"), .pasted)
        inserter.capture(); platform.clipboardMatches = false
        XCTAssertEqual(inserter.insert("another"), .unavailable)
        XCTAssertEqual(platform.pastes, ["prompt"])
    }
}
