import Foundation
import Combine
import MurmurKit

/// Explicitly typed operational metadata; never accept arbitrary log messages.
enum DiagnosticKind: String, Codable, Sendable {
    case recordingRequested, captureStarted, captureProgress, captureStopped
    case connectionRequested, connectionReady, connectionClosed, providerBoundary, transportProgress, transportFailure, transcriptProgress
    case segmentFinalized, finishRequested, inputClosed, finalReceipt, retryScheduled, replayScheduled
    case interruptionRequested, interrupted, completed, disposed, failed, timedOut, previewPresented, mainQueueDelay
    case targetCapture, insertionCheck, clipboardWrite, insertionAttempt, insertionResult, insertionRetry, undoResult
}
enum InsertionReason: String, Codable, Sendable {
    case targetReady, noAccessibility, secureInput, noExternalApp, noFocusedElement, secureField, unsupportedEditor
    case noTarget, emptyText, appChanged, focusChanged, textChanged, selectionChanged
    case accessibilityWrite, writeUnverified, writeRejected, unsupportedWrite, pasteAttempt
    case pasteGuardChanged, pasteUnavailable, pasteDispatched
}
enum DiagnosticTrigger: String, Codable, Sendable {
    case escape, controlC, eventTapLost, shortcutUnavailable, userStop, appSleep, displayChanged, disabled
}
struct DiagnosticEnvironment: Codable, Equatable, Sendable {
    let appVersion: String
    let build: String
    let osMajor: Int
    let osMinor: Int
    let osPatch: Int
    let architecture: String
    init() {
        appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osMajor = os.majorVersion; osMinor = os.minorVersion; osPatch = os.patchVersion
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "other"
        #endif
    }
}
enum DiagnosticDeliveryResult: String, Codable, Sendable {
    case none, inserted, pasted, copied, changed, unavailable, clipboardFailed, undone
}
struct DiagnosticValues: Codable, Equatable, Sendable {
    var trigger: DiagnosticTrigger?
    var capturedBytes: Int?
    var textCharacters: Int?
    var textChanged: Bool?
    var signalLevel: Double?
    var delaySeconds: Double?
    var failure: VoiceFailure?
    var progress: VoiceStreamProgress?
    var transportFailure: VoiceTransportFailure?
    var providerBoundary: VoiceProviderBoundary?
    var reason: InsertionReason?
    var axCode: Int?
    var processID: Int?
    var targetBundleID: String?
    var deliveryResult: DiagnosticDeliveryResult?
    var succeeded: Bool?
    var insertionRequested: Bool?
    var writingStyle: VoiceWritingStyle?
    var languageCode: String?
}
struct DiagnosticEvent: Codable, Equatable, Sendable {
    let sequence: Int
    let elapsedSeconds: Double
    let kind: DiagnosticKind
    let attemptID: UUID?
    let values: DiagnosticValues
}
struct DiagnosticSession: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    var environment: DiagnosticEnvironment?
    var droppedEvents = 0
    var events: [DiagnosticEvent] = []
}

@MainActor
final class DiagnosticStore: ObservableObject {
    enum StorageIssue: String, Codable { case directoryUnavailable, unreadableFile, writeFailed }
    @Published private(set) var sessions: [DiagnosticSession] = []
    @Published private(set) var storageIssue: StorageIssue?
    private(set) var retentionDays = 7
    private let maxSessions: Int
    private let maxEvents: Int
    private let maxBytes = 20_000_000
    private let clock: () -> TimeInterval
    private var directory: URL?
    private var anchors: [UUID: TimeInterval] = [:]
    private var throttles: [String: TimeInterval] = [:]
    private var lastFlush: [UUID: TimeInterval] = [:]
    private let writer = DispatchQueue(label: "com.murmur.diagnostics", qos: .utility)
    init(maxSessions: Int = 50, maxEvents: Int = 2400, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maxSessions = maxSessions; self.maxEvents = maxEvents; self.clock = clock
    }
    func open(at override: URL? = nil) {
        guard directory == nil else { return }
        let url = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            directory = url
            let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            var bytes = 0
            for file in files.sorted(by: { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }) {
                guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size < 1_000_000, bytes + size <= maxBytes else { storageIssue = .unreadableFile; continue }
                bytes += size
                do {
                    var session = try JSONDecoder().decode(DiagnosticSession.self, from: Data(contentsOf: file))
                    guard session.id.uuidString.lowercased() == file.deletingPathExtension().lastPathComponent.lowercased() else { throw CocoaError(.fileReadCorruptFile) }
                    if session.events.count > maxEvents { session.droppedEvents += session.events.count - maxEvents; session.events = Array(session.events.suffix(maxEvents)) }
                    sessions.append(session)
                } catch { storageIssue = .unreadableFile }
            }
            trimMemory()
            pruneFiles(in: url)
        } catch { storageIssue = .directoryUnavailable }
    }
    func begin(_ id: UUID) {
        guard !sessions.contains(where: { $0.id == id }) else { return }
        anchors[id] = clock()
        sessions.append(DiagnosticSession(id: id, createdAt: Date(), environment: DiagnosticEnvironment()))
        trimMemory()
    }
    func record(_ kind: DiagnosticKind, id: UUID, attempt: UUID? = nil, values: DiagnosticValues = .init(), coalesce: Double = 0, force: Bool = false) {
        begin(id)
        let now = clock(), key = id.uuidString + kind.rawValue
        if coalesce > 0, let last = throttles[key], now - last < coalesce { return }
        throttles[key] = now
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let sequence = (sessions[index].events.last?.sequence ?? 0) + 1
        let elapsed = max(0, now - (anchors[id] ?? now))
        var metadata = values
        if let bundle = metadata.targetBundleID, bundle.count > 240 || bundle.range(of: #"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)+$"#, options: .regularExpression) == nil { metadata.targetBundleID = nil }
        sessions[index].events.append(.init(sequence: sequence, elapsedSeconds: elapsed, kind: kind, attemptID: attempt, values: metadata))
        if sessions[index].events.count > maxEvents { sessions[index].events.removeFirst(); sessions[index].droppedEvents += 1 }
        if force || now - (lastFlush[id] ?? -.infinity) >= 1 {
            lastFlush[id] = now
            persist(sessions[index])
        }
    }
    func clear() {
        sessions = []; anchors = [:]; throttles = [:]; lastFlush = [:]
        guard let directory else { return }
        writer.async { Self.removeKnownFiles(directory) }
    }
    func flush() async {
        for session in sessions where anchors[session.id] != nil { persist(session) }
        await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
    }
    func flushBeforeExit() {
        for session in sessions where anchors[session.id] != nil { persist(session) }
        writer.sync {}
    }
    private func trimMemory() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
        sessions = Array(sessions.filter { $0.createdAt >= cutoff }.sorted { $0.createdAt < $1.createdAt }.suffix(maxSessions))
        let ids = Set(sessions.map(\.id))
        anchors = anchors.filter { ids.contains($0.key) }
        lastFlush = lastFlush.filter { ids.contains($0.key) }
        throttles = throttles.filter { entry in ids.contains { entry.key.hasPrefix($0.uuidString) } }
    }
    private func persist(_ session: DiagnosticSession) {
        guard let directory else { return } // In-memory unit tests/previews.
        let retained = Set(sessions.map { $0.id.uuidString.lowercased() })
        let oldestIDs = sessions.sorted { $0.createdAt < $1.createdAt }.map(\.id)
        writer.async { [weak self] in
            do {
                let data = try JSONEncoder().encode(session)
                let file = directory.appendingPathComponent(session.id.uuidString + ".json")
                try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                var total = 0
                for file in files where file.pathExtension == "json" {
                    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                    if !retained.contains(id.uuidString.lowercased()) { try? FileManager.default.removeItem(at: file) }
                    else { total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
                }
                // The in-memory cap is 50 x 2400 small typed events. Enforce a
                // second disk cap even if future payloads grow unexpectedly.
                if total > 20_000_000 {
                    for id in oldestIDs where total > 20_000_000 && id != session.id {
                        let file = directory.appendingPathComponent(id.uuidString + ".json")
                        total -= (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        try? FileManager.default.removeItem(at: file)
                    }
                }
            } catch { Task { @MainActor [weak self] in self?.storageIssue = .writeFailed } }
        }
    }
    private func pruneFiles(in directory: URL) {
        let retained = Set(sessions.map { $0.id.uuidString.lowercased() })
        writer.async {
            for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else { continue }
                if !retained.contains(id.uuidString.lowercased()) { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
    private nonisolated static func removeKnownFiles(_ directory: URL) {
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil { try? FileManager.default.removeItem(at: file) }
        }
    }
}
