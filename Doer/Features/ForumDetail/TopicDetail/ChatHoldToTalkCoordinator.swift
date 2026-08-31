import AVFoundation
import UIKit

/// Hold-to-talk recording + Speech (zh-CN). Overlay is WeChat-inspired, not a clone.
@MainActor
final class ChatHoldToTalkCoordinator {
    var onTranscribed: ((String) -> Void)?
    var onActiveChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    private weak var host: UIViewController?
    private weak var hostView: UIView?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var fingerDown = false
    private var wantsCancel = false

    private lazy var overlay: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.addSubview(bubble)
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            bubble.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bubble.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            bubble.widthAnchor.constraint(equalToConstant: 168),
            bubble.heightAnchor.constraint(equalToConstant: 108),
            waveIcon.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            waveIcon.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            waveIcon.widthAnchor.constraint(equalToConstant: 72),
            waveIcon.heightAnchor.constraint(equalToConstant: 36),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        return view
    }()

    private let bubble: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor(red: 0.58, green: 0.91, blue: 0.45, alpha: 1)
        view.layer.cornerRadius = 18
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let waveIcon: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.tintColor = UIColor.black.withAlphaComponent(0.72)
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        view.image = UIImage(systemName: "waveform", withConfiguration: config)
        return view
    }()

    private let hintLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 2
        return label
    }()

    init() {
        bubble.addSubview(waveIcon)
    }

    func installOverlay(in host: UIViewController) {
        self.host = host
        let hostView = host.view!
        self.hostView = hostView
        guard overlay.superview !== hostView else { return }
        overlay.removeFromSuperview()
        hostView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: hostView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
        ])
    }

    func handle(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            fingerDown = true
            wantsCancel = false
            beginRecording()
        case .changed:
            guard recorder != nil || fingerDown else { return }
            let location = gesture.location(in: hostView ?? gesture.view)
            let midY = hostView?.bounds.midY ?? 0
            let cancel = location.y < midY
            if cancel != wantsCancel {
                wantsCancel = cancel
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            updateOverlay()
        case .ended:
            fingerDown = false
            if wantsCancel {
                cancel()
            } else {
                Task { await finish() }
            }
        case .cancelled, .failed:
            fingerDown = false
            cancel()
        default:
            break
        }
    }

    private func beginRecording() {
        guard fingerDown else { return }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .denied:
            fingerDown = false
            onError?(ComposerVoiceRecorderError.microphoneDenied)
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted, self.fingerDown {
                        self.startRecorder()
                    } else if !granted {
                        self.fingerDown = false
                        self.onError?(ComposerVoiceRecorderError.microphoneDenied)
                    }
                }
            }
        default:
            startRecorder()
        }
    }

    private func startRecorder() {
        guard fingerDown, recorder == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("doer-hold-\(UUID().uuidString)")
                .appendingPathExtension("m4a")
            fileURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            onActiveChange?(true)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            updateOverlay()
        } catch {
            fingerDown = false
            onError?(error)
        }
    }

    private func updateOverlay() {
        let recording = recorder != nil && fingerDown
        overlay.isHidden = !recording
        if recording {
            hostView?.bringSubviewToFront(overlay)
        }
        if wantsCancel {
            bubble.backgroundColor = UIColor(white: 0.62, alpha: 1)
            hintLabel.text = String(localized: "speech.release_cancel", defaultValue: "松开 取消")
        } else {
            bubble.backgroundColor = UIColor(red: 0.58, green: 0.91, blue: 0.45, alpha: 1)
            hintLabel.text = String(localized: "speech.release_transcribe", defaultValue: "松开 转成文字")
        }
    }

    private func finish() async {
        let recorder = recorder
        self.recorder = nil
        recorder?.stop()
        onActiveChange?(false)
        overlay.isHidden = true
        guard !wantsCancel,
              let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
            self.fileURL = nil
            return
        }
        self.fileURL = nil
        if let host {
            DoerFeedback.presentToast(
                String(localized: "speech.transcribing", defaultValue: "正在识别…"),
                on: host
            )
        }
        do {
            let text = try await ComposerSpeechTranscriber.transcribeChinese(fileURL: fileURL)
            onTranscribed?(text)
        } catch {
            onError?(error)
        }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func cancel() {
        recorder?.stop()
        recorder = nil
        wantsCancel = false
        onActiveChange?(false)
        overlay.isHidden = true
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        fileURL = nil
    }
}
