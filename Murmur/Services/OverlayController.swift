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
    private var dismissTask: Task<Void, Never>?
    private let state: AppState
    init(state: AppState) { self.state = state }
    var isVisible: Bool { !panels.isEmpty }

    func show() {
        guard !state.shadowMode else { hide(); return }
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
    }
}
