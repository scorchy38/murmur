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
    @Published private(set) var probing = false
    @Published private(set) var frameworkChecking = false
    var isChecking: Bool { probing || frameworkChecking }
    var canRequestCheck: Bool { !isChecking && (!started || canCheck) }
    var isBusy: () -> Bool = { false }
    private var postponedInstall: (() -> Void)?
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var started = false
    private var observing = false
    private var polling: Task<Void, Never>?
    private let feedProbe: @MainActor () async throws -> Int

    init(feedProbe: (@MainActor () async throws -> Int)? = nil) {
        self.feedProbe = feedProbe ?? Self.fetchFeedStatus
        super.init()
    }

    func start() {
        guard !observing else { return }
        #if DEBUG
        status = "Automatic updates are available in release builds."
        return
        #else
        observing = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyInstalls)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        updater.publisher(for: \.sessionInProgress).assign(to: &$frameworkChecking)
        scheduleUntilPublished()
        #endif
    }

    private static func fetchFeedStatus() async throws -> Int {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: value) else { throw URLError(.badURL) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    @discardableResult
    func inspectFeed() async -> Bool {
        guard !probing else { return false }
        probing = true
        status = nil
        defer { probing = false; lastChecked = Date() }
        do {
            let code = try await feedProbe()
            if code == 200 { return true }
            if code == 404 {
                status = "Updates aren’t published yet. You can keep using this build; automatic updates will become available after the first signed release is published."
            } else if code == 429 || code == 403 {
                status = "GitHub is temporarily limiting update checks. Try again later."
            } else {
                status = "The update server is unavailable. Try again later."
            }
        } catch {
            status = "Couldn’t reach the update server. Check your connection and try again."
        }
        return false
    }

    private func startFramework() -> Bool {
        if started { return true }
        do {
            try controller.updater.start()
            started = true
            return true
        } catch {
            status = "Updates could not start. Try again or download the release from GitHub."
            return false
        }
    }

    private func scheduleUntilPublished() {
        guard observing, automaticallyChecks, !started, polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.automaticallyChecks, !self.started else { return }
                if !self.isChecking, await self.inspectFeed(), self.startFramework() {
                    return // Sparkle owns the schedule once the feed is published.
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func check() {
        guard canRequestCheck, !isBusy() else { return }
        Task { [weak self] in
            guard let self, await self.inspectFeed(), !self.isBusy(), self.startFramework() else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.controller.checkForUpdates(nil)
        }
    }
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        if !enabled { polling?.cancel(); polling = nil }
        else { scheduleUntilPublished() }
    }
    func setAutomaticInstalls(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }
    func resumeWhenIdle() {
        guard !isBusy(), let install = postponedInstall else { return }
        postponedInstall = nil
        install()
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        frameworkChecking = false
        if let error = error as NSError? {
            if error.domain == SUSparkleErrorDomain && error.code == SUError.noUpdateError.rawValue {
                status = "You’re up to date."
            } else {
                status = "The update check ended. You can retry or view releases on GitHub."
            }
        } else { status = "Update check finished." }
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
