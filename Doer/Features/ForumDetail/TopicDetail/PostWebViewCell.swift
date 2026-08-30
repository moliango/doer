import CookedHTML
import UIKit
import SDWebImage

enum TopicImageGallerySources {
    static func urls(from annotatedBlocks: [AnnotatedBlock]) -> [URL] {
        uniqueImageURLs(annotatedBlocks.flatMap { $0.block.galleryImageURLStrings.compactMap(URL.init(string:)) })
    }

    static func uniqueImageURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            result.append(url)
        }
        return result
    }
}

private extension ContentBlock {
    var galleryImageURLStrings: [String] {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.galleryImageURLStrings
        case .blockquote(let blocks), .spoiler(let blocks):
            return blocks.flatMap(\.galleryImageURLStrings)
        case .discourseQuote(_, _, _, _, _, _, _, let content):
            return content.flatMap(\.galleryImageURLStrings)
        case .image(let src, _, _, _, let href):
            return [ImageURLDetector.preferredResourceURL(src: src, href: href)]
        case .imageGrid(let images, _, _):
            return images.map(\.lightboxURL)
        case .onebox(_, _, _, let imageURL, _, _, _):
            return [imageURL].compactMap { $0 }
        case .list(_, _, let items):
            return items.flatMap(\.galleryImageURLStrings)
        case .table(let headers, let rows):
            return headers.flatMap { $0.flatMap(\.galleryImageURLStrings) }
                + rows.flatMap { row in row.flatMap { $0.flatMap(\.galleryImageURLStrings) } }
        case .details(let summary, let content):
            return summary.galleryImageURLStrings + content.flatMap(\.galleryImageURLStrings)
        case .policy(let policy):
            return policy.content.flatMap(\.galleryImageURLStrings)
        case .codeBlock, .poll, .video, .divider, .rawHTML:
            return []
        }
    }
}

private extension ListItem {
    var galleryImageURLStrings: [String] {
        content.galleryImageURLStrings + children.flatMap(\.galleryImageURLStrings)
    }
}

private extension Array where Element == InlineNode {
    var galleryImageURLStrings: [String] {
        flatMap(\.galleryImageURLStrings)
    }
}

private extension InlineNode {
    var galleryImageURLStrings: [String] {
        switch self {
        case .image(let src, _, _, _, let isEmoji):
            return isEmoji ? [] : [src]
        case .link(_, let children), .spoiler(let children):
            return children.galleryImageURLStrings
        case .text, .styledText, .code, .lineBreak, .mention, .mentionGroup, .hashtag:
            return []
        }
    }
}

extension UIViewController {
    func presentTopicImageGallery(currentURL: URL, imageURLs: [URL], sourceView: UIView? = nil) {
        // Avoid stacking two galleries (tap races / web+native double fire) —
        // closing the top one used to "pop" the lower one from the side.
        if presentedViewController != nil {
            return
        }

        var galleryURLs = TopicImageGallerySources.uniqueImageURLs(imageURLs)
        if !galleryURLs.contains(where: { $0.absoluteString == currentURL.absoluteString }) {
            galleryURLs.insert(currentURL, at: 0)
        }
        guard !galleryURLs.isEmpty else { return }

        let sourceFrame = TopicImageGalleryHeroPolicy.sourceFrameInScreen(sourceView)
        let heroImage = TopicImageGalleryHeroPolicy.heroBitmap(from: sourceView)
        let shouldFly = TopicImageGalleryHeroPolicy.shouldFly(
            hasSource: sourceFrame != nil && heroImage != nil,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        )

        let controller = TopicImageGalleryViewController(
            urls: galleryURLs,
            initialURL: currentURL,
            heroSourceView: shouldFly ? sourceView : nil,
            heroImage: shouldFly ? heroImage : nil,
            heroSourceFrameInScreen: shouldFly ? sourceFrame : nil
        )
        controller.modalPresentationStyle = .overFullScreen
        if shouldFly {
            TopicImageGalleryHeroPolicy.hideSourceDuringFlight(sourceView)
            present(controller, animated: false)
        } else {
            controller.modalTransitionStyle = .crossDissolve
            present(controller, animated: true)
        }
    }
}

enum TopicImageGalleryDismissPolicy {
    static let translationThreshold: CGFloat = 140
    static let velocityThreshold: CGFloat = 900

    static func shouldDismiss(translationY: CGFloat, velocityY: CGFloat) -> Bool {
        translationY > translationThreshold || velocityY > velocityThreshold
    }

    static func backgroundAlpha(for translationY: CGFloat, viewHeight: CGFloat) -> CGFloat {
        let height = max(viewHeight, 1)
        let progress = min(max(translationY / height, 0), 1)
        return 1 - progress * 0.85
    }
}

enum TopicImageGalleryHeroPolicy {
    static func shouldFly(hasSource: Bool, reduceMotion: Bool) -> Bool {
        hasSource && !reduceMotion
    }

    static func canReturnToSource(
        sourceInWindow: Bool,
        sourceFrameInScreen: CGRect,
        screenBounds: CGRect
    ) -> Bool {
        sourceInWindow
            && !sourceFrameInScreen.isNull
            && !sourceFrameInScreen.isEmpty
            && sourceFrameInScreen.intersects(screenBounds)
    }

    static func sourceFrameInScreen(_ sourceView: UIView?) -> CGRect? {
        guard let sourceView, sourceView.window != nil else { return nil }
        let frame = sourceView.convert(sourceView.bounds, to: nil)
        guard !frame.isEmpty, frame.width > 1, frame.height > 1 else { return nil }
        return frame
    }

    static func aspectFitFrame(for imageSize: CGSize, in container: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: container.midX - size.width / 2,
            y: container.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func heroBitmap(from sourceView: UIView?) -> UIImage? {
        guard let sourceView else { return nil }
        if let imageView = sourceView as? UIImageView, let image = imageView.image {
            return image
        }
        guard sourceView.bounds.width > 1, sourceView.bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = sourceView.window?.screen.scale ?? UIScreen.main.scale
        format.opaque = false
        if let parent = sourceView.superview {
            let rect = sourceView.frame
            guard rect.width > 1, rect.height > 1 else { return nil }
            let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
            return renderer.image { ctx in
                ctx.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                parent.drawHierarchy(in: parent.bounds, afterScreenUpdates: false)
            }
        }
        let renderer = UIGraphicsImageRenderer(bounds: sourceView.bounds, format: format)
        return renderer.image { _ in
            sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: false)
        }
    }

    /// UIImageView sources hide so the bitmap does not double-draw. Web snapshot
    /// taps use a clear anchor; hide the pixels with an opaque veil instead.
    static func hideSourceDuringFlight(_ sourceView: UIView?) {
        guard let sourceView else { return }
        if sourceView is UIImageView {
            sourceView.alpha = 0
            return
        }
        if sourceView.backgroundColor == nil || sourceView.backgroundColor == .clear {
            sourceView.backgroundColor = sourceView.superview?.backgroundColor
                ?? sourceView.window?.backgroundColor
                ?? .systemBackground
        }
        sourceView.alpha = 1
    }

    static func restoreSourceAfterFlight(_ sourceView: UIView?) {
        guard let sourceView else { return }
        sourceView.alpha = 1
        if !(sourceView is UIImageView) {
            sourceView.backgroundColor = .clear
        }
    }
}

final class TopicImageGalleryViewController: UIViewController {
    private let urls: [URL]
    private var currentIndex: Int
    private var didScrollToInitialIndex = false
    private var isDismissing = false
    private weak var heroSourceView: UIView?
    private let heroImage: UIImage?
    private let heroSourceFrameInScreen: CGRect?
    private var didPlayPresentHero = false
    private var isPlayingHero = false
    private var presentHeroFlyer: UIImageView?
    private lazy var dismissPanRecognizer: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        return pan
    }()

    private lazy var collectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0

        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .black
        view.dataSource = self
        view.delegate = self
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.register(TopicImageGalleryCell.self, forCellWithReuseIdentifier: TopicImageGalleryCell.reuseIdentifier)
        return view
    }()

    private let downloadButton = TopicImageGalleryViewController.makeToolbarButton(
        symbolName: "arrow.down.to.line",
        fallbackSymbolName: "square.and.arrow.down",
        accessibilityLabel: String(localized: "image_viewer.action.save")
    )

    private let shareButton = TopicImageGalleryViewController.makeToolbarButton(
        symbolName: "arrowshape.turn.up.right.fill",
        fallbackSymbolName: "square.and.arrow.up",
        accessibilityLabel: String(localized: "topic_detail.action.share")
    )

    private let actionStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = true
        return stack
    }()

    private let counterLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        label.layer.cornerRadius = 10
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.isAccessibilityElement = true
        return label
    }()

    private let toastLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        label.layer.cornerRadius = 18
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.alpha = 0
        return label
    }()

    private let actionActivityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.color = .white
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override var preferredStatusBarStyle: UIStatusBarStyle {
        .lightContent
    }

    init(
        urls: [URL],
        initialURL: URL,
        heroSourceView: UIView? = nil,
        heroImage: UIImage? = nil,
        heroSourceFrameInScreen: CGRect? = nil
    ) {
        let uniqueURLs = TopicImageGallerySources.uniqueImageURLs(urls)
        self.urls = uniqueURLs
        self.currentIndex = uniqueURLs.firstIndex { $0.absoluteString == initialURL.absoluteString } ?? 0
        self.heroSourceView = heroSourceView
        self.heroImage = heroImage
        self.heroSourceFrameInScreen = heroSourceFrameInScreen
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        updateCounter()
        ForumImageLoader.prefetch(urls: urls)
        if shouldPlayPresentHero {
            view.backgroundColor = .clear
            collectionView.alpha = 0
            collectionView.backgroundColor = .clear
            actionStack.alpha = 0
            counterLabel.alpha = 0
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        playPresentHeroIfNeeded()
        if shouldPlayPresentHero, !didPlayPresentHero {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.playPresentHeroIfNeeded()
                guard self.shouldPlayPresentHero, !self.didPlayPresentHero else { return }
                self.didPlayPresentHero = true
                self.restoreHeroSourceAlpha()
                self.presentHeroFlyer?.removeFromSuperview()
                self.presentHeroFlyer = nil
                self.revealGalleryChrome()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            restoreHeroSourceAlpha()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if !didScrollToInitialIndex, !urls.isEmpty,
           collectionView.bounds.width > 1, collectionView.bounds.height > 1,
           urls.indices.contains(currentIndex) {
            didScrollToInitialIndex = true
            collectionView.scrollToItem(
                at: IndexPath(item: currentIndex, section: 0),
                at: .centeredHorizontally,
                animated: false
            )
        }
        playPresentHeroIfNeeded()
    }

    private func setupUI() {
        view.addSubview(collectionView)
        actionStack.addArrangedSubview(shareButton)
        actionStack.addArrangedSubview(downloadButton)
        view.addSubview(counterLabel)
        view.addSubview(actionStack)
        view.addSubview(toastLabel)
        view.addSubview(actionActivityIndicator)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            shareButton.widthAnchor.constraint(equalToConstant: 32),
            shareButton.heightAnchor.constraint(equalToConstant: 32),
            downloadButton.widthAnchor.constraint(equalToConstant: 32),
            downloadButton.heightAnchor.constraint(equalToConstant: 32),

            actionStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            actionStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),

            counterLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counterLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            counterLabel.heightAnchor.constraint(equalToConstant: 20),
            counterLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -18),
            toastLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            toastLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),

            actionActivityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            actionActivityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        view.addGestureRecognizer(dismissPanRecognizer)
    }

    private static func makeToolbarButton(
        symbolName: String,
        fallbackSymbolName: String,
        accessibilityLabel: String
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.accessibilityLabel = accessibilityLabel
        let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = UIImage(systemName: symbolName, withConfiguration: configuration)
            ?? UIImage(systemName: fallbackSymbolName, withConfiguration: configuration)
        button.setImage(image, for: .normal)
        button.backgroundColor = UIColor(white: 0.26, alpha: 0.92)
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        return button
    }

    private func updateCounter() {
        counterLabel.isHidden = urls.count <= 1
        counterLabel.text = "  \(currentIndex + 1)/\(urls.count)  "
        counterLabel.accessibilityLabel = "\(currentIndex + 1) / \(urls.count)"
    }

    private func currentCell() -> TopicImageGalleryCell? {
        collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? TopicImageGalleryCell
    }

    private func loadCurrentImage(completion: @escaping (UIImage?) -> Void) {
        if let image = currentCell()?.loadedImage {
            completion(image)
            return
        }

        guard urls.indices.contains(currentIndex) else {
            completion(nil)
            return
        }

        actionActivityIndicator.startAnimating()
        ForumImageLoader.loadImage(with: urls[currentIndex]) { [weak self] image in
            self?.actionActivityIndicator.stopAnimating()
            completion(image)
        }
    }

    @objc private func downloadTapped() {
        loadCurrentImage { [weak self] image in
            guard let self, let image else {
                self?.showToast(String(localized: "image_viewer.save.failed"))
                return
            }
            UIImageWriteToSavedPhotosAlbum(
                image,
                self,
                #selector(TopicImageGalleryViewController.image(_:didFinishSavingWithError:contextInfo:)),
                nil
            )
        }
    }

    @objc private func shareTapped() {
        loadCurrentImage { [weak self] image in
            guard let self, let image else {
                self?.showToast(String(localized: "image_viewer.share.failed"))
                return
            }
            let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = self.shareButton
            activity.popoverPresentationController?.sourceRect = self.shareButton.bounds
            self.present(activity, animated: true)
        }
    }

    @objc private func closeTapped() {
        dismissGallery(preferHero: true)
    }

    private var shouldPlayPresentHero: Bool {
        heroImage != nil && heroSourceFrameInScreen != nil
    }

    private func installPresentHeroFlyerIfNeeded() {
        guard !didPlayPresentHero, presentHeroFlyer == nil, shouldPlayPresentHero else { return }
        guard let heroImage, let heroSourceFrameInScreen else { return }
        guard view.bounds.width > 1 else { return }
        let from = view.convert(heroSourceFrameInScreen, from: nil)
        guard from.width > 1, from.height > 1 else { return }
        let flyer = makeHeroFlyer(image: heroImage, frame: from)
        flyer.layer.cornerRadius = heroSourceView?.layer.cornerRadius
            ?? heroSourceView?.superview?.layer.cornerRadius
            ?? 0
        view.insertSubview(flyer, aboveSubview: collectionView)
        presentHeroFlyer = flyer
    }

    private func playPresentHeroIfNeeded() {
        guard !didPlayPresentHero else { return }
        guard shouldPlayPresentHero else {
            didPlayPresentHero = true
            return
        }
        guard view.window != nil else { return }

        installPresentHeroFlyerIfNeeded()
        guard let heroImage, let flyer = presentHeroFlyer else { return }
        let container = collectionView.bounds.width > 1 ? collectionView.bounds : view.bounds
        let to = TopicImageGalleryHeroPolicy.aspectFitFrame(for: heroImage.size, in: container)
        guard to.width > 1, to.height > 1 else { return }

        didPlayPresentHero = true
        isPlayingHero = true
        view.isUserInteractionEnabled = false

        DoerMotion.animate(
            duration: DoerMotion.emphasized,
            timingParameters: DoerMotion.easeOutCubic,
            animations: {
                flyer.frame = to
                flyer.layer.cornerRadius = 0
                self.view.backgroundColor = .black
            },
            completion: { _ in
                self.revealGalleryChrome()
                flyer.removeFromSuperview()
                self.presentHeroFlyer = nil
                self.isPlayingHero = false
                self.view.isUserInteractionEnabled = true
            }
        )
    }

    private func revealGalleryChrome() {
        collectionView.alpha = 1
        collectionView.backgroundColor = .black
        actionStack.alpha = 1
        counterLabel.alpha = 1
        view.backgroundColor = .black
    }

    private func makeHeroFlyer(image: UIImage, frame: CGRect) -> UIImageView {
        let flyer = UIImageView(image: image)
        flyer.contentMode = .scaleAspectFill
        flyer.clipsToBounds = true
        flyer.frame = frame
        flyer.layer.cornerCurve = .continuous
        return flyer
    }

    private func restoreHeroSourceAlpha() {
        TopicImageGalleryHeroPolicy.restoreSourceAfterFlight(heroSourceView)
    }

    private func canFlyBackToSource() -> Bool {
        guard TopicImageGalleryHeroPolicy.shouldFly(
            hasSource: heroSourceView != nil && (currentCell()?.loadedImage ?? heroImage) != nil,
            reduceMotion: UIAccessibility.isReduceMotionEnabled
        ) else {
            return false
        }
        let screen = view.window?.bounds ?? UIScreen.main.bounds
        let frame = TopicImageGalleryHeroPolicy.sourceFrameInScreen(heroSourceView) ?? .zero
        return TopicImageGalleryHeroPolicy.canReturnToSource(
            sourceInWindow: heroSourceView?.window != nil,
            sourceFrameInScreen: frame,
            screenBounds: screen
        )
    }

    private func dismissGallery(preferHero: Bool) {
        guard !isDismissing, !isBeingDismissed else { return }
        isDismissing = true
        view.isUserInteractionEnabled = false
        let width = max(collectionView.bounds.width, 1)
        if urls.indices.contains(currentIndex) {
            collectionView.setContentOffset(
                CGPoint(x: CGFloat(currentIndex) * width, y: 0),
                animated: false
            )
        }

        if preferHero, canFlyBackToSource() {
            playDismissHero()
            return
        }

        restoreHeroSourceAlpha()
        if modalTransitionStyle == .crossDissolve {
            dismiss(animated: true) { [weak self] in
                self?.isDismissing = false
            }
            return
        }

        let finish = { [weak self] in
            self?.dismiss(animated: false) {
                self?.isDismissing = false
            }
        }

        if UIAccessibility.isReduceMotionEnabled {
            finish()
            return
        }

        DoerMotion.animate(
            duration: DoerMotion.emphasized,
            timingParameters: DoerMotion.easeInCubic,
            animations: {
                self.view.backgroundColor = .clear
                self.collectionView.alpha = 0
                self.actionStack.alpha = 0
                self.counterLabel.alpha = 0
                self.toastLabel.alpha = 0
            },
            completion: { _ in
                finish()
            }
        )
    }

    private func playDismissHero() {
        let image = currentCell()?.loadedImage ?? heroImage
        guard let image, let source = heroSourceView, source.window != nil else {
            restoreHeroSourceAlpha()
            dismiss(animated: false) { self.isDismissing = false }
            return
        }

        isPlayingHero = true
        let fitInCollection = TopicImageGalleryHeroPolicy.aspectFitFrame(
            for: image.size,
            in: collectionView.bounds
        )
        let from = collectionView.convert(fitInCollection, to: view)
        let dest = source.convert(source.bounds, to: view)
        let flyer = makeHeroFlyer(image: image, frame: from)
        flyer.layer.cornerRadius = 0
        collectionView.alpha = 0
        collectionView.transform = .identity
        collectionView.backgroundColor = .clear
        actionStack.alpha = 0
        counterLabel.alpha = 0
        toastLabel.alpha = 0
        view.insertSubview(flyer, aboveSubview: collectionView)

        DoerMotion.animate(
            duration: DoerMotion.standard,
            timingParameters: DoerMotion.easeInCubic,
            animations: {
                flyer.frame = dest
                let radius = source.layer.cornerRadius > 0
                    ? source.layer.cornerRadius
                    : (source.superview?.layer.cornerRadius ?? 0)
                flyer.layer.cornerRadius = radius
                self.view.backgroundColor = .clear
            },
            completion: { _ in
                self.restoreHeroSourceAlpha()
                flyer.removeFromSuperview()
                self.isPlayingHero = false
                self.dismiss(animated: false) {
                    self.isDismissing = false
                }
            }
        )
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        guard !isBeingDismissed, !isPlayingHero else { return }
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        let y = max(translation.y, 0)

        switch pan.state {
        case .began:
            collectionView.isScrollEnabled = false
        case .changed:
            applyInteractiveDismiss(translationY: y)
        case .ended, .cancelled, .failed:
            collectionView.isScrollEnabled = true
            if pan.state == .ended,
               TopicImageGalleryDismissPolicy.shouldDismiss(translationY: y, velocityY: velocity.y) {
                finishInteractiveDismiss(currentY: y)
            } else if !isDismissing {
                cancelInteractiveDismiss()
            }
        default:
            break
        }
    }

    private func applyInteractiveDismiss(translationY: CGFloat) {
        collectionView.transform = CGAffineTransform(translationX: 0, y: translationY)
        let alpha = TopicImageGalleryDismissPolicy.backgroundAlpha(
            for: translationY,
            viewHeight: view.bounds.height
        )
        view.backgroundColor = UIColor.black.withAlphaComponent(alpha)
        collectionView.backgroundColor = .clear
        actionStack.alpha = alpha
        counterLabel.alpha = alpha
    }

    private func finishInteractiveDismiss(currentY: CGFloat) {
        guard !isDismissing else { return }
        if canFlyBackToSource() {
            isDismissing = true
            view.isUserInteractionEnabled = false
            playDismissHero()
            return
        }
        isDismissing = true
        view.isUserInteractionEnabled = false
        let distance = max(view.bounds.height - currentY, 1)
        let duration = min(max(TimeInterval(distance / 1_800), 0.18), 0.32)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.collectionView.transform = CGAffineTransform(
                translationX: 0,
                y: self.view.bounds.height
            )
            self.view.backgroundColor = .clear
            self.actionStack.alpha = 0
            self.counterLabel.alpha = 0
            self.toastLabel.alpha = 0
        } completion: { _ in
            self.restoreHeroSourceAlpha()
            self.dismiss(animated: false) {
                self.isDismissing = false
            }
        }
    }

    private func cancelInteractiveDismiss() {
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.collectionView.transform = .identity
            self.view.backgroundColor = .black
            self.collectionView.backgroundColor = .black
            self.actionStack.alpha = 1
            self.counterLabel.alpha = 1
        }
    }

    @objc private func image(_ image: UIImage, didFinishSavingWithError error: NSError?, contextInfo: UnsafeRawPointer) {
        showToast(String(localized: error == nil ? "image_viewer.save.success" : "image_viewer.save.failed"))
    }

    private func showToast(_ text: String) {
        toastLabel.text = "  \(text)  "
        toastLabel.alpha = 0
        AnimationOptimizer.animateAlpha(toastLabel, to: 1, duration: 0.18) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                AnimationOptimizer.animateAlpha(self.toastLabel, to: 0, duration: 0.20)
            }
        }
    }
}

extension TopicImageGalleryViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        urls.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TopicImageGalleryCell.reuseIdentifier,
            for: indexPath
        ) as? TopicImageGalleryCell else {
            return UICollectionViewCell()
        }
        guard urls.indices.contains(indexPath.item) else { return cell }
        cell.configure(url: urls[indexPath.item])
        cell.onSingleTap = { [weak self] in
            self?.closeTapped()
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        // Avoid zero-size cells during the first layout pass (can crash scrollToItem).
        let size = collectionView.bounds.size
        return CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentIndex(from: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateCurrentIndex(from: scrollView)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateCurrentIndex(from: scrollView)
    }

    private func updateCurrentIndex(from scrollView: UIScrollView) {
        let width = max(scrollView.bounds.width, 1)
        currentIndex = min(max(Int(round(scrollView.contentOffset.x / width)), 0), max(urls.count - 1, 0))
        updateCounter()
    }
}

extension TopicImageGalleryViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPanRecognizer else { return true }
        guard !isDismissing, !isPlayingHero else { return false }
        if (currentCell()?.zoomScale ?? 1) > 1.01 {
            return false
        }
        let velocity = dismissPanRecognizer.velocity(in: view)
        let translation = dismissPanRecognizer.translation(in: view)
        let dy: CGFloat
        let dx: CGFloat
        if abs(velocity.y) < 12, abs(velocity.x) < 12 {
            dy = translation.y
            dx = translation.x
        } else {
            dy = velocity.y
            dx = velocity.x
        }
        return dy > 0 && abs(dy) > abs(dx)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

private final class TopicImageGalleryCell: UICollectionViewCell, UIScrollViewDelegate {
    static let reuseIdentifier = "TopicImageGalleryCell"

    private var representedURL: URL?

    var loadedImage: UIImage? {
        imageView.image
    }

    var zoomScale: CGFloat {
        scrollView.zoomScale
    }

    var onSingleTap: (() -> Void)?

    private let scrollView: UIScrollView = {
        let view = UIScrollView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.minimumZoomScale = 1
        view.maximumZoomScale = 4
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .black
        view.contentInsetAdjustmentBehavior = .never
        return view
    }()

    private let imageView: SDAnimatedImageView = {
        let view = SDAnimatedImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .black
        view.autoPlayAnimatedImage = true
        return view
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.color = .white
        indicator.hidesWhenStopped = true
        return indicator
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        scrollView.delegate = self
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedURL = nil
        onSingleTap = nil
        imageView.sd_cancelCurrentImageLoad()
        imageView.image = nil
        imageView.alpha = 1
        scrollView.zoomScale = 1
        scrollView.contentInset = .zero
        activityIndicator.stopAnimating()
    }

    func configure(url: URL) {
        representedURL = url
        scrollView.zoomScale = 1
        scrollView.contentInset = .zero
        ImagePaintPolicy.prepareForLoad(on: imageView)

        if AvatarImageLoader.cachedImageIfAvailable(for: url) != nil {
            activityIndicator.stopAnimating()
        } else {
            activityIndicator.startAnimating()
        }

        ForumImageLoader.setImage(on: imageView, url: url) { [weak self] image, _, _, _ in
            guard let self, self.representedURL == url else { return }
            self.activityIndicator.stopAnimating()
            if image != nil {
                self.centerZoomedContent()
            }
        }
    }

    private func setupUI() {
        contentView.addSubview(scrollView)
        scrollView.addSubview(imageView)
        contentView.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerZoomedContent()
    }

    private func centerZoomedContent() {
        let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > 1 {
            scrollView.setZoomScale(1, animated: true)
            return
        }

        let point = gesture.location(in: imageView)
        let targetScale = min(scrollView.maximumZoomScale, 2.4)
        let size = CGSize(
            width: scrollView.bounds.width / targetScale,
            height: scrollView.bounds.height / targetScale
        )
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        scrollView.zoom(to: rect, animated: true)
    }
}

protocol PostCellDelegate: AnyObject {
    func postCell(didTapImageURL url: URL, imageURLs: [URL], sourceView: UIView?)
    func postCell(didTapLinkURL url: URL)
    func postCell(didTapShowRepliesForPostId postId: Int)
    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int)
    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post)
    func postCell(didTapEditPost post: DiscourseTopicDetail.Post)
    func postCell(didTapShareImageForPost post: DiscourseTopicDetail.Post)
    func postCell(didTapShowRevisionForPost post: DiscourseTopicDetail.Post)
    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool)
    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post)
    func postCell(didRequestDeleteBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post)
    func postCell(didUpdateBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post)
    func postCell(didTapAvatarForUsername username: String)
    func postCell(didTapQuotedPostNumber postNumber: Int)
    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post)
    func postCell(didTapToggleSharedIssueForTopicId topicId: Int)
    func postCell(didSubmitPollVoteForPostId postId: Int, pollName: String, optionIds: [String])
    func postCell(didTogglePolicyAccepted accepted: Bool, forPostId postId: Int)
    func postCell(didCastPostVotingVote direction: String, forPost post: DiscourseTopicDetail.Post)
    func postCell(didQuoteSelectedText text: String, postId: Int?)
    func postCell(didRequestDecrypt text: String, postId: Int?)
}

extension PostCellDelegate {
    func postCell(didCastPostVotingVote direction: String, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didQuoteSelectedText text: String, postId: Int?) {}
    func postCell(didRequestDecrypt text: String, postId: Int?) {}
    func postCell(didTogglePolicyAccepted accepted: Bool, forPostId postId: Int) {}
}

final class PostWebViewCell: UITableViewCell {
    static let reuseIdentifier = "PostWebViewCell"
    static let headerHeight: CGFloat = 44
    static let bottomBarHeight: CGFloat = 30

    weak var delegate: PostCellDelegate?
    private var interactiveRegions: [InteractiveRegion] = []
    private var postId: Int = 0
    private var postLink: String?
    private var currentPost: DiscourseTopicDetail.Post?
    private var codeBlockViews: [UIScrollView] = []

    // MARK: - Header UI

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 16
        iv.backgroundColor = ImagePaintPolicy.waitingFillColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let floorLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let replyToLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    // MARK: - Content

    private let snapshotImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleToFill
        iv.clipsToBounds = true
        iv.isUserInteractionEnabled = true
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let imageHeroAnchorView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }()

    // MARK: - Bottom Bar

    private let showRepliesButton: UIButton = {
        let button = UIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        button.tintColor = .secondaryLabel
        button.contentHorizontalAlignment = .leading
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    private let copyLinkButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.setImage(UIImage(systemName: "link", withConfiguration: config), for: .normal)
        button.tintColor = .tertiaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let replyButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.setImage(UIImage(systemName: "arrowshape.turn.up.left", withConfiguration: config), for: .normal)
        button.tintColor = .tertiaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let editButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        button.setImage(UIImage(systemName: "pencil", withConfiguration: config), for: .normal)
        button.tintColor = .tertiaryLabel
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.accessibilityLabel = String(localized: "post.edit.action", defaultValue: "编辑")
        return button
    }()

    private let separatorLine: UIView = {
        let view = UIView()
        view.backgroundColor = .separator
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private var imageViewHeightConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        contentView.addSubview(avatarImageView)
        contentView.addSubview(usernameLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(floorLabel)
        contentView.addSubview(replyToLabel)
        contentView.addSubview(snapshotImageView)
        contentView.addSubview(showRepliesButton)
        contentView.addSubview(editButton)
        contentView.addSubview(replyButton)
        contentView.addSubview(copyLinkButton)
        contentView.addSubview(separatorLine)

        NSLayoutConstraint.activate([
            avatarImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarImageView.widthAnchor.constraint(equalToConstant: 32),
            avatarImageView.heightAnchor.constraint(equalToConstant: 32),

            usernameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            usernameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8),

            usernameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            replyToLabel.centerYAnchor.constraint(equalTo: floorLabel.centerYAnchor),
            replyToLabel.trailingAnchor.constraint(equalTo: floorLabel.leadingAnchor, constant: -8),

            floorLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 2),
            floorLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            snapshotImageView.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor),
            snapshotImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            snapshotImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            showRepliesButton.topAnchor.constraint(equalTo: snapshotImageView.bottomAnchor),
            showRepliesButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            showRepliesButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),

            copyLinkButton.topAnchor.constraint(equalTo: snapshotImageView.bottomAnchor),
            copyLinkButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            copyLinkButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            copyLinkButton.widthAnchor.constraint(equalToConstant: 26),
            copyLinkButton.bottomAnchor.constraint(equalTo: separatorLine.topAnchor, constant: -6),

            replyButton.topAnchor.constraint(equalTo: snapshotImageView.bottomAnchor),
            replyButton.trailingAnchor.constraint(equalTo: copyLinkButton.leadingAnchor),
            replyButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            replyButton.widthAnchor.constraint(equalToConstant: 26),

            editButton.topAnchor.constraint(equalTo: snapshotImageView.bottomAnchor),
            editButton.trailingAnchor.constraint(equalTo: replyButton.leadingAnchor),
            editButton.heightAnchor.constraint(equalToConstant: Self.bottomBarHeight),
            editButton.widthAnchor.constraint(equalToConstant: 26),

            separatorLine.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorLine.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        snapshotImageView.addGestureRecognizer(tap)

        showRepliesButton.addTarget(self, action: #selector(repliesButtonTapped), for: .touchUpInside)
        copyLinkButton.addTarget(self, action: #selector(copyLinkTapped), for: .touchUpInside)
        replyButton.addTarget(self, action: #selector(replyButtonTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editButtonTapped), for: .touchUpInside)

        avatarImageView.isUserInteractionEnabled = true
        let avatarTap = UITapGestureRecognizer(target: self, action: #selector(avatarTapped))
        avatarImageView.addGestureRecognizer(avatarTap)
    }

    func configure(
        with post: DiscourseTopicDetail.Post,
        snapshot: UIImage?,
        contentHeight: CGFloat,
        interactiveRegions: [InteractiveRegion],
        codeBlocks: [CodeBlockInfo],
        baseURL: String,
        delegate: PostCellDelegate?,
        floorNumber: Int,
        postLink: String?
    ) {
        self.postId = post.id
        self.postLink = postLink
        self.currentPost = post
        editButton.isHidden = !PostEditingPolicy.canShowEditAction(for: post)
        usernameLabel.text = post.username
        timeLabel.text = Self.formatDate(post.createdAt)
        snapshotImageView.image = snapshot
        self.interactiveRegions = interactiveRegions
        self.delegate = delegate

        floorLabel.text = "#\(floorNumber)"

        if let replyUser = post.replyToUser {
            let attachment = NSTextAttachment()
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            attachment.image = UIImage(systemName: "arrowshape.turn.up.left.fill", withConfiguration: symbolConfig)?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            let attrStr = NSMutableAttributedString(attachment: attachment)
            attrStr.append(NSAttributedString(string: " @\(replyUser.username)"))
            replyToLabel.attributedText = attrStr
            replyToLabel.isHidden = false
        } else {
            replyToLabel.isHidden = true
        }

        let hasReplies = post.replyCount > 0
        showRepliesButton.isHidden = !hasReplies
        if hasReplies {
            showRepliesButton.setTitle(String(localized: "post.replies \(post.replyCount)"), for: .normal)
        }

        imageViewHeightConstraint?.isActive = false
        let hc = snapshotImageView.heightAnchor.constraint(equalToConstant: contentHeight)
        imageViewHeightConstraint = hc
        hc.isActive = true

        // Overlay scrollable code blocks
        setupCodeBlockOverlays(codeBlocks)

        AvatarImageLoader.setImage(
            on: avatarImageView,
            template: post.avatarTemplate,
            baseURL: baseURL,
            size: AvatarImageLoader.primaryAvatarPixelSize
        )
    }

    // MARK: - Code Block Overlays

    private func setupCodeBlockOverlays(_ codeBlocks: [CodeBlockInfo]) {
        codeBlockViews.forEach { $0.removeFromSuperview() }
        codeBlockViews = []

        let codeFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        let codeBg = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.165, alpha: 1)
            : UIColor(white: 0.957, alpha: 1)
        }

        for block in codeBlocks {
            let sv = UIScrollView(frame: block.frame)
            sv.showsHorizontalScrollIndicator = true
            sv.showsVerticalScrollIndicator = false
            sv.bounces = false
            sv.backgroundColor = codeBg
            sv.layer.cornerRadius = 6
            sv.clipsToBounds = true

            let label = UILabel()
            label.text = block.text
            label.font = codeFont
            label.textColor = .label
            label.numberOfLines = 0
            label.lineBreakMode = .byClipping

            let padding: CGFloat = 10
            let textSize = (block.text as NSString).boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: codeFont],
                context: nil
            ).size
            label.frame = CGRect(x: padding, y: padding, width: ceil(textSize.width), height: ceil(textSize.height))
            sv.addSubview(label)
            sv.contentSize = CGSize(width: ceil(textSize.width) + padding * 2, height: block.frame.height)

            snapshotImageView.addSubview(sv)
            codeBlockViews.append(sv)
        }
    }

    // MARK: - Tap Handling

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: snapshotImageView)
        for region in interactiveRegions {
            if region.frame.contains(location) {
                switch region.kind {
                case .image(let url):
                    let imageURLs = TopicImageGallerySources.uniqueImageURLs(interactiveRegions.compactMap { region in
                        if case .image(let imageURL) = region.kind {
                            return imageURL
                        }
                        return nil
                    })
                    imageHeroAnchorView.frame = region.frame
                    if imageHeroAnchorView.superview !== snapshotImageView {
                        snapshotImageView.addSubview(imageHeroAnchorView)
                    }
                    delegate?.postCell(didTapImageURL: url, imageURLs: imageURLs, sourceView: imageHeroAnchorView)
                case .link(let url):
                    delegate?.postCell(didTapLinkURL: url)
                case .details(let index):
                    delegate?.postCell(didTapToggleDetails: index, postId: postId)
                }
                return
            }
        }
    }

    @objc private func repliesButtonTapped() {
        delegate?.postCell(didTapShowRepliesForPostId: postId)
    }

    @objc private func replyButtonTapped() {
        guard let post = currentPost else { return }
        delegate?.postCell(didTapReplyToPost: post)
    }

    @objc private func editButtonTapped() {
        guard let post = currentPost else { return }
        delegate?.postCell(didTapEditPost: post)
    }

    @objc private func avatarTapped() {
        guard let username = currentPost?.username else { return }
        delegate?.postCell(didTapAvatarForUsername: username)
    }

    @objc private func copyLinkTapped() {
        guard let link = postLink else { return }
        UIPasteboard.general.string = link
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyLinkButton.setImage(UIImage(systemName: "checkmark", withConfiguration: config), for: .normal)
        copyLinkButton.tintColor = .systemGreen
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
            self?.copyLinkButton.setImage(UIImage(systemName: "link", withConfiguration: config), for: .normal)
            self?.copyLinkButton.tintColor = .tertiaryLabel
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        snapshotImageView.image = nil
        imageHeroAnchorView.removeFromSuperview()
        interactiveRegions = []
        delegate = nil
        postId = 0
        postLink = nil
        currentPost = nil
        editButton.isHidden = true
        usernameLabel.text = nil
        timeLabel.text = nil
        floorLabel.text = nil
        replyToLabel.attributedText = nil
        replyToLabel.text = nil
        replyToLabel.isHidden = true
        showRepliesButton.isHidden = true
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        codeBlockViews.forEach { $0.removeFromSuperview() }
        codeBlockViews = []
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyLinkButton.setImage(UIImage(systemName: "link", withConfiguration: config), for: .normal)
        copyLinkButton.tintColor = .tertiaryLabel
    }

    private static func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else { return isoString }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }
}


extension PostCellDelegate {
    func postCell(didTapShareImageForPost post: DiscourseTopicDetail.Post) {}
    func postCell(didTapShowRevisionForPost post: DiscourseTopicDetail.Post) {}
    func postCell(didRequestDeleteBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didUpdateBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {}
}
