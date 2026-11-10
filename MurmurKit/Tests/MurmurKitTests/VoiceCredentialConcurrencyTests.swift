#if os(macOS)
import XCTest
import Security
@testable import MurmurKit

final class VoiceCredentialConcurrencyTests: XCTestCase {
    func testStatusChecksNeverWaitForInteractiveApprovalAndPolicyIsRestored() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var before = DarwinBoolean(true)
        let observedBefore = SecKeychainGetUserInteractionAllowed(&before) == errSecSuccess
        DispatchQueue.global().async {
            VoiceCredential.userInitiated {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let start = Date()
        let result = VoiceCredential.nonInteractive(fallback: false) { true }
        XCTAssertFalse(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        var after = DarwinBoolean(true)
        if observedBefore && SecKeychainGetUserInteractionAllowed(&after) == errSecSuccess {
            XCTAssertEqual(before.boolValue, after.boolValue)
        }
    }
}
#endif
