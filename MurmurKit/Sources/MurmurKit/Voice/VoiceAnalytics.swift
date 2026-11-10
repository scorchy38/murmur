import Foundation

/// Counts only: never retains the words or audio of a prompt.
public struct VoiceUsageSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    public var words: Int
    public var outcome: String
    public var attempts: [VoiceAttemptSummary]
    // Freeze the rate with the session so future price changes cannot rewrite history.
    public var inputUSDPerMillion: Decimal = Decimal(string: "3.50")!
    public var outputUSDPerMillion: Decimal = 21
    public init(id: UUID = UUID(), startedAt: Date = Date(), duration: TimeInterval, words: Int, outcome: String, attempts: [VoiceAttemptSummary]) {
        self.id = id; self.startedAt = startedAt; self.duration = max(0, duration)
        self.words = max(0, words); self.outcome = outcome; self.attempts = attempts
    }
    public static func countWords(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in count += 1 }
        return count
    }
    /// Fallbacks are deliberately estimates, never supplier receipts.
    public static func estimateTextTokens(_ text: String) -> Int {
        Int(ceil(Double(text.count) / 4))
    }
    public func inputEstimate(for attempt: VoiceAttemptSummary) -> Int {
        Int(ceil(Double(attempt.queuedAudioBytes) / Double(VoiceAudio.bytesPerSecond) * 25))
    }
    public func outputEstimate(for attempt: VoiceAttemptSummary) -> Int {
        if let estimate = attempt.estimatedOutputTokens { return estimate }
        // Older ledger entries retained word counts but no transcript length.
        guard attempt.id == attempts.last?.id, words > 0 else { return 0 }
        return Int(ceil(Double(words) * 4 / 3))
    }
    public var estimatedCost: Decimal {
        attempts.reduce(Decimal.zero) { cost, attempt in
            let input = attempt.usage?.inputTokens ?? inputEstimate(for: attempt)
            let output = attempt.usage?.billedOutputTokens ?? outputEstimate(for: attempt)
            return cost + (Decimal(input) * inputUSDPerMillion + Decimal(output) * outputUSDPerMillion) / 1_000_000
        }
    }

}

public struct VoiceUsageTotals: Sendable {
    public var words = 0
    public var duration: TimeInterval = 0
    public var prompts = 0
    public var longestPrompt = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var estimatedInputTokens = 0
    public var estimatedOutputTokens = 0
    public var attempts = 0
    public var receipts = 0
    public var estimatedCost = Decimal.zero
    public var typingSecondsSaved: Double { max(0, Double(words) / 40 * 60 - duration) }
    public init(sessions: [VoiceUsageSession]) {
        for session in sessions {
            if session.outcome != "diagnostic" {
                words += session.words; duration += session.duration
                if session.words > 0 { prompts += 1 }
                longestPrompt = max(longestPrompt, session.words)
            }
            estimatedCost += session.estimatedCost
            for attempt in session.attempts {
                attempts += 1
                estimatedInputTokens += attempt.usage?.inputTokens ?? session.inputEstimate(for: attempt)
                estimatedOutputTokens += attempt.usage?.billedOutputTokens ?? session.outputEstimate(for: attempt)
                inputTokens += attempt.usage?.inputTokens ?? 0
                outputTokens += attempt.usage?.billedOutputTokens ?? 0
                if attempt.usage?.hasCostReceipt == true { receipts += 1 }
            }
        }
    }
}
