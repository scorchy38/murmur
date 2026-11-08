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
        try? await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(completed, ["rename CacheManager"])
        XCTAssertEqual(state.recordingState, .idle)
        XCTAssertTrue(stream.cancelled)
        controller.dispose()
    }

    func testCancellationRejectsAllLateCallbacksAndNeverCompletes() async {
        let state = AppState(); state.voiceEnabled = true
        let recorder = FakeCapture(); let stream = FakeStream()
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, authorize: { true })
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
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in FakeStream() }, credentialProvider: { "test" }, authorize: {
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
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, authorize: { true })
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
        }, credentialProvider: { "test" }, authorize: { true })
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
        }, credentialProvider: { "test" }, authorize: { true })
        controller.start(); await settle()
        let obsoleteCallback = streams[0].onEvent
        obsoleteCallback?(.failure(.connection))
        try? await Task.sleep(for: .milliseconds(320))
        obsoleteCallback?(.failure(.credentials))
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
        }, credentialProvider: { "test" }, authorize: { true })
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
        let controller = VoiceController(state: state, recorder: recorder, streamFactory: { _, _, _ in stream }, credentialProvider: { "test" }, authorize: { true })
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

}
