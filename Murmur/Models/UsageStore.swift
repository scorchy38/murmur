import Foundation
import Combine
import MurmurKit

@MainActor
final class UsageStore: ObservableObject {
    private struct Ledger: Codable {
        var version = 1
        var trackingStarted = Date()
        var sessions: [VoiceUsageSession] = []
    }
    @Published private(set) var sessions: [VoiceUsageSession] = []
    @Published private(set) var trackingStarted = Date()
    @Published private(set) var storageError: String?
    private var fileURL: URL?
    private var writable = true

    /// Explicitly opened by the real app, never by previews or test hosts.
    func open(at overrideURL: URL? = nil) {
        guard fileURL == nil else { return }
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/Usage", isDirectory: true)
        let directory = overrideURL?.deletingLastPathComponent() ?? defaultDirectory
        fileURL = overrideURL ?? directory.appendingPathComponent("usage-v1.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: fileURL!.path) {
                let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: fileURL!))
                guard ledger.version == 1 else { throw CocoaError(.fileReadUnknown) }
                trackingStarted = ledger.trackingStarted
                sessions = ledger.sessions.map { session in
                    var session = session
                    if session.outcome == "active" { session.outcome = "interrupted" }
                    return session
                }
            }
            save()
            if overrideURL == nil {
                importEvaluationReceipts(from: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/Evaluations"))
            }
        } catch {
            writable = false
            storageError = "Usage history could not be opened. Existing data has been preserved."
        }
    }
    func record(_ session: VoiceUsageSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
        else { sessions.append(session) }
        save()
    }
    /// Live probes write separate receipts so they cannot race the running
    /// app's ledger. Import once on the next normal launch, without duplication.
    func importEvaluationReceipts(from directory: URL) {
        guard fileURL != nil, writable else { return }
        for file in ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []).prefix(50) {
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1_000_001) <= 1_000_000,
                  let data = try? Data(contentsOf: file), let receipt = try? JSONDecoder().decode(VoiceUsageSession.self, from: data),
                  receipt.id == id, receipt.outcome == "diagnostic", receipt.words == 0, receipt.duration == 0 else { continue }
            if !sessions.contains(where: { $0.id == id }) { sessions.append(receipt) }
            sessions.sort { $0.startedAt < $1.startedAt }
            save()
            if storageError == nil { try? FileManager.default.removeItem(at: file) }
        }
    }
    private func save() {
        guard let fileURL, writable else { return }
        do {
            let data = try JSONEncoder().encode(Ledger(trackingStarted: trackingStarted, sessions: sessions))
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            storageError = nil
        } catch { storageError = "Usage could not be saved. These totals may be lost when Murmur quits." }
    }
}
