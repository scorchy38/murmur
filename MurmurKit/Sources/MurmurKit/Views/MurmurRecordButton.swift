import SwiftUI

public struct MurmurRecordButton: View {
    public let state: RecordButtonState
    public let style: Style
    public let action: () -> Void

    public enum Style {
        case circle
        case capsule
    }

    public init(state: RecordButtonState, style: Style = .circle, action: @escaping () -> Void) {
        self.state = state
        self.style = style
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            switch style {
            case .circle: circleContent
            case .capsule: capsuleContent
            }
        }
        .buttonStyle(RecordButtonPressStyle())
        .disabled(state == .transcribing)
        #if os(iOS) || os(watchOS)
        .sensoryFeedback(.impact(weight: .medium), trigger: state)
        #endif
    }

    // MARK: - Circle Style (iOS / watchOS)

    private var circleContent: some View {
        ZStack {
            Circle()
                .fill(buttonFill.opacity(0.15))
                .frame(width: outerSize, height: outerSize)

            Circle()
                .fill(buttonFill)
                .frame(width: innerSize, height: innerSize)

            Group {
                if state == .transcribing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: state == .recording
                        ? MurmurTokens.Symbol.stop
                        : MurmurTokens.Symbol.micIdle)
                        .font(iconFont)
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .contentShape(Circle())
    }

    // MARK: - Capsule Style (macOS)

    private var capsuleContent: some View {
        HStack(spacing: 6) {
            if state == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: state == .recording
                    ? MurmurTokens.Symbol.stop
                    : MurmurTokens.Symbol.micIdle)
                    .contentTransition(.symbolEffect(.replace))
            }

            Text(capsuleLabel)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(buttonFill))
    }

    /// Indigo when idle/transcribing, red when recording.
    private var buttonFill: Color {
        state == .recording
            ? MurmurTokens.recordButtonActiveFill
            : MurmurTokens.recordButtonIdleFill
    }

    private var capsuleLabel: String {
        switch state {
        case .idle: return "Record"
        case .recording: return "Stop"
        case .transcribing: return "Processing"
        }
    }

    private var outerSize: CGFloat { MurmurTokens.Sizing.recordButtonOuter }
    private var innerSize: CGFloat { MurmurTokens.Sizing.recordButtonInner }
    private var iconFont: Font { MurmurTokens.Sizing.recordButtonIconFont }
}

private struct RecordButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
