import XCTest
@testable import MurmurKit

final class VoicePingTests: XCTestCase {
    func testPongFollowedByCancelAndLateErrorResumesOnlyOnce() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let completion = VoicePingCompletion(continuation)
            completion.complete(nil)
            completion.complete(CancellationError())
            completion.complete(URLError(.cancelled))
        }
    }

    func testCancelBeforePongPreservesCancellation() async {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = VoicePingCompletion(continuation)
                completion.complete(CancellationError())
                completion.complete(nil)
                completion.complete(URLError(.networkConnectionLost))
            }
            XCTFail("Cancellation should be reported")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSimultaneousDelegateCallbacksCannotDoubleResume() async throws {
        for _ in 0..<100 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completion = VoicePingCompletion(continuation)
                DispatchQueue.concurrentPerform(iterations: 8) { _ in completion.complete(nil) }
            }
        }
    }
}
