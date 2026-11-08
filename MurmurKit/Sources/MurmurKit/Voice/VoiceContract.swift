import Foundation
import CoreFoundation

public enum VoiceSettings {
    public static func enabled(nested: [String: Any]?, legacy: Any?) -> Bool {
        let candidate: Any?
        if let value = nested?["enabled"] { candidate = value }
        else { candidate = legacy }
        guard let candidate, CFGetTypeID(candidate as CFTypeRef) == CFBooleanGetTypeID() else { return false }
        return (candidate as? Bool) == true
    }
}

public struct VoiceAttemptSummary: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var queuedAudioBytes = 0
    public var reportedTokens: Int?
    public var usage: VoiceUsage?
    public var estimatedOutputTokens: Int?
    public var outcome = "active"
    public init() {}
}

public enum VoiceMode: String, CaseIterable, Sendable { case hold, tap }

public enum VoiceFailure: String, Error, LocalizedError, Sendable {
    case credentials, permission, device, connection, quota, limit, noSignal, noSpeech, paused, setup, unsupported

    public var errorDescription: String? {
        switch self {
        case .credentials: "Your speech credential was not accepted. Update it in Settings → Connection."
        case .permission: "Allow microphone access for Murmur in System Settings → Privacy & Security → Microphone."
        case .device: "The microphone could not start. Check your input device in System Settings → Sound."
        case .connection: "The speech connection was interrupted. Check your connection and try again."
        case .quota: "Speech is temporarily unavailable because the account’s quota was reached. Check your speech account and try again."
        case .limit: "This recording reached a resource limit. Your available text has been preserved."
        case .noSignal: "No microphone signal detected. Check your input device and microphone level."
        case .noSpeech: "No speech was recognized. Try speaking a little closer to your microphone."
        case .paused: "Recording is paused after repeated startup failures. Wait a moment, then try again."
        case .setup: "The speech service could not start a session. Check your credential and service access in Settings."
        case .unsupported: "This audio format is not supported. Choose a different microphone."
        }
    }

    public var isFatal: Bool { [.credentials, .permission, .quota, .limit, .unsupported, .setup].contains(self) }
}

/// Product events. Provider field names and credentials stay in the adapter.
public enum VoiceEvent: Equatable, Sendable {
    case ready
    case inputClosed
    case interim(String)
    case text(String)
    case endpoint
    case usage(VoiceUsage)
    case failure(VoiceFailure)
    case closed
}

public struct VoiceUsage: Codable, Equatable, Sendable {
    public var totalTokens: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var thinkingTokens: Int?
    public init(totalTokens: Int? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, thinkingTokens: Int? = nil) {
        self.totalTokens = totalTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.inputTokens = inputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.outputTokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.thinkingTokens = thinkingTokens.flatMap { $0 >= 0 ? $0 : nil }
    }
    /// Supplier receipts are cumulative snapshots within each connection.
    public var billedOutputTokens: Int? { outputTokens.map { $0 + (thinkingTokens ?? 0) } }
    public var hasCostReceipt: Bool { inputTokens != nil && outputTokens != nil }
}

public struct VoiceTranscript: Equatable, Sendable {
    public private(set) var segments: [String] = []
    public private(set) var hypothesis = ""
    public private(set) var receivedText = false
    public private(set) var authoritativeSegments = 0
    public var preview: String { (segments + [hypothesis]).filter { !$0.isEmpty }.joined(separator: " ") }
    public init() {}

    public mutating func accept(_ event: VoiceEvent) {
        switch event {
        case .interim(let value), .text(let value):
            hypothesis = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hypothesis.isEmpty { receivedText = true }
        case .endpoint:
            commit(authoritative: true)
        default: break
        }
    }

    public mutating func salvage() { commit(authoritative: false) }

    private mutating func commit(authoritative: Bool) {
        guard !hypothesis.isEmpty else { return }
        segments.append(hypothesis)
        hypothesis = ""
        if authoritative { authoritativeSegments += 1 }
    }
}

public struct VoiceCircuitBreaker: Sendable {
    private var failures: [Date] = []
    public init() {}
    public mutating func admits(at now: Date = Date()) -> Bool {
        failures.removeAll { now.timeIntervalSince($0) >= 10 }
        return failures.count < 3
    }
    public mutating func failed(at now: Date = Date()) { failures.append(now) }
    public mutating func succeeded() { failures.removeAll() }
}

public enum VoiceAudio {
    public static let bytesPerSecond = 32_000
    public static func level(_ data: Data) -> Double {
        let bytes = [UInt8](data)
        let count = bytes.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<count {
            let value = Double(Int16(bitPattern: UInt16(bytes[i * 2]) | UInt16(bytes[i * 2 + 1]) << 8))
            sum += value * value
        }
        return sqrt(min(sqrt(sum / Double(count)) / 2000, 1))
    }

    public static func coalesced(_ chunks: [Data], target: Int = bytesPerSecond) -> [Data] {
        var result: [Data] = []
        var pending = Data()
        for chunk in chunks {
            pending.append(chunk)
            if pending.count >= target { result.append(pending); pending.removeAll(keepingCapacity: true) }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
}

public struct VoiceLanguage: Equatable, Sendable {
    public let code: String
    public let usedFallback: Bool
    public static let supported = ["en", "es", "fr", "ja", "de", "pt", "it", "ko", "hi", "id", "ru", "pl", "tr", "nl", "uk", "el", "cs", "da", "sv", "no"]
    private static let names = [
        "english": "en", "spanish": "es", "español": "es", "french": "fr", "français": "fr",
        "japanese": "ja", "日本語": "ja", "german": "de", "deutsch": "de", "portuguese": "pt", "português": "pt",
        "italian": "it", "italiano": "it", "korean": "ko", "한국어": "ko", "hindi": "hi", "हिन्दी": "hi", "हिंदी": "hi",
        "indonesian": "id", "bahasa indonesia": "id", "russian": "ru", "русский": "ru", "polish": "pl", "polski": "pl",
        "turkish": "tr", "türkçe": "tr", "dutch": "nl", "nederlands": "nl", "ukrainian": "uk", "українська": "uk",
        "greek": "el", "ελληνικά": "el", "czech": "cs", "čeština": "cs", "danish": "da", "dansk": "da",
        "swedish": "sv", "svenska": "sv", "norwegian": "no", "norsk": "no"
    ]
    public static func resolve(_ value: String) -> Self {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return Self(code: "en", usedFallback: false) }
        if supported.contains(value) { return Self(code: value, usedFallback: false) }
        if let code = names[value] { return Self(code: code, usedFallback: false) }
        let base = String(value.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        if supported.contains(base) { return Self(code: base, usedFallback: false) }
        return Self(code: "en", usedFallback: true)
    }
}

public enum VoiceVocabulary {
    public static let coding = ["MCP", "symlink", "grep", "regex", "localhost", "codebase", "TypeScript", "JSON", "OAuth", "webhook", "gRPC", "dotfiles", "subagent", "worktree"]
    public static func sanitized(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var length = 0
        for term in terms {
            let ascii = term.unicodeScalars.filter { $0.value >= 32 && $0.value < 127 }.map { $0 == "," ? " " : String($0) }.joined()
            let value = ascii.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { continue }
            let next = length + value.count + (result.isEmpty ? 0 : 1)
            if next > 1024 || result.count >= 50 { break }
            result.append(value)
            length = next
        }
        return result
    }
}

/// Anchor for a native editable field. Offsets use UTF-16, matching Accessibility.
public struct VoiceAnchor: Sendable {
    public let original: String
    public let selection: NSRange
    public private(set) var expected: String
    public init?(text: String, selection: NSRange) {
        guard selection.location >= 0, selection.length >= 0, selection.location <= (text as NSString).length,
              selection.length <= (text as NSString).length - selection.location else { return nil }
        original = text
        expected = text
        self.selection = selection
    }
    public mutating func replacement(_ text: String, current: String) -> (text: String, cursor: Int)? {
        guard current == expected else { return nil }
        let source = original as NSString
        let left = source.substring(to: selection.location)
        let right = source.substring(from: NSMaxRange(selection))
        guard !text.isEmpty else { return (original, selection.location) }
        let before = left.last.map { $0.isWhitespace ? "" : " " } ?? ""
        let after = right.first.map { $0.isWhitespace ? "" : " " } ?? ""
        let prefix = left + before + text
        expected = prefix + after + right
        return (expected, (prefix as NSString).length)
    }
}
