import SwiftUI
import AppKit
import MurmurKit
import os

extension Notification.Name {
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let cancelRecording = Notification.Name("cancelRecording")
    static let openSettings = Notification.Name("openSettings")
    static let openLibrary = Notification.Name("openLibrary")
    static let voiceSettingsChanged = Notification.Name("voiceSettingsChanged")
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
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private let inserter = TextInserter()
    private lazy var overlay = OverlayController(state: appState)
    private lazy var voice = VoiceController(state: appState)
    private let hotkey = HotkeyManager()
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
        observe(.startRecording) { $0.startRecording() }
        observe(.stopRecording) { $0.voice.finish() }
        observe(.cancelRecording) { delegate in
            if delegate.appState.isActive { delegate.voice.cancel() }
            else { delegate.overlay.hide(); delegate.inserter.clear() }
        }
        observe(.openSettings) { $0.openSettingsWindow() }
        observe(.openLibrary) { $0.openLibraryWindow() }
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
        if !smokeTest { settingsChanged() }
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
        voice.onPresentation = { [weak self] in
            guard let self else { return }
            self.updateIcon()
            DispatchQueue.main.async { [weak self] in self?.updater.resumeWhenIdle() }
            if self.appState.isActive || self.appState.lastError != nil || !self.appState.completedText.isEmpty {
                self.overlay.show()
                if !self.appState.isActive, self.appState.completedText.isEmpty { self.overlay.dismiss(after: 10) }
            }
        }
        voice.onComplete = { [weak self] text, recovered in
            guard let self else { return }
            if self.appState.saveHistory {
                self.appState.store.add(text, device: "Mac")
                if self.appState.syncEnabled, let item = self.appState.store.transcriptions.first { self.sync.send(item) }
            }
            // Clipboard is the explicit fallback, and remains available after review.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if self.appState.autoInsertText && !recovered {
                switch self.inserter.insert(text) {
                case .inserted:
                    Logger(subsystem: "com.murmur", category: "Voice").info("insertion_succeeded")
                    self.appState.notice = "Inserted into your original text field."
                    self.overlay.show()
                    self.overlay.dismiss(after: 1.8)
                case .changed:
                    Logger(subsystem: "com.murmur", category: "Voice").info("insertion_skipped reason=divergence")
                    self.appState.notice = "Your text or cursor changed. Review here; the result is also copied."
                case .unavailable:
                    Logger(subsystem: "com.murmur", category: "Voice").info("insertion_skipped reason=unavailable_anchor")
                    self.appState.notice = "Ready to paste. The result is copied to your clipboard."
                }
            } else if !recovered { self.appState.notice = "Copied to your clipboard. Edit here or paste when you’re ready." }
            self.inserter.clear()
        }
        voice.onCancel = { [weak self] in self?.inserter.clear(); self?.overlay.hide(); self?.updateIcon(); self?.updater.resumeWhenIdle() }
        hotkey.enabled = { [weak self] in
            guard let self else { return false }
            // Native modal dialogs own their keys, including modifier gestures.
            return self.appState.voiceEnabled && NSApp.modalWindow == nil &&
                (self.appState.mode != .tap || self.appState.isActive || TextInserter.tapEligible())
        }
        hotkey.mode = { [weak self] in self?.appState.mode ?? .hold }
        hotkey.isActive = { [weak self] in self?.appState.isActive == true }
        hotkey.canCancel = { [weak self] in self?.overlay.isVisible == true }
        hotkey.onWarmup = { [weak self] warming in
            guard let self else { return }
            guard self.appState.warmingUp != warming else { return }
            self.appState.warmingUp = warming
            if warming { self.overlay.show() }
            else if !self.appState.isActive { self.overlay.hide() }
            if !warming { DispatchQueue.main.async { [weak self] in self?.updater.resumeWhenIdle() } }
        }
        hotkey.onStart = { [weak self] in self?.startRecording() }
        hotkey.onFinish = { [weak self] in self?.voice.finish() }
        hotkey.onCancel = { [weak self] in
            guard let self else { return }
            if self.appState.isActive { self.voice.cancel() }
            else { self.overlay.hide(); self.inserter.clear() }
        }
    }

    private func startRecording() {
        guard !appState.isActive else { return }
        popover?.performClose(nil)
        overlay.hide()
        inserter.capture()
        voice.start()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
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
        let symbol = appState.isRecording ? "waveform.circle.fill" : appState.isTranscribing ? "ellipsis.circle" : "waveform"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: appState.isRecording ? "Murmur: listening" : appState.isTranscribing ? "Murmur: processing" : "Murmur")
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
            libraryWindow = makeWindow(title: "Murmur", size: NSSize(width: 980, height: 680), content: LibraryView(store: appState.store).environmentObject(appState))
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }
    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: min(650, size.width), height: 460)
        window.center()
        return window
    }
    private func settingsChanged() {
        if !appState.voiceEnabled { voice.cancel(); hotkey.stopListening() }
        else if appState.accessibilityGranted { hotkey.startListening() }
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
        if appState.voiceEnabled && appState.accessibilityGranted { hotkey.startListening() }
        else if !appState.accessibilityGranted { hotkey.stopListening() }
    }
    private func observe(_ name: Notification.Name, center: NotificationCenter = .default, action: @escaping (AppDelegate) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        voice.dispose(); hotkey.stopListening(); overlay.hide(); sync.stop()
        permissionTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
