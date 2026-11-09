import Foundation

public enum VoiceShortcut: String, CaseIterable, Sendable {
    case shift, controlOption, controlSpace
    public var label: String {
        switch self { case .shift: "Shift"; case .controlOption: "Control + Option"; case .controlSpace: "Control + Space" }
    }
    public var symbol: String {
        switch self { case .shift: "⇧"; case .controlOption: "⌃⌥"; case .controlSpace: "⌃Space" }
    }
    public var conflictAdvice: String {
        switch self {
        case .shift: "A short press still works for capitals and punctuation."
        case .controlOption: "Starts immediately. VoiceOver uses Control + Option; choose another shortcut if VoiceOver is enabled."
        case .controlSpace: "Starts immediately. macOS may use Control + Space to switch input sources. Check System Settings → Keyboard → Keyboard Shortcuts if both respond."
        }
    }
}
