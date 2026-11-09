import XCTest
import MurmurKit
@testable import Murmur

@MainActor
final class VoiceDiagnosticsTests: XCTestCase {
    func testExportIncludesOnlyCountsAndBoundedOutcomes() throws {
        let state = AppState()
        let privateText = "neverExportThis-private-prompt-and-error"
        state.completedText = privateText; state.interimTranscript = privateText
        state.lastError = privateText; state.deliveryMessage = privateText
        state.deliveryOutcome = privateText
        var attempt = VoiceAttemptSummary()
        attempt.queuedAudioBytes = 3200; attempt.outcome = privateText
        state.attempts = [attempt]
        let encoded = try VoiceDiagnostics(state: state).data()
        let string = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(string.contains(privateText))
        let decoded = try JSONDecoder().decode(VoiceDiagnostics.self, from: encoded)
        XCTAssertEqual(decoded.attempts.first?.audioBytes, 3200)
        XCTAssertEqual(decoded.attempts.first?.outcome, "unknown")
        XCTAssertEqual(decoded.delivery, "unknown")
    }
}
