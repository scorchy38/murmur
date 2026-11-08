import XCTest
@testable import MurmurKit

final class VoiceContractTests: XCTestCase {
    func testNestedEnablementRequiresABooleanAndOverridesLegacy() {
        XCTAssertFalse(VoiceSettings.enabled(nested: ["enabled": false], legacy: true))
        XCTAssertTrue(VoiceSettings.enabled(nested: ["enabled": true], legacy: false))
        XCTAssertTrue(VoiceSettings.enabled(nested: [:], legacy: true))
        XCTAssertFalse(VoiceSettings.enabled(nested: nil, legacy: "true"))
        XCTAssertFalse(VoiceSettings.enabled(nested: ["enabled": 1], legacy: true))
        XCTAssertFalse(VoiceSettings.enabled(nested: nil, legacy: nil))
    }
    func testReplacementAndFinalCorrectionAreCommittedExactlyOnce() {
        var transcript = VoiceTranscript()
        transcript.accept(.interim("change teh"))
        XCTAssertEqual(transcript.preview, "change teh")
        transcript.accept(.text("change the"))
        transcript.accept(.endpoint)
        transcript.accept(.endpoint)
        XCTAssertEqual(transcript.preview, "change the")
        transcript.accept(.interim("CacheManager"))
        XCTAssertEqual(transcript.preview, "change the CacheManager")
        transcript.accept(.text("CacheManager.swift"))
        transcript.accept(.endpoint)
        XCTAssertEqual(transcript.preview, "change the CacheManager.swift")
    }

    func testSalvageDoesNotClaimAuthorityOrDuplicateText() {
        var transcript = VoiceTranscript()
        transcript.accept(.interim("Keep the negation: do not delete /tmp/cache"))
        transcript.salvage()
        transcript.salvage()
        XCTAssertEqual(transcript.preview, "Keep the negation: do not delete /tmp/cache")
        XCTAssertEqual(transcript.authoritativeSegments, 0)
    }

    func testProviderCorrectsBeforeEndpointAndIgnoresDuplicateFinalAndLateInterim() {
        var normalizer = VoiceProviderNormalizer()
        XCTAssertEqual(normalizer.events(["serverContent": ["interimInputTranscription": ["text": "rename cash manager"]]]), [.interim("rename cash manager")])
        let final: [String: Any] = ["serverContent": ["inputTranscription": ["text": "rename CacheManager"]]]
        XCTAssertEqual(normalizer.events(final), [.text("rename CacheManager"), .endpoint])
        XCTAssertTrue(normalizer.events(final).isEmpty)
        XCTAssertTrue(normalizer.events(["serverContent": ["interimInputTranscription": ["text": "obsolete"]]]).isEmpty)
    }

    func testTurnCompleteDoesNotInventAuthoritativeText() {
        var normalizer = VoiceProviderNormalizer()
        XCTAssertEqual(normalizer.events(["serverContent": ["turnComplete": true]]), [])
        XCTAssertEqual(normalizer.events(["serverContent": ["inputTranscription": ["text": 123]]]), [])
        XCTAssertEqual(normalizer.events(["unknown": true]), [])
    }

    func testProviderErrorsAreBoundedAndDoNotEchoSecrets() {
        var normalizer = VoiceProviderNormalizer()
        XCTAssertEqual(normalizer.events(["error": ["code": 403, "message": "secret raw headers"]]), [.failure(.credentials)])
        XCTAssertEqual(normalizer.events(["error": ["code": 429]]), [.failure(.quota)])
        XCTAssertEqual(normalizer.events(["goAway": ["timeLeft": "1s"]]), [.failure(.limit)])
    }

    @MainActor func testSetupUsesSmartManualModeAndNoConversationalInstructions() throws {
        let setup = try XCTUnwrap(NativeVoiceStream.setup(language: "hi", vocabulary: ["CacheManager"])["setup"] as? [String: Any])
        XCTAssertEqual(setup["model"] as? String, "models/gemini-3.5-transcribe-live")
        let transcription = try XCTUnwrap(setup["inputAudioTranscription"] as? [String: Any])
        XCTAssertEqual(transcription["mode"] as? String, "SMART")
        XCTAssertEqual(transcription["languageCodes"] as? [String], ["hi"])
        XCTAssertNil(setup["systemInstruction"])
        let realtime = try XCTUnwrap(setup["realtimeInputConfig"] as? [String: Any])
        XCTAssertEqual((realtime["automaticActivityDetection"] as? [String: Bool])?["disabled"], true)
    }

    func testPCMLevelAndFrameOrder() {
        XCTAssertEqual(VoiceAudio.level(Data()), 0)
        XCTAssertEqual(VoiceAudio.level(Data([0])), 0)
        XCTAssertEqual(VoiceAudio.level(Data([0, 0, 0, 0])), 0)
        XCTAssertEqual(VoiceAudio.level(Data([0xd0, 0x07, 0x30, 0xf8])), 1, accuracy: 0.001)
        let chunks = [Data(repeating: 1, count: 12_000), Data(repeating: 2, count: 24_000), Data(repeating: 3, count: 2_000)]
        let frames = VoiceAudio.coalesced(chunks)
        XCTAssertEqual(frames.map(\.count), [36_000, 2_000])
        XCTAssertEqual(frames.reduce(Data(), +), chunks.reduce(Data(), +))
    }

    func testCircuitBreakerRecoversAtRollingWindowWithoutARequest() {
        var breaker = VoiceCircuitBreaker()
        let now = Date(timeIntervalSince1970: 100)
        for seconds in [0.0, 1, 2] { breaker.failed(at: now.addingTimeInterval(seconds)) }
        XCTAssertFalse(breaker.admits(at: now.addingTimeInterval(9)))
        XCTAssertTrue(breaker.admits(at: now.addingTimeInterval(10)))
        breaker.failed(at: now.addingTimeInterval(10))
        XCTAssertFalse(breaker.admits(at: now.addingTimeInterval(10)))
        breaker.succeeded()
        XCTAssertTrue(breaker.admits(at: now.addingTimeInterval(10)))
    }

    func testLanguageAliasesAndExplicitFallback() {
        XCTAssertEqual(VoiceLanguage.resolve(" FR-ca ").code, "fr")
        XCTAssertEqual(VoiceLanguage.resolve("日本語").code, "ja")
        XCTAssertEqual(VoiceLanguage.resolve("हिंदी").code, "hi")
        XCTAssertEqual(VoiceLanguage.resolve(" ").code, "en")
        XCTAssertFalse(VoiceLanguage.resolve("").usedFallback)
        XCTAssertTrue(VoiceLanguage.resolve("unsupported").usedFallback)
    }

    func testVocabularySanitizesDeduplicatesAndBounds() {
        let terms = VoiceVocabulary.sanitized(["Cache,Manager", "Cache Manager", "non\nprintable", "😀日本語"] + (0..<100).map { "term\($0)" })
        XCTAssertEqual(terms.first, "Cache Manager")
        XCTAssertEqual(terms.count, 50)
        XCTAssertTrue(terms.joined(separator: ",").count <= 1024)
        XCTAssertTrue(terms.joined().unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 })
    }

    func testAnchorPreservesSuffixUnicodeAndBoundarySpacing() throws {
        var anchor = try XCTUnwrap(VoiceAnchor(text: "Hello world 👋", selection: NSRange(location: 6, length: 0)))
        let replacement = try XCTUnwrap(anchor.replacement("beautiful", current: "Hello world 👋"))
        XCTAssertEqual(replacement.text, "Hello beautiful world 👋")
        XCTAssertEqual(replacement.cursor, 15)
        XCTAssertNil(anchor.replacement("obsolete", current: "I edited this"))
    }

    func testAnchorRejectsInvalidRangesAndDoesNotInsertEmptySpacing() throws {
        XCTAssertNil(VoiceAnchor(text: "abc", selection: NSRange(location: Int.max, length: 1)))
        XCTAssertNil(VoiceAnchor(text: "abc", selection: NSRange(location: 1, length: Int.max)))
        var anchor = try XCTUnwrap(VoiceAnchor(text: "abcd", selection: NSRange(location: 2, length: 0)))
        XCTAssertEqual(anchor.replacement("", current: "abcd")?.text, "abcd")
    }
}
