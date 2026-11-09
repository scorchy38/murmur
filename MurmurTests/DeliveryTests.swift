import XCTest
import AppKit
@testable import Murmur

@MainActor
private final class FakeDeliveryTarget: VoiceTextDelivering {
    var outcome = TextInserter.Outcome.inserted
    var undoSucceeds = true
    var insertCalls = 0
    var undoCalls = 0
    var activations = 0
    var captures = 0
    func capture() { captures += 1 }
    func clear() {}
    func expireUndo() {}
    func activateOriginal() { activations += 1 }
    func insert(_ text: String) -> TextInserter.Outcome { insertCalls += 1; return outcome }
    func undo() -> Bool { undoCalls += 1; return undoSucceeds }
}

@MainActor
final class DeliveryTests: XCTestCase {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("murmur-tests-\(UUID().uuidString)")) }
    func testClipboardRestoresRichTextAndDoesNotOverwriteSomeoneElsesCopy() {
        let board = board(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("before", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .rtf)
        board.writeObjects([item])
        let clipboard = ClipboardDelivery(pasteboard: board)
        XCTAssertTrue(clipboard.copy("dictated"))
        XCTAssertTrue(clipboard.restore())
        XCTAssertEqual(board.string(forType: .string), "before")
        XCTAssertEqual(board.data(forType: .rtf), Data([1, 2, 3]))
        XCTAssertTrue(clipboard.copy("dictated again"))
        board.clearContents(); board.setString("someone else's copy", forType: .string)
        XCTAssertFalse(clipboard.restore())
        XCTAssertEqual(board.string(forType: .string), "someone else's copy")
    }
    func testPrivateOrOversizedClipboardIsNeverRetainedForUndo() {
        let board = board(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("private", forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.writeObjects([item])
        let clipboard = ClipboardDelivery(pasteboard: board)
        XCTAssertTrue(clipboard.copy("result"))
        XCTAssertFalse(clipboard.canRestore)
        board.clearContents(); board.setData(Data(repeating: 1, count: 1_048_577), forType: .rtf)
        XCTAssertTrue(clipboard.copy("result"))
        XCTAssertFalse(clipboard.canRestore)
    }
    func testFailedInsertionStillCopiesAndRetryUsesSameCheckedTarget() {
        let board = board(); defer { board.releaseGlobally() }
        let target = FakeDeliveryTarget(); target.outcome = .changed
        let delivery = DeliveryController(clipboard: ClipboardDelivery(pasteboard: board), inserter: target)
        delivery.capture()
        XCTAssertEqual(delivery.deliver("prompt", insert: true), .changed)
        XCTAssertEqual(board.string(forType: .string), "prompt")
        XCTAssertTrue(delivery.canRetry)
        target.outcome = .inserted
        delivery.prepareOriginalField()
        XCTAssertEqual(target.activations, 1)
        delivery.retryOriginalField()
        XCTAssertEqual(delivery.status, .inserted)
        XCTAssertEqual(target.insertCalls, 2)
        XCTAssertFalse(delivery.canRetry)
        delivery.expire()
    }
    func testChangedFieldRefusesUndoButClipboardCanBeRestored() {
        let board = board(); defer { board.releaseGlobally() }
        board.setString("before", forType: .string)
        let target = FakeDeliveryTarget()
        let delivery = DeliveryController(clipboard: ClipboardDelivery(pasteboard: board), inserter: target)
        delivery.deliver("prompt", insert: true)
        target.undoSucceeds = false
        delivery.undo()
        XCTAssertEqual(target.undoCalls, 1)
        XCTAssertEqual(board.string(forType: .string), "before")
        XCTAssertTrue(delivery.message.contains("left untouched"))
        XCTAssertFalse(delivery.canUndo)
    }
    func testClipboardOnlyModeNeverInsertsAndExpiryDisablesUndo() {
        let board = board(); defer { board.releaseGlobally() }
        let target = FakeDeliveryTarget()
        let delivery = DeliveryController(clipboard: ClipboardDelivery(pasteboard: board), inserter: target)
        delivery.capture(allowInsertion: false)
        XCTAssertEqual(target.captures, 0)
        XCTAssertEqual(delivery.deliver("prompt", insert: false), .copied)
        XCTAssertEqual(target.insertCalls, 0)
        delivery.prepareOriginalField()
        XCTAssertEqual(target.activations, 0)
        delivery.expire()
        XCTAssertFalse(delivery.canUndo)
        delivery.undo()
        XCTAssertEqual(target.undoCalls, 0)
    }
    func testDisablingRetentionImmediatelyForgetsClipboardAndSkipsFutureSnapshots() {
        let board = board(); defer { board.releaseGlobally() }
        board.setString("before", forType: .string)
        let target = FakeDeliveryTarget()
        let delivery = DeliveryController(clipboard: ClipboardDelivery(pasteboard: board), inserter: target)
        delivery.deliver("first", insert: false)
        XCTAssertTrue(delivery.canUndo)
        delivery.expireClipboard()
        XCTAssertFalse(delivery.canUndo)
        delivery.retainClipboardForUndo = { false }
        delivery.deliver("second", insert: false)
        XCTAssertFalse(delivery.canUndo)
        delivery.expire()
    }

}
