import UIKit
import AVFoundation
import MurmurKit

class KeyboardViewController: UIInputViewController {

    // MARK: - State

    private var recorder: AudioRecorder?
    private var syncService: SyncService?
    private var isRecording = false
    private var isTranscribing = false
    private var levelTimer: Timer?
    private var recordingStart: Date?

    // MARK: - UI

    private var waveformView: UIStackView!
    private var actionButton: UIButton!
    private var statusLabel: UILabel!
    private var timeLabel: UILabel!
    private var spinner: UIActivityIndicatorView!
    private var displayLink: CADisplayLink?

    private let barCount = MurmurTokens.Sizing.waveformBarCount

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        recorder = AudioRecorder()
        syncService = SyncService(deviceName: "iPhoneKB")
        syncService?.start { _ in }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isRecording {
            stopWaveformAnimation()
            recorder?.stopRecording()
            isRecording = false
        }
    }

    // MARK: - UI Setup

    private func setupUI() {
        // ── Main container ──
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        // ── Waveform (fixed-height container prevents layout bounce) ──
        let waveformContainer = UIView()
        waveformContainer.translatesAutoresizingMaskIntoConstraints = false
        waveformContainer.heightAnchor.constraint(equalToConstant: MurmurTokens.Sizing.waveformMaxHeight).isActive = true

        waveformView = UIStackView()
        waveformView.axis = .horizontal
        waveformView.spacing = MurmurTokens.Sizing.waveformBarSpacing
        waveformView.alignment = .center
        waveformView.distribution = .fillEqually
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.alpha = 0

        waveformContainer.addSubview(waveformView)
        NSLayoutConstraint.activate([
            waveformView.centerXAnchor.constraint(equalTo: waveformContainer.centerXAnchor),
            waveformView.centerYAnchor.constraint(equalTo: waveformContainer.centerYAnchor),
        ])

        for _ in 0..<barCount {
            let bar = UIView()
            bar.backgroundColor = UIColor(MurmurTokens.waveformTint)
            bar.layer.cornerRadius = MurmurTokens.Sizing.waveformBarWidth / 2
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: MurmurTokens.Sizing.waveformBarWidth).isActive = true
            bar.heightAnchor.constraint(equalToConstant: MurmurTokens.Sizing.waveformMinBarHeight).isActive = true
            waveformView.addArrangedSubview(bar)
        }
        container.addArrangedSubview(waveformContainer)

        // ── Time label ──
        timeLabel = UILabel()
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 28, weight: .medium)
        timeLabel.textColor = UIColor(MurmurTokens.accent)
        timeLabel.text = "0:00"
        timeLabel.alpha = 0
        container.addArrangedSubview(timeLabel)

        // ── Status label ──
        statusLabel = UILabel()
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "Tap to dictate"
        container.addArrangedSubview(statusLabel)

        // ── Spinner (for transcribing state) ──
        spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = UIColor(MurmurTokens.accent)
        spinner.hidesWhenStopped = true
        container.addArrangedSubview(spinner)

        // ── Action button ──
        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.cornerStyle = .capsule
        buttonConfig.baseBackgroundColor = UIColor(MurmurTokens.accent)
        buttonConfig.baseForegroundColor = .white
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24)
        buttonConfig.image = UIImage(systemName: MurmurTokens.Symbol.micIdle, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        buttonConfig.imagePadding = 6
        buttonConfig.attributedTitle = AttributedString("Dictate", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))

        actionButton = UIButton(configuration: buttonConfig)
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        container.addArrangedSubview(actionButton)

        // ── Keyboard height ──
        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 260)
        heightConstraint.priority = .required - 1
        heightConstraint.isActive = true
    }

    // MARK: - Actions

    @objc private func actionTapped() {
        if isRecording {
            stopRecording()
        } else if !isTranscribing {
            startRecording()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        Task {
            let started = await recorder?.startRecording() ?? false
            await MainActor.run {
                if started {
                    isRecording = true
                    recordingStart = Date()
                    transitionToRecording()
                    startWaveformAnimation()
                } else {
                    statusLabel.text = "Microphone access needed"
                    statusLabel.textColor = .systemOrange
                }
            }
        }
    }

    private func stopRecording() {
        isRecording = false
        stopWaveformAnimation()
        transitionToTranscribing()

        Task {
            if let data = recorder?.stopRecording() {
                do {
                    let text = try await TranscriptionService.shared.transcribe(audioData: data)
                    let processed = TextProcessor.process(text)
                    await MainActor.run {
                        textDocumentProxy.insertText(processed)
                        let t = Transcription(text: processed, device: "iPhone Keyboard")
                        // Write to shared store so iOS app sees it
                        let store = MurmurStore()
                        store.addTranscription(t)
                        // Sync to other devices
                        syncService?.send(t)
                        transitionToIdle()
                    }
                } catch {
                    await MainActor.run {
                        statusLabel.text = error.localizedDescription
                        statusLabel.textColor = .systemOrange
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                            self?.transitionToIdle()
                        }
                    }
                }
            } else {
                await MainActor.run { transitionToIdle() }
            }
        }
    }

    // MARK: - State transitions

    private func transitionToRecording() {
        // Button becomes "Done"
        var config = actionButton.configuration!
        config.image = UIImage(systemName: MurmurTokens.Symbol.stop, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.attributedTitle = AttributedString("Done", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        actionButton.configuration = config

        statusLabel.text = "Listening..."
        statusLabel.textColor = .secondaryLabel
        spinner.stopAnimating()

        UIView.animate(withDuration: 0.3) {
            self.waveformView.alpha = 1
            self.timeLabel.alpha = 1
        }

        startTimeDisplay()
    }

    private func transitionToTranscribing() {
        var config = actionButton.configuration!
        config.image = nil
        config.attributedTitle = AttributedString("Transcribing", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        config.baseBackgroundColor = UIColor(MurmurTokens.accent).withAlphaComponent(0.5)
        actionButton.configuration = config
        actionButton.isEnabled = false

        statusLabel.text = ""
        spinner.startAnimating()
        stopTimeDisplay()

        UIView.animate(withDuration: 0.3) {
            self.waveformView.alpha = 0
            self.timeLabel.alpha = 0
        }
    }

    private func transitionToIdle() {
        isTranscribing = false
        actionButton.isEnabled = true

        var config = actionButton.configuration!
        config.image = UIImage(systemName: MurmurTokens.Symbol.micIdle, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        config.attributedTitle = AttributedString("Dictate", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .semibold)]))
        config.baseBackgroundColor = UIColor(MurmurTokens.accent)
        actionButton.configuration = config

        statusLabel.text = "Tap to dictate"
        statusLabel.textColor = .secondaryLabel
        spinner.stopAnimating()

        UIView.animate(withDuration: 0.3) {
            self.waveformView.alpha = 0
            self.timeLabel.alpha = 0
        }

        stopTimeDisplay()
        recordingStart = nil
    }

    // MARK: - Elapsed time

    private func startTimeDisplay() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateTime))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: 1)
        displayLink?.add(to: .main, forMode: .common)
    }

    private func stopTimeDisplay() {
        displayLink?.invalidate()
        displayLink = nil
        timeLabel.text = "0:00"
    }

    @objc private func updateTime() {
        guard let start = recordingStart else { return }
        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        timeLabel.text = String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: - Waveform

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
            let height = max(MurmurTokens.Sizing.waveformMinBarHeight, level * MurmurTokens.Sizing.waveformMaxHeight)

            if let heightConstraint = bar.constraints.first(where: { $0.firstAttribute == .height }) {
                heightConstraint.constant = height
            }
        }

        UIView.animate(withDuration: 0.05) {
            self.waveformView.layoutIfNeeded()
        }
    }
}
