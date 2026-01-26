import Cocoa
import Carbon

/// Handles pasting text at the current cursor position
class TextInserter {
    /// Simulates Cmd+V to paste from clipboard
    static func paste() {
        // Small delay to ensure clipboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .hidSystemState)

            // V key = keycode 9
            let vKeyCode: CGKeyCode = 9

            // Key down with Command
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true) {
                keyDown.flags = .maskCommand
                keyDown.post(tap: .cghidEventTap)
            }

            // Key up
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) {
                keyUp.flags = .maskCommand
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }
}
