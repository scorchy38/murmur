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
}
