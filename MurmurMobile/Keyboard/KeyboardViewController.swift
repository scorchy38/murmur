import UIKit
import AVFoundation
import MurmurKit

class KeyboardViewController: UIInputViewController {

    private var recordButton: UIButton!
    private var statusLabel: UILabel!
    private var waveformView: UIStackView!
    private var recorder: AudioRecorder?
    private var syncService: SyncService?
    private var isRecording = false
    private var isTranscribing = false
    private var audioLevels: [CGFloat] = Array(repeating: 0, count: 20)
    private var levelTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        recorder = AudioRecorder()
        syncService = SyncService(deviceName: "iPhoneKB")
        syncService?.start { _ in }
    }

    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground

        // Main container
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ])

        // Waveform
        waveformView = UIStackView()
        waveformView.axis = .horizontal
        waveformView.spacing = 2
        waveformView.alignment = .center
        waveformView.distribution = .fillEqually
        waveformView.isHidden = true

        for _ in 0..<20 {
            let bar = UIView()
            bar.backgroundColor = .systemRed
            bar.layer.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
            waveformView.addArrangedSubview(bar)
        }

        container.addArrangedSubview(waveformView)

        // Record button
        recordButton = UIButton(type: .system)
        recordButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        recordButton.tintColor = .white
        recordButton.backgroundColor = .systemRed
        recordButton.layer.cornerRadius = 30
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        recordButton.widthAnchor.constraint(equalToConstant: 60).isActive = true
        recordButton.heightAnchor.constraint(equalToConstant: 60).isActive = true
        recordButton.addTarget(self, action: #selector(recordTapped), for: .touchUpInside)
        container.addArrangedSubview(recordButton)

        // Status label
        statusLabel = UILabel()
        statusLabel.text = "Tap to dictate"
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        container.addArrangedSubview(statusLabel)

        // Set keyboard height
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 180)
        heightConstraint.priority = .required - 1
        heightConstraint.isActive = true
    }

    @objc private func recordTapped() {
        if isRecording {
            stopRecording()
        } else if !isTranscribing {
            startRecording()
        }
    }

    private func startRecording() {
        Task {
            let started = await recorder?.startRecording() ?? false
            await MainActor.run {
                if started {
                    isRecording = true
                    recordButton.setImage(UIImage(systemName: "stop.fill"), for: .normal)
                    statusLabel.text = "Recording... Tap to stop"
                    waveformView.isHidden = false
                    startWaveformAnimation()
                } else {
                    statusLabel.text = "Mic access needed"
                }
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        isTranscribing = true
        stopWaveformAnimation()
        waveformView.isHidden = true
        recordButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        statusLabel.text = "Transcribing..."

        Task {
            if let data = recorder?.stopRecording() {
                do {
                    let text = try await TranscriptionService.shared.transcribe(audioData: data)
                    let processed = TextProcessor.process(text)
                    await MainActor.run {
                        // Insert text at cursor
                        textDocumentProxy.insertText(processed)
                        // Send to Mac
                        let t = Transcription(text: processed, device: "iPhone Keyboard")
                        syncService?.send(t)
                        resetUI()
                    }
                } catch {
                    await MainActor.run {
                        statusLabel.text = "Error: \(error.localizedDescription)"
                        resetUI()
                    }
                }
            } else {
                await MainActor.run {
                    resetUI()
                }
            }
        }
    }

    private func resetUI() {
        isTranscribing = false
        recordButton.setImage(UIImage(systemName: "mic.fill"), for: .normal)
        statusLabel.text = "Tap to dictate"
    }

    private func startWaveformAnimation() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updateWaveform()
        }
    }

    private func stopWaveformAnimation() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func updateWaveform() {
        guard let recorder = recorder else { return }
        let levels = recorder.audioLevels

        for (index, bar) in waveformView.arrangedSubviews.enumerated() {
            let level = index < levels.count ? levels[index] : 0
            let height = max(4, level * 40)

            if let heightConstraint = bar.constraints.first(where: { $0.firstAttribute == .height }) {
                heightConstraint.constant = height
            }
        }

        UIView.animate(withDuration: 0.05) {
            self.waveformView.layoutIfNeeded()
        }
    }
}
