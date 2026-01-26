import Foundation

public struct TextProcessor {
    private static let fillerPatterns = [
        "\\bum+\\b", "\\buh+\\b", "\\bah+\\b", "\\ber+\\b",
        "\\byou know,?\\s*", "\\bi mean,?\\s*"
    ]

    public static func process(_ text: String, removeFillers: Bool = true) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if removeFillers {
            for pattern in fillerPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
                }
            }
        }

        // Clean spacing
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Capitalize first letter
        if let first = result.first {
            result = first.uppercased() + result.dropFirst()
        }

        return result
    }
}
