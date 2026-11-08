import XCTest
@testable import MurmurKit

final class VoiceAnalyticsTests: XCTestCase {
    func testReceiptNormalizationAndUnknownSplit() {
        var normalizer = VoiceProviderNormalizer()
        XCTAssertEqual(normalizer.events(["usageMetadata": ["promptTokenCount": 100, "responseTokenCount": 20, "totalTokenCount": 120]]), [.usage(VoiceUsage(totalTokens: 120, inputTokens: 100, outputTokens: 20))])
        XCTAssertFalse(VoiceUsage(totalTokens: 120).hasCostReceipt)
        XCTAssertFalse(VoiceUsage(inputTokens: -1, outputTokens: 0).hasCostReceipt)
    }
    func testExactDecimalCostAcrossRetriesAndCancelledAttempts() {
        var first = VoiceAttemptSummary()
        first.usage = VoiceUsage(inputTokens: 1500, outputTokens: 175)
        var second = VoiceAttemptSummary()
        second.usage = VoiceUsage(inputTokens: 1000, outputTokens: 100)
        let session = VoiceUsageSession(duration: 60, words: 0, outcome: "cancelled", attempts: [first, second, VoiceAttemptSummary()])
        let totals = VoiceUsageTotals(sessions: [session])
        XCTAssertEqual(totals.estimatedCost, Decimal(string: "0.014525"))
        XCTAssertEqual(totals.receipts, 2)
        XCTAssertEqual(totals.attempts, 3)
        XCTAssertEqual(totals.inputTokens, 2500)
        XCTAssertEqual(totals.prompts, 0)
    }
    func testThinkingTokensUseOutputRate() {
        var attempt = VoiceAttemptSummary()
        attempt.usage = VoiceUsage(inputTokens: 0, outputTokens: 100, thinkingTokens: 20)
        let totals = VoiceUsageTotals(sessions: [.init(duration: 1, words: 1, outcome: "completed", attempts: [attempt])])
        XCTAssertEqual(totals.outputTokens, 120)
        XCTAssertEqual(totals.estimatedCost, Decimal(string: "0.00252"))
    }
    func testFallbackEstimatesNeverBecomeProviderReceipts() {
        var attempt = VoiceAttemptSummary()
        attempt.usage = VoiceUsage(totalTokens: 1500)
        let totals = VoiceUsageTotals(sessions: [.init(duration: 30, words: 50, outcome: "completed", attempts: [attempt])])
        XCTAssertEqual(totals.receipts, 0)
        XCTAssertEqual(totals.attempts, 1)
        XCTAssertEqual(totals.typingSecondsSaved, 45)
    }
    func testCountingWordsAndNoTextInEncodedAccounting() throws {
        let text = "Hello, world! This is a prompt."
        XCTAssertEqual(VoiceUsageSession.countWords(text), 6)
        let session = VoiceUsageSession(duration: 4, words: VoiceUsageSession.countWords(text), outcome: "completed", attempts: [])
        let data = try JSONEncoder().encode(session)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(text))
        XCTAssertEqual(try JSONDecoder().decode(VoiceUsageSession.self, from: data), session)
    }
    func testMissingReceiptUsesAudioAndLegacyWordEstimate() {
        var attempt = VoiceAttemptSummary(); attempt.queuedAudioBytes = 768_000
        let totals = VoiceUsageTotals(sessions: [.init(duration: 24, words: 32, outcome: "completed", attempts: [attempt])])
        XCTAssertEqual(totals.estimatedInputTokens, 600)
        XCTAssertEqual(totals.estimatedOutputTokens, 43)
        XCTAssertEqual(totals.estimatedCost, Decimal(string: "0.003003"))
        XCTAssertEqual(totals.receipts, 0)
        XCTAssertEqual(totals.inputTokens, 0)
        XCTAssertEqual(totals.typingSecondsSaved, 24)
    }
    func testReportedCountsReplaceFallbackAndRetriesKeepSeparateAudio() {
        var first = VoiceAttemptSummary(); first.queuedAudioBytes = 32_000
        var second = VoiceAttemptSummary(); second.queuedAudioBytes = 64_000
        second.estimatedOutputTokens = 10
        let session = VoiceUsageSession(duration: 2, words: 8, outcome: "completed", attempts: [first, second])
        let estimated = VoiceUsageTotals(sessions: [session])
        XCTAssertEqual(estimated.estimatedInputTokens, 75)
        XCTAssertEqual(estimated.estimatedOutputTokens, 10)
        second.usage = VoiceUsage(inputTokens: 47, outputTokens: 9)
        let reported = VoiceUsageTotals(sessions: [.init(duration: 2, words: 8, outcome: "completed", attempts: [first, second])])
        XCTAssertEqual(reported.estimatedInputTokens, 72)
        XCTAssertEqual(reported.estimatedOutputTokens, 9)
        XCTAssertEqual(reported.receipts, 1)
        XCTAssertEqual(reported.outputTokens, 9)
    }
    func testTextTokenHeuristicRetainsNoTranscript() {
        XCTAssertEqual(VoiceUsageSession.estimateTextTokens("Hello world!"), 3)
        XCTAssertEqual(VoiceUsageSession.estimateTextTokens(""), 0)
    }

}
