import SwiftUI
import AVFoundation
import MurmurKit

extension Notification.Name {
    static let startRecording = Notification.Name("startRecording")
    static let stopRecording = Notification.Name("stopRecording")
    static let openSettings = Notification.Name("openSettings")
}

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let appState = AppState()
    var hotkeyManager: HotkeyManager?
    var audioRecorder: AudioRecorder?
    var clickMonitor: Any?
    let syncService = SyncService(deviceName: "Mac")

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupDefaults()
        setupMenuBar()
        setupServices()
        setupNotifications()
        requestPermissions()
        startSyncListener()
    }

    private func setupDefaults() {
        let defaults = UserDefaults.standard

        // Set defaults only if not already set
        defaults.register(defaults: [
            "hotkeyEnabled": true,
            "soundsEnabled": true,
            "autoInsertText": true,
            "removeFillerWords": true
        ])
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 340, height: 420)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: MenuBarView()
                .environmentObject(appState)
                .environmentObject(syncService)
        )

        // Monitor for clicks outside popover
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Start Recording (⌃Space)", action: #selector(startRecordingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsWindow), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // Reset so left click shows popover
    }

    @objc private func startRecordingFromMenu() {
        if appState.recordingState == .idle {
            startRecording()
            // Auto-stop after 30 seconds as safety
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.appState.recordingState == .recording {
                    self?.stopRecording()
                }
            }
        }
    }

    @objc private func openSettingsWindow() {
        popover?.performClose(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    private func setupServices() {
        audioRecorder = AudioRecorder(appState: appState)

        hotkeyManager = HotkeyManager(
            onKeyDown: { [weak self] in
                Task { @MainActor in
                    self?.startRecording()
                }
            },
            onKeyUp: { [weak self] in
                Task { @MainActor in
                    self?.stopRecording()
                }
            }
        )
        hotkeyManager?.startListening()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(forName: .startRecording, object: nil, queue: .main) { [weak self] _ in
            self?.startRecording()
        }

        NotificationCenter.default.addObserver(forName: .stopRecording, object: nil, queue: .main) { [weak self] _ in
            self?.stopRecording()
        }

        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            self?.showSettingsWindow()
        }
    }

    private func showSettingsWindow() {
        popover?.performClose(nil)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if #available(macOS 13.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    private func requestPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("[Murmur] Microphone: \(granted ? "✓" : "✗")")
            }
        case .authorized:
            print("[Murmur] Microphone: ✓")
        default:
            print("[Murmur] Microphone: ✗")
        }
        print("[Murmur] Accessibility: \(AXIsProcessTrusted() ? "✓" : "✗")")
    }

    // MARK: - Recording

    func startRecording() {
        guard appState.recordingState == .idle else { return }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    if granted {
                        Task { @MainActor in self?.startRecording() }
                    }
                }
            }
            return
        }

        appState.recordingState = .recording
        appState.recordingStartDate = Date()
        audioRecorder?.startRecording()
        updateMenuBarIcon(recording: true)

        if appState.soundsEnabled {
            NSSound(named: "Tink")?.play()
        }
    }

    func stopRecording() {
        guard appState.recordingState == .recording else { return }

        appState.recordingState = .transcribing
        appState.recordingStartDate = nil
        updateMenuBarIcon(recording: false)

        audioRecorder?.stopRecording { [weak self] audioURL in
            guard let self = self, let url = audioURL else {
                Task { @MainActor in
                    self?.appState.recordingState = .idle
                }
                return
            }

            Task { @MainActor in
                await self.transcribeAudio(url: url)
            }
        }
    }

    private func transcribeAudio(url: URL) async {
        defer {
            appState.recordingState = .idle
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let audioData = try Data(contentsOf: url)
            let rawText = try await TranscriptionService.shared.transcribe(audioData: audioData)
            let text = TextProcessor.process(rawText, removeFillers: appState.removeFillerWords)

            // Always copy to clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)

            // Add to history
            appState.addTranscription(text)

            // Send to connected peers (iPhone/Watch)
            if let latest = appState.store.transcriptions.first {
                syncService.send(latest)
            }

            // Auto-paste if enabled
            if appState.autoInsertText {
                TextInserter.paste()
            }

            if appState.soundsEnabled {
                NSSound(named: "Pop")?.play()
            }

        } catch {
            print("[Murmur] Transcription failed: \(error)")
            appState.lastError = error.localizedDescription
            NSSound.beep()
        }
    }

    private func updateMenuBarIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        if recording {
            // Non-template colored image so it stays visible in the menu bar
            let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(MurmurTokens.accent)])
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
            img?.isTemplate = false
            button.image = img
        } else {
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Murmur")
            button.image = img
        }
    }

    // MARK: - Sync

    private func startSyncListener() {
        syncService.start { [weak self] transcription in
            Task { @MainActor in
                guard let self else { return }
                self.appState.store.addTranscription(transcription)
            }
        } onConnected: { [weak self] in
            // When a peer connects, send Mac's full history
            guard let self else { return }
            self.syncService.sendAll(self.appState.store.transcriptions)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stopListening()
        syncService.stop()
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
