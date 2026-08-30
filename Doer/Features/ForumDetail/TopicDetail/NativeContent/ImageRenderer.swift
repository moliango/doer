import CookedHTML
import SDWebImage
import UIKit

// MARK: - TappableImageContainer

final class TappableImageContainer: UIView {
    /// URL used when tapped — prefers the full-size href over the img src.
    var imageURL: URL?
    var galleryImageURLs: [URL] = []
    weak var delegate: PostCellDelegate?

    private let imageView: SDAnimatedImageView = {
        let iv = SDAnimatedImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private var imageHeightConstraint: NSLayoutConstraint!
    private var imageWidthConstraint: NSLayoutConstraint!

    /// Discourse renders images at a reference width of 690px.
    /// Images narrower than this are displayed proportionally smaller on screen.
    private static let referenceWidth: CGFloat = 690

    private let refererBaseURL: String?
    private let sourceURL: URL
    private let loadContainerWidth: CGFloat
    private let loadHasOriginalSize: Bool
    private var didFailLoad = false
    /// True only after a real bitmap was painted (not the retry glyph).
    private var hasDisplayedImage = false
    private var loadGeneration = 0
    private var loadTimeoutWorkItem: DispatchWorkItem?
    private var gateResumeObserver: NSObjectProtocol?

    init(
        url: URL,
        width: Int?,
        height: Int?,
        containerWidth: CGFloat,
        href: URL? = nil,
        galleryImageURLs: [URL] = [],
        refererBaseURL: String? = nil
    ) {
        imageURL = href ?? url
        self.galleryImageURLs = galleryImageURLs
        self.refererBaseURL = refererBaseURL
        self.sourceURL = url
        self.loadContainerWidth = containerWidth
        self.loadHasOriginalSize = width != nil && height != nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)

        gateResumeObserver = NotificationCenter.default.addObserver(
            forName: CloudflareImageGate.didResumeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.didFailLoad else { return }
            if let base = note.userInfo?[CloudflareImageGate.resumedBaseURLKey] as? String,
               let referer = self.refererBaseURL {
                let a = CloudflareImageGate.normalizedKey(base)
                let b = CloudflareImageGate.normalizedKey(referer)
                // Only auto-retry when the resumed forum matches this image's forum.
                guard a == b || a.contains(b) || b.contains(a) else { return }
            }
            self.loadImage(
                url: self.sourceURL,
                containerWidth: self.loadContainerWidth,
                hasOriginalSize: self.loadHasOriginalSize,
                forceRetry: true
            )
        }

        let displayWidth: CGFloat
        let displayHeight: CGFloat
        if let w = width, let h = height, w > 0, h > 0 {
            let fraction = min(CGFloat(w) / Self.referenceWidth, 1)
            var width = containerWidth * fraction
            var height = CGFloat(h) * (width / CGFloat(w))
            // Very small Discourse thumbs become invisible slivers in chat bubbles.
            // Keep a readable minimum while preserving aspect ratio.
            let minSide: CGFloat = 36
            if width < minSide || height < minSide {
                let scale = max(minSide / max(width, 1), minSide / max(height, 1))
                width = min(width * scale, containerWidth)
                height = CGFloat(h) * (width / CGFloat(w))
                if height < minSide {
                    height = minSide
                    width = min(CGFloat(w) * (height / CGFloat(h)), containerWidth)
                }
            }
            displayWidth = width
            displayHeight = height
        } else {
            displayWidth = containerWidth
            displayHeight = containerWidth * 9.0 / 16.0
        }

        let isFullWidth = displayWidth >= containerWidth

        if isFullWidth {
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                imageView.topAnchor.constraint(equalTo: topAnchor),
                imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
                imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        imageWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: displayWidth)
        imageWidthConstraint.isActive = !isFullWidth
        imageHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: displayHeight)
        imageHeightConstraint.isActive = true

        backgroundColor = isFullWidth ? .tertiarySystemGroupedBackground : .clear
        layer.cornerRadius = isFullWidth ? 10 : 0
        layer.cornerCurve = .continuous
        clipsToBounds = isFullWidth
        imageView.backgroundColor = ImagePaintPolicy.waitingFillColor
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true

        // Pause GIF animation by default; resumed when visible on screen
        imageView.autoPlayAnimatedImage = false

        loadImage(url: url, containerWidth: containerWidth, hasOriginalSize: loadHasOriginalSize)

        let tap = UITapGestureRecognizer(target: self, action: #selector(imageTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
        accessibilityHint = String(
            localized: "topic.image.retry_hint",
            defaultValue: "加载失败时可点按重试"
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTimeoutWorkItem?.cancel()
        if let gateResumeObserver {
            NotificationCenter.default.removeObserver(gateResumeObserver)
        }
    }

    private func loadImage(
        url: URL,
        containerWidth: CGFloat,
        hasOriginalSize: Bool,
        forceRetry: Bool = false
    ) {
        loadTimeoutWorkItem?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        imageView.sd_cancelCurrentImageLoad()
        ImagePaintPolicy.prepareForLoad(on: imageView)

        if !forceRetry, let cached = AvatarImageLoader.cachedImageIfAvailable(for: url) {
            applyLoadResult(
                cached,
                generation: generation,
                containerWidth: containerWidth,
                hasOriginalSize: hasOriginalSize,
                source: .memory
            )
            return
        }

        didFailLoad = false
        if imageView.image == nil {
            imageView.backgroundColor = ImagePaintPolicy.waitingFillColor
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
        }
        hasDisplayedImage = hasDisplayedImage && imageView.image != nil

        // If nothing arrives in time, flip to tap-to-retry instead of an endless gray tile
        // (which made taps open the gallery / do nothing).
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.loadGeneration == generation, !self.hasDisplayedImage else { return }
            self.applyLoadResult(
                nil,
                generation: generation,
                containerWidth: containerWidth,
                hasOriginalSize: hasOriginalSize,
                source: .network
            )
        }
        loadTimeoutWorkItem = timeout
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 18_000_000_000)
            timeout.perform()
        }

        // Topic body images always use ExternalImageFetcher:
        // - attaches forum cookies for main host + upload CDN
        // - never hits SDWebImage's process-local failed-URL blacklist
        // - forceRetry bypasses CF gate + URLCache + stuck inflight coalescing
        ExternalImageFetcher.fetch(
            url: url,
            refererBaseURL: refererBaseURL,
            forceRetry: forceRetry
        ) { [weak self] image in
            self?.applyLoadResult(
                image,
                generation: generation,
                containerWidth: containerWidth,
                hasOriginalSize: hasOriginalSize,
                source: .network
            )
        }
    }

    private func applyLoadResult(
        _ image: UIImage?,
        generation: Int,
        containerWidth: CGFloat,
        hasOriginalSize: Bool,
        source: ImagePaintCacheSource
    ) {
        guard generation == loadGeneration else { return }
        loadTimeoutWorkItem?.cancel()
        loadTimeoutWorkItem = nil

        guard let image else {
            didFailLoad = true
            hasDisplayedImage = false
            imageView.backgroundColor = .tertiarySystemFill
            imageView.contentMode = .center
            let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            imageView.image = UIImage(
                systemName: "arrow.clockwise.circle",
                withConfiguration: config
            )
            imageView.tintColor = .tertiaryLabel
            accessibilityLabel = String(
                localized: "topic.image.load_failed",
                defaultValue: "图片加载失败，点按重试"
            )
            if imageHeightConstraint.constant < 72 {
                imageHeightConstraint.constant = 72
                invalidateIntrinsicContentSize()
                superview?.setNeedsLayout()
                notifyPostCellHeightChanged()
            }
            return
        }

        didFailLoad = false
        hasDisplayedImage = true
        accessibilityLabel = nil
        imageView.contentMode = .scaleAspectFit
        ImagePaintPolicy.paint(image, on: imageView, source: source)
        if image.size.width > 1, image.size.height > 1 {
            let targetWidth = max(
                imageWidthConstraint.isActive ? imageWidthConstraint.constant : containerWidth,
                1
            )
            let newHeight = image.size.height * (targetWidth / image.size.width)
            let current = max(imageHeightConstraint.constant, 1)
            let delta = abs(newHeight - current)
            let relative = delta / current
            let shouldResize: Bool
            if hasOriginalSize {
                shouldResize = delta > 14 && relative > 0.18
            } else {
                shouldResize = delta > 12 && relative > 0.10
            }
            if shouldResize {
                imageHeightConstraint.constant = max(newHeight, 24)
                invalidateIntrinsicContentSize()
                superview?.setNeedsLayout()
                notifyPostCellHeightChanged()
            }
        }
    }

    @objc private func imageTapped() {
        // No successful bitmap yet (failed, loading, or timed out) → force network retry.
        // Previously only `didFailLoad` retried; gray "still loading" tiles opened gallery.
        if didFailLoad || !hasDisplayedImage {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            loadImage(
                url: sourceURL,
                containerWidth: loadContainerWidth,
                hasOriginalSize: loadHasOriginalSize,
                forceRetry: true
            )
            return
        }
        guard let imageURL else { return }
        let imageURLs = galleryImageURLs.isEmpty ? [imageURL] : galleryImageURLs
        delegate?.postCell(didTapImageURL: imageURL, imageURLs: imageURLs, sourceView: imageView)
    }

    func cancelImageLoad() {
        loadTimeoutWorkItem?.cancel()
        loadTimeoutWorkItem = nil
        loadGeneration += 1
        imageView.sd_cancelCurrentImageLoad()
    }

    /// Bubble size changes up to `PostNativeCell` so row height updates coalesce
    /// instead of each image calling `beginUpdates` independently.
    private func notifyPostCellHeightChanged() {
        var view: UIView? = superview
        while let current = view {
            if let cell = current as? PostNativeCell {
                cell.requestHeightReconciliation()
                return
            }
            if let cell = current as? WeChatChatPostCell {
                cell.requestHeightReconciliation()
                return
            }
            if let tableView = current as? UITableView {
                tableView.doer_invalidateSelfSizingRows()
                return
            }
            view = current.superview
        }
    }

    // MARK: - GIF Animation Control

    private var animationsSuspended = false

    func startAnimating() {
        animationsSuspended = false
        imageView.autoPlayAnimatedImage = true
        imageView.startAnimating()
    }

    func stopAnimating() {
        animationsSuspended = true
        imageView.autoPlayAnimatedImage = false
        imageView.stopAnimating()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, !animationsSuspended {
            imageView.startAnimating()
        } else {
            imageView.stopAnimating()
        }
    }
}

// MARK: - ImageRenderer

enum ImageRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .image = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .image(let src, _, let width, let height, let href) = block else {
            return UIView()
        }

        let primaryURL = Self.makeURL(src)
        let preferredTap = ImageURLDetector.preferredResourceURL(src: src, href: href)
        let hrefURL = Self.makeURL(preferredTap)

        // FluxDo-style badge/music cards: parse query params and draw a native card.
        // Prefer href (original link) when present.
        if let cardURL = hrefURL ?? primaryURL,
           let model = BadgeCardModel.parse(url: cardURL) {
            let card = BadgeCardView(model: model, containerWidth: config.contentWidth)
            card.delegate = delegate
            return card
        }

        guard let url = primaryURL else {
            return UIView()
        }

        let container = TappableImageContainer(
            url: url,
            width: width,
            height: height,
            containerWidth: config.contentWidth,
            href: hrefURL,
            galleryImageURLs: config.galleryImageURLs,
            refererBaseURL: config.baseURL
        )
        container.delegate = delegate
        return container
    }

    nonisolated private static func makeURL(_ raw: String) -> URL? {
        let cleaned = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: cleaned) { return url }
        if let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            return URL(string: encoded)
        }
        return nil
    }
}
