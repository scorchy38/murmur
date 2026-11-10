import XCTest
@testable import MurmurKit

final class VoicePersonalizationTests: XCTestCase {
    func testVocabularyHintsNeverRewriteHomophonesOrCaseAfterRecognition() {
        var library = VoicePersonalization()
        library.words = [.init(written: "Claude", spoken: "cloud; clode"), .init(written: "CacheManager", spoken: "cash manager")]
        let input = "Use Claude Code to deploy to the cloud. There is a cloud over the cash manager."
        XCTAssertEqual(VoicePersonalizer.process(input, library: library, app: nil, style: .natural).text, input)
        XCTAssertEqual(VoicePersonalizer.process("clode and cloud", library: library, app: nil, style: .technical).text, "clode and cloud")
        XCTAssertEqual(library.hints(for: nil), ["CacheManager", "Claude"])
    }
    func testScopedWordsOnlyChangeTheHintsSentToRecognition() {
        var library = VoicePersonalization()
        library.words = [.init(written: "Claude", spoken: "cloud", appBundleID: "test.editor")]
        XCTAssertEqual(library.hints(for: "test.editor"), ["Claude"])
        XCTAssertTrue(library.hints(for: "test.mail").isEmpty)
        for app in ["test.editor", "test.mail"] {
            XCTAssertEqual(VoicePersonalizer.process("cloud", library: library, app: app, style: .natural).text, "cloud")
        }
    }
    func testSnippetRequiresExactDeliberateWholeUtteranceAndDoesNotRewriteExpansion() {
        var library = VoicePersonalization.starter
        library.words = [.init(written: "Changed", spoken: "Please")]
        let result = VoicePersonalizer.process("Insert snippet review request.", library: library, app: nil, style: .natural)
        XCTAssertTrue(result.expandedSnippet)
        XCTAssertTrue(result.text.hasPrefix("Please review"))
        XCTAssertFalse(VoicePersonalizer.process("I might insert snippet review request tomorrow", library: library, app: nil, style: .natural).expandedSnippet)
        XCTAssertFalse(VoicePersonalizer.process("insert snippet unknown", library: library, app: nil, style: .natural).expandedSnippet)
    }
    func testUnicodeCorrectionAndLongestAlias() {
        var library = VoicePersonalization()
        library.words = [.init(written: "शुभ", spoken: "shubh"), .init(written: "CacheManager", spoken: "cache manager"), .init(written: "Cache", spoken: "cache")]
        XCTAssertEqual(VoicePersonalizer.process("shubh uses cache manager", library: library, app: nil, style: .natural).text, "shubh uses cache manager")
    }
    func testTechnicalIdentifiersAreExplicitAndNeverExecute() {
        for (spoken, expected) in [("camel case user profile", "userProfile"), ("pascal case user profile", "UserProfile"), ("snake case user profile", "user_profile"), ("kebab case user profile", "user-profile"), ("constant case api base url", "API_BASE_URL")] {
            let result = VoicePersonalizer.process("identifier " + spoken, library: .starter, app: nil, style: .technical)
            XCTAssertEqual(result.text, expected)
            XCTAssertTrue(result.formattedIdentifier)
        }
        XCTAssertFalse(VoicePersonalizer.process("Please use snake case here", library: .starter, app: nil, style: .technical).formattedIdentifier)
        XCTAssertFalse(VoicePersonalizer.process("identifier snake case delete /tmp", library: .starter, app: nil, style: .technical).formattedIdentifier)
    }
    func testChatFormattingProtectsNumbersAndAbbreviations() {
        XCTAssertEqual(VoicePersonalizer.process("Looks good.", library: .init(), app: nil, style: .chat).text, "Looks good")
        for text in ["Version 2.1.", "Talk to Dr.", "Really?", "Wait...", "One.\nTwo."] {
            XCTAssertEqual(VoicePersonalizer.process(text, library: .init(), app: nil, style: .chat).text, text)
        }
    }
    func testLearningSuggestsNamesButNeverNumericCorrectionsOrLongRewrites() {
        XCTAssertEqual(VoiceCorrectionSuggestion.between("Fix cash manager now", "Fix CacheManager now"), VoiceCorrectionSuggestion(spoken: "cash manager", written: "CacheManager"))
        XCTAssertNil(VoiceCorrectionSuggestion.between("Cost is 15 dollars", "Cost is 50 dollars"))
        XCTAssertNil(VoiceCorrectionSuggestion.between("Original", "Original plus more words"))
        XCTAssertNil(VoiceCorrectionSuggestion.between("Use key123", "Use key456"))
    }
    @MainActor func testProviderModesAndAutoLanguagePayload() throws {
        let automatic = NativeVoiceStream.setup(language: "auto", vocabulary: [], mode: .verbatim)
        let setup = try XCTUnwrap(automatic["setup"] as? [String: Any])
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["languageCodes"] as? [String], [])
        XCTAssertEqual(transcription["mode"] as? String, "VERBATIM")
        XCTAssertEqual(VoiceLanguage.resolve("auto").code, "auto")
        XCTAssertEqual(VoiceWritingStyle.natural.transcriptionMode, .smart)
        XCTAssertEqual(VoiceWritingStyle.technical.transcriptionMode, .verbatim)
    }
    func testNativeVocabularyRetainsUnicodeAndNormalizesWhitespace() {
        XCTAssertEqual(VoiceVocabulary.nativeHints(["शुभ", "cache\tmanager", "cache manager", "Murmur"]), ["शुभ", "cache manager", "Murmur"])
        XCTAssertEqual(VoiceVocabulary.nativeHints((0..<120).map { "Word\($0)" }).count, 100)
    }
    func testLearningOnlyExtractsTheOwnedSpan() throws {
        let anchor = try XCTUnwrap(VoiceUndoAnchor(original: "prefix  suffix", replacement: "prefix cash manager suffix", selection: NSRange(location: 7, length: 0), cursor: 19))
        XCTAssertEqual(anchor.correctedSpan(in: "prefix CacheManager suffix"), "CacheManager")
        XCTAssertNil(anchor.correctedSpan(in: "other CacheManager suffix"))
        XCTAssertNil(anchor.correctedSpan(in: "prefix CacheManager changed"))
    }

    func testCorrectionsDoNotSplitCombiningMarksOrQuotedLiterals() {
        var library = VoicePersonalization()
        library.words = [.init(written: "Brand", spoken: "cafe"), .init(written: "CacheManager", spoken: "cash manager")]
        let literal = "cafe\u{301} and \"cash manager\" and 'cash manager'"
        XCTAssertEqual(VoicePersonalizer.process(literal, library: library, app: nil, style: .natural).text, literal)
    }

    func testFullVocabularyTransformsALongPromptWithinInteractiveBudget() {
        var library = VoicePersonalization()
        library.words = (0..<500).map { VoiceWord(written: "Symbol\($0)", spoken: "term\($0)") }
        let input = (0..<500).map { "term\($0)" }.joined(separator: " ")
        let start = Date()
        let result = VoicePersonalizer.process(input, library: library, app: nil, style: .natural)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.corrections, 0)
        XCTAssertEqual(result.text, input)
        XCTAssertLessThan(elapsed, 2, "A full personal library must not stall final delivery")
        print("PERSONALIZATION_BENCHMARK_MS=\(Int(elapsed * 1000))")
    }

    func testLearningSeparatesMultipleNamesAndSkipsGrammarNumbersAndCaseOnlyEdits() {
        let changes = VoiceCorrectionSuggestion.spellingEdits("use clode code and cash manager now", "use Claude code and CacheManager now")
        XCTAssertEqual(changes.map(\.written), ["Claude", "CacheManager"])
        XCTAssertTrue(VoiceCorrectionSuggestion.spellingEdits("send it tomorrow", "send it today").isEmpty)
        XCTAssertTrue(VoiceCorrectionSuggestion.spellingEdits("pay 15", "pay 50").isEmpty)
        XCTAssertTrue(VoiceCorrectionSuggestion.spellingEdits("hello there", "Hello there").isEmpty)
    }

}
