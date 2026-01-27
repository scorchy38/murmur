import SwiftUI

public struct MurmurRecordingIndicator: View {
    public var startDate: Date?
    @State private var isPulsing = false

    public init(startDate: Date? = nil) {
        self.startDate = startDate
    }

    private var dotSize: CGFloat {
        #if os(watchOS)
        return 8
        #else
        return 10
        #endif
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(MurmurTokens.recordingColor)
                .frame(width: dotSize, height: dotSize)
                .opacity(isPulsing ? 1.0 : 0.4)
                .animation(MurmurTokens.Anim.recordingPulse, value: isPulsing)

            #if !os(watchOS)
            Text("Recording")
                .font(MurmurTokens.Typography.statusLabel)
                .foregroundStyle(MurmurTokens.recordingColor)
            #endif

            if let startDate {
                Spacer()
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    Text(elapsedString(from: startDate, to: context.date))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { isPulsing = true }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(start))
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
