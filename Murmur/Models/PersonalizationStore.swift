import Foundation
import Combine
import MurmurKit

@MainActor
final class PersonalizationStore: ObservableObject {
    @Published private(set) var library = VoicePersonalization.starter
    @Published private(set) var storageError: String?
    private var fileURL: URL?
    private var writable = true
    struct InvalidEntry: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func open(at url: URL? = nil) {
        guard fileURL == nil else { return }
        fileURL = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Murmur/Personalization/library-v1.json")
        do {
            let parent = fileURL!.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: fileURL!.path) {
                guard (try fileURL!.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 3_000_000 else { throw InvalidEntry(message: "Library exceeds the 3 MB limit.") }
                let incoming = try JSONDecoder().decode(VoicePersonalization.self, from: Data(contentsOf: fileURL!))
                try Self.validate(incoming); library = incoming
            } else { try persist(library) }
        } catch {
            writable = false
            storageError = "Your vocabulary library could not be opened. The original file has been preserved."
        }
    }
    func addWord(written: String, spoken: String = "", app: String? = nil, replacing id: UUID? = nil) throws {
        let word = VoiceWord(written: written.trimmingCharacters(in: .whitespacesAndNewlines), spoken: spoken.trimmingCharacters(in: .whitespacesAndNewlines), appBundleID: app)
        var next = library
        if let index = next.words.firstIndex(where: { $0.id == id || id == nil && VoicePersonalizer.key($0.written) == VoicePersonalizer.key(word.written) && $0.appBundleID == app }) {
            next.words[index].appBundleID = app
            next.words[index].written = word.written
            if id == nil && !word.spoken.isEmpty {
                var seen = Set<String>()
                next.words[index].spoken = (next.words[index].spoken.components(separatedBy: ";") + word.spoken.components(separatedBy: ";")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert(VoicePersonalizer.key($0)).inserted }.joined(separator: "; ")
            } else if id != nil { next.words[index].spoken = word.spoken }
            next.words[index].enabled = true
        } else { next.words.append(word) }
        try update(next)
    }
    func migrateLegacyVocabulary(_ text: String) throws {
        var next = library
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !next.words.contains(where: { VoicePersonalizer.key($0.written) == VoicePersonalizer.key(value) && $0.appBundleID == nil }) else { continue }
            next.words.append(VoiceWord(written: value))
        }
        if next != library { try update(next) }
    }
    func setWordEnabled(_ id: UUID, _ enabled: Bool) throws {
        var next = library
        if let index = next.words.firstIndex(where: { $0.id == id }) { next.words[index].enabled = enabled }
        try update(next)
    }
    func setSnippetEnabled(_ id: UUID, _ enabled: Bool) throws {
        var next = library
        if let index = next.snippets.firstIndex(where: { $0.id == id }) { next.snippets[index].enabled = enabled }
        try update(next)
    }
    func removeWord(_ id: UUID) throws { var next = library; next.words.removeAll { $0.id == id }; try update(next) }
    func addSnippet(trigger: String, text: String, app: String? = nil, replacing id: UUID? = nil) throws {
        var next = library
        let snippet = VoiceSnippet(trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines), text: text, appBundleID: app)
        if let index = next.snippets.firstIndex(where: { $0.id == id || id == nil && VoicePersonalizer.key($0.trigger) == VoicePersonalizer.key(snippet.trigger) && $0.appBundleID == app }) {
            next.snippets[index].trigger = snippet.trigger; next.snippets[index].appBundleID = app
            next.snippets[index].text = text; next.snippets[index].enabled = true
        } else { next.snippets.append(snippet) }
        try update(next)
    }
    func removeSnippet(_ id: UUID) throws { var next = library; next.snippets.removeAll { $0.id == id }; try update(next) }
    func setStyle(_ style: VoiceWritingStyle, app: String? = nil, name: String = "") throws {
        var next = library
        if let app {
            next.appStyles.removeAll { $0.bundleID == app }
            next.appStyles.append(VoiceAppStyle(bundleID: app, name: name, style: style))
        } else { next.defaultStyle = style }
        try update(next)
    }
    func removeStyle(_ app: String) throws { var next = library; next.appStyles.removeAll { $0.bundleID == app }; try update(next) }
    func exportData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(library)
    }
    static func decodeImport(_ data: Data) throws -> VoicePersonalization {
        guard data.count <= 3_000_000 else { throw InvalidEntry(message: "Choose a library smaller than 3 MB.") }
        let value = try JSONDecoder().decode(VoicePersonalization.self, from: data)
        try validate(value); return value
    }
    @discardableResult func merge(_ incoming: VoicePersonalization) throws -> Int {
        try Self.validate(incoming)
        var next = library; var added = 0
        for var word in incoming.words {
            guard !next.words.contains(where: { existing in existing.appBundleID == word.appBundleID && VoicePersonalizer.key(existing.written) == VoicePersonalizer.key(word.written) }) else { continue }
            word.id = UUID(); next.words.append(word); added += 1
        }
        for var snippet in incoming.snippets {
            guard !next.snippets.contains(where: { $0.appBundleID == snippet.appBundleID && VoicePersonalizer.key($0.trigger) == VoicePersonalizer.key(snippet.trigger) }) else { continue }
            snippet.id = UUID(); next.snippets.append(snippet); added += 1
        }
        for style in incoming.appStyles where !next.appStyles.contains(where: { $0.bundleID == style.bundleID }) { next.appStyles.append(style); added += 1 }
        try update(next); return added
    }
    private func update(_ value: VoicePersonalization) throws {
        try Self.validate(value)
        guard writable else { throw InvalidEntry(message: storageError ?? "The library is read-only.") }
        do { try persist(value); library = value; storageError = nil }
        catch { storageError = "Changes could not be saved. Your previous library is intact."; throw InvalidEntry(message: storageError!) }
    }
    private func persist(_ value: VoicePersonalization) throws {
        guard let fileURL else { return } // Explicit in-memory fixtures and tests.
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    private static func validate(_ value: VoicePersonalization) throws {
        guard value.version == 1, value.words.count <= 500, value.snippets.count <= 100, value.appStyles.count <= 100,
              Set(value.words.map(\.id)).count == value.words.count, Set(value.snippets.map(\.id)).count == value.snippets.count else {
            throw InvalidEntry(message: "This library version or size is not supported.")
        }
        func valid(_ text: String, max: Int, multiline: Bool = false) -> Bool {
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= max && !text.contains("\0") && (multiline || !text.contains(where: \.isNewline))
        }
        func validApp(_ app: String?) -> Bool { app == nil || valid(app!, max: 240) && !app!.contains(where: \.isWhitespace) }
        var aliases = Set<String>()
        for word in value.words {
            guard valid(word.written, max: 100), word.spoken.isEmpty || valid(word.spoken, max: 500) && word.aliases.count <= 6 && word.aliases.allSatisfy({ $0.count <= 100 }), validApp(word.appBundleID) else { throw InvalidEntry(message: "Words and spoken aliases must be single lines, up to 100 characters.") }
            guard aliases.insert((word.appBundleID ?? "*") + "\0" + VoicePersonalizer.key(word.written)).inserted else { throw InvalidEntry(message: "That spelling already exists in this scope.") }
        }
        var triggers = Set<String>()
        for snippet in value.snippets {
            guard valid(snippet.trigger, max: 80), valid(snippet.text, max: 10_000, multiline: true), validApp(snippet.appBundleID),
                  triggers.insert((snippet.appBundleID ?? "*") + "\0" + VoicePersonalizer.key(snippet.trigger)).inserted else { throw InvalidEntry(message: "Use a unique snippet name up to 80 characters and text up to 10,000 characters.") }
        }
        guard (try JSONEncoder().encode(value)).count <= 3_000_000 else { throw InvalidEntry(message: "The library is full. Export or remove some entries before adding more.") }
        guard Set(value.appStyles.map(\.bundleID)).count == value.appStyles.count,
              value.appStyles.allSatisfy({ validApp($0.bundleID) && valid($0.name, max: 240) }) else { throw InvalidEntry(message: "Each app can have one writing style.") }
    }
}
