import Foundation

@MainActor
public protocol VoiceStreaming: AnyObject {
    var onEvent: ((VoiceEvent) -> Void)? { get set }
    func start()
    func send(_ audio: Data)
    func finish()
    func cancel()
}

/// The native application owns the service adapter. The controller sees only product events.
@MainActor
public final class NativeVoiceStream: VoiceStreaming {
    public var onEvent: ((VoiceEvent) -> Void)?
    private let credential: String
    private let language: String
    private let vocabulary: [String]
    private let mode: VoiceTranscriptionMode
    private let keepaliveEnabled: Bool
    private var transport: (any VoiceSocketTransport)?
    var transportFactory: (URLRequest) -> any VoiceSocketTransport = { URLSessionVoiceSocket(request: $0) }
    var finalizationTimeout: Double = 12
    private var resumeOnProviderFinal = true
    private var needsActivityStart = false
    private var activityHasAudio = false
    private var awaitingFinal = false
    private var finalReceived = false
    private var progress = VoiceStreamProgress()
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var lastProviderText: String?
    private var progressReportedAt = -Double.infinity
    private var completed = false
    private var turnDeadline: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var setupDeadline: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var ready = false
    private var closingInput = false
    private var endedInput = false
    private var cancelled = false
    private var started = false
    private var normalizer = VoiceProviderNormalizer()

    public init(credential: String, language: String, vocabulary: [String], keepaliveEnabled: Bool = true, mode: VoiceTranscriptionMode = .smart, recoverEarlyFinals: Bool = true) {
        self.resumeOnProviderFinal = recoverEarlyFinals
        self.mode = mode
        self.credential = credential
        self.language = VoiceLanguage.resolve(language).code
        self.vocabulary = VoiceVocabulary.nativeHints(vocabulary)
        self.keepaliveEnabled = keepaliveEnabled
    }

    public static func setup(language: String, vocabulary: [String], mode: VoiceTranscriptionMode = .smart) -> [String: Any] {
        ["setup": [
            "model": "models/gemini-3.5-transcribe-live",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": ["mode": mode.rawValue, "languageCodes": language == "auto" ? [] : [language], "customVocabulary": vocabulary]
        ]]
    }

    public func start() {
        guard !started, !cancelled else { return }
        started = true
        startedAt = ProcessInfo.processInfo.systemUptime
        // Header authentication keeps secrets out of URL logs and diagnostics.
        var request = URLRequest(url: URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!)
        request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
        let transport = transportFactory(request)
        self.transport = transport
        setupDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, !self.ready, !self.cancelled else { return }
            self.fail(.connection)
        }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.write(Self.setup(language: self.language, vocabulary: self.vocabulary, mode: self.mode))
                while !Task.isCancelled && !self.cancelled {
                    let data = try await transport.receive()
                    guard !self.cancelled else { return }
                    let elapsed = ProcessInfo.processInfo.systemUptime - self.startedAt
                    self.progress.receivedMessages += 1
                    if let previous = self.progress.lastMessageSeconds { self.progress.largestMessageGapSeconds = max(self.progress.largestMessageGapSeconds ?? 0, elapsed - previous) }
                    self.progress.lastMessageSeconds = elapsed
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.progress.malformedMessages = (self.progress.malformedMessages ?? 0) + 1; self.reportProgress(); continue }
                    if let content = json["serverContent"] as? [String: Any] {
                        if let interim = content["interimInputTranscription"] as? [String: Any], let text = interim["text"] as? String {
                            self.progress.interimMessages += 1
                            if text == self.lastProviderText { self.progress.unchangedInterimMessages = (self.progress.unchangedInterimMessages ?? 0) + 1 }
                            else {
                                if let previous = self.progress.lastTranscriptChangeSeconds { self.progress.largestTranscriptChangeGapSeconds = max(self.progress.largestTranscriptChangeGapSeconds ?? 0, elapsed - previous) }
                                self.progress.lastTranscriptChangeSeconds = elapsed
                                self.lastProviderText = text
                            }
                            self.progress.lastTranscriptSeconds = elapsed
                            self.progress.largestInterimCharacters = max(self.progress.largestInterimCharacters, text.count)
                        }
                        if content["inputTranscription"] != nil {
                            self.progress.finalMessages += 1
                            self.progress.lastTranscriptSeconds = elapsed
                        }
                        if content["turnComplete"] as? Bool == true { self.progress.turnCompleteMessages += 1 }
                    }
                    if let content = json["serverContent"] as? [String: Any], content["inputTranscription"] != nil || content["generationComplete"] != nil || content["turnComplete"] != nil || content["waitingForInput"] != nil {
                        let transcription = content["inputTranscription"] as? [String: Any]
                        func seconds(_ value: Any?) -> Double? {
                            guard let string = value as? String, string.hasSuffix("s"), let value = Double(string.dropLast()), value.isFinite, value >= 0 else { return nil }
                            return value
                        }
                        self.onEvent?(.providerBoundary(.init(origin: .server, elapsedSeconds: elapsed, sentAudioBytes: self.progress.sentAudioBytes, queuedAudioBytes: self.queuedBytes, clientFinishRequested: self.closingInput, clientInputEnded: self.endedInput, transcriptionPresent: transcription != nil, transcriptionFinished: transcription?["finished"] as? Bool, startOffsetSeconds: seconds(transcription?["startOffset"]), endOffsetSeconds: seconds(transcription?["endOffset"]), generationComplete: content["generationComplete"] as? Bool, turnComplete: content["turnComplete"] as? Bool, waitingForInput: content["waitingForInput"] as? Bool, textCharacters: (transcription?["text"] as? String)?.count)))
                    }
                    self.reportProgress()
                    if json["setupComplete"] != nil, !self.ready {
                        try await self.write(["realtimeInput": ["activityStart": [:]]])
                        guard !self.cancelled else { return }
                        self.ready = true
                        self.setupDeadline?.cancel()
                        self.keepalive = Task { [weak self] in
                            guard self?.keepaliveEnabled == true else { return }
                            while !Task.isCancelled {
                                guard let self, !self.cancelled else { return }
                                do {
                                    try await transport.ping()
                                }
                                catch { if !self.cancelled { self.reportFailure(.ping, error: error); self.fail(.connection) }; return }
                                try? await Task.sleep(for: .seconds(8))
                            }
                        }
                        self.onEvent?(.ready)
                        self.pump()
                    }
                    for event in self.normalizer.events(json) {
                        guard !self.cancelled else { return }
                        if case .failure(let failure) = event {
                            self.reportFailure(.receive, providerCode: (json["error"] as? [String: Any])?["code"] as? Int)
                            self.fail(failure); return
                        }
                        // turnComplete belongs to conversational models. The
                        // transcription receipt is inputTranscription/endpoint.
                        if event == .turnComplete { continue }
                        if event == .endpoint {
                            if self.awaitingFinal { self.finalReceived = true }
                            else if self.resumeOnProviderFinal && self.ready && self.activityHasAudio {
                                // The service ended its turn while the user still
                                // owns the recording. Re-arm on the next audio;
                                // never send a timed activityEnd ourselves.
                                self.needsActivityStart = true
                                self.activityHasAudio = false
                                self.progress.earlyFinals = (self.progress.earlyFinals ?? 0) + 1
                            }
                        }
                        self.onEvent?(event)
                    }
                    self.completeIfReady()
                }
            } catch {
                guard !self.cancelled else { return }
                self.reportFailure(self.ready ? .receive : .setup, error: error)
                let status = transport.statusCode
                let code = transport.closeCode
                if status == 401 || status == 403 { self.fail(.credentials) }
                else if status == 429 { self.fail(.quota) }
                else if code == 1008 { self.fail(.setup) }
                else if let status, (400..<500).contains(status), status != 101 { self.fail(.setup) }
                else if self.endedInput && (code == 1000 || code == 1005) {
                    self.onEvent?(.closed)
                    self.cancel()
                } else { self.fail(.connection) }
            }
        }
    }

    public func send(_ audio: Data) {
        guard !cancelled, !closingInput, !audio.isEmpty else { return }
        guard audio.count.isMultiple(of: 2) else { fail(.unsupported); return }
        guard audio.count <= 1_048_576, queuedBytes + audio.count <= VoiceAudio.bytesPerSecond * 480 else { fail(.limit); return }
        queue.append(audio)
        queuedBytes += audio.count
        pump()
    }

    public func finish() {
        guard !cancelled, !closingInput else { return }
        closingInput = true
        pump()
    }

    private func pump() {
        guard ready, !cancelled, !completed, sender == nil, !awaitingFinal else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            defer { self.sender = nil; self.completeIfReady() }
            do {
                while !self.queue.isEmpty && !self.cancelled {
                    if self.needsActivityStart {
                        self.needsActivityStart = false
                        try await self.write(["realtimeInput": ["activityStart": [:]]])
                    }
                    let data = self.queue.removeFirst()
                    self.queuedBytes -= data.count
                    self.activityHasAudio = true
                    try await self.write(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
                    self.progress.sentAudioBytes += data.count
                    let elapsed = ProcessInfo.processInfo.systemUptime - self.startedAt
                    if let previous = self.progress.lastAudioSendSeconds { self.progress.largestAudioSendGapSeconds = max(self.progress.largestAudioSendGapSeconds ?? 0, elapsed - previous) }
                    self.progress.lastAudioSendSeconds = elapsed
                    self.reportProgress()
                }
                // Only explicit finish (normally Shift release) ends the turn.
                if self.closingInput && !self.cancelled {
                    if self.needsActivityStart && !self.activityHasAudio {
                        // Release after an already-final server turn, with no
                        // additional audio: use that receipt without an empty
                        // new turn and a ten-second wait for non-existent text.
                        self.completed = true; self.endedInput = true
                        self.reportProgress(force: true)
                        self.onEvent?(.inputClosed); self.onEvent?(.finalized)
                        return
                    }
                    self.awaitingFinal = true
                    self.finalReceived = false
                    self.turnDeadline = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(self?.finalizationTimeout ?? 12))
                        guard !Task.isCancelled, let self, !self.cancelled, self.awaitingFinal else { return }
                        self.reportFailure(.finalizationTimeout)
                        self.fail(.connection)
                    }
                    try await self.write(["realtimeInput": ["activityEnd": [:]]])
                    if !self.cancelled {
                        self.endedInput = true
                        self.reportProgress(force: true)
                        self.onEvent?(.inputClosed)
                    }
                }
            } catch { if !self.cancelled { self.reportFailure(.send, error: error); self.fail(.connection) } }
        }
    }

    private func completeIfReady() {
        guard !cancelled, !completed, sender == nil else { return }
        if awaitingFinal && finalReceived && endedInput {
            turnDeadline?.cancel(); turnDeadline = nil
            completed = true
            reportProgress(force: true)
            onEvent?(.finalized)
        } else if !awaitingFinal && (!queue.isEmpty || closingInput) { pump() }
    }

    private func write(_ value: [String: Any]) async throws {
        guard let transport, !cancelled else { throw CancellationError() }
        try await transport.send(JSONSerialization.data(withJSONObject: value))
        if let input = value["realtimeInput"] as? [String: Any] {
            let origin: VoiceProviderBoundary.Origin?
            if input["activityStart"] != nil { progress.activityStarts = (progress.activityStarts ?? 0) + 1; origin = .clientActivityStart }
            else if input["activityEnd"] != nil { progress.activityEnds = (progress.activityEnds ?? 0) + 1; origin = .clientActivityEnd }
            else { origin = nil }
            if let origin {
                onEvent?(.providerBoundary(.init(origin: origin, elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedAt, sentAudioBytes: progress.sentAudioBytes, queuedAudioBytes: queuedBytes, clientFinishRequested: closingInput, clientInputEnded: endedInput || origin == .clientActivityEnd, transcriptionPresent: false)))
            }
        }
    }

    private func reportFailure(_ phase: VoiceTransportFailure.Phase, error: Error? = nil, providerCode: Int? = nil) {
        let ns = error as NSError?
        let domain: VoiceTransportFailure.Domain? = ns.map { $0.domain == NSURLErrorDomain ? .url : $0.domain == NSPOSIXErrorDomain ? .posix : .other }
        onEvent?(.transportFailure(.init(phase: phase, httpStatus: transport?.statusCode, webSocketCode: transport?.closeCode, errorCode: ns?.code, providerErrorCode: providerCode, domain: domain)))
    }

    private func reportProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - progressReportedAt >= 1 else { return }
        progress.queuedAudioBytes = queuedBytes
        progressReportedAt = now
        onEvent?(.progress(progress))
    }

    private func fail(_ failure: VoiceFailure) {
        guard !cancelled else { return }
        reportProgress(force: true)
        onEvent?(.failure(failure))
        cancel()
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onEvent = nil
        setupDeadline?.cancel()
        keepalive?.cancel()
        turnDeadline?.cancel(); turnDeadline = nil
        receiveTask?.cancel()
        sender?.cancel()
        transport?.cancel()
        queue.removeAll()
        queuedBytes = 0
        transport = nil
    }

    /// An admitted setup check never captures or sends microphone audio.
    public static func check(credential: String, language: String) async throws {
        let stream = NativeVoiceStream(credential: credential, language: language, vocabulary: [], keepaliveEnabled: false)
        let events = AsyncStream<VoiceEvent> { continuation in
            stream.onEvent = { event in continuation.yield(event) }
        }
        defer { stream.cancel() }
        stream.start()
        try await withTaskCancellationHandler {
            for await event in events {
                try Task.checkCancellation()
                switch event {
                case .ready: return
                case .failure(let error): throw error
                case .closed: throw VoiceFailure.connection
                default: break
                }
            }
            throw CancellationError()
        } onCancel: {
            Task { @MainActor in stream.cancel() }
        }
    }
}

@MainActor
protocol VoiceSocketTransport: AnyObject {
    var statusCode: Int? { get }
    var closeCode: Int { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func ping() async throws
    func cancel()
}

@MainActor
private final class URLSessionVoiceSocket: VoiceSocketTransport {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private var pendingPing: VoicePingCompletion?
    var statusCode: Int? { (socket.response as? HTTPURLResponse)?.statusCode }
    var closeCode: Int { socket.closeCode.rawValue }
    init(request: URLRequest) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        socket.resume()
    }
    func send(_ data: Data) async throws { try await socket.send(.string(String(decoding: data, as: UTF8.self))) }
    func receive() async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: return Data()
        }
    }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = VoicePingCompletion(continuation)
            pendingPing = completion
            socket.sendPing { completion.complete($0) }
        }
        pendingPing = nil
    }
    func cancel() {
        pendingPing?.complete(CancellationError()); pendingPing = nil
        socket.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}

/// URLSession may deliver a pong and a cancellation error for the same ping.
/// Take ownership under a lock before resuming, including explicit cancellation.
final class VoicePingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func complete(_ error: Error?) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return }
        if let error { pending.resume(throwing: error) }
        else { pending.resume() }
    }
}

/// Final transcripts commit individual speech segments. The adapter owns
/// manual audio-turn boundaries; conversational turnComplete never closes it.
public struct VoiceProviderNormalizer {
    private var lastFinal: String?
    private var interimSinceFinal = false
    public init() {}
    public mutating func events(_ json: [String: Any]) -> [VoiceEvent] {
        if let error = json["error"] as? [String: Any] {
            switch error["code"] as? Int {
            case 401, 403: return [.failure(.credentials)]
            case 429: return [.failure(.quota)]
            case 400, 404: return [.failure(.setup)]
            default: return [.failure(.connection)]
            }
        }
        var result: [VoiceEvent] = []
        if let content = json["serverContent"] as? [String: Any] {
            if let interim = content["interimInputTranscription"] as? [String: Any], let text = interim["text"] as? String {
                interimSinceFinal = true
                result.append(.interim(text))
            }
            if let final = content["inputTranscription"] as? [String: Any], let text = final["text"] as? String {
                if final["finished"] as? Bool == false {
                    interimSinceFinal = true
                    result.append(.interim(text))
                } else if text != lastFinal || interimSinceFinal {
                    result.append(.text(text))
                    result.append(.endpoint)
                    lastFinal = text
                }
                if final["finished"] as? Bool != false { interimSinceFinal = false }
            }
            if content["turnComplete"] as? Bool == true {
                result.append(.turnComplete)
            }
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            result.append(.usage(VoiceUsage(totalTokens: usage["totalTokenCount"] as? Int, inputTokens: usage["promptTokenCount"] as? Int, outputTokens: usage["responseTokenCount"] as? Int ?? usage["candidatesTokenCount"] as? Int, thinkingTokens: usage["thoughtsTokenCount"] as? Int)))
        }
        if json["goAway"] != nil { result.append(.failure(.limit)) }
        return result
    }
}
