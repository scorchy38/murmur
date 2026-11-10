import Foundation

public enum VoiceWritingStyle: String, Codable, CaseIterable, Sendable {
    case natural, chat, literal, technical
    public var title: String { switch self { case .natural: "Natural"; case .chat: "Chat"; case .literal: "Verbatim"; case .technical: "Technical" } }
    public var detail: String { switch self {
        case .natural: "Clean up spoken corrections and filler words."
        case .chat: "Natural wording, without a final period on short messages."
        case .literal: "Keep the words you said, including repetitions and fillers."
        case .technical: "Verbatim recognition with explicit identifier formatting."
    } }
    public var transcriptionMode: VoiceTranscriptionMode { [.literal, .technical].contains(self) ? .verbatim : .smart }
}
public enum VoiceTranscriptionMode: String, Codable, Sendable { case smart = "SMART", verbatim = "VERBATIM" }

public struct VoiceWord: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var written: String
    public var spoken: String
    public var appBundleID: String?
    public var enabled = true
    public var aliases: [String] { [written] + spoken.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    public init(written: String, spoken: String = "", appBundleID: String? = nil) {
        self.written = written; self.spoken = spoken; self.appBundleID = appBundleID
    }
}
public struct VoiceSnippet: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var trigger: String
    public var text: String
    public var appBundleID: String?
    public var enabled = true
    public init(trigger: String, text: String, appBundleID: String? = nil) {
        self.trigger = trigger; self.text = text; self.appBundleID = appBundleID
    }
}
public struct VoiceAppStyle: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String
    public var style: VoiceWritingStyle
    public init(bundleID: String, name: String, style: VoiceWritingStyle) { self.bundleID = bundleID; self.name = name; self.style = style }
}
public struct VoicePersonalization: Codable, Equatable, Sendable {
    public var version = 1
    public var words: [VoiceWord] = []
    public var snippets: [VoiceSnippet] = []
    public var appStyles: [VoiceAppStyle] = []
    public var defaultStyle = VoiceWritingStyle.natural
    public init() {}
    public static var starter: Self {
        var value = Self()
        value.words = ["Murmur", "Gemini", "Codex", "Wispr Flow", "CacheManager"].map { VoiceWord(written: $0) }
        value.snippets = [
            VoiceSnippet(trigger: "review request", text: "Please review this change for correctness, edge cases, and regressions. Explain the important findings and suggest focused fixes."),
            VoiceSnippet(trigger: "implementation plan", text: "Create an implementation plan for this change. Cover the approach, affected components, risks, and validation. Preserve existing behavior unless a change is explicitly requested."),
            VoiceSnippet(trigger: "bug report", text: "What happened:\n\nWhat I expected:\n\nSteps to reproduce:\n\nRelevant details:\n")
        ]
        return value
    }
    public func style(for app: String?) -> VoiceWritingStyle { appStyles.first { $0.bundleID == app }?.style ?? defaultStyle }
    public func hints(for app: String?) -> [String] {
        words.reversed().filter { $0.enabled && ($0.appBundleID == nil || $0.appBundleID == app) }
            .sorted { ($0.appBundleID != nil ? 0 : 1) < ($1.appBundleID != nil ? 0 : 1) }.map(\.written)
    }
}
public struct VoicePersonalizedText: Equatable, Sendable {
    public var text: String
    public var corrections = 0
    public var expandedSnippet = false
    public var formattedIdentifier = false
    public init(text: String) { self.text = text }
}
public enum VoicePersonalizer {
    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    public static func process(_ input: String, library: VoicePersonalization, app: String?, style: VoiceWritingStyle) -> VoicePersonalizedText {
        var result = VoicePersonalizedText(text: input)
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!?。"))
        let normalized = key(command)
        if normalized.hasPrefix("insert snippet ") {
            let trigger = String(normalized.dropFirst("insert snippet ".count))
            let candidates = library.snippets.filter { $0.enabled && key($0.trigger) == trigger && ($0.appBundleID == nil || $0.appBundleID == app) }
            if let snippet = candidates.first(where: { $0.appBundleID == app && app != nil }) ?? candidates.first {
                result.text = snippet.text; result.expandedSnippet = true; return result
            }
        }
        if style == .technical, normalized.hasPrefix("identifier ") {
            for (phrase, separator, capitalized) in [("camel case", "", false), ("pascal case", "", true), ("snake case", "_", false), ("kebab case", "-", false), ("constant case", "_", true)] {
                let prefix = "identifier " + phrase + " "
                guard normalized.hasPrefix(prefix) else { continue }
                let words = normalized.dropFirst(prefix.count).split(separator: " ").map(String.init)
                guard !words.isEmpty, words.count <= 12, words.allSatisfy({ $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } }) else { break }
                if separator.isEmpty {
                    result.text = words.enumerated().map { index, word in index == 0 && !capitalized ? word : word.prefix(1).uppercased() + word.dropFirst() }.joined()
                } else { result.text = words.joined(separator: separator); if capitalized { result.text = result.text.uppercased() } }
                result.formattedIdentifier = true; return result
            }
        }
        // Recognition owns spelling decisions. Saved words are contextual hints
        // supplied with the audio, never global search-and-replace rules. In
        // particular, a remembered Claude must not rewrite an ordinary cloud.
        if style == .chat, !result.text.contains("\n"), result.text.count < 300, result.text.hasSuffix("."), !result.text.hasSuffix("..") {
            let last = result.text.dropLast().split(separator: " ").last.map(String.init) ?? ""
            if !last.contains("."), !last.contains(where: \.isNumber), !["mr", "mrs", "dr", "jr", "sr", "etc"].contains(last.lowercased()) { result.text.removeLast() }
        }
        return result
    }
}

public struct VoiceCorrectionSuggestion: Equatable, Sendable {
    public var spoken: String
    public var written: String
    /// Extract separate edits so correcting two names in a long prompt does
    /// not turn the intervening prose into one vocabulary entry.
    public static func spellingEdits(_ original: String, _ edited: String) -> [Self] {
        let old = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let new = edited.split(whereSeparator: \.isWhitespace).map(String.init)
        guard old.count <= 4000, new.count <= 4000 else { return [] }
        let diff = new.difference(from: old)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var i = 0, j = 0, result: [Self] = []
        while i < old.count || j < new.count {
            let startI = i, startJ = j
            while i < old.count && removed.contains(i) { i += 1 }
            while j < new.count && inserted.contains(j) { j += 1 }
            if i > startI, j > startJ,
               let change = between(old[startI..<i].joined(separator: " "), new[startJ..<j].joined(separator: " ")),
               VoicePersonalizer.key(change.spoken) != VoicePersonalizer.key(change.written),
               change.written.contains(where: { $0.isUppercase }),
               change.written.split(separator: " ").count <= 4 {
                result.append(change)
            }
            if i < old.count { i += 1 }
            if j < new.count { j += 1 }
        }
        return result
    }
    public static func between(_ original: String, _ edited: String) -> Self? {
        func tokens(_ text: String) -> [(String, Range<String.Index>)] {
            var values: [(String, Range<String.Index>)] = []
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in if let word { values.append((word, range)) } }
            return values
        }
        let old = tokens(original), new = tokens(edited)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix].0 == new[prefix].0 { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix, old[old.count - suffix - 1].0 == new[new.count - suffix - 1].0 { suffix += 1 }
        guard old.count - prefix - suffix > 0, new.count - prefix - suffix > 0,
              old.count - prefix - suffix <= 4, new.count - prefix - suffix <= 4 else { return nil }
        let spoken = String(original[old[prefix].1.lowerBound..<old[old.count - suffix - 1].1.upperBound])
        let written = String(edited[new[prefix].1.lowerBound..<new[new.count - suffix - 1].1.upperBound])
        let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " _-"))
        guard spoken.count <= 80, written.count <= 80, spoken != written,
              (spoken + written).unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return Self(spoken: spoken, written: written)
    }
}
