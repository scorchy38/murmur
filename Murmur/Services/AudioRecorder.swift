import AVFoundation

@MainActor
class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var recordingURL: URL?
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    func startRecording() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "murmur_recording_\(UUID().uuidString).m4a"
        recordingURL = tempDir.appendingPathComponent(fileName)

        guard let url = recordingURL else { return }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()

            startLevelMonitoring()

        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        stopLevelMonitoring()

        guard let recorder = audioRecorder else {
            completion(nil)
            return
        }

        recorder.stop()
        completion(recordingURL)
        audioRecorder = nil
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateAudioLevel()
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func updateAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }

        recorder.updateMeters()

        // Normalize dB to 0-1: speech typically falls between -50 and 0 dB
        let power = recorder.averagePower(forChannel: 0)
        let clamped = max(-50.0, min(0.0, power))
        let level = CGFloat((clamped + 50.0) / 50.0)

        appState?.updateAudioLevels(level)
    }
}
