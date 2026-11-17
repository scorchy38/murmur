import Foundation
import Combine

/// One local safety draft, never microphone audio. Disk use follows Save History.
@MainActor
final class RecoveryStore: ObservableObject {
    struct Draft: Codable, Equatable {
        var recordingID: UUID
        var text: String
        var interrupted: Bool
        var updatedAt: Date
    }
    @Published private(set) var draft: Draft?
    @Published private(set) var storageError: String?
    private var fileURL: URL?
    private var writable = true
    private var lastSaved = Date.distantPast
    func open(at override: URL? = nil) {
        guard fileURL == nil else { return }
        fileURL = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/Recovery/latest-draft.json")
        do {
            try FileManager.default.createDirectory(at: fileURL!.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: fileURL!.path) {
                guard (try fileURL!.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 2_000_000 else { throw CocoaError(.fileReadCorruptFile) }
                draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: fileURL!))
            }
        } catch { writable = false; storageError = "The recovery draft could not be opened. The original file has been preserved." }
    }
    func checkpoint(id: UUID, text: String, interrupted: Bool = false, persist: Bool, force: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = Draft(recordingID: id, text: text, interrupted: interrupted, updatedAt: Date())
        guard persist else { removeFile(); return }
        guard force || Date().timeIntervalSince(lastSaved) >= 1 else { return }
        guard let draft, let fileURL, writable else { return }
        do {
            try JSONEncoder().encode(draft).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            lastSaved = Date(); storageError = nil
        } catch { storageError = "The recovery draft could not be saved. Your current text is still available in Murmur." }
    }
    func clear() { draft = nil; removeFile() }
    private func removeFile() {
        guard let fileURL, writable, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { try FileManager.default.removeItem(at: fileURL) }
        catch { storageError = "The recovery draft could not be removed." }
    }
}
