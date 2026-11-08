import AppKit
import MurmurKit

/// A native modifier gesture. Shift keeps its ordinary typing behavior; another
/// key during warmup cancels admission, so capitals and Shift shortcuts still work.
@MainActor
final class HotkeyManager {
    var enabled: () -> Bool = { false }
    var mode: () -> VoiceMode = { .hold }
    var isActive: () -> Bool = { false }
    var canCancel: () -> Bool = { false }
    var onWarmup: (Bool) -> Void = { _ in }
    var onStart: () -> Void = {}
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var warmup: Task<Void, Never>?
    private var shiftDown = false
    private var admitted = false
    private var blocked = false
    private var pressedAt = Date.distantPast
    private var lastTap = Date.distantPast

    @discardableResult
    func startListening() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = manager.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    _ = manager.handle(type, event: event)
                    return Unmanaged.passUnretained(event)
                }
                return manager.handle(type, event: event) ? nil : Unmanaged.passUnretained(event)
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func handle(_ type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if isActive() { onCancel() }
            return false
        }
        if type == .keyDown {
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if canCancel(), key == 53 || (key == 8 && event.flags.contains(.maskControl)) {
                reset(); onCancel(); return true
            }
            if shiftDown {
                blocked = true
                warmup?.cancel(); onWarmup(false)
                // A Shift shortcut or text entry takes ownership, even after warmup.
                if admitted && mode() == .hold { onCancel() }
                admitted = false
            }
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            if shiftDown && !admitted { blocked = true; warmup?.cancel(); onWarmup(false) }
            return false
        }
        guard type == .flagsChanged else { return false }
        let flags = event.flags
        let down = flags.contains(.maskShift)
        let otherModifier = !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]).isEmpty
        if otherModifier {
            blocked = true; warmup?.cancel(); onWarmup(false)
            if admitted && mode() == .hold { onCancel(); admitted = false }
        }
        guard down != shiftDown else { return false }
        shiftDown = down
        if down {
            guard enabled(), !otherModifier else { blocked = true; return false }
            blocked = false
            pressedAt = Date()
            if mode() == .hold {
                guard !isActive() else { blocked = true; return false }
                warmup = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(160))
                    guard !Task.isCancelled, let self, self.shiftDown, !self.blocked, self.enabled() else { return }
                    self.onWarmup(true)
                    try? await Task.sleep(for: .milliseconds(240))
                    guard !Task.isCancelled, self.shiftDown, !self.blocked, self.enabled() else { return }
                    self.admitted = true
                    self.onWarmup(false)
                    self.onStart()
                }
            }
        } else {
            warmup?.cancel(); warmup = nil
            onWarmup(false)
            let wasAdmitted = admitted
            admitted = false
            if mode() == .hold {
                if wasAdmitted { onFinish() }
            } else if enabled(), !blocked, Date().timeIntervalSince(pressedAt) < 0.5, Date().timeIntervalSince(lastTap) >= 0.12 {
                lastTap = Date()
                if isActive() { onFinish() } else { onStart() }
            }
            blocked = false
        }
        return false
    }
    func reset() {
        warmup?.cancel(); warmup = nil
        shiftDown = false; admitted = false; blocked = false
        onWarmup(false)
    }
    func stopListening() {
        let interrupted = tap != nil && isActive()
        reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if interrupted { onCancel() }
    }
}
