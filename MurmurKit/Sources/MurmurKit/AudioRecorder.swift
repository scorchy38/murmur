import AVFoundation
import Foundation

@MainActor
public class AudioRecorder: NSObject, ObservableObject {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?

    @Published public var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    private var levelTimer: Timer?

    public override init() {
        super.init()
    }

    public func startRecording() async -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur_\(UUID().uuidString).m4a")
        recordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        #if os(iOS) || os(watchOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)
        } catch {
            print("[Murmur] Audio session error: \(error)")
            return false
        }
        #endif

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.isMeteringEnabled = true
            recorder?.record()
            startLevelMonitoring()
            return true
        } catch {
            print("[Murmur] Recording error: \(error)")
            return false
        }
    }

    public func stopRecording() -> Data? {
        stopLevelMonitoring()
        recorder?.stop()
        recorder = nil

        guard let url = recordingURL else { return nil }
        defer {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }

        return try? Data(contentsOf: url)
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateLevel()
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevels = Array(repeating: 0, count: 30)
    }

    private func updateLevel() {
        guard let r = recorder, r.isRecording else { return }
        r.updateMeters()
        // Normalize dB to 0-1: speech typically falls between -50 and 0 dB
        let power = r.averagePower(forChannel: 0)
        let clamped = max(-50.0, min(0.0, power))
        let level = CGFloat((clamped + 50.0) / 50.0)
        audioLevels.removeFirst()
        audioLevels.append(level)
    }
}
