import SwiftUI
import MurmurKit

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
            MurmurRecordingIndicator(startDate: appState.recordingStartDate)

            MurmurWaveformView(levels: appState.audioLevels)
                .frame(height: 50)
                .transition(.opacity)

            MurmurRecordButton(state: .recording, style: .capsule) {
                NotificationCenter.default.post(name: .stopRecording, object: nil)
            }

            Text("Release Control-Space or click Stop")
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
                .font(MurmurTokens.Typography.statusLabel)

            Text("Processing audio")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
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
