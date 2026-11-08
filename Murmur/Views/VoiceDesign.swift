import SwiftUI

extension View {
    @ViewBuilder
    func voiceGlass(cornerRadius: CGFloat = 28) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct ShortcutBadge: View {
    var title = "⇧"
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(title == "⇧" ? "Shift" : title)
    }
}

struct VoiceMeter: View {
    let levels: [CGFloat]
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(level > 0.15 ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 3, height: reducedMotion ? 8 : 4 + level * 24)
            }
        }
        .frame(height: 30)
        .animation(reducedMotion ? nil : .easeOut(duration: 0.1), value: levels)
        .accessibilityLabel("Microphone level")
        .accessibilityValue(levels.last.map { "\(Int($0 * 100)) percent" } ?? "Quiet")
    }
}
