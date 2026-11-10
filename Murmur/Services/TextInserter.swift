import AppKit
import ApplicationServices
import Carbon
import MurmurKit

/// Injectable platform boundary: tests exercise focus/selection races and
/// ambiguous AX failures without touching the user's clipboard or keyboard.
@MainActor
protocol TextInsertionEnvironment {
    var trusted: Bool { get }
    var frontmostPID: pid_t? { get }
    var secureInput: Bool { get }
    func focused(in process: pid_t) -> AXUIElement?
    func text(_ element: AXUIElement) -> String?
    func selection(_ element: AXUIElement) -> NSRange?
    func secure(_ element: AXUIElement) -> Bool
    func pasteable(_ element: AXUIElement) -> Bool
    func prefersPaste(_ element: AXUIElement) -> Bool
    func selectedTextSettable(_ element: AXUIElement) -> Bool
    func replace(_ element: AXUIElement, text: String) -> AXError
    func select(_ element: AXUIElement, range: NSRange) -> Bool
    func paste(text: String, process: pid_t) -> Bool
}

@MainActor
private struct SystemTextInsertion: TextInsertionEnvironment {
    var trusted: Bool { AXIsProcessTrusted() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var secureInput: Bool { IsSecureEventInputEnabled() }
    func focused(in process: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(process)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    func secure(_ element: AXUIElement) -> Bool {
        (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }
    func text(_ element: AXUIElement) -> String? {
        guard !secure(element) else { return nil }
        return attribute(element, kAXValueAttribute) as? String
    }
    func selection(_ element: AXUIElement) -> NSRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    func pasteable(_ element: AXUIElement) -> Bool {
        guard !secure(element) else { return false }
        let role = attribute(element, kAXRoleAttribute) as? String
        if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "") { return true }
        // Some browser/Electron composers expose selected text on a custom role.
        return attribute(element, kAXSelectedTextAttribute) is String
    }
    func prefersPaste(_ element: AXUIElement) -> Bool {
        // WebKit/Chromium may report a successful AXSelectedText write before
        // the DOM accepts it, or omit the editor's input event entirely. Use
        // the editor's native paste path, including rich text composers.
        var node = element
        for _ in 0..<16 {
            if (attribute(node, kAXRoleAttribute) as? String) == "AXWebArea" { return true }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }
    func selectedTextSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
    }
    func replace(_ element: AXUIElement, text: String) -> AXError {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
    }
    func select(_ element: AXUIElement, range: NSRange) -> Bool {
        var range = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
    func paste(text: String, process: pid_t) -> Bool {
        // Delivery has already written this exact text. Never paste a clipboard
        // that another application changed, and never synthesize Return.
        guard NSPasteboard.general.string(forType: .string) == text,
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(process); up.postToPid(process)
        return true
    }
}

@MainActor
final class TextInserter: VoiceTextDelivering {
    enum Outcome { case inserted, pasted, changed, unavailable }
    private let environment: any TextInsertionEnvironment
    private var capturedText: String?
    private var capturedSelection: NSRange?
    init(environment: (any TextInsertionEnvironment)? = nil) { self.environment = environment ?? SystemTextInsertion() }
    private var element: AXUIElement?
    private var anchor: VoiceAnchor?
    private var process: pid_t = 0
    private struct UndoReceipt {
        let element: AXUIElement
        let process: pid_t
        let anchor: VoiceUndoAnchor
    }
    private var receipt: UndoReceipt?

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
        guard environment.trusted, !environment.secureInput,
              let process = environment.frontmostPID,
              process != ProcessInfo.processInfo.processIdentifier,
              let focused = environment.focused(in: process), !environment.secure(focused),
              environment.pasteable(focused) else { return }
        self.process = process
        element = focused
        capturedText = environment.text(focused)
        capturedSelection = environment.selection(focused)
        if let text = capturedText, let range = capturedSelection { anchor = VoiceAnchor(text: text, selection: range) }
    }

    func insert(_ text: String) -> Outcome {
        guard let element, !text.isEmpty, environment.trusted, !environment.secureInput,
              !environment.secure(element) else { return .unavailable }
        guard environment.frontmostPID == process,
              let focused = environment.focused(in: process), CFEqual(focused, element) else { return .changed }
        let current = environment.text(element), selected = environment.selection(element)
        if let capturedText, current != capturedText { return .changed }
        if let capturedSelection, selected != capturedSelection { return .changed }
        if var anchor, let current, !environment.prefersPaste(element), environment.selectedTextSettable(element),
           let replacement = anchor.replacement(text, current: current),
           let undo = VoiceUndoAnchor(original: current, replacement: replacement.text, selection: anchor.selection, cursor: replacement.cursor) {
            let source = replacement.text as NSString
            let insertedLength = source.length - (current as NSString).length + anchor.selection.length
            let insertion = source.substring(with: NSRange(location: anchor.selection.location, length: insertedLength))
            let result = environment.replace(element, text: insertion)
            if result == .success {
                _ = environment.select(element, range: NSRange(location: replacement.cursor, length: 0))
                // A write may have succeeded even when the read-back fails.
                // Never send a second paste in this ambiguous case.
                guard environment.text(element) == replacement.text else { clear(); return .unavailable }
                receipt = UndoReceipt(element: element, process: process, anchor: undo)
                clear()
                return .inserted
            }
            guard result == .attributeUnsupported || result == .notImplemented else { return .unavailable }
        }
        // A native paste reaches terminal and web/Electron editors that expose
        // a focused text element but cannot implement AXSelectedText writes.
        guard environment.pasteable(element), !environment.secure(element), !environment.secureInput,
              environment.frontmostPID == process,
              let focused = environment.focused(in: process), CFEqual(focused, element),
              capturedText == nil || environment.text(element) == capturedText,
              capturedSelection == nil || environment.selection(element) == capturedSelection,
              environment.paste(text: text, process: process) else { return .unavailable }
        clear()
        return .pasted // Shortcut dispatched; do not claim verified insertion/undo.
    }

    func correctedInsertion() -> VoiceCorrectionSuggestion? {
        guard let receipt, NSWorkspace.shared.frontmostApplication?.processIdentifier == receipt.process else { return nil }
        var focused: CFTypeRef?
        let app = AXUIElementCreateApplication(receipt.process)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, receipt.element),
              let current = string(receipt.element), let edited = receipt.anchor.correctedSpan(in: current) else { return nil }
        return VoiceCorrectionSuggestion.between(receipt.anchor.insertedText, edited)
    }

    func activateOriginal() {
        let target = receipt?.process ?? process
        guard target != 0, AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: target), !app.isTerminated else { return }
        // Only invoked by the user's explicit Retry/Undo action. Field identity,
        // contents and selection are still checked after activation settles.
        app.activate(options: [])
    }

    func undo() -> Bool {
        guard let receipt else { return false }
        defer { self.receipt = nil }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == receipt.process,
              let current = string(receipt.element), let selectedRange = selection(receipt.element),
              receipt.anchor.matches(text: current, selection: selectedRange) else { return false }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(receipt.process), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, receipt.element) else { return false }
        var range = CFRange(location: receipt.anchor.insertedRange.location, length: receipt.anchor.insertedRange.length)
        guard let selected = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(receipt.element, kAXSelectedTextRangeAttribute as CFString, selected) == .success else { return false }
        guard AXUIElementSetAttributeValue(receipt.element, kAXSelectedTextAttribute as CFString, receipt.anchor.originalText as CFString) == .success else {
            var cursor = CFRange(location: receipt.anchor.cursor, length: 0)
            if let value = AXValueCreate(.cfRange, &cursor) { AXUIElementSetAttributeValue(receipt.element, kAXSelectedTextRangeAttribute as CFString, value) }
            return false
        }
        var original = CFRange(location: receipt.anchor.originalSelection.location, length: receipt.anchor.originalSelection.length)
        if let value = AXValueCreate(.cfRange, &original) { AXUIElementSetAttributeValue(receipt.element, kAXSelectedTextRangeAttribute as CFString, value) }
        return string(receipt.element) == receipt.anchor.restoredText
    }
    func expireUndo() { receipt = nil }
    func clear() { element = nil; anchor = nil; process = 0; capturedText = nil; capturedSelection = nil }
    private func string(_ element: AXUIElement) -> String? {
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) != kAXSecureTextFieldSubrole else { return nil }
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
