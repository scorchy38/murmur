import XCTest
@testable import MurmurKit

final class VoiceUndoTests: XCTestCase {
    func testUndoRestoresOnlyTheOriginalSelectionIncludingUnicode() throws {
        let original = "🙂 before OLD after"
        let selection = (original as NSString).range(of: "OLD")
        var anchor = try XCTUnwrap(VoiceAnchor(text: original, selection: selection))
        let replacement = try XCTUnwrap(anchor.replacement("नमस्ते", current: original))
        let undo = try XCTUnwrap(VoiceUndoAnchor(original: original, replacement: replacement.text, selection: selection, cursor: replacement.cursor))
        XCTAssertTrue(undo.matches(text: replacement.text, selection: NSRange(location: replacement.cursor, length: 0)))
        XCTAssertEqual(undo.restoredText, original)
        XCTAssertFalse(undo.matches(text: replacement.text + " changed", selection: NSRange(location: replacement.cursor, length: 0)))
        XCTAssertFalse(undo.matches(text: replacement.text, selection: NSRange(location: 0, length: 0)))
    }
    func testInvalidOrUnrelatedReplacementCannotCreateUndoReceipt() {
        XCTAssertNil(VoiceUndoAnchor(original: "before", replacement: "other", selection: NSRange(location: 99, length: 0), cursor: 0))
        XCTAssertNil(VoiceUndoAnchor(original: "left right", replacement: "elsewhere", selection: NSRange(location: 5, length: 0), cursor: 5))
        XCTAssertNil(VoiceUndoAnchor(original: "hello", replacement: "hello world", selection: NSRange(location: 5, length: 0), cursor: 0))
    }
}
