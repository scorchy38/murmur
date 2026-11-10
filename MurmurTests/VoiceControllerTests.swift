import XCTest
import SwiftUI
@testable import Murmur
import MurmurKit

@MainActor
private final class FakeCapture: VoiceCapturing {
    var onAudio: (@Sendable (Data) -> Void)?
    var starts = 0
    var stops = 0
    var tail: Data?
    func start(onAudio: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable () -> Void) throws {
        starts += 1; self.onAudio = onAudio
    }
    @discardableResult func stop() -> Data? { stops += 1; return tail }
}

@MainActor
private final class FakeStream: VoiceStreaming {
    var onEvent: ((VoiceEvent) -> Void)?
    var frames: [Data] = []
    var finished = false
    var cancelled = false
    func start() {}
    func send(_ audio: Data) { frames.append(audio) }
    func finish() { finished = true; onEvent?(.inputClosed) }
    func cancel() { cancelled = true }
}

@MainActor
final class VoiceControllerTests: XCTestCase {
    private func settle() async { for _ in 0..<8 { await Task.yield() } }

    func testReleaseBeforeNetworkReadyPreservesAudioAndFinalCorrection() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test-credential" }, authorize: { true })
        var completed: [String] = []
        var usage: VoiceUsageSession?
        controller.onUsageSnapshot = { usage = $0 }
        controller.onComplete = { text, _ in completed.append(text) }
        controller.start(); await settle()
        let audio = Data(repeating: 4, count: 3200)
        recorder.onAudio?(audio); await settle()
        XCTAssertTrue(stream.frames.isEmpty)
        controller.finish()
        XCTAssertFalse(stream.finished)
        stream.onEvent?(.ready)
        XCTAssertEqual(stream.frames, [audio])
        await settle()
        XCTAssertTrue(stream.finished)
        stream.onEvent?(.interim("rename cash manager"))
        stream.onEvent?(.text("rename CacheManager"))
        stream.onEvent?(.endpoint)
        stream.onEvent?(.turnComplete)
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(completed, ["rename CacheManager"])
        XCTAssertEqual(usage?.words, 2)
        XCTAssertEqual(usage?.attempts.first?.estimatedOutputTokens, 5)
        XCTAssertEqual(VoiceUsageTotals(sessions: usage.map { [$0] } ?? []).estimatedInputTokens, 3)
        XCTAssertEqual(state.recordingState, .idle)
        XCTAssertTrue(stream.cancelled)
        controller.dispose()
    }

    func testCancellationRejectsAllLateCallbacksAndNeverCompletes() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        var completions = 0
        controller.onComplete = { _, _ in completions += 1 }
        controller.start(); await settle()
        let lateCallback = stream.onEvent
        controller.cancel()
        lateCallback?(.ready)
        lateCallback?(.text("obsolete result"))
        lateCallback?(.endpoint)
        recorder.onAudio?(Data(repeating: 1, count: 3200))
        await settle()
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(state.interimTranscript, "")
        XCTAssertEqual(state.recordingState, .idle)
        XCTAssertTrue(stream.frames.isEmpty)
    }

    func testPermissionCompletionCannotResurrectCancelledRecording() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in FakeStream() }, credentialProvider: { "test" }, drainWait: 1.5, authorize: {
            try? await Task.sleep(for: .milliseconds(100))
            return true
        })
        controller.start()
        await settle()
        controller.cancel()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(state.recordingState, .idle)
    }

    func testProcessingBlocksAnotherStartAndErrorsSalvageOnlyOnce() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        var completed: [(String, Bool)] = []
        controller.onComplete = { completed.append(($0, $1)) }
        controller.start(); await settle()
        stream.onEvent?(.ready)
        stream.onEvent?(.interim("Do not delete /tmp/cache"))
        controller.finish()
        controller.start()
        XCTAssertEqual(recorder.starts, 1)
        let late = stream.onEvent
        stream.onEvent?(.failure(.connection))
        late?(.failure(.connection))
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0, "Do not delete /tmp/cache")
        XCTAssertEqual(completed.first?.1, true)
        XCTAssertNotNil(state.lastError)
        controller.dispose()
    }

    func testOneEarlyRetryAndOneEvidenceBasedReplay() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture()
        var streams: [FakeStream] = []
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in
            let stream = FakeStream(); streams.append(stream); return stream
        }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        controller.start(); await settle()
        streams[0].onEvent?(.failure(.connection))
        try? await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(streams.count, 2)
        recorder.onAudio?(Data(repeating: 0x10, count: 3200)); await settle()
        streams[1].onEvent?(.ready)
        controller.finish()
        try? await Task.sleep(for: .milliseconds(1850))
        XCTAssertEqual(streams.count, 3)
        streams[2].onEvent?(.ready)
        XCTAssertEqual(streams[2].frames.reduce(0) { $0 + $1.count }, 3200)
        streams[2].onEvent?(.text("Recovered text"))
        streams[2].onEvent?(.endpoint)
        streams[2].onEvent?(.turnComplete)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(state.completedText, "Recovered text")
        XCTAssertEqual(state.currentAttemptCount, 3)
        controller.dispose()
    }
    func testSupersededErrorsCannotRestartButTextStillBelongsToRecording() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture()
        var streams: [FakeStream] = []
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in
            let stream = FakeStream(); streams.append(stream); return stream
        }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        controller.start(); await settle()
        let obsoleteCallback = streams[0].onEvent
        obsoleteCallback?(.failure(.connection))
        try? await Task.sleep(for: .milliseconds(320))
        obsoleteCallback?(.failure(.credentials))
        obsoleteCallback?(.usage(VoiceUsage(inputTokens: 100, outputTokens: 20)))
        XCTAssertEqual(state.attempts[0].usage?.inputTokens, 100)
        XCTAssertNil(state.attempts[1].usage)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(streams.count, 2)
        obsoleteCallback?(.interim("recognized before reconnect"))
        XCTAssertEqual(state.interimTranscript, "recognized before reconnect")
        controller.cancel()
    }

    func testSilentMicrophoneDoesNotReplayAndGetsADeviceExplanation() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        var attempts = 0
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in
            attempts += 1; return stream
        }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        controller.start(); await settle()
        recorder.onAudio?(Data(repeating: 0, count: 96_000)); await settle()
        stream.onEvent?(.ready)
        controller.finish()
        try? await Task.sleep(for: .milliseconds(1650))
        XCTAssertEqual(state.lastError, VoiceFailure.noSignal.localizedDescription)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state.recordingState, .idle)
        controller.dispose()
    }

    func testFinishDrainsAcceptedCaptureBeforeResamplerTailAndClose() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        controller.start(); await settle()
        stream.onEvent?(.ready)
        let frame = Data(repeating: 3, count: 3200)
        let tail = Data(repeating: 4, count: 480)
        recorder.tail = tail
        recorder.onAudio?(frame)
        controller.finish()
        await settle()
        XCTAssertEqual(stream.frames, [frame, tail])
        XCTAssertTrue(stream.finished)
        XCTAssertTrue(state.audioLevels.allSatisfy { $0 == 0 })
        controller.cancel()
    }

    func testUsageSnapshotsKeepLatestReceiptAndCancellationOnlyOnce() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        var snapshots: [VoiceUsageSession] = []
        controller.onUsageSnapshot = { snapshots.append($0) }
        controller.start(); await settle()
        recorder.onAudio?(Data(repeating: 4, count: 32_000)); await settle()
        stream.onEvent?(.usage(VoiceUsage(inputTokens: 100, outputTokens: 20)))
        stream.onEvent?(.usage(VoiceUsage(inputTokens: 200, outputTokens: 40)))
        controller.cancel()
        controller.dispose()
        stream.onEvent?(.usage(VoiceUsage(inputTokens: 900, outputTokens: 900)))
        XCTAssertEqual(Set(snapshots.map(\.id)).count, 1)
        XCTAssertEqual(snapshots.filter { $0.outcome != "active" }.count, 1)
        XCTAssertEqual(snapshots.last?.outcome, "cancelled")
        XCTAssertEqual(snapshots.last?.duration, 1)
        XCTAssertEqual(snapshots.last?.words, 0)
        XCTAssertEqual(snapshots.last?.attempts.first?.usage?.inputTokens, 200)
    }

    func testPersonalizationIsFrozenPerRecordingAndCountsSpokenWords() async throws {
        let state = AppState(); state.voiceEnabled = true
        try state.personalization.addWord(written: "CacheManager", spoken: "cash manager")
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        var usage: VoiceUsageSession?
        controller.onUsageSnapshot = { usage = $0 }
        controller.start(); await settle()
        try state.personalization.addWord(written: "CacheStore", spoken: "cash store")
        try state.personalization.setStyle(.chat)
        stream.onEvent?(.ready)
        controller.finish(); await settle()
        stream.onEvent?(.text("cash manager.")); stream.onEvent?(.endpoint)
        stream.onEvent?(.turnComplete)
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(state.completedText, "cash manager.")
        XCTAssertEqual(state.originalTranscript, "cash manager.")
        XCTAssertEqual(usage?.words, 2)
        controller.dispose()
    }
    func testSnippetExpansionAndSalvagedCommandStayDistinct() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 1.5, authorize: { true })
        var usage: VoiceUsageSession?
        controller.onUsageSnapshot = { usage = $0 }
        controller.start(); await settle(); stream.onEvent?(.ready)
        controller.finish(); await settle()
        stream.onEvent?(.text("Insert snippet review request.")); stream.onEvent?(.endpoint)
        stream.onEvent?(.turnComplete)
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(state.completedText.hasPrefix("Please review this change"))
        XCTAssertEqual(usage?.words, 4)
        controller.start(); await settle(); stream.onEvent?(.ready)
        stream.onEvent?(.interim("insert snippet review request")); stream.onEvent?(.failure(.connection))
        XCTAssertEqual(state.completedText, "insert snippet review request")
        XCTAssertTrue(state.isRecoveredText)
        controller.dispose()
    }

    func testLockedCredentialDoesNotStartCaptureAndProvidesUnlockAction() {
        let state = AppState(); state.voiceEnabled = true; state.hasCredential = true
        let recorder = FakeCapture()
        let controller = VoiceController(state: state, recorder: recorder, credentialProvider: { nil }, authorize: { true })
        controller.start()
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertFalse(state.isActive)
        XCTAssertTrue(state.credentialNeedsApproval)
        XCTAssertEqual(state.lastError, VoiceFailure.keychain.localizedDescription)
    }

    func testEarlierFinalDoesNotEndRecordingAndDelayedTailSurvivesRelease() async {
        let state = AppState(); state.voiceEnabled = true
        let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: FakeCapture(), streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, authorize: { true })
        controller.start(); await settle(); stream.onEvent?(.ready)
        stream.onEvent?(.text("The first part.")); stream.onEvent?(.endpoint)
        stream.onEvent?(.interim("Keep the last"))
        controller.finish(); await settle()
        try? await Task.sleep(for: .milliseconds(1800))
        XCTAssertTrue(state.isTranscribing, "An earlier final must not close a lagging recording")
        stream.onEvent?(.interim("Keep the last four or five words"))
        try? await Task.sleep(for: .milliseconds(100))
        stream.onEvent?(.text("Keep the last four or five words.")); stream.onEvent?(.endpoint)
        stream.onEvent?(.turnComplete)
        XCTAssertEqual(state.completedText, "The first part. Keep the last four or five words.")
        XCTAssertFalse(state.isRecoveredText)
        controller.dispose()
    }
    func testNewTailCancelsQuietFallbackAndTimeoutMarksRecovery() async {
        let state = AppState(); state.voiceEnabled = true
        let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: FakeCapture(), streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, drainWait: 0.5, quietWait: 0.05, authorize: { true })
        controller.start(); await settle(); stream.onEvent?(.ready)
        controller.finish(); await settle()
        stream.onEvent?(.text("First segment")); stream.onEvent?(.endpoint)
        stream.onEvent?(.interim("unfinished tail"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isTranscribing)
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(state.completedText, "First segment unfinished tail")
        XCTAssertTrue(state.isRecoveredText)
        controller.dispose()
    }

    func testFastServerTurnReceiptWaitsForInputDrainInsteadOfBeingLost() async {
        let state = AppState(); state.voiceEnabled = true
        let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: FakeCapture(), streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, authorize: { true })
        controller.start(); await settle(); stream.onEvent?(.ready)
        controller.finish()
        stream.onEvent?(.text("Complete ending.")); stream.onEvent?(.endpoint); stream.onEvent?(.turnComplete)
        XCTAssertTrue(state.isTranscribing)
        await settle()
        XCTAssertTrue(stream.finished)
        XCTAssertEqual(state.completedText, "Complete ending.")
        XCTAssertFalse(state.isRecoveredText)
        controller.dispose()
    }

}
