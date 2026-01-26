import SwiftUI

struct RecordingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            if appState.isTranscribing {
                transcribingContent
            } else {
                recordingContent
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Recording State

    private var recordingContent: some View {
        VStack(spacing: 20) {
            // Recording indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                    .shadow(color: .red.opacity(0.6), radius: 6)

                Text("Recording")
                    .font(.subheadline.weight(.medium))
            }

            // Waveform
            WaveformView(levels: appState.audioLevels)
                .frame(height: 50)

            // Stop button
            Button {
                NotificationCenter.default.post(name: .stopRecording, object: nil)
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.red)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Text("Release ⌃Space or click Stop")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Transcribing State

    private var transcribingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            Text("Transcribing...")
                .font(.subheadline.weight(.medium))

            Text("Processing audio")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Waveform

struct WaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<levels.count, id: \.self) { index in
                WaveformBar(
                    level: levels[index],
                    position: CGFloat(index) / CGFloat(levels.count)
                )
            }
        }
    }
}

struct WaveformBar: View {
    let level: CGFloat
    let position: CGFloat

    var body: some View {
        // Fade effect: newer bars (right) are more visible
        let opacity = (0.3 + position * 0.7) * (0.5 + level * 0.5)

        RoundedRectangle(cornerRadius: 1.5)
            .fill(
                LinearGradient(
                    colors: [.red, .orange],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .frame(width: 3, height: max(3, level * 50))
            .opacity(opacity)
            .animation(.easeOut(duration: 0.08), value: level)
    }
}

#Preview("Recording") {
    RecordingView()
        .environmentObject({
            let state = AppState()
            state.recordingState = .recording
            state.audioLevels = (0..<50).map { _ in CGFloat.random(in: 0.2...1.0) }
            return state
        }())
        .frame(width: 340, height: 300)
}

#Preview("Transcribing") {
    RecordingView()
        .environmentObject({
            let state = AppState()
            state.recordingState = .transcribing
            return state
        }())
        .frame(width: 340, height: 300)
}
