import SwiftUI
import MurmurKit

struct SetupView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Let's hear your first prompt.").font(.title2.bold())
                    Text("Connect once, try a prompt, and get back to what you were doing.")
                        .foregroundStyle(.secondary)
                }.padding(.vertical, 8)
            }
            Section("1 · Connect and enable") {
                check("API key saved in Keychain", passed: state.hasCredential)
                check("Microphone permission", passed: state.microphoneGranted)
                check("Dictation enabled", passed: state.voiceEnabled)
                if let checked = state.lastConnectionCheck { Text("Connection verified \(checked.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary) }
                Button(state.voiceEnabled && state.hasCredential ? "Connection settings" : "Connect your speech account") { post(.selectConnectionSettings) }
                Text("Audio goes directly to Gemini. Practice uses your API account too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("2 · Make the shortcut yours") {
                check("Global shortcut listening", passed: state.shortcutListening)
                HStack {
                    ShortcutBadge(title: state.shortcut.symbol)
                    Text(state.shortcutInstruction + " to speak. Escape cancels.")
                }
                if !state.accessibilityGranted {
                    Button("Allow Accessibility") { post(.openShortcutPermissions) }
                }
                Text("Try your shortcut with this page active, or use the practice button below. The checklist updates as each part works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("3 · Try it here") {
                Text("Try saying: ‘Murmur is ready for my next idea.’ Or say anything you like.")
                    .foregroundStyle(.secondary)
                if state.practiceSession && state.isActive {
                    HStack {
                        VoiceMeter(levels: state.audioLevels)
                        Text(state.isRecording ? "Listening…" : "Finishing…").font(.callout)
                        Spacer()
                        if state.isRecording { Button("Finish") { post(.stopRecording) } }
                        Button("Cancel", role: .cancel) { post(.cancelRecording) }
                    }
                    Text(state.interimTranscript.isEmpty ? "Your words will appear here." : state.interimTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Button(state.setupPracticePassed ? "Practice again" : "Start practice") { post(.startPractice) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.voiceEnabled || state.isActive)
                }
                if !state.practiceText.isEmpty {
                    Text(state.practiceText).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !state.practiceMessage.isEmpty { Text(state.practiceMessage).font(.callout).foregroundStyle(.secondary) }
                check("Microphone signal detected", passed: state.practiceHeardSignal)
                check("Speech recognized and copied", passed: state.setupPracticePassed)
                check("Started with the global shortcut", passed: state.practiceShortcutVerified)
                Text("Practice text is not added to your saved Library or synced. Usage counts still include this speech session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("4 · Try your real workflow") {
                Text("Switch to Notes or a chat box. Paste the practice result, or \(state.shortcutInstruction.lowercased()) to dictate a new prompt there.")
                check("External delivery checked", passed: state.setupExternalPassed)
                Button("I pasted the result successfully") { state.setupExternalPassed = true }
                    .disabled(!state.setupPracticePassed)
                Text("Direct insertion is verified automatically when a supported field accepts text. For clipboard workflows, this button records your confirmation. Murmur never presses Send or Enter for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

    }
    private func check(_ title: String, passed: Bool) -> some View {
        Label(title, systemImage: passed ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(passed ? Color.green : Color.secondary)
            .accessibilityLabel(title + (passed ? ", verified" : ", not verified"))
    }
    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }
}

struct ResultReviewView: View {
    @EnvironmentObject var state: AppState
    @State private var baseline = ""
    @State private var learnedMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your last prompt").font(.title2.bold())
            Text("Ready to copy whenever you are.").foregroundStyle(.secondary)
            TextEditor(text: $state.completedText)
                .font(.system(size: 18)).scrollContentBackground(.hidden)
                .accessibilityLabel("Last prompt")
            if let suggestion = VoiceCorrectionSuggestion.between(baseline, state.completedText) {
                Button("Remember \(suggestion.spoken) → \(suggestion.written)", systemImage: "sparkles") {
                    do {
                        try state.personalization.addWord(written: suggestion.written, spoken: suggestion.spoken)
                        learnedMessage = "Remembered as a recognition hint for future dictations."
                        baseline = state.completedText
                    } catch { learnedMessage = error.localizedDescription }
                }
            }
            if !state.learnedSpellingMessage.isEmpty { Text(state.learnedSpellingMessage).font(.caption).foregroundStyle(.secondary) }
            if let learnedMessage { Text(learnedMessage).font(.caption).foregroundStyle(.secondary) }
            if !state.originalTranscript.isEmpty && state.originalTranscript != state.completedText {
                DisclosureGroup("Original recognition") {
                    Text(state.originalTranscript).font(.callout).textSelection(.enabled)
                    Button("Copy original") {
                        baseline = state.originalTranscript
                        state.completedText = state.originalTranscript
                        NotificationCenter.default.post(name: .copyLastResult, object: nil)
                    }
                }
            }
            HStack {
                Text(state.deliveryMessage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    state.learnReviewedSpellings(original: baseline, edited: state.completedText)
                    NotificationCenter.default.post(name: .copyLastResult, object: nil)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(minWidth: 480, minHeight: 320)
        .task(id: state.completedText) {
            let draft = state.completedText
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            state.learnReviewedSpellings(original: baseline, edited: draft)
        }
        .onAppear { baseline = state.completedText }
        .onChange(of: state.completedRecordingID) { _, _ in baseline = state.completedText; learnedMessage = nil }
    }
}

struct ShadowStatusView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack(spacing: 10) {
            if state.isRecording { VoiceMeter(levels: Array(state.audioLevels.suffix(5))) }
            else { Image(systemName: state.lastError != nil ? "exclamationmark.circle" : state.isTranscribing ? "ellipsis" : state.warmingUp ? "mic" : "checkmark.circle") }
            Text(state.isRecording ? "Listening" : state.isTranscribing ? "Finishing…" : state.warmingUp ? "Keep holding…" : state.lastError != nil ? "Check Murmur in the menu bar" : "Copied. Ready to paste.")
                .font(.callout.weight(.medium)).lineLimit(1)
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .padding(5)
        .accessibilityElement(children: .combine)
    }
}
