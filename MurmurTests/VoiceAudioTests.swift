import XCTest
import AVFoundation
@testable import Murmur
import MurmurKit

final class VoiceAudioTests: XCTestCase {
    func testNativeStereoMicrophoneConversionProducesMono16kPCM() throws {
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800))
        input.frameLength = 4800
        let samples = try XCTUnwrap(input.floatChannelData)
        for frame in 0..<4800 {
            let value = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.2)
            samples[0][frame] = value
            samples[1][frame] = value
        }
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        let conversion = PCMConversion(converter: converter, target: target)
        let output = try XCTUnwrap(conversion.convert(input))
        let tail = conversion.finish() ?? Data()
        XCTAssertTrue(output.count.isMultiple(of: 2))
        XCTAssertTrue((3000...3300).contains(output.count + tail.count), "100ms of 16kHz mono int16 produced \(output.count) bytes plus \(tail.count) tail bytes")
        XCTAssertGreaterThan(VoiceAudio.level(output), 0.1)
    }
}
