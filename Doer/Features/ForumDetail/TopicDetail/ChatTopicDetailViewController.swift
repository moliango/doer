import CookedHTML
import UIKit

/// Chat-style Topic Detail parent for WeChat / Telegram themes.
/// Parallel to `TopicDetailViewController` — classic path unchanged.
/// Subclasses override theme hooks; lifecycle stays here.
class ChatTopicDetailViewController: ObservableViewController {
    func chatThemeStyle() -> ChatTopicStyle { .weChat }
    var chatStyle: ChatTopicStyle { chatThemeStyle() }

    func dateSeparatorText(for post: DiscourseTopicDetail.Post, at row: Int) -> String? { nil }

    func incomingLinkColor(defaultColor: UIColor) -> UIColor { defaultColor }

    func registerChatCells(on tableView: UITableView) {
        tableView.register(WeChatChatPostCell.self, forCellReuseIdentifier: WeChatChatPostCell.reuseIdentifier)
    }

    func chatPostCellReuseIdentifier() -> String {
        WeChatChatPostCell.reuseIdentifier
    }

    func makeChatInputBar() -> WeChatChatInputBar {
        WeChatChatInputBar(chatStyle: chatThemeStyle())
    }

    func estimatedChatRowHeight() -> CGFloat { 140 }

    func jumpScrollPosition() -> UITableView.ScrollPosition { .middle }

    func scrollsToBottomWhenOpeningLatest() -> Bool { true }

    func animatesCanvasColorChange() -> Bool { false }

    let api: DiscourseAPI
    let viewModel: TopicDetailViewModel
    let topicId: Int
    var lastReadPostNumber: Int?
    /// Notification / deep-link: try nested tree first, fall back to flat.
    var preferNestedOnLoad = false
    let initialFloor: Int?
    let initialPostId: Int?
    let baseURL: String
    private let forum: ForumInstance?

    private var didLoad = false
    private var cloudflareCompletionObservationToken: NSObjectProtocol?
    private var isRecoveringAfterCloudflare = false
    private var isLoadingMore = false
    private var isLoadingEarlier = false
    private var postRowHeightCache: [Int: CGFloat] = [:]
    lazy var readingTracker = TopicReadingTracker(api: api)
    let findController = TopicFindBarController()

    private lazy var tableView: UITableView = {
        let tv = TopicDetailPopAwareTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        registerChatCells(on: tv)
        tv.separatorStyle = .none
        // Force a real background view — plain UITableView sometimes ignores backgroundColor
        // and falls back to system white, which reads as “no chat wallpaper”.
        let canvas = chatThemeStyle().chatBackgroundColor
        tv.backgroundColor = canvas
        let bg = UIView()
        bg.backgroundColor = canvas
        tv.backgroundView = bg
        tv.keyboardDismissMode = .interactive
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = estimatedChatRowHeight()
        tv.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        tv.showsHorizontalScrollIndicator = false
        tv.delegate = self
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = {
        UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { [weak self] tableView, indexPath, postId in
            guard let self,
                  let post = self.viewModel.post(byId: postId),
                  let cell = tableView.dequeueReusableCell(
                    withIdentifier: chatPostCellReuseIdentifier(),
                    for: indexPath
                  ) as? WeChatChatPostCell
            else {
                return UITableViewCell()
            }

            // Prefer parsed blocks; empty array still renders plain-text fallback in the cell.
            let annotatedBlocks = self.viewModel.parsedBlocks[postId] ?? []
            let floorNumber = self.floorNumber(for: postId)
            let tableWidth = tableView.bounds.width > 1 ? tableView.bounds.width : UIScreen.main.bounds.width
            let style = self.chatStyle
            // Reserve avatar column for incoming; outgoing Telegram has no avatar.
            let avatarReserve: CGFloat = (post.yours && !style.showsOutgoingAvatar) ? 0 : style.avatarSize
            // Row: inset + avatar + gap + bubble + trailing margin — wider for chat themes.
            let maxOuter = tableWidth - 8 - avatarReserve - 6 - 8
            let bubbleOuter = max(maxOuter * style.maxBubbleFraction, 200)
            let pad = style.bubblePadding
            let bubbleWidth = max(bubbleOuter - pad * 2, 160) // inner content width for NativeRenderConfig
            let galleryImageURLs = TopicImageGallerySources.urls(from: annotatedBlocks)
            var config = NativeRenderConfig.default(
                contentWidth: bubbleWidth,
                baseURL: self.baseURL,
                postId: post.id,
                galleryImageURLs: galleryImageURLs,
                topicTagNames: Set(self.viewModel.topic?.tags.map(\.name) ?? []),
                topicCategoryPresentation: self.viewModel.categoryPresentation
            )
            let isDark = self.traitCollection.userInterfaceStyle == .dark
            // Keep body typography on the shared content scale — do not densify fonts
            // per chat theme (that made WeChat/Telegram look smaller than classic).
            config = NativeRenderConfig(
                baseFont: config.baseFont,
                baseColor: post.yours
                    ? style.outgoingTextColor(isDark: isDark)
                    : .label,
                linkColor: post.yours
                    ? style.outgoingLinkColor(isDark: isDark)
                    : incomingLinkColor(defaultColor: config.linkColor),
                codeFont: config.codeFont,
                codeBackgroundColor: config.codeBackgroundColor,
                contentWidth: config.contentWidth,
                baseURL: config.baseURL,
                postId: config.postId,
                galleryImageURLs: config.galleryImageURLs,
                topicTagNames: config.topicTagNames,
                topicCategoryPresentation: config.topicCategoryPresentation,
                defaultLineSpacing: config.defaultLineSpacing,
                defaultParagraphSpacing: config.defaultParagraphSpacing
            )

            let dateSeparator = self.dateSeparatorText(for: post, at: indexPath.row)

            cell.actionDelegate = self
            cell.configure(
                with: post,
                annotatedBlocks: annotatedBlocks,
                config: config,
                floorNumber: floorNumber,
                baseURL: self.baseURL,
                contentDelegate: self,
                dateSeparatorText: dateSeparator,
                chatStyle: style,
                replyQuote: self.makeChatReplyQuote(for: post)
            )
            return cell
        }
    }()

    private let loadingSkeletonView = TopicDetailSkeletonView()
    private let suggestedTopicsFooter = SuggestedTopicsFooterView()

    private let errorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let remainderErrorFooter: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private var chatInputBarBottomConstraint: NSLayoutConstraint?

    /// Bottom chat input from the subclass hook; plus still opens the full composer.
    private lazy var chatInputBar: WeChatChatInputBar = {
        let bar = makeChatInputBar()
        bar.onSend = { [weak self] raw in
            self?.performAuthenticated { self?.sendQuickReply(raw) }
        }
        bar.onPlus = { [weak self] in
            self?.performAuthenticated {
                guard let self else { return }
                let target = self.chatInputBar.replyToPost
                let draft = self.chatInputBar.text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.presentReplyComposer(
                    for: target,
                    initialText: draft.isEmpty ? nil : draft
                )
            }
        }
        bar.onEmoji = { [weak self] in
            self?.performAuthenticated { self?.presentChatEmojiPicker() }
        }
        bar.onBeginEditing = { [weak self] in
            self?.performAuthenticated {
                // Auth gate only; keep first responder if already logged in.
            }
        }
        return bar
    }()

    private var chatBackgroundColor: UIColor {
        chatStyle.chatBackgroundColor
    }

    private var lastCanvasColor: UIColor?

    /// Keep view + table + backgroundView in sync (trait / dark mode).
    /// Opened chat pages keep their subclass; WeChat/Telegram canvases are never swapped here.
    private func applyChatCanvasBackground() {
        let canvas = chatBackgroundColor
        let shouldAnimate = animatesCanvasColorChange()
            && lastCanvasColor != nil
            && lastCanvasColor != canvas

        if shouldAnimate {
            let animator = DoerMotion.propertyAnimator(
                duration: DoerMotion.standard,
                timingParameters: DoerMotion.softSpring
            )
            animator.addAnimations {
                self.updateCanvasBackground(to: canvas)
                self.chatInputBar.applyChatStyle()
            }
            animator.startAnimation()
        } else {
            updateCanvasBackground(to: canvas)
            chatInputBar.applyChatStyle()
        }

        lastCanvasColor = canvas
    }

    private func updateCanvasBackground(to canvas: UIColor) {
        view.backgroundColor = canvas
        tableView.backgroundColor = ForumWallpaper.storedImage == nil ? canvas : .clear
        ForumWallpaper.apply(to: view, dim: 0.55)
        if let bg = tableView.backgroundView {
            bg.backgroundColor = canvas
        } else {
            let bg = UIView()
            bg.backgroundColor = canvas
            tableView.backgroundView = bg
        }
        // Empty table footer prevents last-cell white bleed on some iOS versions.
        if tableView.tableFooterView == nil {
            tableView.tableFooterView = UIView()
        }
        tableView.tableFooterView?.backgroundColor = .clear
    }

    init(
        api: DiscourseAPI,
        topicId: Int,
        initialFloor: Int? = nil,
        initialPostId: Int? = nil,
        lastReadPostNumber: Int? = nil,
        forum: ForumInstance? = nil
    ) {
        self.api = api
        self.viewModel = TopicDetailViewModel(api: api)
        self.topicId = topicId
        self.initialFloor = initialFloor
        self.initialPostId = initialPostId
        self.lastReadPostNumber = lastReadPostNumber
        self.baseURL = api.baseURL
        self.forum = forum
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
        _ = lastReadPostNumber // reserved for jump-to-unread follow-up
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    deinit {
        if let cloudflareCompletionObservationToken {
            NotificationCenter.default.removeObserver(cloudflareCompletionObservationToken)
        }
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        startObservingCloudflareVerification()
        applyChatCanvasBackground()
        chatInputBar.applyChatStyle()
        loadingSkeletonView.applyThemeStyle(chatStyle: chatThemeStyle())
        navigationItem.largeTitleDisplayMode = .never
        configureTopicActions()
        title = String(localized: "topic_detail.default_title", defaultValue: "话题")

        view.addSubview(tableView)
        view.addSubview(chatInputBar)
        view.addSubview(loadingSkeletonView)
        view.addSubview(errorLabel)
        installTopicFindBar()

        let inputBottom = chatInputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        chatInputBarBottomConstraint = inputBottom
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: findController.bar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: chatInputBar.topAnchor),

            chatInputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatInputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottom,

            loadingSkeletonView.topAnchor.constraint(equalTo: findController.bar.bottomAnchor),
            loadingSkeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingSkeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingSkeletonView.bottomAnchor.constraint(equalTo: chatInputBar.topAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Tap blank chat area to dismiss keyboard.
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissChatKeyboard))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chatKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chatKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func dismissChatKeyboard() {
        chatInputBar.resign()
    }

    @objc private func chatKeyboardWillChangeFrame(_ notification: Notification) {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }
        let converted = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.minY)
        let lift = max(0, overlap - view.safeAreaInsets.bottom)
        chatInputBarBottomConstraint?.constant = -lift
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt)
            ?? UIView.AnimationOptions.curveEaseInOut.rawValue
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        ) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func chatKeyboardWillHide(_ notification: Notification) {
        chatInputBarBottomConstraint?.constant = 0
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt)
            ?? UIView.AnimationOptions.curveEaseInOut.rawValue
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        ) {
            self.view.layoutIfNeeded()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = canNavigateBack
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = canNavigateBack
        readingTracker.start(topicId: topicId)
        updateVisibleReadingPosts()
        if !didLoad {
            didLoad = true
            Task { await loadInitial() }
        }
        Task {
            await api.loadOrFetchEmojiMap()
            await MainActor.run { [weak self] in
                self?.tableView.reloadData()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        readingTracker.stop()
        syncReadLaterProgressOnExit()
    }

    private var lastContentFontSize = AppSettings.shared.contentFontSize
    private var lastContentFontScalePercent = AppSettings.shared.contentFontScalePercent
    private var lastContentFontFamily = AppSettings.shared.contentFontFamily
    private var lastContentFontScope = AppSettings.shared.contentFontScope
    private var lastInterfaceFontScalePercent = AppSettings.shared.interfaceFontScalePercent
    private var lastReadingComfortMode = AppSettings.shared.readingComfortMode
    private var lastContentImageCarouselEnabled = AppSettings.shared.contentImageCarouselEnabled

    override func updateUI() {
        tableView.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        tableView.showsHorizontalScrollIndicator = false
        applyChatCanvasBackground()
        chatInputBar.applyChatStyle()
        loadingSkeletonView.applyThemeStyle(chatStyle: chatThemeStyle())
        if let topic = viewModel.topic {
            let display = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
            title = display
            navigationItem.title = display
        }
        configureTopicActions()

        let settings = AppSettings.shared
        let shouldReloadVisibleContent = lastReadingComfortMode != settings.readingComfortMode
            || lastContentFontSize != settings.contentFontSize
            || lastContentFontScalePercent != settings.contentFontScalePercent
            || lastContentFontFamily != settings.contentFontFamily
            || lastContentFontScope != settings.contentFontScope
            || lastInterfaceFontScalePercent != settings.interfaceFontScalePercent
            || lastContentImageCarouselEnabled != settings.contentImageCarouselEnabled
        lastReadingComfortMode = settings.readingComfortMode
        lastContentFontSize = settings.contentFontSize
        lastContentFontScalePercent = settings.contentFontScalePercent
        lastContentFontFamily = settings.contentFontFamily
        lastContentFontScope = settings.contentFontScope
        lastInterfaceFontScalePercent = settings.interfaceFontScalePercent
        lastContentImageCarouselEnabled = settings.contentImageCarouselEnabled

        let showsInitialLoading = viewModel.isLoading && !viewModel.isReady && viewModel.errorMessage == nil
        loadingSkeletonView.setSkeletonActive(showsInitialLoading, animated: view.window != nil)
        tableView.isHidden = showsInitialLoading
            || (viewModel.errorMessage != nil && !viewModel.isReady)

        if let error = viewModel.errorMessage, !viewModel.isReady {
            errorLabel.isHidden = false
            errorLabel.text = error
            errorLabel.font = TopicDetailTypography.chromeFont(.error, weight: .regular)
        } else {
            errorLabel.isHidden = true
        }

        if viewModel.isReady {
            applySnapshot()
            if shouldReloadVisibleContent {
                postRowHeightCache.removeAll(keepingCapacity: true)
                // Force body/chrome re-render with the shared content scale.
                tableView.reloadData()
            }
            updateSuggestedTopicsFooter()
        }
    }

    private func applyRemainderLoadErrorFooter(_ text: String) {
        remainderErrorFooter.text = text
        remainderErrorFooter.font = TopicDetailTypography.chromeFont(.error, weight: .regular)
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        let fittingWidth = max(0, width - 32)
        let size = remainderErrorFooter.sizeThatFits(
            CGSize(width: fittingWidth, height: .greatestFiniteMagnitude)
        )
        remainderErrorFooter.frame = CGRect(
            x: 0,
            y: 0,
            width: width,
            height: max(44, size.height + 24)
        )
        tableView.tableFooterView = remainderErrorFooter
    }

    private func updateSuggestedTopicsFooter() {
        if TopicDetailFirstPaintPolicy.shouldPreserveEarlyOpeningPost(
            isReady: viewModel.isReady,
            hasFirstPost: viewModel.posts.first != nil,
            hasTopic: viewModel.topic != nil
        ), let error = viewModel.errorMessage {
            applyRemainderLoadErrorFooter(error)
            return
        }
        let relatedTopics = viewModel.topic?.relatedTopics ?? []
        let suggestedTopics = viewModel.topic?.suggestedTopics ?? []
        let show = viewModel.isReady
            && !viewModel.canLoadMore
            && (!relatedTopics.isEmpty || !suggestedTopics.isEmpty)
            && AppSettings.shared.showSuggestedTopics
        guard show else {
            if tableView.tableFooterView === suggestedTopicsFooter
                || tableView.tableFooterView === remainderErrorFooter {
                tableView.tableFooterView = UIView()
            }
            return
        }
        suggestedTopicsFooter.onSelectTopic = { [weak self] id in
            guard let self else { return }
            let detail = TopicDetailFactory.make(api: self.api, topicId: id)
            self.navigationController?.pushViewController(detail, animated: true)
        }
        suggestedTopicsFooter.onBrowseCategory = { [weak self] _, _ in
            guard let self, let category = self.viewModel.category else { return }
            self.navigationController?.pushViewController(
                CategoryTopicsViewController(api: self.api, category: category),
                animated: true
            )
        }
        suggestedTopicsFooter.configure(
            relatedTopics: relatedTopics,
            suggestedTopics: suggestedTopics,
            baseURL: baseURL,
            categoryId: viewModel.topic?.categoryId,
            categoryName: viewModel.category?.name
        )
        let width = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        let height = suggestedTopicsFooter.preferredHeight(forWidth: width)
        suggestedTopicsFooter.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableFooterView = suggestedTopicsFooter
    }

    private func loadInitial() async {
        if preferNestedOnLoad {
            viewModel.setNestedViewEnabled(true)
        }
        let width = max(view.bounds.width, UIScreen.main.bounds.width)
        await viewModel.loadTopic(
            id: topicId,
            containerWidth: width,
            initialFloor: initialFloor,
            initialPostId: initialPostId
        )
        // Nested may fail without errorMessage (catch path clears it). Exit tree if unrenderable.
        if viewModel.isNestedViewEnabled {
            viewModel.abandonNestedIfUnrenderable()
            if viewModel.topic != nil {
                viewModel.errorMessage = nil
            }
        }
        // Merge server detail last_read with constructor hint / local store.
        if let detailLast = viewModel.topic?.lastReadPostNumber {
            lastReadPostNumber = max(lastReadPostNumber ?? 0, detailLast)
        }
        let local = TopicReadProgressStore.shared.highestSeen(
            topicId: topicId,
            baseURL: baseURL,
            username: AuthManager.shared.username(for: baseURL)
        )
        if local > 0 {
            lastReadPostNumber = max(lastReadPostNumber ?? 0, local)
        }

        switch TopicDetailOpenAnchor.resolve(
            initialPostId: initialPostId,
            initialFloor: initialFloor,
            lastRead: lastReadPostNumber ?? 0,
            totalFloors: viewModel.totalFloors,
            pinLatestWhenFullyRead: scrollsToBottomWhenOpeningLatest(),
            openingPostId: viewModel.posts.first(where: { $0.postNumber == 1 })?.id
        ) {
        case .postId(let postId):
            if isOpeningPostId(postId) { break }
            jumpToPostId(postId)
        case .floor(let floor):
            if floor <= 1 { break }
            await jumpToPostNumber(floor)
        case .top:
            break
        }
    }

    func applySnapshot() {
        // Only show posts that finished HTML parse — same gate as classic Topic Detail.
        // (Cell still has plain-text fallback if blocks are empty.)
        _ = viewModel.abandonNestedIfUnrenderable(notify: false)
        var seen = Set<Int>()
        // Nested API rows already carry tree order; NestedReplyOrdering would scramble sort.
        var ids = viewModel.visiblePosts.compactMap { post -> Int? in
            guard viewModel.parsedBlocks[post.id] != nil,
                  seen.insert(post.id).inserted
            else { return nil }
            return post.id
        }
        // Title-only white body: nested produced nothing paintable — force flat stream ids.
        if ids.isEmpty {
            seen.removeAll(keepingCapacity: true)
            if viewModel.isNestedViewEnabled {
                viewModel.forceDisableNested(notify: false)
            }
            let flat = viewModel.visiblePosts.compactMap { post -> Int? in
                guard viewModel.parsedBlocks[post.id] != nil,
                      seen.insert(post.id).inserted else { return nil }
                return post.id
            }
            if !flat.isEmpty {
                ids = flat
            }
        }
        let current = dataSource.snapshot().itemIdentifiers
        guard ids != current else {
            // Same IDs: still reconfigure visible rows so reaction/bookmark state refreshes.
            var snapshot = dataSource.snapshot()
            let visible = (tableView.indexPathsForVisibleRows ?? []).compactMap {
                dataSource.itemIdentifier(for: $0)
            }.filter { snapshot.indexOfItem($0) != nil }
            if !visible.isEmpty {
                snapshot.reloadItems(visible)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            return
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
        prefetchContentImages(forPostIds: ids)
    }

    private func floorNumber(for postId: Int) -> Int {
        let allPostIds = viewModel.allPostIds
        if let streamIndex = allPostIds.firstIndex(of: postId) {
            return streamIndex + 1
        }
        return (viewModel.visiblePosts.firstIndex(where: { $0.id == postId }) ?? 0) + 1
    }

    func currentVisibleFloor() -> Int {
        guard viewModel.totalFloors > 0 else { return 1 }
        let visibleIndexPath = tableView.indexPathsForVisibleRows?
            .sorted { $0.row < $1.row }
            .first
        if let visibleIndexPath,
           let postId = dataSource.itemIdentifier(for: visibleIndexPath) {
            return floorNumber(for: postId)
        }
        return max(1, min(viewModel.totalFloors, 1))
    }

    func showTimelineSheet() {
        let stream = viewModel.allPostIds
        guard !stream.isEmpty else { return }
        let timeline = TopicTimelineSheetViewController(
            currentIndex: currentVisibleFloor(),
            stream: stream,
            title: TitleEmojiRenderer.plainTitle(
                fancyTitle: viewModel.topic?.fancyTitle,
                title: viewModel.topic?.title ?? ""
            )
        )
        timeline.onJumpToPostId = { [weak self] postId in
            guard let self else { return }
            self.jumpToPostId(postId)
        }
        timeline.modalPresentationStyle = .pageSheet
        timeline.isModalInPresentation = true
        if let sheet = timeline.sheetPresentationController {
            if #available(iOS 16.0, *) {
                let timelineDetent = UISheetPresentationController.Detent.custom(
                    identifier: .init("topic.timeline")
                ) { context in
                    let fitted = TopicTimelineSheetViewController.preferredSheetHeight + 34
                    return min(fitted, context.maximumDetentValue)
                }
                sheet.detents = [timelineDetent]
                sheet.selectedDetentIdentifier = timelineDetent.identifier
            } else {
                sheet.detents = [.medium()]
            }
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(timeline, animated: true)
    }

    /// Centered date chip when the calendar day changes vs previous row.
    func chatDateSeparatorText(for post: DiscourseTopicDetail.Post, at row: Int) -> String? {
        let ids = dataSource.snapshot().itemIdentifiers
        var previousCreatedAt: String?
        if row > 0, row - 1 < ids.count {
            let prevId = ids[row - 1]
            previousCreatedAt = viewModel.posts.first(where: { $0.id == prevId })?.createdAt
        }
        return ChatDateSeparator.text(forCreatedAt: post.createdAt, previousCreatedAt: previousCreatedAt)
    }

    /// Quote for any reply (A→you and A→B). Parent body is used when that post is already loaded.
    func makeChatReplyQuote(for post: DiscourseTopicDetail.Post) -> ChatReplyQuote? {
        guard post.replyToUser != nil || post.replyToPostNumber != nil else { return nil }
        let parent = post.replyToPostNumber.flatMap { viewModel.post(byPostNumber: $0) }
        let displayName: String
        if let parent {
            displayName = (parent.name?.isEmpty == false ? parent.name : nil) ?? parent.username
        } else {
            displayName = post.replyToUser?.username ?? ""
        }
        let preview: String
        if let parent {
            preview = CookedContentPipeline.plainTextPreview(fromCooked: parent.cooked)
        } else if let n = post.replyToPostNumber {
            preview = String(
                format: String(localized: "telegram_chat.reply_floor_fmt", defaultValue: "回复 #%d"),
                n
            )
        } else {
            preview = String(localized: "telegram_chat.reply", defaultValue: "回复")
        }
        return ChatReplyQuote(
            displayName: displayName,
            preview: preview,
            postId: parent?.id,
            postNumber: parent?.postNumber ?? post.replyToPostNumber
        )
    }

    private func reloadPostCell(postId: Int) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(postId) != nil else { return }
        snapshot.reloadItems([postId])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func scrollToPostId(_ postId: Int) {
        guard let index = dataSource.snapshot().indexOfItem(postId) else { return }
        let indexPath = IndexPath(row: index, section: 0)
        tableView.scrollToRow(at: indexPath, at: jumpScrollPosition(), animated: false)
    }

    func shouldStayAtOpeningPost(floor: Int? = nil, postNumber: Int? = nil, postId: Int? = nil) -> Bool {
        let openingId = viewModel.posts.first(where: { $0.postNumber == 1 })?.id
            ?? viewModel.allPostIds.first
        let isOpening = TopicDetailOpenAnchor.isOpeningPostTarget(
            floor: floor,
            postNumber: postNumber,
            postId: postId,
            openingPostId: openingId
        )
        return TopicDetailOpenAnchor.shouldStayAtOpeningPost(
            isOpeningPostTarget: isOpening,
            contentOffsetY: tableView.contentOffset.y
        )
    }

    func isOpeningPostId(_ postId: Int) -> Bool {
        if viewModel.posts.first(where: { $0.postNumber == 1 })?.id == postId { return true }
        return viewModel.allPostIds.first == postId
    }

    func scrollToContentTop(animated: Bool) {
        let y = -tableView.adjustedContentInset.top
        guard abs(tableView.contentOffset.y - y) > 1 else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: animated)
    }

    func jumpToPostId(_ postId: Int) {
        if isOpeningPostId(postId) {
            scrollToContentTop(animated: false)
            return
        }
        if dataSource.snapshot().indexOfItem(postId) != nil {
            scrollToPostId(postId)
            return
        }
        guard let streamIndex = viewModel.allPostIds.firstIndex(of: postId) else { return }
        Task { await jumpToFloor(streamIndex + 1) }
    }

    func jumpToPostNumber(_ postNumber: Int) async {
        guard postNumber > 1 else {
            scrollToContentTop(animated: false)
            return
        }
        if let post = viewModel.post(byPostNumber: postNumber) {
            jumpToPostId(post.id)
            return
        }
        do {
            let post = try await api.fetchPostByNumber(topicId: topicId, postNumber: postNumber)
            if viewModel.allPostIds.contains(post.id) {
                jumpToPostId(post.id)
            }
        } catch {
            showPostActionError(error)
        }
    }

    func jumpToFindHit(_ hit: TopicFindHit) {
        if hit.postId > 0 {
            jumpToPostId(hit.postId)
            return
        }
        Task { await jumpToPostNumber(hit.postNumber) }
    }

    func installTopicFindBar() {
        findController.install(
            in: view,
            topAnchor: view.safeAreaLayoutGuide.topAnchor,
            onJump: { [weak self] hit in
                self?.jumpToFindHit(hit)
            },
            search: { [weak self] query in
                guard let self else { return [] }
                let result = try await self.api.searchTopic(topicId: self.topicId, term: query)
                return (result.posts ?? [])
                    .filter { $0.topicId == self.topicId }
                    .map { TopicFindHit(postId: $0.id, postNumber: $0.postNumber) }
            }
        )
        findController.onVisibilityChange = { [weak self] _ in
            self?.view.layoutIfNeeded()
        }
    }

    func presentUserProfilePreview(username: String) {
        let previewVC = UserProfilePreviewViewController(api: api, username: username)
        previewVC.onViewProfile = { [weak self] selectedUsername in
            guard let self else { return }
            let vc = UserProfileViewController(api: self.api, username: selectedUsername)
            self.navigationController?.pushViewController(vc, animated: true)
        }
        previewVC.onFilterPostsByUsername = { [weak self] selectedUsername in
            guard let self else { return }
            self.viewModel.toggleFilterUsername(selectedUsername)
            self.applySnapshot()
            self.configureTopicActions()
        }
        previewVC.isFilteringThisUser = viewModel.isFiltering(username: username)
        present(previewVC, animated: true)
    }

    func scrollToLatestMessage() {
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { return }
        tableView.layoutIfNeeded()
        let indexPath = IndexPath(row: count - 1, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: false)
    }

    func jumpToFloor(_ floor: Int) async {
        guard floor > 1 else { return }
        await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
        applySnapshot()
        let ids = viewModel.allPostIds
        guard floor >= 1, floor <= ids.count else { return }
        let postId = ids[floor - 1]
        Task { @MainActor in
            self.scrollToPostId(postId)
        }
    }

    // MARK: - Auth / errors

    func performAuthenticated(_ action: @escaping () -> Void) {
        if let gate = nearestAuthGating() {
            gate.requireAuth(then: action)
        } else {
            action()
        }
    }

    func showPostActionError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "post.action.failed", defaultValue: "操作失败"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Composer / boost

    private func presentChatEmojiPicker() {
        let picker = EmojiPickerView()
        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        host.title = String(localized: "emoji.picker", defaultValue: "表情")
        picker.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            picker.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        picker.showLoading()
        if let cached = EmojiStore.cachedEntries(for: baseURL), !cached.isEmpty {
            picker.setEmojiGroups(
                [DiscourseEmojiGroup(key: "custom", emojis: cached)],
                baseURL: baseURL
            )
        }
        picker.onEmojiSelected = { [weak self, weak host] shortcode in
            host?.dismiss(animated: true) {
                self?.chatInputBar.insertText(shortcode)
            }
        }
        let nav = UINavigationController(rootViewController: host)
        host.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak nav] _ in
                nav?.dismiss(animated: true)
            }
        )
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
        Task { [weak picker] in
            do {
                let groups = try await self.api.fetchEmojiGroups()
                picker?.setEmojiGroups(groups, baseURL: self.baseURL)
            } catch {
                if EmojiStore.cachedEntries(for: self.baseURL)?.isEmpty != false {
                    picker?.showError()
                }
            }
        }
    }

    private func presentReplyComposer(for post: DiscourseTopicDetail.Post?, initialText: String? = nil) {
        chatInputBar.resign()
        let composer = ReplyComposerViewController(
            api: api,
            topicId: topicId,
            replyToPost: post,
            baseURL: baseURL,
            initialText: initialText,
            mentionSeedUsers: mentionSeedUsers()
        )
        composer.onPostCreated = { [weak self] in
            guard let self else { return }
            self.chatInputBar.clearAfterSend()
            Task {
                await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
            }
        }
        composer.modalPresentationStyle = .pageSheet
        if let sheet = composer.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
        }
        present(composer, animated: true)
    }

    /// Focus bottom bar for a quick text reply (WeChat style), optional reply-to target.
    private func beginQuickReply(to post: DiscourseTopicDetail.Post?) {
        chatInputBar.setReplyTarget(post)
        chatInputBar.focus()
    }

    private func sendQuickReply(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let replyTo = chatInputBar.replyToPost
        chatInputBar.setSending(true)
        Task {
            do {
                let response = try await api.createReply(
                    topicId: topicId,
                    replyToPostNumber: replyTo?.postNumber,
                    raw: trimmed
                )
                await MainActor.run {
                    self.chatInputBar.clearAfterSend()
                    self.chatInputBar.resign()
                }
                if response.isEnqueued {
                    await MainActor.run {
                        let alert = UIAlertController(
                            title: String(localized: "reply.queued.title", defaultValue: "已进入审核"),
                            message: String(localized: "reply.queued.message", defaultValue: "回复已提交，等待审核通过后显示。"),
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true)
                    }
                    return
                }
                await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            } catch {
                await MainActor.run {
                    self.chatInputBar.setSending(false)
                    self.showPostActionError(error)
                }
            }
        }
    }

    private func deleteBoost(_ boost: DiscourseTopicDetail.Boost, for post: DiscourseTopicDetail.Post) {
        Task {
            do {
                try await api.deleteBoost(boostId: boost.id)
                viewModel.removePostBoost(postId: post.id, boostId: boost.id)
                reloadPostCell(postId: post.id)
            } catch {
                reloadPostCell(postId: post.id)
                showPostActionError(error)
            }
        }
    }

    private func presentBoostInput(for post: DiscourseTopicDetail.Post) {
        let input = BoostInputViewController(api: api)
        input.onSubmit = { [weak self] result in
            guard let self else { return }
            switch result {
            case let .boost(raw):
                Task {
                    do {
                        let boost = try await self.api.createBoost(postId: post.id, raw: raw)
                        self.viewModel.appendPostBoost(postId: post.id, boost: boost)
                        self.reloadPostCell(postId: post.id)
                    } catch {
                        self.reloadPostCell(postId: post.id)
                        self.showPostActionError(error)
                    }
                }
            case let .reply(raw):
                self.presentReplyComposer(for: post, initialText: raw)
            }
        }
        input.modalPresentationStyle = .pageSheet
        if let sheet = input.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = false
        }
        present(input, animated: true)
    }

    private func mentionSeedUsers() -> [DiscourseMentionUser] {
        var seen = Set<String>()
        var users: [DiscourseMentionUser] = []
        for post in viewModel.posts {
            let key = post.username.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            users.append(
                DiscourseMentionUser(
                    username: post.username,
                    name: post.name,
                    avatarTemplate: post.avatarTemplate
                )
            )
            if users.count >= 12 { break }
        }
        return users
    }

    private func handleLink(_ url: URL) {
        let linkURL = ForumInternalLinkParser.normalizedURL(from: url, baseURL: baseURL)
        if ForumInternalLinkParser.isInternalURL(linkURL, baseURL: baseURL),
           let destination = ForumInternalLinkParser.destination(for: linkURL) {
            switch destination {
            case let .topic(id, postNumber):
                if id == topicId, let postNumber {
                    Task { await jumpToPostNumber(postNumber) }
                } else {
                    let vc = TopicDetailFactory.make(
                        api: api,
                        topicId: id,
                        initialFloor: postNumber,
                        forum: forum
                    )
                    navigationController?.pushViewController(vc, animated: true)
                }
            case let .category(slug, categoryId):
                let category = DiscourseCategory(id: categoryId, name: slug, slug: slug)
                navigationController?.pushViewController(
                    CategoryTopicsViewController(api: api, category: category),
                    animated: true
                )
            case let .tag(tagName):
                navigationController?.pushViewController(
                    TagTopicsViewController(api: api, tagName: tagName),
                    animated: true
                )
            case let .user(username):
                navigationController?.pushViewController(
                    UserProfileViewController(api: api, username: username),
                    animated: true
                )
            }
        } else {
            DoerSafariPresenter.present(
                url: linkURL,
                from: self,
                api: api,
                username: AuthManager.shared.username(for: api.baseURL)
            )
        }
    }

// MARK: - Cloudflare recovery

    private func startObservingCloudflareVerification() {
        guard cloudflareCompletionObservationToken == nil else { return }
        cloudflareCompletionObservationToken = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareVerificationCompletedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let verifiedBaseURL = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String
            Task { @MainActor [weak self] in
                var userInfo: [AnyHashable: Any] = [:]
                if let verifiedBaseURL {
                    userInfo[DiscourseAPI.cloudflareBaseURLUserInfoKey] = verifiedBaseURL
                }
                self?.handleCloudflareVerificationCompleted(
                    Notification(name: DiscourseAPI.cloudflareVerificationCompletedNotification, object: nil, userInfo: userInfo)
                )
            }
        }
    }

    /// Also invoked as a backup from ForumContainer after CF sheet dismiss.
    func handleCloudflareVerificationCompleted(_ notification: Notification) {
        if let verifiedBaseURL = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String {
            guard ForumInstance.normalizedBaseURL(verifiedBaseURL) == ForumInstance.normalizedBaseURL(baseURL)
            else { return }
        }
        guard !isRecoveringAfterCloudflare else { return }
        isRecoveringAfterCloudflare = true

        // Unstick UI immediately — CF sheet / grace races must not leave the chat frozen.
        view.isUserInteractionEnabled = true
        tableView.isUserInteractionEnabled = true
        tableView.isScrollEnabled = true

        let shouldReload = TopicDetailCloudflareRecoveryPolicy.shouldReloadTopic(
            isReady: viewModel.isReady,
            hasParsedPosts: !viewModel.parsedBlocks.isEmpty,
            errorMessage: viewModel.errorMessage
        )
        if shouldReload {
            errorLabel.isHidden = false
            errorLabel.text = String(
                localized: "cloudflare.recovering",
                defaultValue: "验证已通过，正在重新加载…"
            )
        }

        Task { [weak self] in
            guard let self else { return }
            defer { self.isRecoveringAfterCloudflare = false }
            await WebCookieStore.shared.forceSyncCloudflareClearance(for: self.baseURL)
            let readyPostIds = self.viewModel.posts.compactMap { post in
                self.viewModel.parsedBlocks[post.id] == nil ? nil : post.id
            }
            let avatarURLs = self.viewModel.posts.compactMap { post -> URL? in
                guard readyPostIds.contains(post.id) else { return nil }
                return AvatarImageLoader.url(
                    from: post.avatarTemplate,
                    baseURL: self.baseURL,
                    size: AvatarImageLoader.primaryAvatarPixelSize
                )
            }
            AvatarImageLoader.credentialsDidChange(for: self.baseURL, retrying: avatarURLs)

            if shouldReload {
                self.api.resetSession()
                let width = max(self.view.bounds.width, UIScreen.main.bounds.width)
                await self.viewModel.recoverAfterCloudflare(
                    id: self.topicId,
                    containerWidth: width,
                    initialFloor: self.initialFloor,
                    initialPostId: self.initialPostId
                )
            }

            await MainActor.run {
                self.view.isUserInteractionEnabled = true
                self.tableView.isUserInteractionEnabled = true
                self.tableView.isScrollEnabled = true
                if shouldReload {
                    self.applySnapshot()
                } else if let visible = self.tableView.indexPathsForVisibleRows, !visible.isEmpty {
                    var snapshot = self.dataSource.snapshot()
                    let ids = visible.compactMap { self.dataSource.itemIdentifier(for: $0) }
                        .filter { snapshot.indexOfItem($0) != nil }
                    if !ids.isEmpty {
                        snapshot.reconfigureItems(ids)
                        self.dataSource.apply(snapshot, animatingDifferences: false)
                    }
                }
                if self.viewModel.isReady {
                    self.errorLabel.isHidden = true
                    self.tableView.isHidden = false
                }
            }
        }
    }


    // MARK: - Back swipe

    private var canNavigateBack: Bool {
        guard let navigationController else { return false }
        return navigationController.viewControllers.count > 1
            && navigationController.viewControllers.first !== self
    }

    // MARK: - Reading Tracking

    func updateVisibleReadingPosts() {
        guard isViewLoaded, view.window != nil, viewModel.isReady else { return }
        let postNumbers = (tableView.indexPathsForVisibleRows ?? []).compactMap { indexPath -> Int? in
            guard let postId = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return viewModel.posts.first(where: { $0.id == postId })?.postNumber
        }
        readingTracker.setVisiblePostNumbers(Set(postNumbers))
        if let highest = postNumbers.max(), highest > 0 {
            lastReadPostNumber = max(lastReadPostNumber ?? 0, highest)
        }
    }

    /// Persist resume floor into the read-later queue when the topic is queued.
    func syncReadLaterProgressOnExit() {
        let username = AuthManager.shared.username(for: baseURL)
        let merged = TopicReadProgressStore.shared.mergedLastRead(
            serverLastRead: lastReadPostNumber ?? viewModel.topic?.lastReadPostNumber,
            topicId: topicId,
            baseURL: baseURL,
            username: username
        )
        guard merged > 0 else { return }
        let title = viewModel.topic.map {
            TitleEmojiRenderer.plainTitle(fancyTitle: $0.fancyTitle, title: $0.title)
        }
        TopicReadLaterStore.shared.updateProgress(
            topicId: topicId,
            baseURL: baseURL,
            username: username,
            lastReadPostNumber: merged,
            title: title
        )
    }

    private func prefetchContentImages(forPostIds postIds: [Int]) {
        var seen = Set<String>()
        var urls: [URL] = []
        for postId in postIds {
            let raw = viewModel.parsedBlocks[postId]?.imageSourceURLs.compactMap(URL.init(string:)) ?? []
            for url in raw {
                guard seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }
        ForumImageLoader.prefetch(urls: urls, cloudflareBaseURL: baseURL, maxUncached: 8)
    }
}

/// Topic Detail table: a rightward back-swipe from the system pop edge must not
/// start vertical scrolling. No `require(toFail:)` on the edge recognizer —
/// waiting on it delays every left-edge pan and can freeze.
final class TopicDetailPopAwareTableView: UITableView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer,
           let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let location = pan.location(in: self)
            if NavigationPopGesturePriority.shouldYieldScrollPanToSystemPop(
                locationX: location.x,
                translation: pan.translation(in: self),
                velocity: pan.velocity(in: self)
            ) {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

// MARK: - Table

extension ChatTopicDetailViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let postId = dataSource.itemIdentifier(for: indexPath),
           let cached = postRowHeightCache[postId], cached > 1 {
            return cached
        }
        return estimatedChatRowHeight()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tableView.doer_setScrollBusy(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            tableView.doer_setScrollBusy(false)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        tableView.doer_setScrollBusy(false)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let scrollBusy = tableView.doer_isScrollBusy || tableView.isDragging || tableView.isDecelerating
        if !scrollBusy {
            (cell as? WeChatChatPostCell)?.requestHeightReconciliation()
        }

        guard let postId = dataSource.itemIdentifier(for: indexPath) else { return }
        if cell.frame.height > 1 {
            postRowHeightCache[postId] = cell.frame.height
        }
        var ahead: [Int] = [postId]
        let total = tableView.numberOfRows(inSection: 0)
        if !scrollBusy {
            for offset in 1...3 {
                let next = indexPath.row + offset
                guard next < total,
                      let id = dataSource.itemIdentifier(for: IndexPath(row: next, section: 0))
                else { break }
                ahead.append(id)
            }
            prefetchContentImages(forPostIds: ahead)
            if let streamIndex = viewModel.allPostIds.firstIndex(of: postId) {
                let width = max(view.bounds.width, UIScreen.main.bounds.width)
                viewModel.acknowledgeVisibleTailIfNeeded(visibleStreamIndex: streamIndex)
                Task {
                    await viewModel.ensureForwardWindowReady(
                        visibleStreamIndex: streamIndex,
                        containerWidth: width
                    )
                }
            }
        }

        if indexPath.row >= max(0, total - 4) {
            loadMoreIfNeeded()
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let postId = dataSource.itemIdentifier(for: indexPath), cell.frame.height > 1 {
            postRowHeightCache[postId] = cell.frame.height
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard viewModel.isReady else { return }
        readingTracker.scrolled()
        // Throttle visible-post bookkeeping while flinging.
        if !tableView.doer_isScrollBusy {
            updateVisibleReadingPosts()
        }
        let offsetY = scrollView.contentOffset.y
        let contentH = scrollView.contentSize.height
        let frameH = scrollView.frame.height

        if offsetY > contentH - frameH * 1.6 {
            loadMoreIfNeeded()
        }
        if offsetY < 80 {
            loadEarlierIfNeeded()
        }
    }

    private func loadMoreIfNeeded() {
        guard !isLoadingMore, viewModel.canLoadMore else { return }
        isLoadingMore = true
        let width = max(view.bounds.width, UIScreen.main.bounds.width)
        Task {
            await viewModel.loadMorePosts(containerWidth: width)
            isLoadingMore = false
        }
    }

    private func loadEarlierIfNeeded() {
        guard !isLoadingEarlier, viewModel.canLoadEarlier else { return }
        isLoadingEarlier = true
        let width = max(view.bounds.width, UIScreen.main.bounds.width)
        Task {
            _ = await viewModel.loadEarlierPosts(containerWidth: width)
            isLoadingEarlier = false
        }
    }
}

// MARK: - Long-press actions

extension ChatTopicDetailViewController: WeChatChatPostCellDelegate {
    func weChatChatPostCell(_ cell: WeChatChatPostCell, didRequestLike post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            let reactionId = post.currentUserReaction?.id ?? "heart"
            Task {
                do {
                    if let response = try await self.api.toggleReaction(postId: post.id, reactionId: reactionId) {
                        self.viewModel.updatePostReaction(
                            postId: post.id,
                            reactions: response.reactions,
                            reactionUsersCount: response.reactionUsersCount,
                            currentUserReaction: response.currentUserReaction
                        )
                        self.reloadPostCell(postId: post.id)
                    } else {
                        await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
                    }
                } catch {
                    self.reloadPostCell(postId: post.id)
                    self.showPostActionError(error)
                }
            }
        }
    }

    func weChatChatPostCell(_ cell: WeChatChatPostCell, didRequestReply post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.beginQuickReply(to: post)
        }
    }

    func weChatChatPostCell(_ cell: WeChatChatPostCell, didRequestBookmark post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            let shouldBookmark = !post.bookmarked
            Task {
                do {
                    if shouldBookmark {
                        let response = try await self.api.createBookmark(postId: post.id)
                        self.viewModel.updatePostBookmark(
                            postId: post.id,
                            bookmarked: true,
                            bookmarkId: response.id
                        )
                    } else if let bookmarkId = post.bookmarkId {
                        try await self.api.deleteBookmark(id: bookmarkId)
                        self.viewModel.updatePostBookmark(
                            postId: post.id,
                            bookmarked: false,
                            bookmarkId: nil
                        )
                    } else {
                        await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
                    }
                    self.reloadPostCell(postId: post.id)
                } catch {
                    self.reloadPostCell(postId: post.id)
                    self.showPostActionError(error)
                }
            }
        }
    }

    func weChatChatPostCell(_ cell: WeChatChatPostCell, didRequestBoost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.presentBoostInput(for: post)
        }
    }

    func weChatChatPostCell(_ cell: WeChatChatPostCell, didTapAvatar username: String) {
        presentUserProfilePreview(username: username)
    }

    func weChatChatPostCell(_ cell: WeChatChatPostCell, didTapReplyQuote postId: Int?, postNumber: Int?) {
        if let postId, dataSource.snapshot().indexOfItem(postId) != nil {
            scrollToPostId(postId)
            return
        }
        if let postNumber {
            Task { await jumpToPostNumber(postNumber) }
        }
    }
}

// MARK: - Content taps (native blocks inside bubble)

extension ChatTopicDetailViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, imageURLs: [URL], sourceView: UIView?) {
        presentTopicImageGallery(currentURL: url, imageURLs: imageURLs, sourceView: sourceView)
    }

    func postCell(didTapLinkURL url: URL) {
        handleLink(url)
    }

    func postCell(didTapShowRepliesForPostId postId: Int) {
        let repliesVC = RepliesViewController(api: api, postId: postId, topicId: topicId)
        if let sheet = repliesVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(repliesVC, animated: true)
    }

    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {}

    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.beginQuickReply(to: post)
        }
    }

    func postCell(didQuoteSelectedText text: String, postId: Int?) {
        let post = postId.flatMap { viewModel.post(byId: $0) }
        guard let post else { return }
        let markdown = DiscourseQuoteMarkdown.make(
            username: post.username,
            postNumber: post.postNumber,
            topicId: topicId,
            excerpt: text
        )
        guard !markdown.isEmpty else { return }
        performAuthenticated { [weak self] in
            self?.presentReplyComposer(for: post, initialText: markdown)
        }
    }

    func postCell(didRequestDecrypt text: String, postId: Int?) {
        CryptoSheetViewController.present(
            mode: .decrypt,
            text: text,
            from: self,
            onQuoteReply: { [weak self] plaintext in
                self?.postCell(didQuoteSelectedText: plaintext, postId: postId)
            }
        )
    }

    func postCell(didTapEditPost post: DiscourseTopicDetail.Post) {}

    func postCell(didTapShareImageForPost post: DiscourseTopicDetail.Post) {}

    func postCell(didTapShowRevisionForPost post: DiscourseTopicDetail.Post) {}

    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {
        // Route through the same bookmark action used by long-press.
        performAuthenticated { [weak self] in
            guard let self else { return }
            let shouldBookmark = isBookmarked
            Task {
                do {
                    if shouldBookmark {
                        let response = try await self.api.createBookmark(postId: post.id)
                        self.viewModel.updatePostBookmark(postId: post.id, bookmarked: true, bookmarkId: response.id)
                    } else if let bookmarkId = post.bookmarkId {
                        try await self.api.deleteBookmark(id: bookmarkId)
                        self.viewModel.updatePostBookmark(postId: post.id, bookmarked: false, bookmarkId: nil)
                    }
                    self.reloadPostCell(postId: post.id)
                } catch {
                    self.reloadPostCell(postId: post.id)
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.presentBoostInput(for: post)
        }
    }

    func postCell(didRequestDeleteBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.deleteBoost(boost, for: post)
        }
    }

    func postCell(didUpdateBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {
        viewModel.updatePostBoost(postId: post.id, boost: boost)
    }

    func postCell(didTapAvatarForUsername username: String) {
        presentUserProfilePreview(username: username)
    }

    func postCell(didTapQuotedPostNumber postNumber: Int) {
        Task { await jumpToPostNumber(postNumber) }
    }

    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    if let response = try await self.api.toggleReaction(postId: post.id, reactionId: reactionId) {
                        self.viewModel.updatePostReaction(
                            postId: post.id,
                            reactions: response.reactions,
                            reactionUsersCount: response.reactionUsersCount,
                            currentUserReaction: response.currentUserReaction
                        )
                        self.reloadPostCell(postId: post.id)
                    }
                } catch {
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didTapToggleSharedIssueForTopicId topicId: Int) {}

    func postCell(didSubmitPollVoteForPostId postId: Int, pollName: String, optionIds: [String]) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.viewModel.submitPollVote(
                        postId: postId,
                        pollName: pollName,
                        optionIds: optionIds
                    )
                    self.reloadPostCell(postId: postId)
                } catch {
                    self.reloadPostCell(postId: postId)
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didTogglePolicyAccepted accepted: Bool, forPostId postId: Int) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    if accepted {
                        try await self.api.acceptPolicy(postId: postId)
                    } else {
                        try await self.api.unacceptPolicy(postId: postId)
                    }
                    self.reloadPostCell(postId: postId)
                } catch {
                    self.reloadPostCell(postId: postId)
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didCastPostVotingVote direction: String, forPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let normalized = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if normalized.isEmpty || normalized == "none" {
                        try await self.api.removePostVotingVote(postId: post.id)
                    } else {
                        try await self.api.castPostVotingVote(postId: post.id, direction: normalized)
                    }
                    await self.viewModel.loadTopic(
                        id: self.topicId,
                        containerWidth: max(self.view.bounds.width, UIScreen.main.bounds.width)
                    )
                    self.reloadPostCell(postId: post.id)
                } catch {
                    self.showPostActionError(error)
                }
            }
        }
    }
}
