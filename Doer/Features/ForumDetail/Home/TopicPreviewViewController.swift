import CookedHTML
import UIKit

/// A compact TopicDetail-style action shown below the topic preview.
struct TopicPreviewAction {
    let title: String
    let image: UIImage?
    let handler: () -> Void

    init(title: String, image: UIImage? = nil, handler: @escaping () -> Void) {
        self.title = title
        self.image = image
        self.handler = handler
    }
}

/// Owns the gesture target so a table can trigger the custom preview without
/// relying on UIKit's context-menu presentation lifecycle.
@MainActor
final class TopicPreviewLongPressHandler: NSObject {
    private let action: (CGPoint) -> Void
    private var didTrigger = false

    private(set) lazy var gestureRecognizer: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        gesture.minimumPressDuration = 0.45
        gesture.allowableMovement = 12
        gesture.cancelsTouchesInView = true
        return gesture
    }()

    init(action: @escaping (CGPoint) -> Void) {
        self.action = action
        super.init()
    }

    @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !didTrigger, let view = gesture.view else { return }
            didTrigger = true
            action(gesture.location(in: view))
        case .ended, .cancelled, .failed:
            didTrigger = false
        default:
            break
        }
    }
}

enum TopicPreviewLinkPolicy {
    enum Behavior: Equatable {
        case stay
        case navigateOut
    }

    static func behavior(
        destination: ForumInternalLinkDestination,
        currentTopicId: Int
    ) -> Behavior {
        switch destination {
        case let .topic(topicId, _) where topicId == currentTopicId:
            return .stay
        case .topic, .category, .tag, .user:
            return .navigateOut
        }
    }
}

/// An expanded reading card: list-card chrome + native first-post body.
final class TopicPreviewViewController: UIViewController {
    private let api: DiscourseAPI
    private let topic: DiscourseTopicList.Topic
    private let categoryName: String?
    private let actions: [TopicPreviewAction]
    private let firstPostLoader: (() async throws -> String?)?

    private let dimView = UIView()
    private let cardView = UIView()
    private let clipView = UIView()
    private let cardStack = UIStackView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let titleLabel = UILabel()
    private let avatarView = UIImageView()
    private let metaLabel = UILabel()
    private let bodyStack = UIStackView()
    private let statsStack = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var cardHeightConstraint: NSLayoutConstraint?
    private var presentationDelegate: TopicPreviewTransitioningDelegate?
    private var loadTask: Task<Void, Never>?
    private var firstPost: DiscourseTopicDetail.Post?
    private var annotatedBlocks: [AnnotatedBlock] = []
    private var lastBodyWidth: CGFloat = 0

    /// The transition animator uses these views to animate the real card, not a blank snapshot.
    fileprivate var transitionCardView: UIView { cardView }
    fileprivate var transitionDimView: UIView { dimView }

    init(
        api: DiscourseAPI,
        topic: DiscourseTopicList.Topic,
        categoryName: String?,
        actions: [TopicPreviewAction] = [],
        firstPostLoader: (() async throws -> String?)? = nil
    ) {
        self.api = api
        self.topic = topic
        self.categoryName = categoryName
        self.actions = actions
        self.firstPostLoader = firstPostLoader
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 380, height: 520)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    fileprivate func setPresentationDelegate(_ delegate: TopicPreviewTransitioningDelegate) {
        presentationDelegate = delegate
        transitioningDelegate = delegate
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let theme = AppSettings.shared.themeStyle

        view.backgroundColor = .clear
        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.32)
        view.addSubview(dimView)
        NSLayoutConstraint.activate([
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissPreview))
        dimView.addGestureRecognizer(dismissTap)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .clear
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.16
        cardView.layer.shadowRadius = 20
        cardView.layer.shadowOffset = CGSize(width: 0, height: 8)
        view.addSubview(cardView)

        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.backgroundColor = theme.topicCardBackgroundColor
        clipView.layer.cornerRadius = previewCornerRadius(theme)
        clipView.layer.cornerCurve = .continuous
        clipView.layer.borderWidth = 1 / UIScreen.main.scale
        clipView.layer.borderColor = UIColor.separator.withAlphaComponent(0.28).cgColor
        clipView.clipsToBounds = true
        cardView.addSubview(clipView)

        cardStack.axis = .vertical
        cardStack.spacing = 0
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(cardStack)

        cardHeightConstraint = cardView.heightAnchor.constraint(equalToConstant: 640)
        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.92),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 430),
            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            cardHeightConstraint!,
            clipView.topAnchor.constraint(equalTo: cardView.topAnchor),
            clipView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
            cardStack.topAnchor.constraint(equalTo: clipView.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
        ])

        configureReadingContent()
        cardStack.addArrangedSubview(scrollView)
        if !actions.isEmpty {
            cardStack.addArrangedSubview(makeActionStack())
        }
        applyHeader()
        applyExcerptFallback()
        installCloseButton()
        loadTask = Task { [weak self] in
            await self?.loadFirstPost()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let availableHeight = max(view.bounds.height - 32, 300)
        let height = min(availableHeight * 0.72, availableHeight - 24)
        if cardHeightConstraint?.constant != height {
            cardHeightConstraint?.constant = height
        }
        cardView.layer.shadowPath = UIBezierPath(
            roundedRect: cardView.bounds,
            cornerRadius: previewCornerRadius(AppSettings.shared.themeStyle)
        ).cgPath
        let bodyWidth = max(contentStack.bounds.width, 0)
        if bodyWidth > 1, abs(bodyWidth - lastBodyWidth) > 1, !annotatedBlocks.isEmpty {
            renderNativeBody(width: bodyWidth)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            loadTask?.cancel()
        }
    }

    private func previewCornerRadius(_ theme: AppSettings.ThemeStyle) -> CGFloat {
        min(theme.chromeCornerRadius + 8, 20)
    }

    private func installCloseButton() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 14
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        clipView.addSubview(blur)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)),
            for: .normal
        )
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = String(localized: "common.close", defaultValue: "关闭")
        closeButton.addTarget(self, action: #selector(dismissPreview), for: .touchUpInside)
        blur.contentView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 12),
            blur.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -12),
            blur.widthAnchor.constraint(equalToConstant: 28),
            blur.heightAnchor.constraint(equalToConstant: 28),
            closeButton.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
            closeButton.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            closeButton.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),
        ])
    }

    private func configureReadingContent() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.addSubview(contentStack)

        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        titleLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 17,
            weight: .semibold,
            fallback: .systemFont(ofSize: 17, weight: .semibold)
        )
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 3
        titleLabel.adjustsFontForContentSizeCategory = true

        let titleClearance = UIView()
        titleClearance.translatesAutoresizingMaskIntoConstraints = false
        titleClearance.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, titleClearance])
        titleRow.axis = .horizontal
        titleRow.alignment = .top
        titleRow.spacing = 8

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 11
        avatarView.backgroundColor = ImagePaintPolicy.waitingFillColor
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 22),
            avatarView.heightAnchor.constraint(equalToConstant: 22),
        ])

        metaLabel.font = TopicListTypography.font(for: .meta, weight: .regular)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail

        let metaRow = UIStackView(arrangedSubviews: [avatarView, metaLabel, spinner])
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = 8
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        bodyStack.axis = .vertical
        bodyStack.spacing = 8
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        contentStack.addArrangedSubview(titleRow)
        contentStack.addArrangedSubview(metaRow)
        contentStack.setCustomSpacing(12, after: metaRow)
        contentStack.addArrangedSubview(bodyStack)
    }

    private func applyHeader() {
        TitleEmojiRenderer.apply(
            TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title),
            to: titleLabel,
            font: titleLabel.font ?? .systemFont(ofSize: 17, weight: .semibold),
            textColor: .label,
            baseURL: api.baseURL
        )
        applyMeta(username: nil)
        applyStats(likes: nil)
    }

    private func applyMeta(username: String?) {
        var parts: [String] = []
        if let username, !username.isEmpty { parts.append(username) }
        if let categoryName, !categoryName.isEmpty { parts.append(categoryName) }
        parts.append(TopicCell.formatDate(topic.lastPostedAt ?? topic.createdAt))
        if let tags = topic.tags, !tags.isEmpty {
            parts.append(tags.prefix(2).map { "#\($0)" }.joined(separator: " "))
        }
        metaLabel.text = parts.joined(separator: " · ")
        avatarView.isHidden = username == nil
    }

    private func applyStats(likes: Int?) {
        statsStack.arrangedSubviews.forEach {
            statsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let replies = max(topic.postsCount - 1, 0)
        statsStack.addArrangedSubview(makeStatChip(symbol: "bubble.left", count: replies))
        if let likes, likes > 0 {
            statsStack.addArrangedSubview(makeStatChip(symbol: "heart", count: likes))
        }
        statsStack.addArrangedSubview(makeStatChip(symbol: "eye", count: topic.views))
        statsStack.isHidden = false
    }

    private func makeStatChip(symbol: String, count: Int) -> UIView {
        let icon = UIImageView(
            image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        )
        icon.tintColor = .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = UILabel()
        label.font = TopicListTypography.font(for: .meta, weight: .medium)
        label.textColor = .secondaryLabel
        label.text = "\(count)"
        label.setContentHuggingPriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 3
        return row
    }

    private func applyExcerptFallback() {
        let excerpt = strippedExcerpt(topic.excerpt)
        if excerpt.isEmpty {
            showBodyPlaceholder(String(localized: "topic.preview.loading", defaultValue: "加载预览…"))
        } else {
            showBodyPlaceholder(excerpt)
        }
    }

    private func showBodyPlaceholder(_ text: String) {
        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let label = UILabel()
        label.font = TopicDetailTypography.bodyContentFont()
        label.textColor = .label
        label.numberOfLines = 0
        label.text = text
        bodyStack.addArrangedSubview(label)
    }

    private func loadFirstPost() async {
        spinner.startAnimating()
        do {
            let cooked: String?
            var loadedPost: DiscourseTopicDetail.Post?
            if let firstPostLoader {
                cooked = try await firstPostLoader()
            } else {
                let detail = try await api.fetchTopic(id: topic.id, trackVisit: false)
                loadedPost = detail.postStream.posts.first
                cooked = loadedPost?.cooked
            }
            let html = cooked?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parsed: [AnnotatedBlock]
            if html.isEmpty {
                parsed = []
            } else {
                parsed = await TopicDetailHTMLParsing.parse(
                    posts: [TopicDetailPostHTML(postId: loadedPost?.id ?? topic.id, cooked: html)],
                    baseURL: api.baseURL
                ).first?.annotatedBlocks ?? []
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.spinner.stopAnimating()
                self.firstPost = loadedPost
                if let post = loadedPost {
                    self.applyMeta(username: post.name ?? post.username)
                    AvatarImageLoader.setImage(
                        on: self.avatarView,
                        template: post.avatarTemplate,
                        baseURL: self.api.baseURL,
                        userId: post.userId,
                        size: 40
                    )
                    self.applyStats(likes: post.reactionUsersCount)
                }
                if parsed.isEmpty {
                    self.applyExcerptFallback()
                    if self.bodyStack.arrangedSubviews.isEmpty {
                        self.showBodyPlaceholder(
                            String(localized: "topic.preview.empty", defaultValue: "暂无预览内容")
                        )
                    }
                } else {
                    self.annotatedBlocks = parsed
                    self.renderNativeBody(width: max(self.contentStack.bounds.width, 1))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.spinner.stopAnimating()
                self.applyExcerptFallback()
            }
        }
    }

    private func renderNativeBody(width: CGFloat) {
        let contentWidth = max(width - 36, 200)
        lastBodyWidth = width
        bodyStack.arrangedSubviews.forEach {
            bodyStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let gallery = TopicImageGallerySources.urls(from: annotatedBlocks)
        let config = NativeRenderConfig.default(
            contentWidth: contentWidth,
            baseURL: api.baseURL,
            postId: firstPost?.id,
            galleryImageURLs: gallery,
            topicTagNames: Set(topic.tags ?? [])
        )
        let views = NativeContentRenderer.renderBlocks(annotatedBlocks, config: config, delegate: self)
        for view in views {
            bodyStack.addArrangedSubview(view)
            wireTextViews(in: view)
        }
        view.setNeedsLayout()
    }

    private func wireTextViews(in view: UIView) {
        if let textView = view as? UITextView {
            textView.delegate = self
            return
        }
        if let stack = view as? UIStackView {
            stack.arrangedSubviews.forEach { wireTextViews(in: $0) }
            return
        }
        view.subviews.forEach { wireTextViews(in: $0) }
    }

    private func strippedExcerpt(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&hellip;", with: "…")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleLink(_ url: URL) {
        let linkURL = ForumInternalLinkParser.normalizedURL(from: url, baseURL: api.baseURL)
        guard ForumInternalLinkParser.isInternalURL(linkURL, baseURL: api.baseURL),
              let destination = ForumInternalLinkParser.destination(for: linkURL)
        else {
            DoerSafariPresenter.present(
                url: linkURL,
                from: self,
                api: api,
                username: AuthManager.shared.username(for: api.baseURL)
            )
            return
        }
        switch TopicPreviewLinkPolicy.behavior(destination: destination, currentTopicId: topic.id) {
        case .stay:
            return
        case .navigateOut:
            let viewController: UIViewController
            switch destination {
            case let .topic(id, postNumber):
                viewController = TopicDetailFactory.make(
                    api: api,
                    topicId: id,
                    initialFloor: postNumber
                )
            case let .category(slug, categoryId):
                viewController = CategoryTopicsViewController(
                    api: api,
                    category: DiscourseCategory(id: categoryId, name: slug, slug: slug)
                )
            case let .tag(tagName):
                viewController = TagTopicsViewController(api: api, tagName: tagName)
            case let .user(username):
                viewController = UserProfileViewController(api: api, username: username)
            }
            dismissThen { presenter in
                if let nav = presenter.navigationController {
                    nav.pushViewController(viewController, animated: true)
                } else {
                    presenter.present(UINavigationController(rootViewController: viewController), animated: true)
                }
            }
        }
    }

    private func openCurrentTopic() {
        let open = actions.first?.handler
        dismissThen { _ in open?() }
    }

    private func makeActionStack() -> UIView {
        let theme = AppSettings.shared.themeStyle
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = theme.topicChipBackgroundColor

        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
        bar.addSubview(hairline)

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        statsStack.axis = .horizontal
        statsStack.alignment = .center
        statsStack.spacing = 12
        statsStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(statsStack)
        applyStats(likes: nil)

        let primary = actions.first
        let secondary = Array(actions.dropFirst())
        for action in secondary {
            row.addArrangedSubview(makeIconActionButton(action, theme: theme))
        }
        if let primary {
            let button = makePrimaryActionButton(primary, theme: theme)
            row.addArrangedSubview(button)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: bar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
        return bar
    }

    private func makeIconActionButton(_ action: TopicPreviewAction, theme: AppSettings.ThemeStyle) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(action.image, for: .normal)
        button.tintColor = theme.accentColor
        button.backgroundColor = theme.topicCountBackgroundColor
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .continuous
        button.accessibilityLabel = action.title
        button.addAction(UIAction { [weak self] _ in
            self?.runPreviewAction(action)
        }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    private func makePrimaryActionButton(_ action: TopicPreviewAction, theme: AppSettings.ThemeStyle) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = action.title
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = theme.accentColor
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 14, bottom: 7, trailing: 14)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = AppSettings.shared.appInterfaceFont(
                ofSize: 15,
                weight: .semibold,
                fallback: .systemFont(ofSize: 15, weight: .semibold)
            )
            return outgoing
        }
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = action.title
        button.addAction(UIAction { [weak self] _ in
            self?.runPreviewAction(action)
        }, for: .touchUpInside)
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func runPreviewAction(_ action: TopicPreviewAction) {
        dismiss(animated: true, completion: action.handler)
    }

    private func dismissThen(_ body: @escaping (UIViewController) -> Void) {
        let presenter = presentingViewController
        dismiss(animated: true) {
            guard let presenter else { return }
            body(presenter)
        }
    }

    @objc private func dismissPreview() {
        dismiss(animated: true)
    }
}

extension TopicPreviewViewController: PostCellDelegate, UITextViewDelegate {
    func postCell(didTapImageURL url: URL, imageURLs: [URL], sourceView: UIView?) {
        presentTopicImageGallery(currentURL: url, imageURLs: imageURLs, sourceView: sourceView)
    }

    func postCell(didTapLinkURL url: URL) {
        handleLink(url)
    }

    func postCell(didTapShowRepliesForPostId postId: Int) { openCurrentTopic() }
    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {}
    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) { openCurrentTopic() }
    func postCell(didTapEditPost post: DiscourseTopicDetail.Post) { openCurrentTopic() }
    func postCell(didTapShareImageForPost post: DiscourseTopicDetail.Post) { openCurrentTopic() }
    func postCell(didTapShowRevisionForPost post: DiscourseTopicDetail.Post) { openCurrentTopic() }
    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {}
    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) { openCurrentTopic() }
    func postCell(didRequestDeleteBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didUpdateBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didTapAvatarForUsername username: String) {
        let profile = UserProfileViewController(api: api, username: username)
        dismissThen { presenter in
            if let nav = presenter.navigationController {
                nav.pushViewController(profile, animated: true)
            } else {
                presenter.present(UINavigationController(rootViewController: profile), animated: true)
            }
        }
    }
    func postCell(didTapQuotedPostNumber postNumber: Int) { openCurrentTopic() }
    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {}
    func postCell(didTapToggleSharedIssueForTopicId topicId: Int) {}
    func postCell(didSubmitPollVoteForPostId postId: Int, pollName: String, optionIds: [String]) { openCurrentTopic() }

    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        handleLink(URL)
        return false
    }
}

final class TopicPreviewTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    private let anchorRect: CGRect?

    init(anchorRect: CGRect?) {
        self.anchorRect = anchorRect
    }

    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        TopicPreviewTransitionAnimator(isPresenting: true, anchorRect: anchorRect)
    }

    func animationController(
        forDismissed dismissed: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        TopicPreviewTransitionAnimator(isPresenting: false, anchorRect: anchorRect)
    }
}

private final class TopicPreviewTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool
    private let anchorRect: CGRect?

    init(isPresenting: Bool, anchorRect: CGRect?) {
        self.isPresenting = isPresenting
        self.anchorRect = anchorRect
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.01 : 0.36
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)

        if isPresenting {
            guard let preview = transitionContext.viewController(forKey: .to) as? TopicPreviewViewController else {
                transitionContext.completeTransition(false)
                return
            }
            let previewView = preview.view!
            previewView.frame = container.bounds
            container.addSubview(previewView)
            previewView.layoutIfNeeded()
            let card = preview.transitionCardView
            let initialTransform = transformToAnchor(for: card, in: container)
            card.transform = initialTransform
            preview.transitionDimView.alpha = 0
            previewView.isUserInteractionEnabled = false

            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: 0.88,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                card.transform = .identity
                preview.transitionDimView.alpha = 1
            } completion: { finished in
                previewView.isUserInteractionEnabled = finished
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
            return
        }

        guard let preview = transitionContext.viewController(forKey: .from) as? TopicPreviewViewController else {
            transitionContext.completeTransition(false)
            return
        }
        let previewView = preview.view!
        previewView.layoutIfNeeded()
        let card = preview.transitionCardView
        card.transform = .identity
        let finalTransform = transformToAnchor(for: card, in: container)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseIn],
            animations: {
                card.transform = finalTransform
                preview.transitionDimView.alpha = 0
            },
            completion: { finished in
                transitionContext.completeTransition(finished && !transitionContext.transitionWasCancelled)
            }
        )
    }

    private func transformToAnchor(for card: UIView, in container: UIView) -> CGAffineTransform {
        guard let anchorRect,
              anchorRect.width > 1,
              anchorRect.height > 1,
              !anchorRect.isNull,
              !anchorRect.isInfinite
        else {
            return CGAffineTransform(scaleX: 0.92, y: 0.92)
        }

        let targetFrame = card.convert(card.bounds, to: container)
        let anchorFrame = container.convert(anchorRect, from: nil)
        let scaleX = max(anchorFrame.width / max(targetFrame.width, 1), 0.01)
        let scaleY = max(anchorFrame.height / max(targetFrame.height, 1), 0.01)
        return CGAffineTransform(translationX: anchorFrame.midX - targetFrame.midX, y: anchorFrame.midY - targetFrame.midY)
            .scaledBy(x: scaleX, y: scaleY)
    }
}

protocol TopicPreviewTargetProviding: AnyObject {
    var topicPreviewTargetView: UIView { get }
}

enum XiaohongshuPreviewSelection {
    enum Side: Equatable { case left, right }

    static func side(at point: CGPoint, in bounds: CGRect) -> Side? {
        guard bounds.width > 0, bounds.contains(point) else { return nil }
        return point.x < bounds.midX ? .left : .right
    }

    static func unpinnedTopicIndex(rowIndex: Int, side: Side) -> Int {
        rowIndex * 2 + (side == .right ? 1 : 0)
    }

    static func topic<T>(in unpinnedTopics: [T], rowIdentifier: Int, side: Side) -> T? {
        guard let rowIndex = XiaohongshuHomeTopicListLayout.rowIndex(from: rowIdentifier) else { return nil }
        let index = unpinnedTopicIndex(rowIndex: rowIndex, side: side)
        return unpinnedTopics.indices.contains(index) ? unpinnedTopics[index] : nil
    }
}

enum TopicPreviewMenu {
    static func installLongPress(
        on tableView: UITableView,
        action: @escaping (CGPoint) -> Void
    ) -> TopicPreviewLongPressHandler {
        let handler = TopicPreviewLongPressHandler(action: action)
        tableView.addGestureRecognizer(handler.gestureRecognizer)
        return handler
    }

    static func present(
        topic: DiscourseTopicList.Topic,
        api: DiscourseAPI,
        categoryName: String?,
        actions: [TopicPreviewAction],
        sourceView: UIView?,
        from presenter: UIViewController
    ) {
        guard presenter.viewIfLoaded?.window != nil,
              presenter.presentedViewController == nil
        else { return }

        let anchorRect: CGRect? = {
            guard let sourceView,
                  sourceView.window != nil,
                  !sourceView.bounds.isEmpty
            else { return nil }
            return sourceView.convert(sourceView.bounds, to: nil)
        }()
        let preview = TopicPreviewViewController(
            api: api,
            topic: topic,
            categoryName: categoryName,
            actions: actions
        )
        preview.setPresentationDelegate(TopicPreviewTransitioningDelegate(anchorRect: anchorRect))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        presenter.present(preview, animated: true)
    }

    static func targetView(in cell: UITableViewCell) -> UIView {
        if let providing = cell as? TopicPreviewTargetProviding {
            return providing.topicPreviewTargetView
        }
        return cell.contentView
    }
}
