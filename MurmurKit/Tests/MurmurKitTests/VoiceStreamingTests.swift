import XCTest
@testable import MurmurKit

@MainActor
private final class SpeechSocket: VoiceSocketTransport {
    var statusCode: Int? = 101
    var closeCode = 1000
    var written = Data()
    var turnSizes: [Int] = []
    var currentSize = 0
    var starts = 0
    var finals = 0
    var cancelled = false
    var automaticallyFinalize = true
    var finalDelay: Duration = .zero
    var finalTexts: [String]?
    var earlyFinalAtByte: Int?
    var accepted = Data()
    private var earlyFinalEmitted = false
    private var acceptingAudio = true
    var markerAtAudioByte: Int?
    private var markerEmitted = false
    private var queued: [Data] = []
    private var reader: CheckedContinuation<Data, Error>?
    func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        if let reader { self.reader = nil; reader.resume(returning: data) }
        else { queued.append(data) }
    }
    func send(_ data: Data) async throws {
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if value["setup"] != nil { emit(["setupComplete": [:]]) }
        if let input = value["realtimeInput"] as? [String: Any] {
            if input["activityStart"] != nil { starts += 1; acceptingAudio = true }
            if let audio = input["audio"] as? [String: String], let bytes = Data(base64Encoded: audio["data"]!) {
                written.append(bytes)
                guard acceptingAudio else { return }
                accepted.append(bytes); currentSize += bytes.count
                emit(["serverContent": ["interimInputTranscription": ["text": "segment \(starts)"]]])
                if let earlyFinalAtByte, accepted.count >= earlyFinalAtByte, !earlyFinalEmitted {
                    earlyFinalEmitted = true; acceptingAudio = false
                    currentSize = 0
                    emit(["serverContent": ["inputTranscription": ["text": "First paragraph.", "finished": true, "endOffset": "0.00025s"]]])
                }
                if let markerAtAudioByte, written.count >= markerAtAudioByte, !markerEmitted {
                    markerEmitted = true
                    emit(["serverContent": ["turnComplete": true]])
                }
            }
            if input["activityEnd"] != nil {
                turnSizes.append(currentSize); currentSize = 0
                if automaticallyFinalize {
                    let segment = starts
                    Task {
                        try? await Task.sleep(for: finalDelay)
                        guard !cancelled else { return }
                        finals += 1
                        let text = finalTexts.flatMap { $0.indices.contains(segment - 1) ? $0[segment - 1] : nil } ?? "Segment \(segment)."
                        emit(["serverContent": ["inputTranscription": ["text": text]]])
                    }
                }
            }
        }
    }
    func receive() async throws -> Data {
        if !queued.isEmpty { return queued.removeFirst() }
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }
    func ping() async throws {}
    func cancel() { cancelled = true; reader?.resume(throwing: CancellationError()); reader = nil }
}

@MainActor
final class VoiceStreamingTests: XCTestCase {
    private func settle() async { for _ in 0..<25 { await Task.yield() } }
    private func make(_ socket: SpeechSocket) -> NativeVoiceStream {
        let stream = NativeVoiceStream(credential: "synthetic", language: "en", vocabulary: [], keepaliveEnabled: false, recoverEarlyFinals: true)
        stream.transportFactory = { _ in socket }
        return stream
    }

    func testEightMinutesUsesOneContinuousTurnAndNeverFinalizesBeforeRelease() async {
        let socket = SpeechSocket(), stream = make(socket)
        socket.markerAtAudioByte = VoiceAudio.bytesPerSecond * 210
        var transcript = VoiceTranscript(), finished = 0
        var progress: VoiceStreamProgress?
        stream.onEvent = { event in
            transcript.accept(event)
            if case .progress(let sample) = event { progress = sample }
            if event == .finalized { finished += 1 }
        }
        stream.start(); await settle()
        var expected = Data()
        for second in 0..<480 {
            let bytes = Data(repeating: UInt8(second % 251), count: VoiceAudio.bytesPerSecond)
            expected.append(bytes); stream.send(bytes)
        }
        for _ in 0..<300 { if socket.written.count == expected.count { break }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(socket.written, expected)
        XCTAssertEqual(socket.starts, 1)
        XCTAssertTrue(socket.turnSizes.isEmpty, "No activityEnd while Shift remains held")
        XCTAssertEqual(finished, 0)
        stream.finish()
        for _ in 0..<100 { if finished > 0 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(socket.turnSizes, [expected.count])
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(progress?.sentAudioBytes, expected.count)
        XCTAssertEqual(progress?.turnCompleteMessages, 1)
        XCTAssertEqual(progress?.finalMessages, 1)
        XCTAssertEqual(progress?.interimMessages, 480)
        XCTAssertEqual(transcript.preview, "Segment 1.")
        stream.cancel()
    }
    func testReleaseDrainsQueuedAudioBeforeSingleActivityEnd() async {
        let socket = SpeechSocket(), stream = make(socket)
        var events: [VoiceEvent] = []
        stream.onEvent = { events.append($0) }
        stream.start(); await settle()
        let audio = Data(0..<26)
        stream.send(audio); stream.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(socket.written, audio)
        XCTAssertEqual(socket.turnSizes, [26])
        XCTAssertEqual(events.filter { $0 == .inputClosed }.count, 1)
        XCTAssertEqual(events.filter { $0 == .finalized }.count, 1)
        stream.cancel()
    }
    func testTimeoutIsArmedOnlyAfterReleaseAndPreservesFailureSignal() async {
        let socket = SpeechSocket(), stream = make(socket)
        socket.automaticallyFinalize = false
        stream.finalizationTimeout = 0.05
        var events: [VoiceEvent] = []
        stream.onEvent = { events.append($0) }
        stream.start(); await settle(); stream.send(Data(repeating: 1, count: 3200))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(events.contains(.failure(.connection)))
        XCTAssertTrue(socket.turnSizes.isEmpty)
        stream.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(events.contains(.failure(.connection)))
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(events.contains(.finalized))
    }
    func testFinalReceiptCompletesWithoutTurnCompleteOrQuietDelay() async {
        let socket = SpeechSocket(), stream = make(socket)
        var done = false
        stream.onEvent = { if $0 == .finalized { done = true } }
        stream.start(); await settle()
        stream.send(Data(repeating: 1, count: 3200)); stream.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(done)
        stream.cancel()
    }
    func testReleaseBeforeSetupDrainsQueuedAudioAndFinalizesExactlyOnce() async {
        let socket = SpeechSocket(), stream = make(socket)
        var events: [VoiceEvent] = []
        stream.onEvent = { events.append($0) }
        stream.start()
        let audio = Data(0..<18)
        stream.send(audio); stream.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(socket.written, audio)
        XCTAssertEqual(events.filter { $0 == .finalized }.count, 1)
        XCTAssertEqual(events.filter { $0 == .inputClosed }.count, 1)
        stream.cancel()
    }
    func testTelemetrySeparatesUnchangedInterimsFromTextProgressAndExcludesErrorMessages() async throws {
        let socket = SpeechSocket(), stream = make(socket)
        var progress: VoiceStreamProgress?
        var failure: VoiceTransportFailure?
        stream.onEvent = { event in
            if case .progress(let value) = event { progress = value }
            if case .transportFailure(let value) = event { failure = value }
        }
        stream.start(); await settle()
        socket.emit(["serverContent": ["interimInputTranscription": ["text": "same"]]])
        await settle()
        try? await Task.sleep(for: .milliseconds(30))
        socket.emit(["serverContent": ["interimInputTranscription": ["text": "same"]]])
        await settle()
        try? await Task.sleep(for: .milliseconds(30))
        socket.emit(["serverContent": ["interimInputTranscription": ["text": "same"]]])
        await settle()
        try? await Task.sleep(for: .milliseconds(30))
        socket.emit(["serverContent": ["interimInputTranscription": ["text": "same plus new words"]]])
        await settle()
        socket.emit(["error": ["code": 429, "message": "do-not-log-this-secret-error"]])
        await settle()
        XCTAssertEqual(progress?.unchangedInterimMessages, 2)
        XCTAssertGreaterThan(progress?.largestTranscriptChangeGapSeconds ?? 0, 0.06)
        XCTAssertEqual(failure?.providerErrorCode, 429)
        let data = try JSONEncoder().encode(failure)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("do-not-log-this-secret-error"))
        stream.cancel()
    }

    func testProviderFinalWhileHoldingResumesAudioWithoutTimedClientEnd() async {
        let socket = SpeechSocket(), stream = make(socket)
        socket.earlyFinalAtByte = 8; socket.finalTexts = ["First paragraph.", "Last words."]
        var transcript = VoiceTranscript(), done = false, boundaries: [VoiceProviderBoundary] = []
        stream.onEvent = { event in
            transcript.accept(event)
            if case .providerBoundary(let value) = event { boundaries.append(value) }
            if event == .finalized { done = true }
        }
        stream.start(); await settle()
        stream.send(Data(0..<8)); await settle()
        XCTAssertFalse(done)
        XCTAssertTrue(socket.turnSizes.isEmpty)
        XCTAssertEqual(transcript.preview, "First paragraph.")
        stream.send(Data(8..<24)); await settle()
        XCTAssertEqual(socket.starts, 2, "Resume only because the provider actually finalized its turn")
        XCTAssertTrue(socket.turnSizes.isEmpty, "Murmur must not manufacture an activityEnd while held")
        XCTAssertEqual(socket.accepted, Data(0..<24))
        stream.finish(); try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(done)
        XCTAssertEqual(socket.turnSizes.count, 1)
        XCTAssertEqual(transcript.preview, "First paragraph. Last words.")
        let early = boundaries.first { $0.transcriptionPresent }
        XCTAssertEqual(early?.clientFinishRequested, false)
        XCTAssertEqual(early?.endOffsetSeconds, 0.00025)
        stream.cancel()
    }
    func testReleaseImmediatelyAfterProviderFinalDoesNotWaitForAnotherFinal() async {
        let socket = SpeechSocket(), stream = make(socket)
        socket.earlyFinalAtByte = 8
        var done = false
        stream.onEvent = { if $0 == .finalized { done = true } }
        stream.start(); await settle(); stream.send(Data(0..<8)); await settle()
        stream.finish(); await settle()
        XCTAssertTrue(done)
        XCTAssertEqual(socket.starts, 1)
        XCTAssertTrue(socket.turnSizes.isEmpty)
        stream.cancel()
    }

    func testQueuedTailStillDrainsWhenReleaseRacesServerFinalRecovery() async {
        let socket = SpeechSocket(), stream = make(socket)
        socket.earlyFinalAtByte = 8; socket.finalTexts = ["First paragraph.", "Tail preserved."]
        var transcript = VoiceTranscript(), completed = 0
        stream.onEvent = { event in transcript.accept(event); if event == .finalized { completed += 1 } }
        stream.start(); await settle(); stream.send(Data(0..<8)); await settle()
        socket.emit(["serverContent": ["inputTranscription": ["text": "First paragraph.", "finished": true]]])
        await settle()
        stream.send(Data(8..<32)); stream.finish()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(socket.starts, 2)
        XCTAssertEqual(socket.accepted, Data(0..<32))
        XCTAssertEqual(completed, 1)
        XCTAssertEqual(transcript.preview, "First paragraph. Tail preserved.")
        stream.cancel()
    }

}
