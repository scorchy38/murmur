import Foundation

/// A short-lived receipt for one selected-span replacement. Never persisted.
public struct VoiceUndoAnchor: Sendable {
    public let expected: String
    public let originalSelection: NSRange
    public let insertedRange: NSRange
    public let originalText: String
    public let cursor: Int
    public init?(original: String, replacement: String, selection: NSRange, cursor: Int) {
        let before = original as NSString
        let after = replacement as NSString
        guard selection.location >= 0, selection.length >= 0, selection.location <= before.length,
              selection.length <= before.length - selection.location else { return nil }
        let length = after.length - before.length + selection.length
        guard length >= 0, selection.location <= after.length, length <= after.length - selection.location,
              cursor == selection.location + length,
              after.substring(to: selection.location) == before.substring(to: selection.location),
              after.substring(from: selection.location + length) == before.substring(from: NSMaxRange(selection)) else { return nil }
        expected = replacement; originalSelection = selection
        insertedRange = NSRange(location: selection.location, length: length)
        originalText = before.substring(with: selection); self.cursor = cursor
    }
    public func matches(text: String, selection: NSRange) -> Bool {
        text == expected && selection == NSRange(location: cursor, length: 0)
    }
    public var restoredText: String { (expected as NSString).replacingCharacters(in: insertedRange, with: originalText) }
}
