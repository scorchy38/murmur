import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = true
    @Published private(set) var automaticallyInstalls = true
    @Published private(set) var lastChecked: Date?
    @Published private(set) var status: String?
    var isBusy: () -> Bool = { false }
    private var postponedInstall: (() -> Void)?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var started = false

    func start() {
        guard !started else { return }
        #if DEBUG
        status = "Automatic updates are available in release builds."
        return
        #else
        started = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyInstalls)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        do {
            try updater.start()
            if updater.automaticallyChecksForUpdates { updater.checkForUpdatesInBackground() }
        } catch { status = "Updates could not start. \(error.localizedDescription)" }
        #endif
    }
    func check() {
        guard canCheck, !isBusy() else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticInstalls(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }
    func resumeWhenIdle() {
        guard !isBusy(), let install = postponedInstall else { return }
        postponedInstall = nil
        install()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeIfBusy(installHandler)
    }
    func postponeIfBusy(_ installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        postponedInstall = installHandler
        return true
    }
}
