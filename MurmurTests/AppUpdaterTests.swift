import XCTest
@testable import Murmur

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testUpdateInstallationWaitsForRecordingAndResumesOnlyOnce() {
        let updater = AppUpdater()
        var busy = true
        var installs = 0
        updater.isBusy = { busy }
        XCTAssertTrue(updater.postponeIfBusy { installs += 1 })
        updater.resumeWhenIdle()
        XCTAssertEqual(installs, 0)
        busy = false
        updater.resumeWhenIdle()
        updater.resumeWhenIdle()
        XCTAssertEqual(installs, 1)
    }
    func testIdleUpdaterDoesNotPostponeInstallation() {
        let updater = AppUpdater()
        XCTAssertFalse(updater.postponeIfBusy {})
    }
    func testUnpublishedFeedFinishesAndRemainsRetryable() async {
        let updater = AppUpdater(feedProbe: { 404 })
        let available = await updater.inspectFeed()
        XCTAssertFalse(available)
        XCTAssertFalse(updater.isChecking)
        XCTAssertTrue(updater.canRequestCheck)
        XCTAssertTrue(updater.status?.contains("aren’t published yet") == true)
        XCTAssertNotNil(updater.lastChecked)
    }

    func testNetworkFailureClearsCheckingAndAllowsRecovery() async {
        var fail = true
        let updater = AppUpdater(feedProbe: {
            if fail { throw URLError(.timedOut) }
            return 200
        })
        let failed = await updater.inspectFeed()
        XCTAssertFalse(failed)
        XCTAssertFalse(updater.isChecking)
        XCTAssertTrue(updater.canRequestCheck)
        fail = false
        let recovered = await updater.inspectFeed()
        XCTAssertTrue(recovered)
        XCTAssertNil(updater.status)
    }

    func testDuplicateFeedChecksDoNotRunInParallel() async {
        var requests = 0
        let updater = AppUpdater(feedProbe: {
            requests += 1
            try await Task.sleep(for: .milliseconds(80))
            return 404
        })
        let first = Task { await updater.inspectFeed() }
        await Task.yield()
        let second = await updater.inspectFeed()
        XCTAssertFalse(second)
        _ = await first.value
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(updater.isChecking)
    }

}
