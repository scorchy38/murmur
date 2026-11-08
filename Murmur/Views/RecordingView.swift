import SwiftUI
import MurmurKit

/// The screen overlay owns preview presentation; it never types interim text into other apps.
struct RecordingView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    var availableHeight: CGFloat = 800
    @State private var editedText = ""
    @State private var copied = false
    @State private var transcriptHeight: CGFloat = 100

    private var displayText: String { appState.isActive ? appState.interimTranscript : editedText }
    var body: some View {
        ZStack {
            if !appState.warmingUp {
                Color.black.opacity(0.12).ignoresSafeArea()
            }
            if appState.warmingUp && !appState.isActive {
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        ShortcutBadge()
                        Text("Keep holding…").font(.callout.weight(.medium))
                    }
                    .padding(14)
                    .voiceGlass(cornerRadius: 20)
                    .padding(.bottom, 72)
                }
            } else {
                VStack(spacing: 24) {
                    header
                    transcript
                    if let error = appState.lastError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let notice = appState.notice {
                        Text(notice).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    footer
                }
                .padding(32)
                .frame(maxWidth: 760)
                .voiceGlass(cornerRadius: 36)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { editedText = appState.completedText }
        .onChange(of: appState.completedText) { _, text in editedText = text; copied = false }
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.2), value: appState.recordingState)
        .accessibilityAction(.escape) { NotificationCenter.default.post(name: .cancelRecording, object: nil) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.isRecording ? "waveform" : appState.isTranscribing ? "ellipsis" : appState.lastError != nil ? "exclamationmark.circle" : "checkmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(appState.lastError != nil ? Color.orange : Color.accentColor)
            Text(appState.isRecording ? "Listening" : appState.isTranscribing ? "Finishing your thought" : appState.completedText.isEmpty ? "Let’s try that again" : "Your words, ready")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if appState.isRecording, let start = appState.recordingStartDate {
                Text(start, style: .timer)
                    .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            Button {
                NotificationCenter.default.post(name: .cancelRecording, object: nil)
            } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(appState.isActive ? "Cancel (Escape)" : "Dismiss")
            .accessibilityLabel(appState.isActive ? "Cancel recording" : "Dismiss result")
        }
    }

    @ViewBuilder private var transcript: some View {
        if !appState.isActive && !editedText.isEmpty {
            TextEditor(text: $editedText)
                .font(.system(size: 26, weight: .regular, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(height: min(availableHeight * 0.42, max(110, CGFloat(editedText.count / 48 + 1) * 38)))
                .accessibilityLabel("Editable dictation result")
        } else if displayText.isEmpty {
            VStack(spacing: 16) {
                if appState.isTranscribing {
                    if reducedMotion { Image(systemName: "ellipsis").font(.title2) }
                    else { ProgressView().controlSize(.small) }
                }
                Text(appState.isRecording ? "A thought. A message.\nWhatever’s on your mind." : appState.isTranscribing ? "Making room for the last word…" : "Your next thought starts here.")
                    .font(.system(size: 32, weight: .regular, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 32)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(displayText)
                        .font(.system(size: displayText.count < 180 ? 34 : 27, weight: .regular, design: .rounded))
                        .tracking(-0.5)
                        .foregroundStyle(.primary.opacity(appState.isRecording ? 0.75 : 1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                        })
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(height: min(availableHeight * 0.45, max(72, transcriptHeight + 8)))
                .onPreferenceChange(TranscriptHeightKey.self) { height in
                    if abs(transcriptHeight - height) > 1 { transcriptHeight = height }
                }
                .onChange(of: displayText) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if appState.isRecording {
                VoiceMeter(levels: appState.audioLevels)
                Spacer()
                Text(appState.mode == .hold ? "Release ⇧ to finish" : "Tap ⇧ to finish")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Finish") { NotificationCenter.default.post(name: .stopRecording, object: nil) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else if appState.isTranscribing {
                Text("Final corrections arrive here.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("esc to cancel").font(.caption).foregroundStyle(.tertiary)
            } else {
                Text(editedText.isEmpty ? "Check your connection in Settings." : "Editable. Yours to use.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if editedText.isEmpty {
                    Button("Settings") { NotificationCenter.default.post(name: .openSettings, object: nil) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(editedText, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }
}

private struct TranscriptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 100
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
