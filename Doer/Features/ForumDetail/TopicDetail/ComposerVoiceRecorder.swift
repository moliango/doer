import AVFoundation
import UIKit

final class ComposerVoiceRecorderViewController: UIViewController {
    var onRecorded: ((URL) -> Void)?
    var onFailed: ((Error) -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var isRecording = false

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .headline)
        return label
    }()

    private let holdButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(String(localized: "reply.voice.hold", defaultValue: "按住说话"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.backgroundColor = AppSettings.shared.themeStyle.accentColor
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 28
        button.layer.cornerCurve = .continuous
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "reply.tool.media.voice", defaultValue: "语音消息")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        statusLabel.text = String(localized: "reply.voice.hint", defaultValue: "按住录音，松手上传")
        view.addSubview(statusLabel)
        view.addSubview(holdButton)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: holdButton.topAnchor, constant: -28),
            holdButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            holdButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            holdButton.widthAnchor.constraint(equalToConstant: 180),
            holdButton.heightAnchor.constraint(equalToConstant: 56),
        ])
        let press = UILongPressGestureRecognizer(target: self, action: #selector(holdChanged(_:)))
        press.minimumPressDuration = 0.15
        holdButton.addGestureRecognizer(press)
    }

    @objc private func closeTapped() {
        stopAndDiscard()
        dismiss(animated: true)
    }

    @objc private func holdChanged(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            Task { await startRecording() }
        case .ended:
            finishRecording()
        case .cancelled, .failed:
            stopAndDiscard()
            statusLabel.text = String(localized: "reply.voice.cancelled", defaultValue: "已取消")
        default:
            break
        }
    }

    private func startRecording() async {
        let granted = await requestMicrophone()
        guard granted else {
            let error = ComposerVoiceRecorderError.microphoneDenied
            onFailed?(error)
            presentError(error)
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("doer-voice-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            fileURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            isRecording = true
            statusLabel.text = String(localized: "reply.voice.recording", defaultValue: "正在录音…")
            holdButton.backgroundColor = .systemRed
        } catch {
            onFailed?(error)
            presentError(error)
        }
    }

    private func finishRecording() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        holdButton.backgroundColor = AppSettings.shared.themeStyle.accentColor
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else {
            statusLabel.text = String(localized: "reply.voice.hint", defaultValue: "按住录音，松手上传")
            return
        }
        let url = fileURL
        dismiss(animated: true) { [weak self] in
            self?.onRecorded?(url)
        }
    }

    private func stopAndDiscard() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
        holdButton.backgroundColor = AppSettings.shared.themeStyle.accentColor
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "reply.upload.failed"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }
}

enum ComposerVoiceRecorderError: Error, LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        String(localized: "reply.voice.mic_denied", defaultValue: "没有麦克风权限，无法录音")
    }
}
