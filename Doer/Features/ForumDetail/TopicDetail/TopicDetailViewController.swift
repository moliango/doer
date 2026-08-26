import CookedHTML
import UIKit

final class TopicDetailViewController: ObservableViewController {
    let coordinator: TopicDetailCoordinator
    let viewModel: TopicDetailViewModel
    let api: DiscourseAPI
    let topicId: Int
    /// Discourse `post_number` to open (notification / deep link / profile). Not stream index.
    let initialFloor: Int?
    /// Preferred target when the caller already knows the post id (e.g. notification `original_post_id`).
    let initialPostId: Int?
    /// Last read post number from list/detail — used by jump-to-unread (Phase 1).
    var lastReadPostNumber: Int?
    let baseURL: String
    var hasTitleHeader = false
    var lastCategoryPresentation: TopicCategoryBadgePresentation?
    var isLoadingEarlierLocally = false
    var pendingScrollToFloor: Int?
    var lastScrollOffset: CGFloat = 0
    /// Measured row heights keyed by post id — stabilizes estimatedHeight while scrolling.
    var postRowHeightCache: [Int: CGFloat] = [:]
    /// Coarse estimates from parsed blocks when measured height is not yet known.
    var postRowEstimatedHeightCache: [Int: CGFloat] = [:]
    /// Throttle heavy work in `scrollViewDidScroll` (reading tracker / progress bar).
    var lastScrollChromeUpdateUptime: TimeInterval = 0
    /// Suppress load-earlier after a jump until user scrolls down first
    var suppressLoadEarlier = false
    /// Anchor info for restoring scroll position after loading earlier posts
    var earlierLoadAnchor: (postId: Int, cellTopOffset: CGFloat)?
    struct PendingPostSnapshot {
        let itemIDs: [Int]
        let earlierAnchor: (postId: Int, cellTopOffset: CGFloat)?
    }
    var isApplyingPostSnapshot = false
    var pendingPostSnapshot: PendingPostSnapshot?
    var lastReadingComfortMode = AppSettings.shared.readingComfortMode
    var lastContentFontSize = AppSettings.shared.contentFontSize
    var lastContentFontScalePercent = AppSettings.shared.contentFontScalePercent
    var lastContentFontFamily = AppSettings.shared.contentFontFamily
    var lastContentFontScope = AppSettings.shared.contentFontScope
    var lastInterfaceFontScalePercent = AppSettings.shared.interfaceFontScalePercent
    var lastContentImageCarouselEnabled = AppSettings.shared.contentImageCarouselEnabled
    var lastThemeStyle = AppSettings.shared.themeStyle
    var hasPresentedInitialContent = false
    lazy var readingTracker = TopicReadingTracker(api: api)
    var isShowingCollapsedNavigationTitle = false
    var lastBottomBarProgressState: (current: Int, total: Int)?
    /// When true (e.g. opened from notification), enable nested tree on first load; fall back to flat on failure.
    var preferNestedOnLoad = false
    var downloadedAttachmentURLs: Set<URL> = []
    var prefetchedImagePostIds = Set<Int>()
    var pendingSharedIssueTopicIds = Set<Int>()
    var cloudflareCompletionObservationToken: NSObjectProtocol?
    var isRecoveringAfterCloudflare = false
    var liveSyncTimer: Timer?
    var appForegroundObserver: NSObjectProtocol?
    let tocController = TopicTocController()
    var pluginScope: PluginScope {
        PluginScope(
            baseURL: api.baseURL,
            username: AuthManager.shared.username(for: api.baseURL)
        )
    }

    lazy var tableView: UITableView = {
        let tv = TopicDetailPopAwareTableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(PostNativeCell.self, forCellReuseIdentifier: PostNativeCell.reuseIdentifier)
        tv.register(NestedSortBarCell.self, forCellReuseIdentifier: NestedSortBarCell.reuseIdentifier)
        tv.delegate = self
        tv.separatorStyle = .none
        tv.backgroundColor = .systemGroupedBackground
        tv.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        tv.showsHorizontalScrollIndicator = false
        tv.isHidden = true
        return tv
    }()

    lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = .init(tableView: tableView) { [weak self] tableView, indexPath, itemId in
        guard let self else { return UITableViewCell() }

        if itemId == TopicDetailListItem.nestedSortBarID {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: NestedSortBarCell.reuseIdentifier,
                for: indexPath
            ) as? NestedSortBarCell else {
                return UITableViewCell()
            }
            cell.configure(selected: self.viewModel.nestedSort)
            cell.onSelectSort = { [weak self] sort in
                self?.viewModel.setNestedSort(sort)
            }
            return cell
        }

        guard let post = self.viewModel.post(byId: itemId) else {
            return UITableViewCell()
        }

        guard let annotatedBlocks = self.viewModel.parsedBlocks[itemId],
              let cell = tableView.dequeueReusableCell(withIdentifier: PostNativeCell.reuseIdentifier, for: indexPath) as? PostNativeCell
        else {
            return UITableViewCell()
        }
        let nestedRow = self.viewModel.isNestedViewEnabled
            ? self.viewModel.nestedRow(forPostId: itemId)
            : nil
        let visiblePosts = self.viewModel.visiblePosts
        let floorNumber: Int
        if self.viewModel.isNestedViewEnabled {
            // Keep Discourse post_number so jump / share links stay stable in tree mode.
            floorNumber = post.postNumber
        } else if self.viewModel.isFilteringByOP {
            floorNumber = (visiblePosts.firstIndex(where: { $0.id == itemId }) ?? 0) + 1
        } else {
            // Use stream-based floor number when not filtering
            let allPostIds = self.viewModel.allPostIds
            if let streamIndex = allPostIds.firstIndex(of: itemId) {
                floorNumber = streamIndex + 1
            } else {
                floorNumber = (visiblePosts.firstIndex(where: { $0.id == itemId }) ?? 0) + 1
            }
        }
        let postLink = "\(self.baseURL)/t/\(self.topicId)/\(post.postNumber)"
        let renderContentWidth = PostNativeCell.renderContentWidth(
            for: tableView.bounds.width,
            isFirstPost: floorNumber == 1,
            nestedDepth: nestedRow?.depth ?? 0,
            isNestedTree: nestedRow != nil
        )
        let galleryImageURLs = TopicImageGallerySources.urls(from: annotatedBlocks)
        let config = NativeRenderConfig.default(
            contentWidth: renderContentWidth,
            baseURL: self.baseURL,
            postId: post.id,
            galleryImageURLs: galleryImageURLs,
            topicTagNames: Set(self.viewModel.topic?.tags.map(\.name) ?? []),
            topicCategoryPresentation: self.viewModel.categoryPresentation
        )
        let hasUnsupported = self.viewModel.unsupportedPostIds.contains(itemId)

        cell.configure(
            with: post,
            annotatedBlocks: annotatedBlocks,
            config: config,
            delegate: self,
            floorNumber: floorNumber,
            postLink: postLink,
            baseURL: self.baseURL,
            hasUnsupportedBlocks: hasUnsupported,
            cookedHTML: post.cooked,
            validReactions: self.viewModel.topic?.validReactions ?? [],
            sharedIssue: self.sharedIssueState(forFloorNumber: floorNumber),
            nestedPresentation: nestedRow
        )
        return cell
    }

    func sharedIssueState(forFloorNumber floorNumber: Int) -> PostNativeCell.SharedIssueState? {
        guard floorNumber == 1,
              let topic = viewModel.topic,
              topic.sharedIssueVisible
        else { return nil }

        return PostNativeCell.SharedIssueState(
            topicId: topic.id,
            canCreate: topic.canCreateSharedIssue,
            count: topic.sharedIssueCount,
            userCreated: topic.userCreatedSharedIssue
        )
    }

    let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    let loadingSkeletonView = TopicDetailSkeletonView()
    let suggestedTopicsFooter = SuggestedTopicsFooterView()

    let titleLabel: UILabel = {
        let label = UILabel()
        label.font = TopicDetailTypography.topicTitleFont()
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }()

    var renderedTopicTitle: String?
    var emojiUpdateObserver: NSObjectProtocol?

    let tagsContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    let navTitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.numberOfLines = 1
        return label
    }()

    let errorLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    lazy var topLoadingBar: UIView = {
        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .secondarySystemBackground
        bar.alpha = 0
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "topic_detail.loading_earlier")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 36),
        ])
        return bar
    }()

    let bottomBar = TopicDetailBottomBar()

    lazy var floatingReplyButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "arrowshape.turn.up.left")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        let accentColor = AppSettings.shared.themeStyle.accentColor
        config.baseForegroundColor = accentColor
        config.baseBackgroundColor = accentColor.withAlphaComponent(0.14)
        config.cornerStyle = .large
        button.configuration = config
        button.backgroundColor = .clear
        button.layer.cornerRadius = 18
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = accentColor.cgColor
        button.layer.shadowOpacity = 0.20
        button.layer.shadowOffset = CGSize(width: 0, height: 8)
        button.layer.shadowRadius = 16
        button.isHidden = true
        button.accessibilityLabel = String(localized: "topic_detail.action.reply")
        button.addAction(UIAction { [weak self] _ in
            self?.coordinator.replyButtonTapped()
        }, for: .touchUpInside)
        return button
    }()

    lazy var tocFabButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "list.bullet")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let accentColor = AppSettings.shared.themeStyle.accentColor
        config.baseForegroundColor = accentColor
        config.baseBackgroundColor = UIColor.secondarySystemGroupedBackground
        config.cornerStyle = .capsule
        button.configuration = config
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.16
        button.layer.shadowOffset = CGSize(width: 0, height: 6)
        button.layer.shadowRadius = 12
        button.clipsToBounds = false
        button.isHidden = true
        button.alpha = 0
        button.accessibilityLabel = String(localized: "topic.toc", defaultValue: "目录")
        button.addAction(UIAction { [weak self] _ in
            self?.presentTopicToc()
        }, for: .touchUpInside)
        return button
    }()

    lazy var newRepliesBanner: UIButton = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "arrow.down")
        config.imagePlacement = .leading
        config.imagePadding = 8
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.baseForegroundColor = .white
        config.baseBackgroundColor = AppSettings.shared.themeStyle.accentColor
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 14, weight: .semibold)
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        button.alpha = 0
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowOffset = CGSize(width: 0, height: 6)
        button.layer.shadowRadius = 12
        button.addAction(UIAction { [weak self] _ in
            self?.handleNewRepliesBannerTapped()
        }, for: .touchUpInside)
        return button
    }()

    lazy var jumpOverlay: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        v.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }()

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
        self.coordinator = TopicDetailCoordinator(
            viewModel: self.viewModel,
            api: api,
            forum: forum ?? ForumInstance.new(title: "", baseURL: api.baseURL),
            topicId: topicId,
            initialFloor: initialFloor,
            initialPostId: initialPostId
        )
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    deinit {
        if let emojiUpdateObserver {
            NotificationCenter.default.removeObserver(emojiUpdateObserver)
        }
        readingTracker.stop()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        observe(AppSettings.shared)
        emojiUpdateObserver = NotificationCenter.default.addObserver(
            forName: EmojiStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let renderedTopicTitle else { return }
                self.configureTitleLabel(renderedTopicTitle)
            }
        }
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        title = String(localized: "topic_detail.default_title")
        // Cloudflare + plugin observers owned by TopicDetailCoordinator.start
        configureTopicActions()
        applyTypography()
//        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

        // P2: after fling settles, finish progressive bodies + resume GIF.
        tableView.doer_onScrollSettled = { [weak self] in
            self?.finishVisibleCellsAfterScrollSettle()
        }

        view.addSubview(tableView)
        view.addSubview(loadingSkeletonView)
        view.addSubview(activityIndicator)
        view.addSubview(errorLabel)
        view.addSubview(bottomBar)
        view.addSubview(floatingReplyButton)
        view.addSubview(tocFabButton)
        view.addSubview(newRepliesBanner)
        view.addSubview(topLoadingBar)

        bottomBar.delegate = self
        tableView.tableFooterView = footerSpinner

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingSkeletonView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            loadingSkeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingSkeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingSkeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

            bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            floatingReplyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            floatingReplyButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            floatingReplyButton.widthAnchor.constraint(equalToConstant: 56),
            floatingReplyButton.heightAnchor.constraint(equalToConstant: 56),

            tocFabButton.trailingAnchor.constraint(equalTo: floatingReplyButton.trailingAnchor),
            tocFabButton.bottomAnchor.constraint(equalTo: floatingReplyButton.topAnchor, constant: -12),
            tocFabButton.widthAnchor.constraint(equalToConstant: 44),
            tocFabButton.heightAnchor.constraint(equalToConstant: 44),

            newRepliesBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newRepliesBanner.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),

            topLoadingBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topLoadingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topLoadingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        Task {
            if preferNestedOnLoad {
                viewModel.setNestedViewEnabled(true)
            }
            await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
            // Nested load can fail silently (plugin missing / empty tree / unparsed nodes).
            // Always abandon tree when nothing can paint — do not require errorMessage.
            if viewModel.isNestedViewEnabled {
                viewModel.abandonNestedIfUnrenderable()
                viewModel.errorMessage = nil
            }
            // Prefer list hint; fall back to detail payload when present.
            if let detailLastRead = viewModel.topic?.lastReadPostNumber {
                lastReadPostNumber = max(lastReadPostNumber ?? 0, detailLastRead)
            }
            let localHighest = TopicReadProgressStore.shared.highestSeen(
                topicId: topicId,
                baseURL: baseURL,
                username: AuthManager.shared.username(for: baseURL)
            )
            if localHighest > 0 {
                lastReadPostNumber = max(lastReadPostNumber ?? 0, localHighest)
            }
            // Notification / deep-link targets are Discourse post_number or post id —
            // never treat them as raw stream indices (deleted posts create gaps).
            if let initialPostId {
                jumpToPostId(initialPostId)
            } else if let initialFloor {
                await jumpToPostNumber(initialFloor)
            } else if let resume = resumeUnreadFloor() {
                jumpToFloor(resume)
            }
        }
        Task {
            await api.loadOrFetchEmojiMap()
            hasTitleHeader = false
            updateUI()
            // Diffable data source forbids direct reloadRows/reloadData.
            reconfigureVisiblePostCells()
        }
        coordinator.start(in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = canNavigateBack
        syncOwningTabBarVisibility()
        bottomBar.refreshGestureRecognizers()
        // Soft live sync when returning to an already-open topic (no full reload wipe).
        if viewModel.isReady {
            Task { await performLiveTopicSync(reason: "willAppear") }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = canNavigateBack
        readingTracker.start(topicId: topicId)
        updateVisibleReadingPosts()
        updateBottomBarProgress()
        syncOwningTabBarVisibility()
        startLiveTopicSync()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        readingTracker.stop()
        syncReadLaterProgressOnExit()
        stopLiveTopicSync()
    }

    func syncOwningTabBarVisibility() {
        (tabBarController as? ForumTabBarController)?.syncTabBarVisibilityForCurrentContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the progress capsule above the full-screen table so pan/long-press
        // hit-test the bar instead of scrolling the topic list. Reply stays trailing
        // and must not cover the centered capsule — bring bar last.
        view.bringSubviewToFront(floatingReplyButton)
        view.bringSubviewToFront(tocFabButton)
        view.bringSubviewToFront(bottomBar)
        view.bringSubviewToFront(newRepliesBanner)
        // Reserve bottom space for the centered floor control and the floating reply affordance.
        let bottomInset: CGFloat = 56 + 12 + 32
        if tableView.contentInset.bottom != bottomInset {
            tableView.contentInset.bottom = bottomInset
            tableView.verticalScrollIndicatorInsets.bottom = bottomInset
        }

        // Execute deferred jump scroll after layout is complete.
        // Resolve via post id in the Diffable snapshot — never via visiblePosts row index
        // (parsed-only rows / nested order can make that index larger than table rows).
        // Also wait out Diffable mutation / self-sizing beginUpdates to avoid
        // `_visibleRows` vs `_visibleCells` length traps.
        if !isApplyingPostSnapshot, !tableView.doer_isMutatingData, let floor = pendingScrollToFloor {
            let streamIndex = floor - 1
            guard streamIndex >= 0, streamIndex < viewModel.allPostIds.count else {
                pendingScrollToFloor = nil
                return
            }
            let postId = viewModel.allPostIds[streamIndex]
            if scrollToPostIdIfVisible(postId, animated: false) {
                pendingScrollToFloor = nil
                lastScrollOffset = tableView.contentOffset.y
            } else if viewModel.unsupportedPostIds.contains(postId) {
                // Target will never appear as a rendered row — drop the pending jump.
                pendingScrollToFloor = nil
            }
            // Otherwise keep pending until the next snapshot/layout brings the cell in.
        }
    }

    override func updateUI() {
        let settings = AppSettings.shared
        tableView.showsVerticalScrollIndicator = !settings.hideScrollIndicators
        applyThemeStyle()
        applyTypography()
        let didChangeThemeStyle = lastThemeStyle != settings.themeStyle
        let didChangeCategoryPresentation = lastCategoryPresentation != viewModel.categoryPresentation
        let shouldReloadVisibleContent = lastReadingComfortMode != settings.readingComfortMode
            || lastContentFontSize != settings.contentFontSize
            || lastContentFontScalePercent != settings.contentFontScalePercent
            || lastContentFontFamily != settings.contentFontFamily
            || lastContentFontScope != settings.contentFontScope
            || lastInterfaceFontScalePercent != settings.interfaceFontScalePercent
            || lastContentImageCarouselEnabled != settings.contentImageCarouselEnabled
            || didChangeThemeStyle
            || didChangeCategoryPresentation
        lastReadingComfortMode = settings.readingComfortMode
        lastContentFontSize = settings.contentFontSize
        lastContentFontScalePercent = settings.contentFontScalePercent
        lastContentFontFamily = settings.contentFontFamily
        lastContentFontScope = settings.contentFontScope
        lastInterfaceFontScalePercent = settings.interfaceFontScalePercent
        lastContentImageCarouselEnabled = settings.contentImageCarouselEnabled
        lastThemeStyle = settings.themeStyle
        lastCategoryPresentation = viewModel.categoryPresentation
        configureTopicActions()
        if didChangeThemeStyle || didChangeCategoryPresentation {
            hasTitleHeader = false
        }

        // Title header (set once, but rebuild when canLoadEarlier changes after a jump)
        if let topic = viewModel.topic, !hasTitleHeader {
            let displayTitle = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
            configureTitleLabel(displayTitle)
            updateTitleHeader()
            hasTitleHeader = true
        }

        // Loading
        let showsInitialLoading = viewModel.isLoading && !viewModel.isReady && viewModel.errorMessage == nil
        if showsInitialLoading {
            activityIndicator.stopAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        loadingSkeletonView.setSkeletonActive(showsInitialLoading, animated: view.window != nil)

        // Error
        if let error = viewModel.errorMessage {
            errorLabel.text = error
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }

        // Footer: load-more spinner or suggested topics
        if viewModel.isLoadingMore {
            tableView.tableFooterView = footerSpinner
            footerSpinner.startAnimating()
        } else {
            footerSpinner.stopAnimating()
            updateSuggestedTopicsFooter()
        }

        // Top loading bar for loading earlier posts
        if viewModel.isLoadingEarlier {
            DoerMotion.animate(duration: DoerMotion.quick) {
                self.topLoadingBar.alpha = 1
            }
        } else {
            DoerMotion.animate(duration: DoerMotion.quick, timingParameters: DoerMotion.easeInCubic) {
                self.topLoadingBar.alpha = 0
            }
        }

        bottomBar.isHidden = !viewModel.isReady
        floatingReplyButton.isHidden = !viewModel.isReady
        // Settings observe → updateUI; keep swipe/long-press enablement in sync.
        bottomBar.refreshGestureRecognizers()
        updateBottomBarProgress()
        updateTocChrome()
        updateNewRepliesBanner()

        // Show posts — all visible posts that have parsed blocks
        if viewModel.isReady {
            // Last-chance guard: nested tree with zero paintable rows → blank body under header.
            // notify: false — we are already inside updateUI; avoid re-entrant notifyChanged.
            _ = viewModel.abandonNestedIfUnrenderable(notify: false)

            let shouldAnimateInitialContent = !hasPresentedInitialContent && tableView.isHidden
            if shouldAnimateInitialContent {
                prepareInitialContentTransition()
            }
            tableView.isHidden = false
            // Never leave alpha at 0 if a prior transition was interrupted.
            if tableView.alpha < 0.01, hasPresentedInitialContent {
                tableView.alpha = 1
                tableView.transform = .identity
            }
            var seen = Set<Int>()
            // Nested mode already returns rows in API tree order (OP → roots → expanded children).
            // Do NOT re-run NestedReplyOrdering — that scrambles FluxDo sort and collapses depth.
            let sourcePosts = viewModel.visiblePosts
            var readyIds = sourcePosts.compactMap { post -> Int? in
                guard viewModel.parsedBlocks[post.id] != nil,
                      seen.insert(post.id).inserted else { return nil }
                return post.id
            }
            // If nested filtering still produced nothing but flat stream is parsed, force flat ids.
            if readyIds.isEmpty {
                seen.removeAll(keepingCapacity: true)
                let flatFallback = viewModel.posts.compactMap { post -> Int? in
                    guard viewModel.parsedBlocks[post.id] != nil,
                          seen.insert(post.id).inserted else { return nil }
                    return post.id
                }
                if !flatFallback.isEmpty {
                    // Silent — already inside updateUI.
                    viewModel.forceDisableNested(notify: false)
                    readyIds = flatFallback
                    DohDebugLog.record(
                        "topic snapshot flat fallback ids=\(readyIds.count)",
                        subsystem: "topic.firstpaint"
                    )
                }
            }
            // Flat mode: force Discourse stream order so jump/load-earlier never paints
            // e.g. #16 above #1 when the in-memory posts array was briefly unsorted.
            if !viewModel.isNestedViewEnabled, !readyIds.isEmpty, !viewModel.allPostIds.isEmpty {
                let streamOrder = Dictionary(
                    uniqueKeysWithValues: viewModel.allPostIds.enumerated().map { ($1, $0) }
                )
                readyIds.sort { (streamOrder[$0] ?? Int.max) < (streamOrder[$1] ?? Int.max) }
            }
            // Sort chips only when the tree actually has rows (not during flat fallback).
            if viewModel.isNestedViewEnabled,
               !viewModel.nestedRows.isEmpty,
               !readyIds.isEmpty {
                // FluxDo: sort chips sit directly under the OP.
                let sortBar = TopicDetailListItem.nestedSortBarID
                if let opIndex = readyIds.firstIndex(where: { id in
                    viewModel.post(byId: id)?.postNumber == 1
                }) {
                    readyIds.insert(sortBar, at: opIndex + 1)
                } else {
                    readyIds.insert(sortBar, at: min(1, readyIds.count))
                }
            }
            prefetchContentImages(forPostIds: readyIds.filter { $0 != TopicDetailListItem.nestedSortBarID })
            warmEstimatedRowHeights(forPostIds: readyIds.filter { $0 != TopicDetailListItem.nestedSortBarID })
            let completedEarlierAnchor = viewModel.isLoadingEarlier ? nil : earlierLoadAnchor
            applyPostSnapshot(itemIDs: readyIds, earlierAnchor: completedEarlierAnchor)
            refreshNestedSortBarSelection()
            if shouldReloadVisibleContent {
                // Font/theme change invalidates measured row heights.
                postRowHeightCache.removeAll(keepingCapacity: true)
                postRowEstimatedHeightCache.removeAll(keepingCapacity: true)
                warmEstimatedRowHeights(forPostIds: readyIds)
                reconfigureVisiblePostCells(reloadAllIfNoneVisible: true)
            }
            updateVisibleReadingPosts()
            updateBottomBarProgress()
            updateTocChrome()

            // After a jump, defer scroll to next layout pass so cells are sized
            if let targetFloor = viewModel.jumpTargetFloor {
                viewModel.jumpTargetFloor = nil
                pendingScrollToFloor = targetFloor
                tableView.setNeedsLayout()
            }
            if shouldAnimateInitialContent {
                animateInitialContentTransition()
            }
        } else {
            tableView.isHidden = true
        }
    }

    func applyThemeStyle() {
        let accentColor = AppSettings.shared.themeStyle.accentColor
        let themeStyle = AppSettings.shared.themeStyle
        view.backgroundColor = themeStyle.topicListBackgroundColor
        tableView.backgroundColor = themeStyle.topicListBackgroundColor
        topLoadingBar.backgroundColor = themeStyle.topicCardBackgroundColor
        loadingSkeletonView.applyThemeStyle()
        var replyConfig = floatingReplyButton.configuration ?? UIButton.Configuration.filled()
        replyConfig.baseForegroundColor = accentColor
        replyConfig.baseBackgroundColor = accentColor.withAlphaComponent(0.14)
        floatingReplyButton.configuration = replyConfig
        floatingReplyButton.layer.shadowColor = accentColor.cgColor
        var tocConfig = tocFabButton.configuration ?? UIButton.Configuration.filled()
        tocConfig.baseForegroundColor = accentColor
        tocConfig.baseBackgroundColor = UIColor.secondarySystemGroupedBackground
        tocFabButton.configuration = tocConfig
    }

    func updateSuggestedTopicsFooter() {
    let relatedTopics = viewModel.topic?.relatedTopics ?? []
    let suggestedTopics = viewModel.topic?.suggestedTopics ?? []
    // Hide when still loading more, or when the user disabled the recommendation preference.
    let show = viewModel.isReady
        && !viewModel.canLoadMore
        && (!relatedTopics.isEmpty || !suggestedTopics.isEmpty)
        && AppSettings.shared.showSuggestedTopics
    guard show else {
        if tableView.tableFooterView === suggestedTopicsFooter
            || tableView.tableFooterView === footerSpinner {
            tableView.tableFooterView = UIView(
                frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude)
            )
        }
        return
    }
    suggestedTopicsFooter.onSelectTopic = { [weak self] id in
        guard let self else { return }
        let detail = TopicDetailFactory.make(
            api: self.api,
            topicId: id,
            forum: self.coordinator.forum
        )
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
    // Re-assign footer so UITableView picks up the new frame.
    tableView.tableFooterView = suggestedTopicsFooter
    }


    func applyTypography() {
        titleLabel.font = TopicDetailTypography.topicTitleFont()
        navTitleLabel.font = TopicDetailTypography.chromeFont(.navTitle, weight: .semibold)
        errorLabel.font = TopicDetailTypography.chromeFont(.error, weight: .regular)
    }

    func prepareInitialContentTransition() {
        tableView.alpha = 0
        tableView.transform = CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.996, y: 0.996)
        bottomBar.alpha = 0
        bottomBar.transform = CGAffineTransform(translationX: 0, y: 8)
    }

    func animateInitialContentTransition() {
        hasPresentedInitialContent = true
        let animations = {
            self.tableView.alpha = 1
            self.tableView.transform = .identity
            self.bottomBar.alpha = 1
            self.bottomBar.transform = .identity
        }
        DoerMotion.animate(
            duration: DoerMotion.standard,
            timingParameters: DoerMotion.easeOutCubic,
            animations: animations
        )
    }

    func prefetchContentImages(forPostIds postIds: [Int]) {
        let newPostIds = postIds.filter { postId in
            prefetchedImagePostIds.insert(postId).inserted
        }
        // Cap network prefetch after a background disk filter: long posts have dozens of
        // URLs; warming all of them on main/CDN hosts is a common CF shield trigger.
        let rawContentURLs = newPostIds.flatMap { postId in
            viewModel.parsedBlocks[postId]?.imageSourceURLs.compactMap(URL.init(string:)) ?? []
        }
        var seen = Set<String>()
        var contentURLs: [URL] = []
        for url in rawContentURLs {
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            contentURLs.append(url)
        }
        ForumImageLoader.prefetch(urls: contentURLs, cloudflareBaseURL: baseURL, maxUncached: 8)

        let avatarURLs = avatarURLs(forPostIds: newPostIds)
        AvatarImageLoader.prefetch(
            urls: avatarURLs,
            cloudflareBaseURL: baseURL
        )
    }

    func avatarURLs(forPostIds postIds: [Int]) -> [URL] {
        let postIds = Set(postIds)
        return viewModel.posts.compactMap { post in
            guard postIds.contains(post.id) else { return nil }
            return AvatarImageLoader.url(
                from: post.avatarTemplate,
                baseURL: baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
        }
    }

    func startObservingCloudflareVerification() {
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

    func handleCloudflareVerificationCompleted(_ notification: Notification) {
        guard let verifiedBaseURL = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String,
              ForumInstance.normalizedBaseURL(verifiedBaseURL) == ForumInstance.normalizedBaseURL(baseURL)
        else { return }
        guard !isRecoveringAfterCloudflare else { return }
        isRecoveringAfterCloudflare = true

        // Unstick immediately (CF sheet / jump overlay can leave the page non-interactive).
        view.isUserInteractionEnabled = true
        tableView.isUserInteractionEnabled = true
        tableView.isScrollEnabled = true
        jumpOverlay.isHidden = true

        let shouldReload = TopicDetailCloudflareRecoveryPolicy.shouldReloadTopic(
            isReady: viewModel.isReady,
            hasParsedPosts: !viewModel.parsedBlocks.isEmpty,
            errorMessage: viewModel.errorMessage
        )
        if shouldReload {
            viewModel.errorMessage = String(
                localized: "cloudflare.recovering",
                defaultValue: "验证已通过，正在重新加载…"
            )
            viewModel.notifyChanged()
            errorLabel.text = viewModel.errorMessage
            errorLabel.isHidden = false
            loadingSkeletonView.setSkeletonActive(true, animated: true)
        }

        Task { [weak self] in
            guard let self else { return }
            await WebCookieStore.shared.forceSyncCloudflareClearance(for: self.baseURL)

            let readyPostIds = self.viewModel.posts.compactMap { post in
                self.viewModel.parsedBlocks[post.id] == nil ? nil : post.id
            }
            AvatarImageLoader.credentialsDidChange(
                for: self.baseURL,
                retrying: self.avatarURLs(forPostIds: readyPostIds)
            )
            self.prefetchedImagePostIds.removeAll()

            if shouldReload {
                self.api.resetSession()
                await self.viewModel.recoverAfterCloudflare(
                    id: self.topicId,
                    containerWidth: self.view.bounds.width
                )
            }

            await MainActor.run {
                self.isRecoveringAfterCloudflare = false
                self.loadingSkeletonView.setSkeletonActive(false, animated: true)
                self.view.isUserInteractionEnabled = true
                self.tableView.isUserInteractionEnabled = true
                self.tableView.isScrollEnabled = true
                self.jumpOverlay.isHidden = true
                if self.viewModel.isReady {
                    let ids = self.viewModel.posts.compactMap {
                        self.viewModel.parsedBlocks[$0.id] == nil ? nil : $0.id
                    }
                    self.prefetchContentImages(forPostIds: ids)
                }
            }
        }
    }

    func updateTitleHeader() {
        guard let topic = viewModel.topic else { return }
        let container = UIView()
        let metadataRow = makeTopicMetadataRow(topic)
        container.addSubview(titleLabel)
        container.addSubview(tagsContainer)
        container.addSubview(metadataRow)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let tags = topic.tags
        configureTaxonomy(tags: tags, category: viewModel.categoryPresentation)
        let hasVisibleTaxonomy = viewModel.categoryPresentation != nil || !tags.isEmpty

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            tagsContainer.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: hasVisibleTaxonomy ? 8 : 0),
            tagsContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            tagsContainer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            metadataRow.topAnchor.constraint(equalTo: tagsContainer.bottomAnchor, constant: 10),
            metadataRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            metadataRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            metadataRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        let targetSize = CGSize(width: tableView.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let size = container.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        container.frame.size = size
        tableView.tableHeaderView = container
    }

    func makeTopicMetadataRow(_ topic: DiscourseTopicDetail) -> UIStackView {
        let replyCount = max(topic.replyCount, max(topic.postsCount - 1, 0))
        let row = UIStackView(arrangedSubviews: [
            makeTopicMetadataItem(
                symbolName: "bubble.left",
                value: formatCompactCount(replyCount),
                label: String(localized: "topic_detail.metadata.replies")
            ),
            makeTopicMetadataItem(
                symbolName: "eye",
                value: formatCompactCount(topic.views),
                label: String(localized: "topic_detail.metadata.views")
            ),
            makeTopicMetadataItem(
                symbolName: "clock",
                value: formatRelativeDate(topic.createdAt),
                label: nil
            ),
        ])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.distribution = .fill
        return row
    }

    func makeTopicMetadataItem(symbolName: String, value: String, label: String?) -> UIView {
        let iconView = UIImageView(image: UIImage(systemName: symbolName))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        let valueLabel = UILabel()
        valueLabel.font = TopicDetailTypography.interfaceFont(ofSize: 13, weight: .medium)
        valueLabel.textColor = .secondaryLabel
        valueLabel.text = value

        let stack = UIStackView(arrangedSubviews: [iconView, valueLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let label {
            let labelView = UILabel()
            labelView.font = TopicDetailTypography.interfaceFont(ofSize: 13, weight: .regular)
            labelView.textColor = .tertiaryLabel
            labelView.text = label
            stack.addArrangedSubview(labelView)
        }

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])
        return stack
    }

    func formatCompactCount(_ value: Int) -> String {
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    func formatRelativeDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString)
        guard let date else { return "" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    func configureTaxonomy(
        tags: [DiscourseTopicDetail.Tag],
        category: TopicCategoryBadgePresentation?
    ) {
        tagsContainer.subviews.forEach { $0.removeFromSuperview() }
        tagsContainer.constraints.forEach { tagsContainer.removeConstraint($0) }
        guard category != nil || !tags.isEmpty else {
            tagsContainer.heightAnchor.constraint(equalToConstant: 0).isActive = true
            return
        }

        let hSpacing: CGFloat = 6
        let vSpacing: CGFloat = 6
        let maxWidth = tableView.bounds.width - 32 // 16pt padding on each side

        var badges: [TopicTaxonomyBadgeView] = []
        if let category {
            let badge = TopicTaxonomyBadgeView(
                category: category,
                baseURL: baseURL,
                variant: .regular,
                isInteractive: true
            )
            badge.addAction(UIAction { [weak self] _ in
                guard let self, let resolvedCategory = self.viewModel.category else { return }
                let viewController = CategoryTopicsViewController(api: self.api, category: resolvedCategory)
                self.navigationController?.pushViewController(viewController, animated: true)
            }, for: .touchUpInside)
            badges.append(badge)
        }

        for tag in tags {
            let color = TopicTagVisualStyle.color(for: tag.name)
            let badge = TopicTaxonomyBadgeView(
                tag: tag.name,
                color: color,
                variant: .regular,
                isInteractive: true
            )
            let tagName = tag.routeName
            badge.addAction(UIAction { [weak self] _ in
                guard let self, !tagName.isEmpty else { return }
                let vc = TagTopicsViewController(api: self.api, tagName: tagName)
                self.navigationController?.pushViewController(vc, animated: true)
            }, for: .touchUpInside)
            badges.append(badge)
        }

        // Flow layout: calculate positions with line wrapping
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for badge in badges {
            badge.translatesAutoresizingMaskIntoConstraints = true
            let size = badge.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + vSpacing
                lineHeight = 0
            }
            badge.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            tagsContainer.addSubview(badge)
            x += size.width + hSpacing
            lineHeight = max(lineHeight, size.height)
        }
        let totalHeight = y + lineHeight
        tagsContainer.heightAnchor.constraint(equalToConstant: totalHeight).isActive = true
    }

    // MARK: - Emoji Title

    func configureTitleLabel(_ title: String) {
        renderedTopicTitle = title
        let headerFont = titleLabel.font ?? TopicDetailTypography.topicTitleFont()
        let navFont = navTitleLabel.font ?? .systemFont(ofSize: 17, weight: .semibold)
        TitleEmojiRenderer.apply(
            title,
            to: titleLabel,
            font: headerFont,
            textColor: titleLabel.textColor,
            baseURL: baseURL
        )
        TitleEmojiRenderer.apply(
            title,
            to: navTitleLabel,
            font: navFont,
            textColor: navTitleLabel.textColor,
            baseURL: baseURL
        )
        navTitleLabel.sizeToFit()
    }

    // MARK: - Reading Tracking

    func syncReadLaterProgressOnExit() {
        let username = AuthManager.shared.username(for: baseURL)
        let serverLast = viewModel.topic?.lastReadPostNumber
        let local = TopicReadProgressStore.shared.highestSeen(
            topicId: topicId,
            baseURL: baseURL,
            username: username
        )
        let merged = max(serverLast ?? 0, local)
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

    func updateVisibleReadingPosts() {
        guard isViewLoaded, view.window != nil, !isApplyingPostSnapshot else { return }
        let postNumbers = (tableView.indexPathsForVisibleRows ?? []).compactMap { indexPath -> Int? in
            guard let postId = dataSource.itemIdentifier(for: indexPath),
                  postId != TopicDetailListItem.nestedSortBarID
            else { return nil }
            return viewModel.post(byId: postId)?.postNumber
        }
        readingTracker.setVisiblePostNumbers(Set(postNumbers))
    }

    /// Complete deferred long-post tails and unpause animated media on visible rows.
    func finishVisibleCellsAfterScrollSettle() {
        guard isViewLoaded, view.window != nil else { return }
        for cell in tableView.visibleCells {
            guard let native = cell as? PostNativeCell else { continue }
            native.completeProgressiveContentIfNeeded(force: true)
            native.setScrollMediaPaused(false)
        }
        #if DEBUG
        // Occasional breadcrumb while tuning scroll perf.
        if TopicDetailPerfCounters.progressiveCompletes > 0 || TopicDetailPerfCounters.heightInvalidateRequests > 0 {
            print("[TopicDetailPerf] \(TopicDetailPerfCounters.summary)")
        }
        #endif
    }

    /// Pre-fill estimated heights from parsed blocks so first-pass `estimatedHeightForRowAt`
    /// is closer to real size and reduces scroll compensation jank.
    func warmEstimatedRowHeights(forPostIds postIds: [Int]) {
        let tableWidth = tableView.bounds.width > 1 ? tableView.bounds.width : view.bounds.width
        for postId in postIds {
            if postId == TopicDetailListItem.nestedSortBarID {
                postRowEstimatedHeightCache[postId] = 48
                continue
            }
            if let measured = postRowHeightCache[postId], measured > 1 { continue }
            if let existing = postRowEstimatedHeightCache[postId], existing > 1 { continue }
            guard let blocks = viewModel.parsedBlocks[postId] else { continue }
            let nestedRow = viewModel.isNestedViewEnabled ? viewModel.nestedRow(forPostId: postId) : nil
            let isFirst: Bool = {
                if let post = viewModel.post(byId: postId), post.postNumber == 1 { return true }
                if let streamIndex = viewModel.allPostIds.firstIndex(of: postId) {
                    return streamIndex == 0
                }
                return postIds.first == postId
            }()
            let contentWidth = PostNativeCell.renderContentWidth(
                for: tableWidth,
                isFirstPost: isFirst,
                nestedDepth: nestedRow?.depth ?? 0,
                isNestedTree: nestedRow != nil
            )
            postRowEstimatedHeightCache[postId] = TopicDetailRowHeightEstimator.estimate(
                blocks: blocks,
                isFirstPost: isFirst,
                contentWidth: contentWidth
            )
        }
    }

    /// Diffable often skips reloads when post IDs are unchanged after a sort tap.
    /// Force the chip bar to pick up `viewModel.nestedSort` selection chrome.
    func refreshNestedSortBarSelection() {
        let sortBarID = TopicDetailListItem.nestedSortBarID
        if let indexPath = dataSource.indexPath(for: sortBarID),
           let cell = tableView.cellForRow(at: indexPath) as? NestedSortBarCell {
            cell.configure(selected: viewModel.nestedSort)
            return
        }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(sortBarID) else { return }
        snapshot.reconfigureItems([sortBarID])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func applyPostSnapshot(
        itemIDs: [Int],
        earlierAnchor: (postId: Int, cellTopOffset: CGFloat)?
    ) {
        let decision = TopicDetailSnapshotPolicy.decision(
            isApplying: isApplyingPostSnapshot,
            currentItemIDs: dataSource.snapshot().itemIdentifiers,
            requestedItemIDs: itemIDs
        )

        switch decision {
        case .skip:
            if earlierAnchor != nil {
                earlierLoadAnchor = nil
                isLoadingEarlierLocally = false
            }
        case .queue:
            pendingPostSnapshot = PendingPostSnapshot(
                itemIDs: itemIDs,
                earlierAnchor: earlierAnchor ?? pendingPostSnapshot?.earlierAnchor
            )
        case .apply:
            isApplyingPostSnapshot = true
            tableView.doer_beginDataMutation()
            if earlierAnchor != nil {
                earlierLoadAnchor = nil
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems(itemIDs, toSection: 0)
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    if let earlierAnchor {
                        if let newIndexPath = self.dataSource.indexPath(for: earlierAnchor.postId) {
                            UIView.performWithoutAnimation {
                                self.tableView.layoutIfNeeded()
                                let newCellTop = self.tableView.rectForRow(at: newIndexPath).minY
                                self.tableView.setContentOffset(
                                    CGPoint(x: self.tableView.contentOffset.x, y: newCellTop - earlierAnchor.cellTopOffset),
                                    animated: false
                                )
                            }
                            self.lastScrollOffset = self.tableView.contentOffset.y
                        }
                        self.isLoadingEarlierLocally = false
                    }

                    self.isApplyingPostSnapshot = false
                    // Ends mutation and flushes any height passes that queued mid-apply.
                    self.tableView.doer_endDataMutation()
                    if let pending = self.pendingPostSnapshot {
                        self.pendingPostSnapshot = nil
                        self.applyPostSnapshot(
                            itemIDs: pending.itemIDs,
                            earlierAnchor: pending.earlierAnchor
                        )
                    } else if self.pendingScrollToFloor != nil {
                        self.view.setNeedsLayout()
                    }
                    self.updateVisibleReadingPosts()
                    self.updateBottomBarProgress()
                }
            }
        }
    }

    // MARK: - Actions moved to TopicDetailViewController+Actions.swift
}
