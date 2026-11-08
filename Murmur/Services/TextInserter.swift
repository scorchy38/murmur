import AppKit
import ApplicationServices
import MurmurKit

@MainActor
final class TextInserter {
    enum Outcome { case inserted, changed, unavailable }
    private var element: AXUIElement?
    private var anchor: VoiceAnchor?
    private var process: pid_t = 0

    static func tapEligible() -> Bool {
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication else { return false }
        var focused: CFTypeRef?
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != kAXSecureTextFieldSubrole else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return false }
        return (value as? String)?.isEmpty == true
    }

    func capture() {
        clear()
        guard AXIsProcessTrusted(), let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        process = front.processIdentifier
        let app = AXUIElementCreateApplication(process)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
        let focused = unsafeBitCast(value, to: AXUIElement.self)
        var secure: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &secure)
        guard (secure as? String) != kAXSecureTextFieldSubrole else { return }
        guard let text = string(focused), let range = selection(focused), let anchor = VoiceAnchor(text: text, selection: range) else { return }
        self.element = focused
        self.anchor = anchor
    }

    func insert(_ text: String) -> Outcome {
        guard let element, var anchor else { return .unavailable }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == process,
              let current = string(element), current == anchor.expected,
              selection(element) == anchor.selection else { return .changed }
        var focused: CFTypeRef?
        let app = AXUIElementCreateApplication(process)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, element) else { return .changed }
        guard let replacement = anchor.replacement(text, current: current) else { return .changed }
        // Replace only the selected span. Never rewrite an entire foreign document.
        let original = current as NSString
        let left = original.substring(to: anchor.selection.location)
        let right = original.substring(from: NSMaxRange(anchor.selection))
        let insertedRange = NSRange(location: (left as NSString).length,
                                    length: (replacement.text as NSString).length - (left as NSString).length - (right as NSString).length)
        let insertion = (replacement.text as NSString).substring(with: insertedRange)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, insertion as CFString) == .success else { return .unavailable }
        var cursor = CFRange(location: replacement.cursor, length: 0)
        if let value = AXValueCreate(.cfRange, &cursor) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        clear()
        return .inserted
    }

    func clear() { element = nil; anchor = nil; process = 0 }
    private func string(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private func selection(_ element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
