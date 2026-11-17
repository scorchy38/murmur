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
    private var diagnosticSignalPeak = 0.0
    private var diagnosticDelayPeak = 0.0
    private var diagnosticCaptureAt = -Double.infinity
    private var signal = false
    private var everConnected = false
    private var retainedAudio: [Data] = []
    private var retainedUntil: Date?
    private var retentionTask: Task<Void, Never>?
    private let retryRetention: Double
    private var replaying = false
    private var retried = false
    private var inputClosed = false
    private var finalReceipt = false
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

    init(state: AppState, recorder: (any VoiceCapturing)? = nil, streamFactory: StreamFactory? = nil, credentialProvider: @escaping () -> String? = { VoiceCredential.read(interactive: false) }, drainWait: Double = 10, retryRetention: Double = 300, authorize: @escaping () async -> Bool = {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        if permission == .notDetermined { return await AVCaptureDevice.requestAccess(for: .audio) }
        return permission == .authorized
    }) {
        self.retryRetention = retryRetention
        self.drainWait = drainWait
        self.state = state
        self.recorder = recorder ?? AudioRecorder()
        self.streamFactory = streamFactory
        self.credentialProvider = credentialProvider
        self.authorize = authorize
    }

    func start(recordingID: UUID? = nil) {
        guard !state.isActive else { return }
        clearRetainedAudio()
        state.diagnosticRecordingID = recordingID ?? UUID()
        diagnosticSignalPeak = 0; diagnosticDelayPeak = 0; diagnosticCaptureAt = -.infinity
        state.attempts = []; state.currentAttemptCount = 0
        trace(.recordingRequested, force: true)
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
        replaying = false; retried = false; inputClosed = false; finalReceipt = false; attempt = 0
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
        usageID = state.diagnosticRecordingID
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
                    let queuedAt = ProcessInfo.processInfo.systemUptime
                    DispatchQueue.main.async { self?.audio(data, owner: owner, queuedAt: queuedAt) }
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
                self.trace(.captureStarted, values: .init(writingStyle: self.sessionStyle, languageCode: VoiceLanguage.resolve(self.sessionLanguage).code), force: true)
                voiceLog.info("capture_started")
            } catch { self.failCapture(.device) }
        }
    }

    func finish() {
        guard state.isRecording else { return }
        finishDate = Date()
        trace(.finishRequested, force: true)
        let tail = recorder.stop()
        drainingCapture = true
        trace(.captureStopped, values: .init(capturedBytes: totalBytes), force: true)
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

    /// Stop immediately without delivering into another app. Keep everything
    /// already recognized, including a provisional tail, available to recover.
    func cancel() {
        guard state.isActive || state.warmingUp else { return }
        trace(.interrupted, values: .init(capturedBytes: totalBytes, textCharacters: transcript.preview.count), force: true)
        clearRetainedAudio()
        let practice = state.practiceSession
        let text = transcript.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftID = usageID ?? generation
        generation = UUID()
        settleAttempt("interrupted")
        checkpoint(outcome: "interrupted", words: VoiceUsageSession.countWords(text))
        cleanup()
        transcript = VoiceTranscript()
        state.originalTranscript = text; state.personalizationNotice = ""; state.suggestedCorrection = nil
        state.interimTranscript = ""; state.completedText = text
        state.completedRecordingID = UUID()
        state.isRecoveredText = !text.isEmpty
        state.warmingUp = false; state.recordingState = .idle
        state.lastError = nil
        onCancel?()
        if !text.isEmpty && !practice {
            state.recovery.checkpoint(id: draftID, text: text, interrupted: true, persist: state.saveHistory, force: true)
            state.notice = "Recording stopped. Your draft was kept; review or copy it here."
            onComplete?(text, true)
            state.notice = "Recording stopped. Your draft was kept; review or copy it here."
            onPresentation?()
        }
        voiceLog.notice("recording_interrupted preserved_characters=\(text.count)")
    }

    /// A user-requested second attempt never records or inserts into a stale field.
    /// Its API connection is accounted separately; spoken duration is counted once.
    func retryTranscription() {
        guard !state.isActive, let expiry = retainedUntil, expiry > Date(), !retainedAudio.isEmpty else {
            if !state.isActive { clearRetainedAudio() }
            return
        }
        guard let key = credentialProvider() else {
            state.credentialNeedsApproval = state.hasCredential
            showFailure(state.hasCredential ? .keychain : .credentials)
            return
        }
        generation = UUID()
        let owner = generation
        credential = key
        replayAudio = retainedAudio
        totalBytes = replayAudio.reduce(0) { $0 + $1.count }
        replaying = true; retried = true; drainingCapture = false
        transcript = VoiceTranscript()
        pending.removeAll(); pendingBytes = 0
        inputClosed = false; finalReceipt = false; everConnected = false; attempt = 0
        state.attempts = []; state.currentAttemptCount = 0
        state.lastError = nil; state.notice = "Retrying your recording…"
        state.completedText = ""; state.interimTranscript = ""; state.originalTranscript = ""
        state.isRecoveredText = false; state.credentialNeedsApproval = false
        state.lastUsageTokens = nil; state.lastConnectionLatency = nil
        state.lastFirstTextLatency = nil; state.lastFinalizationLatency = nil
        state.practiceSession = false
        state.canRetryTranscription = false
        startDate = Date(); finishDate = startDate; lastCheckpoint = .distantPast
        let id = UUID()
        usageID = id; state.diagnosticRecordingID = id
        state.diagnostics.begin(id)
        state.recordingState = .transcribing
        trace(.replayScheduled, values: .init(capturedBytes: totalBytes), force: true)
        onPresentation?()
        connect(owner: owner)
        schedule(seconds: 15, owner: owner) { $0.drainEnded(owner: owner) }
    }

    private func retainAudioForRetry() {
        retainedAudio = replayAudio
        if retainedUntil == nil { retainedUntil = Date().addingTimeInterval(retryRetention) }
        state.canRetryTranscription = (retainedUntil ?? .distantPast) > Date()
        retentionTask?.cancel()
        let wait = max(0, retainedUntil!.timeIntervalSinceNow)
        retentionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.clearRetainedAudio()
        }
    }

    private func clearRetainedAudio() {
        retentionTask?.cancel(); retentionTask = nil
        retainedAudio.removeAll(); retainedUntil = nil
        state.canRetryTranscription = false
    }

    func dispose() {
        trace(.disposed, force: true)
        if state.isActive && !state.practiceSession {
            state.recovery.checkpoint(id: usageID ?? generation, text: transcript.preview, interrupted: true, persist: state.saveHistory, force: true)
        }
        generation = UUID()
        settleAttempt("disposed")
        checkpoint(outcome: "interrupted", words: VoiceUsageSession.countWords(transcript.preview))
        cleanup()
        clearRetainedAudio()
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
        trace(.connectionRequested, force: true)
        state.connectionReady = false
        inputClosed = false; finalReceipt = false
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
                    self.state.attempts[index].estimatedOutputTokens = (self.state.attempts[index].estimatedOutputTokens ?? 0) + VoiceUsageSession.estimateTextTokens(text)
                }
                if case .providerBoundary(let boundary) = event {
                    guard self.attempt == connection else { return }
                    self.trace(.providerBoundary, values: .init(providerBoundary: boundary), force: true)
                    return
                }
                if case .transportFailure(let failure) = event {
                    guard self.attempt == connection else { return }
                    self.state.attempts[index].transportFailure = failure
                    self.trace(.transportFailure, values: .init(transportFailure: failure), force: true)
                    self.checkpoint()
                    return
                }
                if case .progress(let progress) = event {
                    guard self.attempt == connection else { return }
                    self.state.attempts[index].streamProgress = progress
                    self.trace(.transportProgress, values: .init(progress: progress), coalesce: 1)
                    if Date().timeIntervalSince(self.lastCheckpoint) >= 1 { self.checkpoint() }
                    return
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

    private func audio(_ data: Data, owner: UUID, queuedAt: Double? = nil) {
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
        let delay = queuedAt.map { ProcessInfo.processInfo.systemUptime - $0 }
        diagnosticSignalPeak = max(diagnosticSignalPeak, level)
        diagnosticDelayPeak = max(diagnosticDelayPeak, delay ?? 0)
        let now = ProcessInfo.processInfo.systemUptime
        if now - diagnosticCaptureAt >= 1 {
            trace(.captureProgress, values: .init(capturedBytes: totalBytes, signalLevel: diagnosticSignalPeak, delaySeconds: diagnosticDelayPeak))
            if diagnosticDelayPeak > 0.25 { trace(.mainQueueDelay, values: .init(delaySeconds: diagnosticDelayPeak)) }
            diagnosticCaptureAt = now; diagnosticSignalPeak = 0; diagnosticDelayPeak = 0
        }
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
            trace(.connectionReady, force: true)
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
            trace(.inputClosed, force: true)
            inputClosed = true
            if state.isTranscribing {
                noDataTimer?.cancel()
                // Sending activityEnd is not a receipt for all speech. Keep
                // waiting for authoritative text, including a lagging tail.
                noDataTimer = Task { [weak self] in
                    let wait = self.map { $0.transcript.preview.isEmpty && !$0.replaying ? min(5, $0.drainWait) : $0.drainWait } ?? 10
                    try? await Task.sleep(for: .seconds(wait))
                    // A first result may arrive near the empty-result deadline.
                    // Give its trailing words the normal drain window.
                    if !Task.isCancelled, let self, self.generation == owner, !self.transcript.preview.isEmpty, wait < self.drainWait {
                        try? await Task.sleep(for: .seconds(self.drainWait - wait))
                    }
                    guard !Task.isCancelled, let self, self.generation == owner else { return }
                    self.drainEnded(owner: owner)
                }
                if finalReceipt { completeFinalized(owner: owner) }
            }
        case .interim, .text:
            let previous = transcript.preview
            transcript.accept(event)
            trace(.transcriptProgress, values: .init(textCharacters: transcript.preview.count, textChanged: previous != transcript.preview), coalesce: 1)
            if let index = state.attempts.indices.last {
                state.attempts[index].transcriptEvents = (state.attempts[index].transcriptEvents ?? 0) + 1
                state.attempts[index].lastTextAudioSeconds = Double(totalBytes) / Double(VoiceAudio.bytesPerSecond)
            }
            if !state.practiceSession { state.recovery.checkpoint(id: usageID ?? generation, text: transcript.preview, persist: state.saveHistory) }
            if transcript.receivedText && state.lastFirstTextLatency == nil { state.lastFirstTextLatency = Date().timeIntervalSince(startDate) }
            state.interimTranscript = transcript.preview
            if transcript.receivedText { breaker.succeeded() }
            resetInactivity(owner: owner)
        case .endpoint:
            transcript.accept(event)
            trace(.segmentFinalized, values: .init(textCharacters: transcript.preview.count), force: true)
            state.interimTranscript = transcript.preview
            if let index = state.attempts.indices.last { state.attempts[index].finalizedSegments = (state.attempts[index].finalizedSegments ?? 0) + 1 }
        case .finalized:
            trace(.finalReceipt, force: true)
            finalReceipt = true
            if state.isTranscribing && inputClosed { completeFinalized(owner: owner) }
        case .turnComplete: break // Not a transcription completion receipt.
        case .providerBoundary, .transportFailure, .progress, .usage: break // Accounted against the originating connection above.
        case .failure(let failure):
            if !failure.isFatal, !transcript.receivedText, !retried, state.isRecording {
                retried = true
                trace(.retryScheduled, values: .init(failure: failure), force: true)
                settleAttempt("early_failure")
                stream?.cancel(); stream = nil
                state.connectionReady = false
                attempt += 1 // Invalidate the failing connection immediately.
                schedule(seconds: 0.25, owner: owner) { $0.connect(owner: owner) }
            } else { terminalFailure(failure) }
        case .closed:
            trace(.connectionClosed, force: true)
            if state.isTranscribing { drainEnded(owner: owner, timedOut: false) }
            else { terminalFailure(.connection) }
        }
    }

    private func drainEnded(owner: UUID, timedOut: Bool = true) {
        guard generation == owner, state.isTranscribing else { return }
        if timedOut { trace(.timedOut, values: .init(capturedBytes: totalBytes), force: true) }
        complete(owner: owner, salvaged: true)
    }

    private func completeFinalized(owner: UUID) {
        // The adapter emits this only after its receive batch (including usage)
        // and every audio turn have completed. No quiet-window delay is needed.
        noDataTimer?.cancel()
        complete(owner: owner, salvaged: false)
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
        state.lastDuration = Double(totalBytes) / Double(VoiceAudio.bytesPerSecond)
        state.lastAudioBytes = totalBytes
        state.lastFinalizationLatency = finishDate.map { Date().timeIntervalSince($0) }
        trace(.completed, values: .init(capturedBytes: totalBytes, textCharacters: text.count, delaySeconds: state.lastFinalizationLatency), force: true)
        if let index = state.attempts.indices.last { state.attempts[index].finalizationSeconds = state.lastFinalizationLatency }
        state.isRecoveredText = usedSalvage && !text.isEmpty
        if text.isEmpty, state.lastError == nil {
            state.lastError = (signal ? (everConnected ? VoiceFailure.noSpeech : .connection) : .noSignal).localizedDescription
        }
        if !text.isEmpty && !state.practiceSession { state.recovery.checkpoint(id: usageID ?? generation, text: text, interrupted: usedSalvage, persist: state.saveHistory, force: true) }
        if text.isEmpty && !replayAudio.isEmpty {
            retainAudioForRetry()
            state.notice = "Retry uses this recording; you don’t need to speak again. Audio is kept in memory for up to five minutes."
        } else { clearRetainedAudio() }
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
            onComplete?(text, state.isRecoveredText || replaying)
            if !usedSalvage { state.recovery.clear() }
            if state.soundsEnabled { NSSound(named: "Pop")?.play() }
        }
        voiceLog.notice("recording_finished bytes=\(self.state.lastAudioBytes) attempts=\(self.state.currentAttemptCount) characters=\(text.count) salvaged=\(usedSalvage)")
    }

    private func terminalFailure(_ failure: VoiceFailure) {
        trace(.failed, values: .init(failure: failure), force: true)
        voiceLog.error("stream_failed category=\(failure.rawValue, privacy: .public)")
        if !transcript.receivedText && Date().timeIntervalSince(startDate) < 2 { breaker.failed() }
        state.lastError = failure.localizedDescription
        complete(owner: generation, salvaged: true)
    }
    private func failCapture(_ failure: VoiceFailure) {
        trace(.failed, values: .init(failure: failure), force: true)
        voiceLog.error("capture_failed category=\(failure.rawValue, privacy: .public)")
        breaker.failed()
        state.lastError = failure.localizedDescription
        complete(owner: generation, salvaged: true)
    }
    private func showFailure(_ failure: VoiceFailure) {
        trace(.failed, values: .init(failure: failure), force: true)
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
        onUsageSnapshot?(VoiceUsageSession(id: id, startedAt: startDate, duration: replaying ? 0 : Double(totalBytes) / Double(VoiceAudio.bytesPerSecond), words: words, outcome: outcome, attempts: state.attempts))
        lastCheckpoint = Date()
        if outcome != "active" { usageID = nil }
    }
    private func trace(_ kind: DiagnosticKind, values: DiagnosticValues = .init(), coalesce: Double = 0, force: Bool = false) {
        guard let id = state.diagnosticRecordingID else { return }
        state.diagnostics.record(kind, id: id, attempt: state.attempts.last?.id, values: values, coalesce: coalesce, force: force)
    }
    private func cleanup() {
        recorder.stop()
        stream?.cancel(); stream = nil
        startTask?.cancel(); startTask = nil
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
