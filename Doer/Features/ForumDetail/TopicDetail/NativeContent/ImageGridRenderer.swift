import CookedHTML
import SDWebImage
import UIKit

enum ImageGridPresentation {
    static var usesCarousel: Bool {
        AppSettings.shared.contentImageCarouselEnabled
    }

    static func preparedBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        preparedBlocks(blocks, usesCarousel: usesCarousel)
    }

    static func preparedBlocks(_ blocks: [ContentBlock], usesCarousel: Bool) -> [ContentBlock] {
        let expanded = blocks.flatMap { prepare(block: $0, usesCarousel: usesCarousel) }
        return usesCarousel ? groupConsecutiveImages(expanded) : expanded
    }

    static func preparedAnnotatedBlocks(_ items: [AnnotatedBlock]) -> [AnnotatedBlock] {
        preparedAnnotatedBlocks(items, usesCarousel: usesCarousel)
    }

    static func preparedAnnotatedBlocks(_ items: [AnnotatedBlock], usesCarousel: Bool) -> [AnnotatedBlock] {
        let expanded = items.flatMap { item in
            prepare(block: item.block, usesCarousel: usesCarousel).map {
                AnnotatedBlock(block: $0, sourceHTML: item.sourceHTML)
            }
        }
        return usesCarousel ? groupConsecutiveImageAnnotated(expanded) : expanded
    }

    private static func prepare(block: ContentBlock, usesCarousel: Bool) -> [ContentBlock] {
        if case let .imageGrid(images, columns, _) = block {
            if usesCarousel {
                return [.imageGrid(images: images, columns: columns, mode: .carousel)]
            }
            return images.map {
                .image(src: $0.src, alt: $0.alt, width: $0.width, height: $0.height, href: $0.href)
            }
        }
        switch block {
        case let .blockquote(nested):
            return [.blockquote(blocks: preparedBlocks(nested, usesCarousel: usesCarousel))]
        case let .spoiler(nested):
            return [.spoiler(blocks: preparedBlocks(nested, usesCarousel: usesCarousel))]
        case let .discourseQuote(username, avatarURL, topicTitle, topicURL, categoryName, categoryURL, quotePostNumber, content):
            return [
                .discourseQuote(
                    username: username,
                    avatarURL: avatarURL,
                    topicTitle: topicTitle,
                    topicURL: topicURL,
                    categoryName: categoryName,
                    categoryURL: categoryURL,
                    quotePostNumber: quotePostNumber,
                    content: preparedBlocks(content, usesCarousel: usesCarousel)
                ),
            ]
        case let .details(summary, content):
            return [.details(summary: summary, content: preparedBlocks(content, usesCarousel: usesCarousel))]
        case let .list(ordered, start, items):
            let mapped = items.map {
                ListItem(content: $0.content, children: preparedBlocks($0.children, usesCarousel: usesCarousel))
            }
            return [.list(ordered: ordered, start: start, items: mapped)]
        case let .table(headers, rows):
            return [
                .table(
                    headers: headers.map { preparedBlocks($0, usesCarousel: usesCarousel) },
                    rows: rows.map { row in row.map { preparedBlocks($0, usesCarousel: usesCarousel) } }
                ),
            ]
        default:
            return [block]
        }
    }

    private static func groupConsecutiveImages(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var result: [ContentBlock] = []
        var pending: [ImageGridItem] = []

        func flush() {
            guard !pending.isEmpty else { return }
            if pending.count == 1 {
                let item = pending[0]
                result.append(.image(src: item.src, alt: item.alt, width: item.width, height: item.height, href: item.href))
            } else {
                result.append(.imageGrid(images: pending, columns: 1, mode: .carousel))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if let item = imageItem(from: block), !isBadgeCard(item) {
                pending.append(item)
                continue
            }
            if !pending.isEmpty, isSkippableGlue(block) {
                continue
            }
            flush()
            result.append(block)
        }
        flush()
        return result
    }

    private static func groupConsecutiveImageAnnotated(_ items: [AnnotatedBlock]) -> [AnnotatedBlock] {
        var result: [AnnotatedBlock] = []
        var pending: [AnnotatedBlock] = []

        func flush() {
            guard !pending.isEmpty else { return }
            if pending.count == 1 {
                result.append(pending[0])
            } else {
                let images = pending.compactMap { imageItem(from: $0.block) }
                result.append(AnnotatedBlock(
                    block: .imageGrid(images: images, columns: 1, mode: .carousel),
                    sourceHTML: pending.map(\.sourceHTML).joined()
                ))
            }
            pending.removeAll(keepingCapacity: true)
        }

        for item in items {
            if let image = imageItem(from: item.block), !isBadgeCard(image) {
                pending.append(item)
                continue
            }
            if !pending.isEmpty, isSkippableGlue(item.block) {
                continue
            }
            flush()
            result.append(item)
        }
        flush()
        return result
    }

    private static func imageItem(from block: ContentBlock) -> ImageGridItem? {
        guard case let .image(src, alt, width, height, href) = block else { return nil }
        return ImageGridItem(src: src, alt: alt, width: width, height: height, href: href)
    }

    private static func isSkippableGlue(_ block: ContentBlock) -> Bool {
        guard case .paragraph(let inlines) = block else { return false }
        return inlines.allSatisfy { inline in
            switch inline {
            case .lineBreak:
                return true
            case .text(let text), .styledText(let text, _):
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    private static func isBadgeCard(_ item: ImageGridItem) -> Bool {
        for raw in [item.href, item.src].compactMap({ $0 }) where !raw.isEmpty {
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: cleaned), BadgeCardModel.parse(url: url) != nil {
                return true
            }
        }
        return false
    }
}

enum ImageGridRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .imageGrid = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case let .imageGrid(images, columns, mode) = block, !images.isEmpty else {
            return UIView()
        }
        if mode == .carousel || images.count == 1 {
            return ImageCarouselView(images: images, config: config, delegate: delegate)
        }
        return ImageGridWrapView(images: images, columns: columns, config: config, delegate: delegate)
    }
}

// MARK: - Carousel (FluxDo d-image-grid--carousel)

private final class ImageCarouselView: UIView, UIScrollViewDelegate {
    private static let trackHeight: CGFloat = 300
    private static let maxDots = 10

    private let images: [ImageGridItem]
    private let config: NativeRenderConfig
    private weak var delegate: PostCellDelegate?
    private let galleryURLs: [URL]
    private var slides: [ImageCarouselSlideView] = []
    private var lastPageWidth: CGFloat = 0

    private var currentIndex = 0 {
        didSet { updateChrome() }
    }

    private let trackView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiarySystemFill
        view.layer.cornerRadius = 8
        view.clipsToBounds = true
        return view
    }()

    private let scrollView: UIScrollView = {
        let view = UIScrollView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.bounces = true
        view.contentInsetAdjustmentBehavior = .never
        return view
    }()

    private let pageStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 0
        return stack
    }()

    private let previousButton = ImageCarouselView.makeNavButton(systemName: "chevron.left")
    private let nextButton = ImageCarouselView.makeNavButton(systemName: "chevron.right")
    private let dotsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        return stack
    }()

    private let counterLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    init(images: [ImageGridItem], config: NativeRenderConfig, delegate: PostCellDelegate?) {
        self.images = images
        self.config = config
        self.delegate = delegate
        self.galleryURLs = images.compactMap { URL(string: $0.lightboxURL) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        addSubview(trackView)
        trackView.addSubview(scrollView)
        scrollView.addSubview(pageStack)
        addSubview(dotsStack)
        addSubview(counterLabel)
        scrollView.delegate = self

        previousButton.addTarget(self, action: #selector(goPrevious), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(goNext), for: .touchUpInside)
        trackView.addSubview(previousButton)
        trackView.addSubview(nextButton)

        slides = images.enumerated().map { index, item in
            let slide = ImageCarouselSlideView()
            slide.configure(item: item, refererBaseURL: config.baseURL) { [weak self] in
                self?.openViewer(at: index)
            }
            pageStack.addArrangedSubview(slide)
            return slide
        }

        let showChrome = images.count > 1
        previousButton.isHidden = !showChrome
        nextButton.isHidden = !showChrome
        dotsStack.isHidden = !showChrome || images.count > Self.maxDots
        counterLabel.isHidden = !showChrome || images.count <= Self.maxDots

        if showChrome, images.count <= Self.maxDots {
            for index in images.indices {
                let dot = UIView()
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.layer.cornerRadius = 4
                dot.tag = index
                let tap = UITapGestureRecognizer(target: self, action: #selector(dotTapped(_:)))
                dot.addGestureRecognizer(tap)
                dot.isUserInteractionEnabled = true
                NSLayoutConstraint.activate([
                    dot.heightAnchor.constraint(equalToConstant: 8),
                    dot.widthAnchor.constraint(equalToConstant: index == 0 ? 20 : 8),
                ])
                dotsStack.addArrangedSubview(dot)
            }
        }

        NSLayoutConstraint.activate([
            trackView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackView.heightAnchor.constraint(equalToConstant: Self.trackHeight),

            scrollView.topAnchor.constraint(equalTo: trackView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trackView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: trackView.bottomAnchor),

            pageStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            pageStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            pageStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            pageStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            pageStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            pageStack.widthAnchor.constraint(
                equalTo: scrollView.frameLayoutGuide.widthAnchor,
                multiplier: CGFloat(max(images.count, 1))
            ),

            previousButton.leadingAnchor.constraint(equalTo: trackView.leadingAnchor, constant: 8),
            previousButton.centerYAnchor.constraint(equalTo: trackView.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: trackView.trailingAnchor, constant: -8),
            nextButton.centerYAnchor.constraint(equalTo: trackView.centerYAnchor),

            dotsStack.topAnchor.constraint(equalTo: trackView.bottomAnchor, constant: 8),
            dotsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotsStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            counterLabel.topAnchor.constraint(equalTo: trackView.bottomAnchor, constant: 8),
            counterLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            counterLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])

        if showChrome {
            let chromeBottom = images.count > Self.maxDots ? counterLabel.bottomAnchor : dotsStack.bottomAnchor
            chromeBottom.constraint(equalTo: bottomAnchor).isActive = true
        } else {
            trackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8).isActive = true
        }

        updateChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        restorePageOffsetIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        setNeedsLayout()
        layoutIfNeeded()
        restorePageOffsetIfNeeded(force: true)
        slides.forEach { $0.paintIfNeeded() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let index = Int((scrollView.contentOffset.x / width).rounded())
        let clamped = min(max(index, 0), images.count - 1)
        if clamped != currentIndex {
            currentIndex = clamped
        }
    }

    @objc private func goPrevious() {
        guard currentIndex > 0 else { return }
        scrollTo(currentIndex - 1)
    }

    @objc private func goNext() {
        guard currentIndex < images.count - 1 else { return }
        scrollTo(currentIndex + 1)
    }

    @objc private func dotTapped(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag else { return }
        scrollTo(index)
    }

    private func scrollTo(_ index: Int) {
        let width = scrollView.bounds.width
        guard width > 1 else {
            currentIndex = index
            return
        }
        scrollView.setContentOffset(CGPoint(x: width * CGFloat(index), y: 0), animated: true)
        currentIndex = index
    }

    private func restorePageOffsetIfNeeded(force: Bool = false) {
        let width = scrollView.bounds.width
        guard width > 1 else { return }
        let pageChanged = abs(width - lastPageWidth) > 0.5
        lastPageWidth = width
        guard force || pageChanged else { return }
        scrollView.contentOffset = CGPoint(x: width * CGFloat(currentIndex), y: 0)
    }

    private func openViewer(at index: Int) {
        let item = images[index]
        guard let url = URL(string: item.lightboxURL) else { return }
        delegate?.postCell(didTapImageURL: url, imageURLs: galleryURLs)
    }

    private func updateChrome() {
        previousButton.alpha = currentIndex > 0 ? 1 : 0.3
        previousButton.isEnabled = currentIndex > 0
        nextButton.alpha = currentIndex < images.count - 1 ? 1 : 0.3
        nextButton.isEnabled = currentIndex < images.count - 1
        counterLabel.text = "\(currentIndex + 1) / \(images.count)"
        for (index, view) in dotsStack.arrangedSubviews.enumerated() {
            let active = index == currentIndex
            view.backgroundColor = active ? tintColor : .tertiaryLabel.withAlphaComponent(0.35)
            view.constraints.first { $0.firstAttribute == .width }?.constant = active ? 20 : 8
        }
    }

    private static func makeNavButton(systemName: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .label
        button.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.8)
        button.layer.cornerRadius = 16
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.1
        button.layer.shadowRadius = 4
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }
}

private final class ImageCarouselSlideView: UIView {
    private let imageView: SDAnimatedImageView = {
        let view = SDAnimatedImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.backgroundColor = .clear
        return view
    }()

    private var tapHandler: (() -> Void)?
    private var loadGeneration = 0
    private var pendingImage: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paintIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            paintIfNeeded()
        }
    }

    func configure(item: ImageGridItem, refererBaseURL: String?, tapHandler: @escaping () -> Void) {
        self.tapHandler = tapHandler
        loadGeneration += 1
        let generation = loadGeneration
        pendingImage = nil
        imageView.image = nil
        imageView.contentMode = .scaleAspectFit
        let raw = item.lightboxURL.isEmpty ? item.src : item.lightboxURL
        guard let url = URL(string: raw) else { return }
        ExternalImageFetcher.fetch(url: url, refererBaseURL: refererBaseURL, forceRetry: false) { [weak self] image in
            guard let self, generation == self.loadGeneration else { return }
            self.imageView.contentMode = .scaleAspectFit
            self.pendingImage = image
            self.paintIfNeeded()
        }
    }

    func paintIfNeeded() {
        guard bounds.width > 1, bounds.height > 1, let image = pendingImage else { return }
        pendingImage = nil
        // Re-assign so SDAnimatedImageView / iOS 14+ UIImageView actually
        // displayLayer: after growing from a zero frame (cache hits during init).
        imageView.image = nil
        imageView.image = image
        imageView.layer.setNeedsDisplay()
    }

    @objc private func tapped() {
        tapHandler?()
    }
}

// MARK: - Grid wrap

private final class ImageGridWrapView: UIView {
    init(images: [ImageGridItem], columns: Int, config: NativeRenderConfig, delegate: PostCellDelegate?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let cols = max(columns, 1)
        let spacing: CGFloat = 6
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = spacing
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        let galleryURLs = images.compactMap { URL(string: $0.lightboxURL) }
        let rows = stride(from: 0, to: images.count, by: cols).map { Array(images[$0..<min($0 + cols, images.count)]) }
        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = spacing
            rowStack.distribution = .fillEqually
            rowStack.alignment = .fill
            for item in row {
                let tile = TappableImageContainer(
                    url: URL(string: item.src) ?? URL(fileURLWithPath: "/"),
                    width: item.width,
                    height: item.height,
                    containerWidth: max((config.contentWidth - spacing * CGFloat(cols - 1)) / CGFloat(cols), 1),
                    href: item.href.flatMap(URL.init(string:)),
                    galleryImageURLs: galleryURLs,
                    refererBaseURL: config.baseURL
                )
                tile.delegate = delegate
                tile.layer.cornerRadius = 4
                tile.clipsToBounds = true
                rowStack.addArrangedSubview(tile)
            }
            if row.count < cols {
                for _ in 0..<(cols - row.count) {
                    let spacer = UIView()
                    rowStack.addArrangedSubview(spacer)
                }
            }
            stack.addArrangedSubview(rowStack)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
