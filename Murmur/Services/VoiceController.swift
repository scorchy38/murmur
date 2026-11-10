import AppKit
import AVFoundation
import MurmurKit
import os

private let voiceLog = Logger(subsystem: "com.murmur", category: "Voice")

@MainActor
final class VoiceController {
    typealias StreamFactory = @MainActor (String, String, [String]) -> any VoiceStreaming
    private let state: AppState
    private let recorder: any VoiceCapturing
    private let streamFactory: StreamFactory?
    private let credentialProvider: () -> String?
    private let authorize: () async -> Bool
    private let drainWait: Double
    private let quietWait: Double
    private var stream: (any VoiceStreaming)?
    private var generation = UUID()
    private var attempt = 0
    private var sessionLibrary = VoicePersonalization.starter
    private var sessionApp: String?
    private var sessionStyle = VoiceWritingStyle.natural
    private var sessionVocabulary: [String] = []
    private var sessionLanguage = "en"
    private var transcript = VoiceTranscript()
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var replayAudio: [Data] = []
    private var totalBytes = 0
    private var signal = false
    private var everConnected = false
    private var replaying = false
    private var retried = false
    private var inputClosed = false
    private var postCloseFinal = false
    private var turnCompletedAfterRelease = false
    private var completionTimer: Task<Void, Never>?
    private var drainingCapture = false
    private var credential = ""
    private var finishDate: Date?
    private var startDate = Date()
    private var breaker = VoiceCircuitBreaker()
    private var timers: [Task<Void, Never>] = []
    private var noDataTimer: Task<Void, Never>?
    private var inactivityTimer: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var usageID: UUID?
    private var lastCheckpoint = Date.distantPast
    var onUsageSnapshot: ((VoiceUsageSession) -> Void)?
    var onPresentation: (() -> Void)?
    var onComplete: ((String, Bool) -> Void)?
    var onCancel: (() -> Void)?

    init(state: AppState, recorder: (any VoiceCapturing)? = nil, streamFactory: StreamFactory? = nil, credentialProvider: @escaping () -> String? = { VoiceCredential.read(interactive: false) }, drainWait: Double = 10, quietWait: Double = 2, authorize: @escaping () async -> Bool = {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined { return await AVCaptureDevice.requestAccess(for: .audio) }
        return permission == .authorized
    }) {
        self.drainWait = drainWait; self.quietWait = quietWait
        self.state = state
        self.recorder = recorder ?? AudioRecorder()
        self.streamFactory = streamFactory
        self.credentialProvider = credentialProvider
        self.authorize = authorize
    }

    func start() {
        guard !state.isActive else { return }
        state.warmingUp = false
        state.lastError = nil
        state.notice = nil
        guard state.voiceEnabled else { showFailure(.credentials); return }
        guard breaker.admits() else { showFailure(.paused); return }
        guard let key = credentialProvider() else { state.credentialNeedsApproval = state.hasCredential; showFailure(state.hasCredential ? .keychain : .credentials); return }
        state.credentialNeedsApproval = false
        state.refreshWritingContext()
        sessionLibrary = state.personalization.library
        sessionApp = state.writingAppID
        sessionStyle = state.practiceSession ? .natural : sessionLibrary.style(for: sessionApp)
        sessionVocabulary = state.configuredVocabulary
        sessionLanguage = state.language
        state.recordingStyle = sessionStyle
        state.learnedSpellingMessage = ""
        state.originalTranscript = ""; state.personalizationNotice = ""; state.suggestedCorrection = nil
        generation = UUID()
        let owner = generation
        credential = key
        transcript = VoiceTranscript()
        pending.removeAll(); replayAudio.removeAll()
        pendingBytes = 0; totalBytes = 0; signal = false; everConnected = false
        replaying = false; retried = false; inputClosed = false; postCloseFinal = false; turnCompletedAfterRelease = false; attempt = 0
        drainingCapture = false
        state.currentAttemptCount = 0
        state.attempts = []
        state.lastUsageTokens = nil
        state.lastConnectionLatency = nil
        state.lastFirstTextLatency = nil
        state.lastFinalizationLatency = nil
        finishDate = nil
        state.isRecoveredText = false
        state.completedText = ""
        state.interimTranscript = ""
        state.connectionReady = false
        state.audioLevels = Array(repeating: 0, count: 16)
        startDate = Date()
        usageID = UUID()
        lastCheckpoint = .distantPast
        state.recordingStartDate = startDate
        state.recordingState = .recording
        onPresentation?()
        startTask = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.authorize()
            guard self.generation == owner, self.state.isRecording else { return }
            self.state.microphoneGranted = allowed
            guard allowed else { self.failCapture(.permission); return }
            do {
                try self.recorder.start { [weak self] data in
                    DispatchQueue.main.async { self?.audio(data, owner: owner) }
                } onError: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == owner, self.state.isRecording else { return }
                        self.failCapture(.device)
                    }
                }
                guard self.generation == owner, self.state.isRecording else { self.recorder.stop(); return }
                if self.state.soundsEnabled { NSSound(named: "Tink")?.play() }
                self.connect(owner: owner)
                self.schedule(seconds: self.state.mode == .tap ? 120 : 480, owner: owner) { controller in
                    controller.state.notice = "Recording limit reached. Finishing your text."
                    controller.finish()
                }
                self.resetInactivity(owner: owner)
                voiceLog.info("capture_started")
            } catch { self.failCapture(.device) }
        }
    }

    func finish() {
        guard state.isRecording else { return }
        finishDate = Date()
        let tail = recorder.stop()
        drainingCapture = true
        startTask?.cancel()
        inactivityTimer?.cancel()
        state.recordingState = .transcribing
        state.recordingStartDate = nil
        state.audioLevels = Array(repeating: 0, count: 16)
        let owner = generation
        // Independent hard drain bound starts on release, even if setup is stalled.
        schedule(seconds: 15, owner: owner) { $0.drainEnded(owner: owner) }
        // All microphone callbacks accepted before stop were enqueued ahead of
        // this block. Keep those frames in order, then append resampler tail.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == owner, self.state.isTranscribing else { return }
            if let tail { self.audio(tail, owner: owner) }
            self.drainingCapture = false
            if let stream = self.stream, self.state.connectionReady { stream.finish() }
            else if self.stream == nil { self.drainEnded(owner: owner) }
        }
        onPresentation?()
    }

    func cancel() {
        guard state.isActive || state.warmingUp else { return }
        generation = UUID()
        settleAttempt("cancelled")
        checkpoint(outcome: "cancelled")
        cleanup()
        transcript = VoiceTranscript()
        state.originalTranscript = ""; state.personalizationNotice = ""; state.suggestedCorrection = nil
        state.interimTranscript = ""
        state.completedText = ""
        state.warmingUp = false
        state.recordingState = .idle
        state.lastError = nil
        state.notice = nil
        onCancel?()
        voiceLog.info("cancelled")
    }

    func dispose() {
        generation = UUID()
        settleAttempt("disposed")
        checkpoint(outcome: "interrupted")
        cleanup()
        state.recordingState = .idle
        state.warmingUp = false
        state.interimTranscript = ""
    }

    private func connect(owner: UUID) {
        guard generation == owner, state.isActive else { return }
        attempt += 1
        let connection = attempt
        state.currentAttemptCount += 1
        state.attempts.append(VoiceAttemptSummary())
        let summaryID = state.attempts.last!.id
        state.connectionReady = false
        inputClosed = false; postCloseFinal = false; turnCompletedAfterRelease = false
        completionTimer?.cancel(); completionTimer = nil
        let language = VoiceLanguage.resolve(sessionLanguage)
        if language.usedFallback { state.notice = "This language is not supported yet. Using English." }
        let stream = streamFactory?(credential, language.code, sessionVocabulary) ?? NativeVoiceStream(credential: credential, language: language.code, vocabulary: sessionVocabulary, mode: sessionStyle.transcriptionMode)
        self.stream = stream
        stream.onEvent = { [weak self, weak stream] event in
            guard let self, self.generation == owner else {
                if event == .ready { stream?.cancel() }
                return
            }
            if let index = self.state.attempts.firstIndex(where: { $0.id == summaryID }) {
                if case .text(let text) = event {
                    self.state.attempts[index].estimatedOutputTokens = VoiceUsageSession.estimateTextTokens(text)
                }
                if case .usage(let receipt) = event {
                    self.state.attempts[index].usage = receipt
                    self.state.attempts[index].reportedTokens = receipt.totalTokens
                    let receipts = self.state.attempts.compactMap(\.reportedTokens)
                    self.state.lastUsageTokens = receipts.isEmpty ? nil : receipts.reduce(0, +)
                    self.checkpoint()
                    return
                }
            }
            // Text belongs to the recording. Connection readiness and failure
            // belong to the attempt, so stale errors cannot restart a new one.
            switch event {
            case .interim, .text, .endpoint: break
            default:
                guard self.attempt == connection else {
                    if event == .ready { stream?.cancel() }
                    return
                }
            }
            self.event(event, owner: owner)
        }
        checkpoint()
        stream.start()
        voiceLog.info("stream_attempt \(connection)")
    }

    private func audio(_ data: Data, owner: UUID) {
        guard generation == owner, state.isRecording || drainingCapture, !data.isEmpty else { return }
        guard data.count.isMultiple(of: 2), data.count <= 1_048_576 else { failCapture(.unsupported); return }
        totalBytes += data.count
        if Date().timeIntervalSince(lastCheckpoint) >= 1 { checkpoint() }
        // Eight-minute product cap, below the supplier's ten-minute lifetime.
        guard totalBytes <= VoiceAudio.bytesPerSecond * 480 else {
            state.notice = "Recording limit reached. Finishing your text."
            finish(); return
        }
        let level = VoiceAudio.level(data)
        if state.isRecording { state.updateAudioLevels(level) }
        signal = signal || level > 0.01
        replayAudio.append(data)
        if state.connectionReady { send(data) }
        else {
            guard pendingBytes + data.count <= 2_097_152 else { terminalFailure(.limit); return }
            pending.append(data); pendingBytes += data.count
        }
    }

    private func event(_ event: VoiceEvent, owner: UUID) {
        switch event {
        case .ready:
            if state.lastConnectionLatency == nil { state.lastConnectionLatency = Date().timeIntervalSince(startDate) }
            voiceLog.info("stream_ready attempt=\(self.state.currentAttemptCount)")
            everConnected = true
            state.connectionReady = true
            let chunks = VoiceAudio.coalesced(replaying ? replayAudio : pending)
            pending.removeAll(); pendingBytes = 0
            for data in chunks {
                guard generation == owner else { return }
                send(data)
            }
            if state.isTranscribing && !drainingCapture { stream?.finish() }
        case .inputClosed:
            inputClosed = true
            if state.isTranscribing {
                noDataTimer?.cancel()
                // Sending activityEnd is not a receipt for all speech. Keep
                // waiting for authoritative text, including a lagging tail.
                noDataTimer = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.drainWait ?? 10))
                    guard !Task.isCancelled, let self, self.generation == owner else { return }
                    self.drainEnded(owner: owner)
                }
                if turnCompletedAfterRelease { complete(owner: owner, salvaged: transcript.authoritativeSegments == 0 || !transcript.hypothesis.isEmpty) }
            }
        case .interim, .text:
            completionTimer?.cancel(); completionTimer = nil
            transcript.accept(event)
            if case .text = event, inputClosed { postCloseFinal = true }
            if transcript.receivedText && state.lastFirstTextLatency == nil { state.lastFirstTextLatency = Date().timeIntervalSince(startDate) }
            state.interimTranscript = transcript.preview
            if transcript.receivedText { breaker.succeeded() }
            resetInactivity(owner: owner)
        case .endpoint:
            transcript.accept(event)
            state.interimTranscript = transcript.preview
            if state.isTranscribing && inputClosed && postCloseFinal { completeSoon(owner: owner) }
        case .turnComplete:
            if state.isTranscribing {
                // A fast server can reply while the activityEnd send is still
                // resuming. Latch its receipt until capture/input have drained.
                turnCompletedAfterRelease = true
                if inputClosed { complete(owner: owner, salvaged: transcript.authoritativeSegments == 0 || !transcript.hypothesis.isEmpty) }
            }
        case .usage: break // Accounted against the originating connection above.
        case .failure(let failure):
            if !failure.isFatal, !transcript.receivedText, !retried, state.isRecording {
                retried = true
                settleAttempt("early_failure")
                stream?.cancel(); stream = nil
                state.connectionReady = false
                attempt += 1 // Invalidate the failing connection immediately.
                schedule(seconds: 0.25, owner: owner) { $0.connect(owner: owner) }
            } else { terminalFailure(failure) }
        case .closed:
            if state.isTranscribing { drainEnded(owner: owner) }
            else { terminalFailure(.connection) }
        }
    }

    private func drainEnded(owner: UUID) {
        guard generation == owner, state.isTranscribing else { return }
        if !transcript.receivedText, transcript.preview.isEmpty, signal, everConnected, !replayAudio.isEmpty, !replaying {
            replaying = true
            settleAttempt("no_data")
            stream?.cancel(); stream = nil
            noDataTimer?.cancel()
            cancelTimers()
            attempt += 1
            state.notice = "Recovering your recording…"
            schedule(seconds: 0.25, owner: owner) { controller in
                controller.connect(owner: owner)
                controller.schedule(seconds: 15, owner: owner) { $0.complete(owner: owner, salvaged: true) }
            }
            voiceLog.info("silent_drop_replay")
        } else { complete(owner: owner, salvaged: true) }
    }

    private func completeSoon(owner: UUID) {
        // Some providers omit turnComplete. A post-close segment can finish
        // only after a quiet window; subsequent text cancels this fallback.
        completionTimer?.cancel()
        completionTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.quietWait ?? 2))
            guard !Task.isCancelled, let self, self.generation == owner else { return }
            self.complete(owner: owner, salvaged: false)
        }
    }

    private func complete(owner: UUID, salvaged: Bool) {
        guard generation == owner, state.isActive else { return }
        let usedSalvage = salvaged || !transcript.hypothesis.isEmpty
        transcript.salvage()
        let recognized = transcript.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        state.originalTranscript = recognized
        let personalized = usedSalvage || state.practiceSession ? VoicePersonalizedText(text: recognized) : VoicePersonalizer.process(recognized, library: sessionLibrary, app: sessionApp, style: sessionStyle)
        let text = personalized.text
        state.personalizationNotice = personalized.expandedSnippet ? "Snippet expanded" : personalized.formattedIdentifier ? "Identifier formatted" : personalized.corrections > 0 ? "Personal spelling applied" : ""
        let duration = Double(totalBytes) / Double(VoiceAudio.bytesPerSecond)
        state.lastDuration = Double(totalBytes) / Double(VoiceAudio.bytesPerSecond)
        state.lastAudioBytes = totalBytes
        state.lastFinalizationLatency = finishDate.map { Date().timeIntervalSince($0) }
        state.isRecoveredText = usedSalvage && !text.isEmpty
        if text.isEmpty, duration > 2, state.lastError == nil {
            state.lastError = (signal ? (everConnected ? VoiceFailure.noSpeech : .connection) : .noSignal).localizedDescription
        }
        generation = UUID()
        settleAttempt(state.lastError != nil ? "error" : usedSalvage ? "salvaged" : "completed")
        checkpoint(outcome: text.isEmpty ? "empty" : "completed", words: VoiceUsageSession.countWords(recognized))
        cleanup()
        state.recordingState = .idle
        state.interimTranscript = ""
        state.completedText = text
        state.completedRecordingID = UUID()
        if state.isRecoveredText { state.notice = "Recovered preview. Review before using." }
        onPresentation?()
        if !text.isEmpty {
            breaker.succeeded()
            onComplete?(text, state.isRecoveredText)
            if state.soundsEnabled { NSSound(named: "Pop")?.play() }
        }
        voiceLog.info("recording_finished bytes=\(self.state.lastAudioBytes) attempts=\(self.state.currentAttemptCount) characters=\(text.count) salvaged=\(usedSalvage)")
    }

    private func terminalFailure(_ failure: VoiceFailure) {
        voiceLog.error("stream_failed category=\(failure.rawValue, privacy: .public)")
        if !transcript.receivedText && Date().timeIntervalSince(startDate) < 2 { breaker.failed() }
        state.lastError = failure.localizedDescription
        complete(owner: generation, salvaged: true)
    }
    private func failCapture(_ failure: VoiceFailure) {
        voiceLog.error("capture_failed category=\(failure.rawValue, privacy: .public)")
        breaker.failed()
        state.lastError = failure.localizedDescription
        complete(owner: generation, salvaged: true)
    }
    private func showFailure(_ failure: VoiceFailure) {
        voiceLog.info("gate_rejected category=\(failure.rawValue, privacy: .public)")
        state.lastError = failure.localizedDescription
        onPresentation?()
    }
    private func send(_ data: Data) {
        guard let stream else { return }
        if let last = state.attempts.indices.last { state.attempts[last].queuedAudioBytes += data.count }
        stream.send(data)
    }
    private func settleAttempt(_ outcome: String) {
        if let last = state.attempts.indices.last, state.attempts[last].outcome == "active" {
            state.attempts[last].outcome = outcome
        }
    }
    private func resetInactivity(owner: UUID) {
        guard state.mode == .tap, state.isRecording else { return }
        inactivityTimer?.cancel()
        inactivityTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.generation == owner else { return }
            self.finish()
        }
    }
    private func schedule(seconds: Double, owner: UUID, _ action: @escaping (VoiceController) -> Void) {
        timers.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.generation == owner else { return }
            action(self)
        })
    }
    private func cancelTimers() { timers.forEach { $0.cancel() }; timers.removeAll() }
    private func checkpoint(outcome: String = "active", words: Int = 0) {
        guard let id = usageID else { return }
        onUsageSnapshot?(VoiceUsageSession(id: id, startedAt: startDate, duration: Double(totalBytes) / Double(VoiceAudio.bytesPerSecond), words: words, outcome: outcome, attempts: state.attempts))
        lastCheckpoint = Date()
        if outcome != "active" { usageID = nil }
    }
    private func cleanup() {
        recorder.stop()
        stream?.cancel(); stream = nil
        startTask?.cancel(); startTask = nil
        completionTimer?.cancel(); completionTimer = nil
        noDataTimer?.cancel(); noDataTimer = nil
        inactivityTimer?.cancel(); inactivityTimer = nil
        cancelTimers()
        pending.removeAll(); replayAudio.removeAll(); pendingBytes = 0
        credential = ""
        state.recordingStartDate = nil
        state.connectionReady = false
        state.audioLevels = Array(repeating: 0, count: 16)
        drainingCapture = false
    }
}
