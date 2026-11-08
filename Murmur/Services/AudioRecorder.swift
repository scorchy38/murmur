import AVFoundation
import MurmurKit

@MainActor
protocol VoiceCapturing: AnyObject {
    func start(onAudio: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable () -> Void) throws
    @discardableResult func stop() -> Data?
}

/// Native audio is converted at the microphone boundary; no recording file is created.
@MainActor
final class AudioRecorder: VoiceCapturing {
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var pipeline: CapturePipeline?

    func start(onAudio: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable () -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target) else { throw VoiceFailure.device }
        let conversion = PCMConversion(converter: converter, target: target)
        let pipeline = CapturePipeline(conversion: conversion, onAudio: onAudio, onError: onError)
        self.pipeline = pipeline
        input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
            pipeline.accept(buffer)
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { _ in onError() }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw VoiceFailure.device
        }
    }

    @discardableResult func stop() -> Data? {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let tail = pipeline?.finish()
        pipeline = nil
        return tail
    }

    static func probe() async throws {
        let recorder = AudioRecorder()
        let evidence = ProbeEvidence()
        defer { recorder.stop() }
        try recorder.start { data in
            Task { await evidence.audio(data) }
        } onError: {
            Task { await evidence.failed() }
        }
        try await Task.sleep(for: .milliseconds(250))
        guard await evidence.usable else { throw VoiceFailure.device }
    }
}

private actor ProbeEvidence {
    private var bytes = 0
    private var error = false
    var usable: Bool { bytes > 0 && !error }
    func audio(_ data: Data) { bytes += data.count }
    func failed() { error = true }
}

/// Used exclusively by the serial input-tap callback, never shared with the UI.
final class PCMConversion: @unchecked Sendable {
    let converter: AVAudioConverter
    let target: AVAudioFormat
    init(converter: AVAudioConverter, target: AVAudioFormat) { self.converter = converter; self.target = target }
    func convert(_ input: AVAudioPCMBuffer) throws -> Data? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw VoiceFailure.device }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard error == nil, status != .error else { throw VoiceFailure.device }
        guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }

    func finish() -> Data? {
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return nil }
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, state in
            state.pointee = .endOfStream
            return nil
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}

/// Stop waits for an in-flight tap delivery before flushing the resampler tail.
/// The lock protects audio conversion and callback ordering, never UI operations.
private final class CapturePipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let conversion: PCMConversion
    private let onAudio: @Sendable (Data) -> Void
    private let onError: @Sendable () -> Void
    private var stopped = false
    init(conversion: PCMConversion, onAudio: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable () -> Void) {
        self.conversion = conversion; self.onAudio = onAudio; self.onError = onError
    }
    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !stopped else { return }
            do {
                if let data = try conversion.convert(buffer), !data.isEmpty { onAudio(data) }
            } catch { onError() }
        }
    }
    func finish() -> Data? {
        lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return conversion.finish()
        }
    }
}
