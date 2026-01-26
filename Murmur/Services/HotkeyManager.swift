import Cocoa
import Carbon

/// Global hotkey using Carbon API (the reliable way)
/// Hotkey: Ctrl+Space
class HotkeyManager {
    private var onKeyDown: () -> Void
    private var onKeyUp: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isPressed = false

    private static var instance: HotkeyManager?

    init(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        HotkeyManager.instance = self
    }

    func startListening() {
        // Register for hot key pressed event
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            HotkeyManager.instance?.handleHotKeyPressed()
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandler
        )

        // Also register for hot key released
        var releaseEventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))

        let releaseHandler: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            HotkeyManager.instance?.handleHotKeyReleased()
            return noErr
        }

        var releaseEventHandler: EventHandlerRef?
        InstallEventHandler(
            GetApplicationEventTarget(),
            releaseHandler,
            1,
            &releaseEventType,
            nil,
            &releaseEventHandler
        )

        // Register Ctrl+Space hotkey - overrides input source switching
        // Space = kVK_Space = 49, controlKey = 4096
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D524D52), id: 1) // "MRMR"

        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            print("[Murmur] ✅ Hotkey registered: Ctrl+Space")
        } else {
            print("[Murmur] ❌ Failed to register hotkey: \(status)")
        }
    }

    private func handleHotKeyPressed() {
        guard UserDefaults.standard.bool(forKey: "hotkeyEnabled") else { return }
        guard !isPressed else { return }

        isPressed = true
        DispatchQueue.main.async {
            self.onKeyDown()
        }
    }

    private func handleHotKeyReleased() {
        guard isPressed else { return }

        isPressed = false
        DispatchQueue.main.async {
            self.onKeyUp()
        }
    }

    func stopListening() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
        }
        isPressed = false
    }

    deinit {
        stopListening()
        HotkeyManager.instance = nil
    }
}
