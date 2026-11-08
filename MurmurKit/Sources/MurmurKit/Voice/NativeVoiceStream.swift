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
    private let keepaliveEnabled: Bool
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var setupDeadline: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var pendingPing: VoicePingCompletion?
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var ready = false
    private var closingInput = false
    private var endedInput = false
    private var cancelled = false
    private var started = false
    private var normalizer = VoiceProviderNormalizer()

    public init(credential: String, language: String, vocabulary: [String], keepaliveEnabled: Bool = true) {
        self.credential = credential
        self.language = VoiceLanguage.resolve(language).code
        self.vocabulary = VoiceVocabulary.sanitized(vocabulary)
        self.keepaliveEnabled = keepaliveEnabled
    }

    public static func setup(language: String, vocabulary: [String]) -> [String: Any] {
        ["setup": [
            "model": "models/gemini-3.5-transcribe-live",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "realtimeInputConfig": ["automaticActivityDetection": ["disabled": true]],
            "inputAudioTranscription": ["mode": "SMART", "languageCodes": [language], "customVocabulary": vocabulary]
        ]]
    }

    public func start() {
        guard !started, !cancelled else { return }
        started = true
        // Header authentication keeps secrets out of URL logs and diagnostics.
        var request = URLRequest(url: URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!)
        request.setValue(credential, forHTTPHeaderField: "x-goog-api-key")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_048_576
        self.socket = socket
        socket.resume()
        setupDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, !self.ready, !self.cancelled else { return }
            self.fail(.connection)
        }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.write(Self.setup(language: self.language, vocabulary: self.vocabulary))
                while !Task.isCancelled && !self.cancelled {
                    let message = try await socket.receive()
                    guard !self.cancelled else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
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
                                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                        let completion = VoicePingCompletion(continuation)
                                        self.pendingPing = completion
                                        socket.sendPing { error in completion.complete(error) }
                                    }
                                    self.pendingPing = nil
                                }
                                catch { if !self.cancelled { self.fail(.connection) }; return }
                                try? await Task.sleep(for: .seconds(8))
                            }
                        }
                        self.onEvent?(.ready)
                        self.pump()
                    }
                    for event in self.normalizer.events(json) {
                        guard !self.cancelled else { return }
                        if case .failure(let failure) = event { self.fail(failure); return }
                        self.onEvent?(event)
                    }
                }
            } catch {
                guard !self.cancelled else { return }
                let status = (socket.response as? HTTPURLResponse)?.statusCode
                let code = socket.closeCode.rawValue
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
        guard ready, !cancelled, sender == nil else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            defer { self.sender = nil }
            do {
                while !self.queue.isEmpty && !self.cancelled {
                    let data = self.queue.removeFirst()
                    self.queuedBytes -= data.count
                    try await self.write(["realtimeInput": ["audio": ["data": data.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]])
                }
                if self.closingInput && !self.endedInput && !self.cancelled {
                    self.endedInput = true
                    try await self.write(["realtimeInput": ["activityEnd": [:]]])
                    if !self.cancelled { self.onEvent?(.inputClosed) }
                }
            } catch { if !self.cancelled { self.fail(.connection) } }
        }
    }

    private func write(_ value: [String: Any]) async throws {
        guard let socket, !cancelled else { throw CancellationError() }
        let data = try JSONSerialization.data(withJSONObject: value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func fail(_ failure: VoiceFailure) {
        guard !cancelled else { return }
        onEvent?(.failure(failure))
        cancel()
    }

    public func cancel() {
        guard !cancelled else { return }
        cancelled = true
        onEvent = nil
        setupDeadline?.cancel()
        keepalive?.cancel()
        pendingPing?.complete(CancellationError())
        pendingPing = nil
        receiveTask?.cancel()
        sender?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        queue.removeAll()
        queuedBytes = 0
        socket = nil
        session = nil
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

/// Manual mode has one utterance per attempt. A repeated final or a late close
/// cannot create a second endpoint. Completion without text is never a fake final.
public struct VoiceProviderNormalizer {
    private var finalized = false
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
        if let content = json["serverContent"] as? [String: Any], !finalized {
            if let interim = content["interimInputTranscription"] as? [String: Any], let text = interim["text"] as? String {
                result.append(.interim(text))
            }
            if let final = content["inputTranscription"] as? [String: Any], let text = final["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(text))
                result.append(.endpoint)
                finalized = true
            }
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            result.append(.usage(VoiceUsage(totalTokens: usage["totalTokenCount"] as? Int)))
        }
        if json["goAway"] != nil { result.append(.failure(.limit)) }
        return result
    }
}
