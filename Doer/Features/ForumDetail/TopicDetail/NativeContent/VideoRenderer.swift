import AVKit
import CookedHTML
import SDWebImage
import UIKit

enum VideoRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .video = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .video(let url, let thumbnailURL, let title, let width, let height, _, let provider) = block else {
            return UIView()
        }
        if provider == "voice" || provider == "audio" {
            return VoiceMessageView(url: url, isVoice: provider == "voice")
        }

        let container = VideoCardView(
            url: url,
            thumbnailURL: thumbnailURL,
            title: title,
            width: width,
            height: height,
            containerWidth: config.contentWidth,
            titleFont: config.baseFont.withRelativeSize(-1).weighted(.medium)
        )
        container.delegate = delegate
        return container
    }
}

// MARK: - VideoCardView

final class VideoCardView: UIView {
    weak var delegate: PostCellDelegate?
    private let videoURL: String
    private let thumbnailImageView = UIImageView()
    private let titleFont: UIFont

    init(url: String, thumbnailURL: String?, title: String?, width: Int?, height: Int?, containerWidth: CGFloat, titleFont: UIFont) {
        self.videoURL = url
        self.titleFont = titleFont
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Thumbnail
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true
        thumbnailImageView.backgroundColor = .black
        addSubview(thumbnailImageView)

        layer.cornerRadius = 6
        clipsToBounds = true
        layer.borderWidth = 1.0 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.cgColor

        let imageH: CGFloat
        if let w = width, let h = height, w > 0 {
            imageH = containerWidth * CGFloat(h) / CGFloat(w)
        } else {
            imageH = containerWidth * 9.0 / 16.0
        }

        NSLayoutConstraint.activate([
            thumbnailImageView.topAnchor.constraint(equalTo: topAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            thumbnailImageView.heightAnchor.constraint(equalToConstant: imageH),
            thumbnailImageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let thumbnailURL, let thumbURL = URL(string: thumbnailURL) {
            ForumImageLoader.setImage(on: thumbnailImageView, url: thumbURL)
        }

        // Play button with shadow for contrast on any background
        let playButton = UIImageView()
        playButton.translatesAutoresizingMaskIntoConstraints = false
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 48, weight: .ultraLight)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, UIColor(white: 0, alpha: 0.5)]))
        playButton.image = UIImage(systemName: "play.circle.fill", withConfiguration: symbolConfig)
        playButton.contentMode = .center
        playButton.layer.shadowColor = UIColor.black.cgColor
        playButton.layer.shadowOpacity = 0.6
        playButton.layer.shadowRadius = 8
        playButton.layer.shadowOffset = .zero
        addSubview(playButton)

        NSLayoutConstraint.activate([
            playButton.centerXAnchor.constraint(equalTo: thumbnailImageView.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: thumbnailImageView.centerYAnchor),
        ])

        // Title overlay at top of thumbnail with gradient
        if let title, !title.isEmpty {
            let gradientContainer = UIView()
            gradientContainer.translatesAutoresizingMaskIntoConstraints = false
            gradientContainer.isUserInteractionEnabled = false
            addSubview(gradientContainer)

            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = titleFont
            titleLabel.textColor = .white
            titleLabel.numberOfLines = 2
            titleLabel.text = title
            titleLabel.layer.shadowColor = UIColor.black.cgColor
            titleLabel.layer.shadowOpacity = 0.8
            titleLabel.layer.shadowRadius = 2
            titleLabel.layer.shadowOffset = .zero
            gradientContainer.addSubview(titleLabel)

            NSLayoutConstraint.activate([
                gradientContainer.leadingAnchor.constraint(equalTo: thumbnailImageView.leadingAnchor),
                gradientContainer.trailingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor),
                gradientContainer.topAnchor.constraint(equalTo: thumbnailImageView.topAnchor),

                titleLabel.topAnchor.constraint(equalTo: gradientContainer.topAnchor, constant: 6),
                titleLabel.leadingAnchor.constraint(equalTo: gradientContainer.leadingAnchor, constant: 10),
                titleLabel.trailingAnchor.constraint(equalTo: gradientContainer.trailingAnchor, constant: -10),
                titleLabel.bottomAnchor.constraint(equalTo: gradientContainer.bottomAnchor, constant: -10),
            ])

            let gradient = CAGradientLayer()
            gradient.colors = [UIColor(white: 0, alpha: 0.6).cgColor, UIColor.clear.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradientContainer.layer.insertSublayer(gradient, at: 0)
            self.gradientLayer = gradient
        }

        // Tap gesture
        let tap = UITapGestureRecognizer(target: self, action: #selector(videoTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    private var gradientLayer: CAGradientLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer?.frame = gradientLayer?.superlayer?.bounds ?? .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func videoTapped() {
        guard let url = URL(string: videoURL) else { return }
        // Prefer native player with resume; fall back to link open if host missing.
        guard let host = findViewController() else {
            delegate?.postCell(didTapLinkURL: url)
            return
        }
        let player = DoerVideoPlayerViewController(url: url, sourceKey: videoURL)
        host.present(player, animated: true)
    }

    func cancelImageLoad() {
        thumbnailImageView.sd_cancelCurrentImageLoad()
    }

    private func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }
}

/// FluxDo-style in-app video player with position resume.
final class DoerVideoPlayerViewController: AVPlayerViewController {
    private let sourceKey: String
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    init(url: URL, sourceKey: String) {
        self.sourceKey = sourceKey
        super.init(nibName: nil, bundle: nil)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        if let resume = VideoPlaybackPositionStore.shared.position(for: sourceKey) {
            let time = CMTime(seconds: resume, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 1 else { return }
            VideoPlaybackPositionStore.shared.save(url: self.sourceKey, position: seconds)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            VideoPlaybackPositionStore.shared.clear(url: self.sourceKey)
        }
    }

    deinit {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let player, let seconds = player.currentTime().seconds as Double?,
           seconds.isFinite, seconds > 1 {
            VideoPlaybackPositionStore.shared.save(url: sourceKey, position: seconds)
        }
    }
}

/// Remember last playback position per URL (FluxDo resume).
final class VideoPlaybackPositionStore {
    static let shared = VideoPlaybackPositionStore()

    private let defaults: UserDefaults
    private let storageKey = "video.playback_position.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func position(for url: String) -> TimeInterval? {
        let map = load()
        guard let value = map[normalized(url)], value > 1 else { return nil }
        return value
    }

    func save(url: String, position: TimeInterval) {
        guard position > 1, position.isFinite else { return }
        var map = load()
        map[normalized(url)] = position
        if map.count > 400 {
            let trimmed = map.sorted { $0.value > $1.value }.prefix(300)
            map = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        defaults.set(map, forKey: storageKey)
    }

    func clear(url: String) {
        var map = load()
        map.removeValue(forKey: normalized(url))
        defaults.set(map, forKey: storageKey)
    }

    private func load() -> [String: Double] {
        (defaults.dictionary(forKey: storageKey) as? [String: Double]) ?? [:]
    }

    private func normalized(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

final class VoiceMessageView: UIView {
    private let url: String
    private var player: AVPlayer?
    private let playButton = UIButton(type: .system)

    init(url: String, isVoice: Bool) {
        self.url = url
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AppSettings.shared.themeStyle.accentColor.withAlphaComponent(0.12)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = AppSettings.shared.themeStyle.accentColor
        playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = isVoice
            ? String(localized: "post.voice.message", defaultValue: "语音")
            : String(localized: "post.audio.message", defaultValue: "音频")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        addSubview(playButton)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            playButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func togglePlay() {
        if player == nil, let resolved = URL(string: url) {
            player = AVPlayer(url: resolved)
        }
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        } else {
            player.play()
            playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        }
    }
}

private extension UIFont {
    func withRelativeSize(_ offset: CGFloat) -> UIFont {
        withSize(max(pointSize + offset, 1))
    }

    func weighted(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
