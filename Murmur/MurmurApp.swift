import SwiftUI
import AppKit
import MurmurKit
import os

extension Notification.Name {
    static let copyLastResult = Notification.Name("copyLastResult")
    static let retryLastInsertion = Notification.Name("retryLastInsertion")
    static let undoLastDelivery = Notification.Name("undoLastDelivery")
    static let reviewLastResult = Notification.Name("reviewLastResult")
    static let selectSetupSettings = Notification.Name("selectSetupSettings")
    static let selectConnectionSettings = Notification.Name("selectConnectionSettings")
    static let startPractice = Notification.Name("startPractice")
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let cancelRecording = Notification.Name("cancelRecording")
    static let openSettings = Notification.Name("openSettings")
    static let openLibrary = Notification.Name("openLibrary")
    static let voiceSettingsChanged = Notification.Name("voiceSettingsChanged")
    static let checkForUpdates = Notification.Name("checkForUpdates")
    static let selectUpdateSettings = Notification.Name("selectUpdateSettings")
    static let openShortcutPermissions = Notification.Name("openShortcutPermissions")
}

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { SettingsView().environmentObject(appDelegate.appState) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var libraryWindow: NSWindow?
    private var reviewWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private let delivery = DeliveryController()
    private lazy var overlay = OverlayController(state: appState)
    private lazy var voice = VoiceController(state: appState)
    private let hotkey = HotkeyManager()
    private var boundShortcut = VoiceShortcut.shift
    private var boundMode = VoiceMode.hold
    private let sync = SyncService(deviceName: "Mac")
    private var syncing = false
    private let updater = AppUpdater.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSClassFromString("XCTestCase") != nil { return }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--preview"), CommandLine.arguments.count > index + 1 {
            libraryWindow = showVoicePreview(CommandLine.arguments[index + 1], state: appState)
            return
        }
        #endif
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        updater.isBusy = { [weak self] in self?.appState.isActive == true || self?.appState.warmingUp == true }
        updater.start()
        configureVoice()
        observe(.copyLastResult) { delegate in
            guard !delegate.appState.completedText.isEmpty else { return }
            delegate.delivery.deliver(delegate.appState.completedText, insert: false)
        }
        observe(.retryLastInsertion) { delegate in
            delegate.popover?.performClose(nil)
            delegate.overlay.hide()
            delegate.delivery.prepareOriginalField()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { delegate.delivery.retryOriginalField() }
        }
        observe(.undoLastDelivery) { delegate in
            delegate.popover?.performClose(nil)
            delegate.overlay.hide()
            delegate.delivery.prepareOriginalField()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { delegate.delivery.undo() }
        }
        observe(.reviewLastResult) { $0.openReviewWindow() }
        observe(.startPractice) { $0.startRecording(practice: true) }
        observe(.startRecording) { $0.startRecording() }
        observe(.stopRecording) { $0.voice.finish() }
        observe(.cancelRecording) { delegate in
            if delegate.appState.isActive { delegate.voice.cancel() }
            else { delegate.overlay.hide(); delegate.delivery.discardAnchor() }
        }
        observe(.openSettings) { $0.openSettingsWindow() }
        observe(.openLibrary) { $0.openLibraryWindow() }
        observe(.openShortcutPermissions) { delegate in
            delegate.popover?.performClose(nil)
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        observe(.checkForUpdates) { delegate in
            delegate.openSettingsWindow()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .selectUpdateSettings, object: nil)
                delegate.updater.check()
            }
        }
        observe(.voiceSettingsChanged) { $0.settingsChanged() }
        observe(NSApplication.didBecomeActiveNotification) { $0.refreshPermissions() }
        observe(NSApplication.didResignActiveNotification) { delegate in
            if delegate.settingsWindow?.isVisible == true { delegate.appState.refreshPermissions() }
        }
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { $0.voice.cancel(); $0.overlay.hide() }
        observe(NSApplication.didChangeScreenParametersNotification) { delegate in
            delegate.voice.cancel(); delegate.overlay.hide()
        }
        // Permissions can be changed while the app remains a background menu extra.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        let smokeTest = CommandLine.arguments.contains("--smoke-test")
        if !smokeTest {
            appState.usageStore.open()
            settingsChanged()
            #if !DEBUG
            appState.configureLoginItem()
            #endif
        }
        if smokeTest {
            guard statusItem?.button?.image != nil else {
                FileHandle.standardError.write(Data("Murmur menu bar initialization failed.\n".utf8))
                exit(1)
            }
            FileHandle.standardOutput.write(Data("MURMUR_READY menu_bar=present\n".utf8))
            NSApp.terminate(nil)
        }
    }

    private func configureVoice() {
        delivery.retainClipboardForUndo = { [weak self] in self?.appState.clipboardUndoEnabled ?? false }
        delivery.onChange = { [weak self] in
            guard let self else { return }
            self.appState.deliveryOutcome = self.delivery.status.rawValue
            self.appState.deliveryCanUndo = self.delivery.canUndo
            self.appState.deliveryCanRetry = self.delivery.canRetry
            self.appState.deliveryMessage = self.delivery.message
            self.appState.notice = self.delivery.message
        }
        voice.onUsageSnapshot = { [weak self] session in self?.appState.usageStore.record(session) }
        voice.onPresentation = { [weak self] in
            guard let self else { return }
            self.updateIcon()
            let presentingPractice = self.appState.practiceSession
            if self.appState.practiceSession && !self.appState.isActive && self.appState.completedText.isEmpty {
                self.appState.practiceSession = false
                self.appState.practiceMessage = self.appState.lastError ?? "No text was recognized. Try again."
            }
            DispatchQueue.main.async { [weak self] in self?.updater.resumeWhenIdle() }
            if !presentingPractice && (self.appState.isActive || self.appState.lastError != nil || !self.appState.completedText.isEmpty) {
                self.overlay.show()
                if !self.appState.isActive, self.appState.completedText.isEmpty { self.overlay.dismiss(after: 10) }
            }
        }
        voice.onComplete = { [weak self] text, recovered in
            guard let self else { return }
            if self.appState.practiceSession {
                let status = self.delivery.deliver(text, insert: false)
                self.appState.completePractice(text: text, recovered: recovered, copied: status == .copied)
                self.overlay.hide()
                return
            }
            if self.appState.saveHistory {
                self.appState.store.add(text, device: "Mac")
                if self.appState.syncEnabled, let item = self.appState.store.transcriptions.first { self.sync.send(item) }
            }
            let result = self.delivery.deliver(text, insert: self.appState.autoInsertText && !self.appState.shadowMode && !recovered)
            if result == .inserted { self.appState.setupExternalPassed = true }
            if self.appState.shadowMode {
                self.overlay.show()
                self.overlay.dismiss(after: 2)
                self.delivery.discardAnchor()
                return
            }
            self.overlay.show()
            if result == .inserted { self.overlay.dismiss(after: 1.8) }
        }
        voice.onCancel = { [weak self] in
            guard let self else { return }
            if self.appState.practiceSession { self.appState.practiceMessage = "Practice cancelled. Try again when you're ready." }
            self.appState.practiceSession = false
            self.delivery.discardAnchor(); self.overlay.hide(); self.updateIcon(); self.updater.resumeWhenIdle()
        }

        hotkey.enabled = { [weak self] in
            guard let self else { return false }
            // Native modal dialogs own their keys, including modifier gestures.
            return self.appState.voiceEnabled && NSApp.modalWindow == nil &&
                (self.appState.mode != .tap || self.appState.isActive || (self.appState.setupVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) || TextInserter.tapEligible())
        }
        hotkey.shortcut = { [weak self] in self?.appState.shortcut ?? .shift }
        hotkey.mode = { [weak self] in self?.appState.mode ?? .hold }
        hotkey.activationDelay = { [weak self] in self?.appState.holdDelay ?? 2.0 }
        hotkey.isActive = { [weak self] in self?.appState.isActive == true }
        hotkey.canCancel = { [weak self] in
            guard let self else { return false }
            return self.appState.isActive || self.appState.warmingUp || self.overlay.isVisible
        }
        hotkey.onWarmup = { [weak self] warming in
            guard let self else { return }
            guard self.appState.warmingUp != warming else { return }
            self.appState.warmingUp = warming
            if warming { self.overlay.show() }
            else if !self.appState.isActive { self.overlay.hide() }
            if !warming { DispatchQueue.main.async { [weak self] in self?.updater.resumeWhenIdle() } }
        }
        hotkey.onStart = { [weak self] in
            if self?.appState.setupVisible == true && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { self?.appState.practiceShortcutVerified = true }
            self?.startRecording()
        }
        hotkey.onFinish = { [weak self] in self?.voice.finish() }
        hotkey.onCancel = { [weak self] in
            guard let self else { return }
            if self.appState.isActive { self.voice.cancel() }
            else { self.overlay.hide(); self.delivery.discardAnchor() }
        }
    }

    private func startRecording(practice: Bool = false) {
        guard !appState.isActive else { return }
        popover?.performClose(nil)
        overlay.hide()
        appState.practiceSession = practice || (appState.setupVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        if appState.practiceSession {
            appState.practiceHeardSignal = false
            appState.practiceClipboardVerified = false
            appState.practiceMessage = ""
            appState.practiceText = ""
        }
        delivery.capture(allowInsertion: appState.autoInsertText && !appState.shadowMode && !appState.practiceSession)
        voice.start()
        if appState.practiceSession && !appState.isActive {
            appState.practiceMessage = appState.lastError ?? "Enable dictation in Connection first."
            appState.practiceSession = false
        }
    }
    private func openReviewWindow() {
        popover?.performClose(nil)
        guard !appState.completedText.isEmpty else { return }
        if reviewWindow == nil {
            reviewWindow = makeWindow(title: "Last prompt", size: NSSize(width: 650, height: 480), content: ResultReviewView().environmentObject(appState))
        }
        NSApp.activate(ignoringOtherApps: true)
        reviewWindow?.makeKeyAndOrderFront(nil)
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(togglePopover)
        statusItem?.button?.sendAction(on: [.leftMouseUp])
        popover = NSPopover()
        popover?.behavior = .transient
        let content = NSHostingController(rootView: MenuBarView(store: appState.store).environmentObject(appState))
        content.sizingOptions = [.preferredContentSize]
        popover?.contentViewController = content
    }
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover?.isShown == true { popover?.performClose(nil) }
        else { popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
    private func updateIcon() {
        guard let mark = NSImage(named: "StatusBarIcon") else { return }
        let size = NSSize(width: 18, height: 18)
        let recording = appState.isRecording
        let processing = appState.isTranscribing
        let icon = NSImage(size: size, flipped: false) { rect in
            mark.draw(in: rect)
            if recording || processing, let context = NSGraphicsContext.current?.cgContext {
                // A transparent separation keeps the tiny state badge readable
                // without replacing Murmur's mark with a different symbol.
                let badge = recording ? CGRect(x: 12, y: 0, width: 6, height: 6) : CGRect(x: 9, y: 0, width: 9, height: 5)
                context.setBlendMode(.clear)
                context.fillEllipse(in: badge)
                context.setBlendMode(.normal)
                context.setFillColor(NSColor.black.cgColor)
                if recording {
                    context.fillEllipse(in: CGRect(x: 13, y: 1, width: 4, height: 4))
                } else {
                    for x in [10.0, 13.0, 16.0] {
                        context.fillEllipse(in: CGRect(x: x, y: 1.5, width: 1.5, height: 1.5))
                    }
                }
            }
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = recording ? "Murmur: listening" : processing ? "Murmur: processing" : "Murmur"
        statusItem?.button?.image = icon
    }
    private func openSettingsWindow() {
        popover?.performClose(nil)
        if !appState.isActive { overlay.hide() }
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "Murmur Settings", size: NSSize(width: 700, height: 600), content: SettingsView().environmentObject(appState))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func openLibraryWindow() {
        popover?.performClose(nil)
        if !appState.isActive { overlay.hide() }
        if libraryWindow == nil {
            libraryWindow = makeWindow(title: "Murmur", size: NSSize(width: 1080, height: 720), minimumSize: NSSize(width: 900, height: 580), content: LibraryView(store: appState.store).environmentObject(appState))
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }
    private func makeWindow<Content: View>(title: String, size: NSSize, minimumSize: NSSize = NSSize(width: 650, height: 460), content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.contentMinSize = minimumSize
        window.setContentSize(size)
        window.center()
        return window
    }
    private func settingsChanged() {
        if !appState.clipboardUndoEnabled { delivery.expireClipboard() }
        if boundShortcut != appState.shortcut || boundMode != appState.mode {
            hotkey.reset(); boundShortcut = appState.shortcut; boundMode = appState.mode
        }
        if appState.shadowMode { overlay.hide() }
        if !appState.voiceEnabled { voice.cancel() }
        refreshShortcut()
        if appState.syncEnabled && !syncing {
            syncing = true
            sync.start { [weak self] item in
                guard let self, self.appState.saveHistory else { return }
                self.appState.store.addTranscription(item)
            } onConnected: { [weak self] in
                guard let self else { return }
                self.sync.sendAll(self.appState.store.transcriptions)
            }
        } else if !appState.syncEnabled && syncing { sync.stop(); syncing = false }
    }
    private func refreshPermissions() {
        appState.refreshPermissions()
        appState.refreshLoginItemStatus()
        refreshShortcut()
    }
    private func refreshShortcut() {
        let listening: Bool
        if appState.voiceEnabled && appState.accessibilityGranted { listening = hotkey.startListening() }
        else { hotkey.stopListening(); listening = false }
        if appState.shortcutListening != listening { appState.shortcutListening = listening }
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter = .default, action: @escaping (AppDelegate) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        voice.dispose(); hotkey.stopListening(); overlay.hide(); delivery.expire(); sync.stop()
        permissionTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
