import AppKit
import SwiftUI

private final class VoicePanel: NSPanel {
    var allowsEditing = false
    override var canBecomeKey: Bool { allowsEditing }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    private var panels: [VoicePanel] = []
    private var indicator: VoicePanel?
    private var dismissTask: Task<Void, Never>?
    private let state: AppState
    init(state: AppState) { self.state = state }
    var isVisible: Bool { !panels.isEmpty || indicator != nil }

    func show() {
        guard !state.practiceSession else { hide(); return }
        if state.shadowMode {
            if state.shadowIndicatorEnabled { showIndicator() } else { hide() }
            return
        }
        dismissTask?.cancel()
        if panels.isEmpty {
            let pointer = NSEvent.mouseLocation
            let active = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            for screen in NSScreen.screens {
                let panel = VoicePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.level = .floating
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.isMovable = false
                panel.animationBehavior = .none
                if screen == active {
                    let content = NSHostingView(rootView: RecordingView(availableHeight: screen.visibleFrame.height).environmentObject(state))
                    content.sizingOptions = []
                    content.autoresizingMask = [.width, .height]
                    panel.contentView = content
                } else {
                    panel.contentView = NSHostingView(rootView: Color.black.opacity(0.08).ignoresSafeArea())
                    panel.ignoresMouseEvents = true
                }
                panel.setFrame(screen.frame, display: false)
                panels.append(panel)
                panel.orderFrontRegardless()
            }
        }
        panels.forEach { $0.allowsEditing = !state.isActive && !state.warmingUp }
    }

    private func showIndicator() {
        dismissTask?.cancel()
        panels.forEach { $0.close() }; panels.removeAll()
        guard indicator == nil else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let rect = NSRect(x: frame.midX - 140, y: frame.minY + 20, width: 280, height: 58)
        let panel = VoicePanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        let content = NSHostingView(rootView: ShadowStatusView().environmentObject(state))
        content.sizingOptions = []; content.autoresizingMask = [.width, .height]; panel.contentView = content
        panel.setFrame(rect, display: false); indicator = panel; panel.orderFrontRegardless()
    }

    func dismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        dismissTask?.cancel(); dismissTask = nil
        panels.forEach { $0.close() }
        panels.removeAll()
        indicator?.close(); indicator = nil
    }
}
