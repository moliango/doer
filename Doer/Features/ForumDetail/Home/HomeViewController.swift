import Combine
import UIKit

enum HomeFABMode {
    case create
    case refresh
}

final class HomeViewController: ObservableViewController {
    static let initialContentReadyNotification = Notification.Name("DoerHomeInitialContentReadyNotification")

    static let reloadTimeoutNanoseconds: UInt64 = 25_000_000_000
    static let searchRowExpandedHeight: CGFloat = 40
    static let categoryRowHeight: CGFloat = 36
    static let filterRowHeight: CGFloat = 36
    static let incomingTopicsBannerHeight: CGFloat = 64
    /// Compact chat-theme banner host height (Telegram pill / WeChat tip bar).
    static let incomingTopicsBannerHeightChat: CGFloat = 52
    /// Category chip row → filter row (matches `filterTopToCategoryConstraint` constant).
    static let categoryToFilterSpacing: CGFloat = 6
    /// Filter row → search row (matches `searchBelowFilterConstraint` constant).
    static let filterToSearchSpacing: CGFloat = 8
    /// Safe-area → filter when the chip row is collapsed for drawer mode.
    static let filterTopInDrawerSpacing: CGFloat = 2
    static let headerBottomPadding: CGFloat = 8
    static let baseTableTopSpacing: CGFloat = 16
    static let baseTableBottomSpacing: CGFloat = 12
    static let xiaohongshuTableTopSpacing: CGFloat = 32
    static let xiaohongshuTableBottomSpacing: CGFloat = 16
    static let topRefreshGeometryReleaseDelay: TimeInterval = 0.28

    let api: DiscourseAPI
    let viewModel: HomeViewModel
    let notificationCoordinator: ForumNotificationCoordinator
    weak var authGate: AuthGating?
    var categoryTabButtons: [Int?: UIButton] = [:]
    var categoryTabOrder: [Int?] = []
    var headerHeightConstraint: NSLayoutConstraint?
    var searchRowHeightConstraint: NSLayoutConstraint?
    var categoryManagerTrailingToChromeConstraint: NSLayoutConstraint?
    var categoryManagerTrailingToHeaderConstraint: NSLayoutConstraint?
    var categoryScrollHeightConstraint: NSLayoutConstraint?
    /// Filter under category chips (normal mode).
    var filterTopToCategoryConstraint: NSLayoutConstraint?
    /// Filter under safe area when category chips are hidden (drawer mode).
    var filterTopToSafeAreaConstraint: NSLayoutConstraint?
    var trailingChromeCenterYToCategoryConstraint: NSLayoutConstraint?
    var trailingChromeCenterYToFilterConstraint: NSLayoutConstraint?
    /// Chip mode: filter uses full width (chrome is on the top row).
    var filterTrailingToHeaderConstraint: NSLayoutConstraint?
    /// Drawer mode: filter leaves room for chrome on the same row.
    var filterTrailingToChromeConstraint: NSLayoutConstraint?
    var floatingActionButtonBottomConstraint: NSLayoutConstraint?
    var isSearchRowCollapsed = false
    /// Cancels in-flight morph so a stale expand completion cannot hide the
    /// compact search icon while the row is still collapsed (fast flick bug).
    var searchRowMorphGeneration = 0
    var searchRowMorphAnimator: UIViewPropertyAnimator?
    var fabMode: HomeFABMode = .create
    var isCreateMenuVisible = false
    var isHomeTabBarHidden = false
    var lastHomeScrollY: CGFloat?
    var incomingTopicsPollTimer: Timer?
    var cloudflareCompletionObservationToken: NSObjectProtocol?
    var authObservationToken: AnyCancellable?
    var settingsObservationToken: AnyCancellable?
    var foregroundObservationToken: NSObjectProtocol?
    var topicReadProgressObservationToken: NSObjectProtocol?
    var topicReloadTask: Task<Void, Never>?
    var topicLoadMoreTask: Task<Void, Never>?
    var reloadTimeoutTask: Task<Void, Never>?
    var incomingTopicsRetryTask: Task<Void, Never>?
    var reloadSequence = 0
    var lastAuthenticatedState: Bool?
    var isInitialTopicLoadPending = true
    var didPostInitialContentReady = false
    var isIncomingTopicsBannerVisible = false
    var isIncomingTopicsInlineBannerVisible = false
    var incomingTopicsUsesTopSpace = false
    /// Floating banner layout (theme-adaptive margins / height / centering).
    var incomingTopicsHeaderHeightConstraint: NSLayoutConstraint?
    var incomingTopicsButtonHeightConstraint: NSLayoutConstraint?
    var incomingTopicsButtonLeadingConstraint: NSLayoutConstraint?
    var incomingTopicsButtonTrailingConstraint: NSLayoutConstraint?
    var incomingTopicsButtonCenterXConstraint: NSLayoutConstraint?
    var incomingTopicsButtonMaxWidthConstraint: NSLayoutConstraint?
    var incomingTopicsInlineButtonHeightConstraint: NSLayoutConstraint?
    var incomingTopicsInlineButtonLeadingConstraint: NSLayoutConstraint?
    var incomingTopicsInlineButtonTrailingConstraint: NSLayoutConstraint?
    var incomingTopicsInlineButtonCenterXConstraint: NSLayoutConstraint?
    var incomingTopicsInlineButtonMaxWidthConstraint: NSLayoutConstraint?
    var isTopRefreshGeometryLocked = false
    var topRefreshGeometryLockID = 0
    /// 刷新/回弹窗口：冻结滚动驱动的 tab bar 显隐，避免和 contentOffset 抖动打架。
    var isTabBarScrollFrozenForRefresh = false
    var tabBarScrollFreezeID = 0
    /// 加载下一页及 contentSize 稳定窗口。
    var isTabBarScrollFrozenForLoadMore = false
    var tabBarLoadMoreFreezeID = 0
    var wasLoadingMoreTopics = false
    /// Tracks list content height so load-more contentSize jumps are not
    /// mistaken for "scroll up" (which would incorrectly reveal the tab bar).
    var lastTopicListContentHeight: CGFloat = 0
    /// After pagination contentSize jumps, suppress tab-bar *show* until this time
    /// (CACurrentMediaTime). Hide is still allowed. Prevents bounce-reveal.
    var tabBarShowSuppressedUntil: CFTimeInterval = 0
    var loadingSkeletonTopConstraint: NSLayoutConstraint?
    let categoryDrawer = HomeCategoryDrawerView(frame: .zero)
    var categoryDrawerEdgePan: UIScreenEdgePanGestureRecognizer?
    var didLoadCategoryDrawerTags = false
    /// Observation of app-wide `ConnectivityService` (FluxDo-aligned).
    var connectivityObservationToken: NSObjectProtocol?
    let offlineIndicatorView = OfflineIndicatorView()

    var isCategoryDrawerMode: Bool {
        AppSettings.shared.homeCategoryDrawerSwipeEnabled
    }

    /// Category chip row is hidden when the side drawer owns category navigation.
    var effectiveCategoryRowHeight: CGFloat {
        isCategoryDrawerMode ? 0 : Self.categoryRowHeight
    }

    /// Vertical gaps between category chips / filter (最新) / search.
    /// Drawer mode drops the chip row, so only filter→search spacing remains.
    var effectiveHeaderVerticalSpacing: CGFloat {
        if isCategoryDrawerMode {
            return Self.filterToSearchSpacing
        }
        // category → filter + filter → search
        return Self.categoryToFilterSpacing + Self.filterToSearchSpacing
    }

    var expandedHeaderHeight: CGFloat {
        view.safeAreaInsets.top
            + 2
            + Self.searchRowExpandedHeight
            + effectiveHeaderVerticalSpacing
            + effectiveCategoryRowHeight
            + Self.filterRowHeight
            + Self.headerBottomPadding
    }

    var collapsedHeaderHeight: CGFloat {
        view.safeAreaInsets.top
            + 2
            + effectiveHeaderVerticalSpacing
            + effectiveCategoryRowHeight
            + Self.filterRowHeight
            + Self.headerBottomPadding
    }

    let headerContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .systemGroupedBackground
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    let searchRowStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.clipsToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    let searchButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "home.search.placeholder")
        config.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        config.imagePlacement = .leading
        config.imagePadding = 8
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 14, weight: .regular)
            return a
        }
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.backgroundColor = .secondarySystemGroupedBackground
        button.layer.cornerRadius = 20
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    let notificationButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "bell", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular))
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "notifications.title")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    let notificationBadgeView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemRed
        view.layer.cornerRadius = 4.5
        view.layer.borderWidth = 1.5
        view.isHidden = true
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    let categoryManagerButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "home.category_manager.title")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    let miniProgramButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "square.grid.2x2",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "mini_program.drawer.open", defaultValue: "打开小程序")
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    /// Icon-only search shown on the trailing chrome when the full search bar is collapsed.
    let compactSearchButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "home.search.placeholder")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.alpha = 0
        button.isHidden = true
        return button
    }()

    /// Trailing action cluster on the filter/category row: [search icon] [mini-program] [bell].
    let trailingChromeStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    var miniProgramDrawer: MiniProgramDrawerViewController?

    let categoryScrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    let categoryStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    let filterStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    let filterButton: UIButton = {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    let newSubsetButton: UIButton = {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    let categoryButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "home.filter.categories")
        config.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 3
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 8)
        config.background.backgroundColor = .secondarySystemGroupedBackground
        config.background.cornerRadius = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var a = attrs
            a.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            return a
        }
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        HomeTopicListLayoutSupport.registerAllCells(in: tv)
        tv.delegate = self
        tv.separatorStyle = .none
        tv.backgroundColor = .systemGroupedBackground
        tv.showsVerticalScrollIndicator = false
        tv.showsHorizontalScrollIndicator = false
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = TopicCell.estimatedHeight
        return tv
    }()

    lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = .init(tableView: tableView) { [weak self] tableView, indexPath, topicId in
        guard let self else {
            return UITableViewCell()
        }
        return self.topicListLayout.cell(
            tableView: tableView,
            indexPath: indexPath,
            itemId: topicId,
            context: self.homeTopicListCellContext()
        )
    }

    var usesXiaohongshuCardLayout: Bool {
        topicListLayout.kind == .xiaohongshu
    }

    /// Chat session-list layout (WeChat / Telegram) via `WeChatTopicListCell`.
    var usesChatHomeListLayout: Bool {
        topicListLayout.kind == .weChat || topicListLayout.kind == .telegram
    }

    /// Legacy alias used by older call sites; prefer `usesChatHomeListLayout`.
    var usesWeChatListLayout: Bool { usesChatHomeListLayout }

    enum HomeListLayoutKind: Equatable {
        case standard
        case xiaohongshu
        case weChat
        case telegram
    }

    var homeListLayoutKind: HomeListLayoutKind { topicListLayout.kind }

    /// Last applied list layout — when this changes, force cell-class swap.
    var lastAppliedHomeListLayoutKind: HomeListLayoutKind?
    var topicListLayout: any HomeTopicListLayout

    static func xiaohongshuRowIdentifier(for rowIndex: Int) -> Int {
        XiaohongshuHomeTopicListLayout.rowIdentifier(for: rowIndex)
    }

    static func xiaohongshuRowIndex(from identifier: Int) -> Int? {
        XiaohongshuHomeTopicListLayout.rowIndex(from: identifier)
    }

    func homeTopicListCellContext() -> HomeTopicListCellContext {
        HomeTopicListCellContext(
            viewModel: viewModel,
            api: api,
            colorFromHex: Self.color(fromHex:),
            onOpenTopic: { [weak self] id in self?.openTopic(id) }
        )
    }

    func makeHomeTopicDetail(
        topicId: Int,
        initialFloor: Int? = nil,
        initialPostId: Int? = nil,
        lastReadPostNumber: Int? = nil
    ) -> UIViewController {
        topicListLayout.makeTopicDetail(
            api: api,
            topicId: topicId,
            initialFloor: initialFloor,
            initialPostId: initialPostId,
            lastReadPostNumber: lastReadPostNumber
        )
    }

    let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    let loadingSkeletonView = HomeTopicListSkeletonView()
    let emptyStateView = HomeEmptyStateView()

    let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    let emptyFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
    let emptyTableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

    lazy var loadMoreErrorFooter: UIView = {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 68))
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.tag = 901
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.text = String(localized: "home.load_more_failed", defaultValue: "加载更多失败，点击重试")

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(String(localized: "action.retry", defaultValue: "重试"), for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        button.addTarget(self, action: #selector(loadMoreRetryTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -20),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return footer
    }()

    let errorLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    let loginPromptCard: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 28
        view.layer.cornerCurve = .continuous
        view.isHidden = true
        return view
    }()

    let loginLogoView: UIImageView = {
        let view = UIImageView(image: UIImage(named: "LinuxDoLogo") ?? UIImage(named: "launchImg"))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        return view
    }()

    let loginTitleLabel: UILabel = {
        let label = UILabel()
        label.text = "欢迎使用 Doer"
        label.font = .systemFont(ofSize: 24, weight: .bold)
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    let loginFeatureLabel: UILabel = {
        let label = UILabel()
        label.text = "连接观点、记录阅读，也不错过每一次回应"
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    let loginBenefitsStack: UIStackView = {
        let items = [
            ("text.bubble.fill", "探索话题"),
            ("bell.badge.fill", "及时回应"),
            ("bookmark.fill", "同步收藏"),
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 8
        for (symbol, title) in items {
            var config = UIButton.Configuration.tinted()
            config.title = title
            config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
            config.imagePlacement = .top
            config.imagePadding = 6
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 5, bottom: 9, trailing: 5)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updated = attributes
                updated.font = .systemFont(ofSize: 11.5, weight: .semibold)
                return updated
            }
            let item = UIButton(configuration: config)
            item.isUserInteractionEnabled = false
            stack.addArrangedSubview(item)
        }
        return stack
    }()

    let loginButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "home.login_prompt")
        config.cornerStyle = .large
        config.image = UIImage(systemName: "arrow.right")
        config.imagePlacement = .trailing
        config.imagePadding = 8
        config.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 22, bottom: 13, trailing: 22)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        return button
    }()

    let floatingActionButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = AppSettings.shared.themeStyle.accentColor
        button.layer.cornerRadius = 28
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.22
        button.layer.shadowRadius = 10
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.accessibilityLabel = String(localized: "new_topic.title")
        return button
    }()

    let createMenuBackdrop: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.10)
        view.alpha = 0
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }()

    let createMenuContainer: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1.0 / UIScreen.main.scale
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.14
        view.layer.shadowRadius = 18
        view.layer.shadowOffset = CGSize(width: 0, height: 9)
        view.clipsToBounds = false
        view.alpha = 0
        view.isHidden = true
        view.accessibilityViewIsModal = true
        return view
    }()

    let createTopicMenuButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "new_topic.title")
        config.subtitle = String(localized: "new_topic.body.placeholder")
        config.image = UIImage(systemName: "square.and.pencil")
        config.imagePadding = 12
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.background.cornerRadius = 15
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = String(localized: "new_topic.title")
        return button
    }()

    let draftsMenuButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "me.drafts", defaultValue: "我的草稿")
        config.subtitle = String(localized: "me.action.drafts.subtitle", defaultValue: "继续编辑保存的内容")
        config.image = UIImage(systemName: "doc.text.fill")
        config.imagePadding = 12
        config.titleAlignment = .leading
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.background.cornerRadius = 15
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.accessibilityHint = String(localized: "me.action.drafts.subtitle", defaultValue: "继续编辑保存的内容")
        return button
    }()

    lazy var createMenuStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [createTopicMenuButton, draftsMenuButton])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    lazy var createMenuDismissTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(createMenuBackdropTapped))
        gesture.cancelsTouchesInView = true
        gesture.delegate = self
        gesture.isEnabled = false
        return gesture
    }()

    let incomingTopicsHeaderView: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alpha = 0
        view.isHidden = true
        view.accessibilityElementsHidden = true
        return view
    }()

    let incomingTopicsButton: IncomingTopicsBannerView = {
        let button = IncomingTopicsBannerView()
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    let incomingTopicsInlineHeaderView: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: HomeViewController.incomingTopicsBannerHeight))
        view.backgroundColor = .clear
        return view
    }()

    let incomingTopicsInlineButton: IncomingTopicsBannerView = {
        let button = IncomingTopicsBannerView()
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    init(
        api: DiscourseAPI,
        authGate: AuthGating? = nil,
        notificationCoordinator: ForumNotificationCoordinator
    ) {
        self.api = api
        self.viewModel = HomeViewModel(api: api)
        self.authGate = authGate
        self.notificationCoordinator = notificationCoordinator
        self.topicListLayout = HomeTopicListLayoutFactory.make(style: AppSettings.shared.themeStyle)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCategorySelectionIndicators()
        // Never call `updateHeaderHeight` here — it flips compact-search visibility and
        // calls `layoutIfNeeded`, which re-enters this method and pegs CPU at 100%.
        reassertHeaderHeightIfNeeded()

        hideHomeScrollIndicators()
        updateIncomingTopicsInlineHeaderFrame()
        updateIncomingTopicsHeader()
        updateTableInsets()
        let fabBottom = -currentBottomChromeHeight - 20
        if abs((floatingActionButtonBottomConstraint?.constant ?? 0) - fabBottom) > 0.5 {
            floatingActionButtonBottomConstraint?.constant = fabBottom
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        DohDebugLog.record("home viewDidLoad begin", subsystem: "Launch")
        observe(viewModel)
        // Keep the home bell badge in sync with coordinator refresh / mark-read (Phase 3).
        observe(notificationCoordinator)
        view.backgroundColor = .systemGroupedBackground

        tableView.tableFooterView = emptyFooterView
        tableView.refreshControl = refreshControl
        tableView.contentInsetAdjustmentBehavior = .never
        hideHomeScrollIndicators()

        tableView.tableHeaderView = emptyTableHeaderView
        incomingTopicsHeaderView.addSubview(incomingTopicsButton)
        incomingTopicsInlineHeaderView.addSubview(incomingTopicsInlineButton)
        view.addSubview(tableView)
        view.addSubview(loadingSkeletonView)
        view.addSubview(emptyStateView)
        view.addSubview(headerContainer)
        view.addSubview(offlineIndicatorView)
        view.addSubview(incomingTopicsHeaderView)

        view.addSubview(activityIndicator)
        let loginStack = UIStackView(arrangedSubviews: [loginLogoView, loginTitleLabel, loginFeatureLabel, errorLabel, loginBenefitsStack, loginButton])
        loginStack.axis = .vertical
        loginStack.alignment = .fill
        loginStack.spacing = 12
        loginStack.setCustomSpacing(7, after: loginTitleLabel)
        loginStack.setCustomSpacing(18, after: errorLabel)
        loginStack.setCustomSpacing(22, after: loginBenefitsStack)
        loginStack.translatesAutoresizingMaskIntoConstraints = false
        loginPromptCard.addSubview(loginStack)
        view.addSubview(loginPromptCard)
        createMenuContainer.contentView.addSubview(createMenuStackView)
        view.addSubview(createMenuBackdrop)
        view.addSubview(createMenuContainer)
        view.addSubview(floatingActionButton)
        view.addGestureRecognizer(createMenuDismissTapGesture)

        setupHeader()
        applyThemeStyle()
        updateFloatingActionButton(animated: false)
        emptyStateView.onRefresh = { [weak self] in
            self?.refreshFromEmptyState()
        }
        offlineIndicatorView.onRetry = { [weak self] in
            ConnectivityService.shared.check()
            // Always attempt list recovery — path may already look "up" while forum is still down.
            self?.recoverTransportAndReload()
        }

        let fabBottomConstraint = floatingActionButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -currentBottomChromeHeight - 20)
        floatingActionButtonBottomConstraint = fabBottomConstraint
        let skeletonTopConstraint = loadingSkeletonView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: Self.baseTableTopSpacing)
        loadingSkeletonTopConstraint = skeletonTopConstraint

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            skeletonTopConstraint,
            loadingSkeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingSkeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingSkeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyStateView.topAnchor.constraint(greaterThanOrEqualTo: headerContainer.bottomAnchor, constant: 64),
            emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 28),

            headerContainer.topAnchor.constraint(equalTo: view.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            offlineIndicatorView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            offlineIndicatorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            offlineIndicatorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            incomingTopicsHeaderView.topAnchor.constraint(equalTo: offlineIndicatorView.bottomAnchor, constant: 6),
            incomingTopicsHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            incomingTopicsHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            incomingTopicsButton.centerYAnchor.constraint(equalTo: incomingTopicsHeaderView.centerYAnchor),

            incomingTopicsInlineButton.centerYAnchor.constraint(equalTo: incomingTopicsInlineHeaderView.centerYAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            loginPromptCard.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -34),
            loginPromptCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            loginPromptCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            loginStack.topAnchor.constraint(equalTo: loginPromptCard.topAnchor, constant: 28),
            loginStack.leadingAnchor.constraint(equalTo: loginPromptCard.leadingAnchor, constant: 24),
            loginStack.trailingAnchor.constraint(equalTo: loginPromptCard.trailingAnchor, constant: -24),
            loginStack.bottomAnchor.constraint(equalTo: loginPromptCard.bottomAnchor, constant: -26),
            loginLogoView.heightAnchor.constraint(equalToConstant: 68),
            loginButton.heightAnchor.constraint(equalToConstant: 50),

            createMenuBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            createMenuBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            createMenuBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            createMenuBackdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            createMenuContainer.trailingAnchor.constraint(equalTo: floatingActionButton.trailingAnchor),
            createMenuContainer.bottomAnchor.constraint(equalTo: floatingActionButton.topAnchor, constant: -12),
            createMenuContainer.widthAnchor.constraint(equalToConstant: 218),

            createMenuStackView.topAnchor.constraint(equalTo: createMenuContainer.contentView.topAnchor, constant: 8),
            createMenuStackView.leadingAnchor.constraint(equalTo: createMenuContainer.contentView.leadingAnchor, constant: 8),
            createMenuStackView.trailingAnchor.constraint(equalTo: createMenuContainer.contentView.trailingAnchor, constant: -8),
            createMenuStackView.bottomAnchor.constraint(equalTo: createMenuContainer.contentView.bottomAnchor, constant: -8),
            createTopicMenuButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            draftsMenuButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),

            floatingActionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            fabBottomConstraint,
            floatingActionButton.widthAnchor.constraint(equalToConstant: 56),
            floatingActionButton.heightAnchor.constraint(equalToConstant: 56),
        ])
        headerHeightConstraint = headerContainer.heightAnchor.constraint(equalToConstant: expandedHeaderHeight)
        headerHeightConstraint?.isActive = true
        installIncomingTopicsBannerLayoutConstraints()
        applyIncomingTopicsBannerLayout()

        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        compactSearchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        notificationButton.addTarget(self, action: #selector(notificationsTapped), for: .touchUpInside)
        categoryManagerButton.addTarget(self, action: #selector(categoryManagerTapped), for: .touchUpInside)
        miniProgramButton.addTarget(self, action: #selector(miniProgramButtonTapped), for: .touchUpInside)
        updateMiniProgramButtonVisibility()
        let managerLongPress = UILongPressGestureRecognizer(target: self, action: #selector(categoryManagerLongPressed(_:)))
        categoryManagerButton.addGestureRecognizer(managerLongPress)
        setupCategoryDrawer()
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        createTopicMenuButton.addTarget(self, action: #selector(createTopicMenuTapped), for: .touchUpInside)
        draftsMenuButton.addTarget(self, action: #selector(draftsMenuTapped), for: .touchUpInside)
        floatingActionButton.addTarget(self, action: #selector(fabTapped), for: .touchUpInside)
        incomingTopicsButton.addTarget(self, action: #selector(incomingTopicsTapped), for: .touchUpInside)
        incomingTopicsInlineButton.addTarget(self, action: #selector(incomingTopicsTapped), for: .touchUpInside)
        lastAuthenticatedState = AuthManager.shared.isAuthenticated(for: api.baseURL)
        startObservingCloudflareVerification()
        startObservingAuthChanges()
        startObservingSettingsChanges()
        startObservingForeground()
        startObservingTopicReadProgress()
        startMonitoringNetwork()

        loadingSkeletonView.setSkeletonActive(true, animated: false)
        tableView.isHidden = true
        // 后台 latest.json 缓存先填列表，再走网络刷新。
        viewModel.hydrateFromBackgroundCacheIfNeeded()
        if !viewModel.topics.isEmpty {
            isInitialTopicLoadPending = false
            updateUI()
        }
        reloadTopics()
        DohDebugLog.record(
            "home viewDidLoad end topics=\(viewModel.topics.count) theme=\(AppSettings.shared.themeStyle.rawValue)",
            subsystem: "Launch"
        )
        Task {
            await api.loadOrFetchEmojiMap()
        }
    }

    @MainActor deinit {
        if let cloudflareCompletionObservationToken {
            NotificationCenter.default.removeObserver(cloudflareCompletionObservationToken)
        }
        authObservationToken?.cancel()
        settingsObservationToken?.cancel()
        if let foregroundObservationToken {
            NotificationCenter.default.removeObserver(foregroundObservationToken)
        }
        if let topicReadProgressObservationToken {
            NotificationCenter.default.removeObserver(topicReadProgressObservationToken)
        }
        topicReloadTask?.cancel()
        reloadTimeoutTask?.cancel()
        incomingTopicsRetryTask?.cancel()
        if let connectivityObservationToken {
            NotificationCenter.default.removeObserver(connectivityObservationToken)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Mini-program dismiss must not animate the bar hide, or it flashes while
        // the host is still sliding away. Interactive pops hide it along the swipe
        // so the list does not snap.
        if let coordinator = transitionCoordinator,
           coordinator.isInteractive,
           presentedViewController == nil,
           coordinator.viewController(forKey: .from) !== self {
            navigationController?.setNavigationBarHidden(true, animated: animated)
            coordinator.notifyWhenInteractionChanges { [weak self] context in
                guard let self, context.isCancelled else { return }
                self.navigationController?.setNavigationBarHidden(false, animated: false)
            }
        } else {
            navigationController?.setNavigationBarHidden(true, animated: false)
        }

        let applyVisibleChrome = { [weak self] in
            guard let self else { return }
            // Always surface tab bar when home becomes visible; passive offset checks
            // previously could leave it hidden after first-launch layout jumps.
            self.setHomeTabBarHidden(false, animated: false)
            self.lastHomeScrollY = self.tableView.contentOffset.y + self.tableView.contentInset.top
            // Near top: always show the full search bar (never leave it collapsed
            // from a previous scroll session / inset jump).
            let y = self.tableView.contentOffset.y + self.tableView.contentInset.top
            if y < 24 {
                self.setSearchRowCollapsed(false, animated: false)
            } else if self.searchChromeNeedsHeal() {
                self.applySearchRowChromeFinalState()
            }
            self.updateTabBarVisibilityForCurrentScroll(animated: false)
        }

        // Mini-program host dismiss: chrome was already settled under the cover.
        // Defer search/tab heal until the transition ends so we don't reflow the
        // list under a half-dismissed modal (reads as a bounce at the end).
        if let coordinator = transitionCoordinator,
           presentedViewController == nil,
           coordinator.viewController(forKey: .from) !== self {
            coordinator.animate(alongsideTransition: nil) { context in
                guard !context.isCancelled else { return }
                applyVisibleChrome()
            }
        } else {
            applyVisibleChrome()
        }

        viewModel.restoreBackgroundTopicUpdates()
        updateIncomingTopicsHeader()
        startIncomingTopicsPolling()
        reloadAfterBecomingVisibleIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // fullScreen mini-program / modal cover: keep home chrome as-is under the
        // presenter. Unhiding nav/tab bar here is invisible while covered, then
        // flashes during dismiss when viewWillAppear tries to hide them again.
        let coveredByModal = presentedViewController != nil
            || navigationController?.presentedViewController != nil
            || tabBarController?.presentedViewController != nil
        if !coveredByModal {
            navigationController?.setNavigationBarHidden(false, animated: animated)
            if !isNavigatingToControllerThatOwnsBottomBarVisibility {
                setHomeTabBarHidden(false, animated: animated)
            }
        }
        stopIncomingTopicsPolling()
    }

    var isNavigatingToControllerThatOwnsBottomBarVisibility: Bool {
        if let destination = transitionCoordinator?.viewController(forKey: .to),
           destination !== self {
            return destination.hidesBottomBarWhenPushed
        }
        guard let topViewController = navigationController?.topViewController,
              topViewController !== self
        else {
            return false
        }
        return topViewController.hidesBottomBarWhenPushed
    }

    override func updateUI() {
        applyThemeStyle()
        updateNotificationBadge()
        let scope = viewModel.consumePendingUIScope()

        if viewModel.requiresLogin {
            applyLoginRequiredUI()
            return
        }

        if scope.contains(.login) {
            applyLoggedInChrome()
        }
        if scope.contains(.chrome) {
            applyCategoryChrome()
        }
        if scope.contains(.incoming) {
            updateIncomingTopicsHeader()
        }
        if scope.contains(.list) || scope.contains(.loading) {
            applyHomeContentVisibility()
        }
        if scope.contains(.list) {
            applyTopicSnapshot()
            if shouldFreezeTabBarScrollControl {
                lastHomeScrollY = tableView.contentOffset.y + tableView.contentInset.top
            }
        }
        if scope.contains(.loading) {
            applyHomeLoadingChrome()
            syncTabBarFreezeWithLoadMoreState()
        }
    }

    private func applyLoginRequiredUI() {
        setCreateMenuVisible(false, animated: false)
        isInitialTopicLoadPending = false
        errorLabel.text = viewModel.errorMessage
        errorLabel.isHidden = false
        loginButton.isHidden = false
        loginPromptCard.isHidden = false
        tableView.isHidden = true
        headerContainer.isHidden = true
        floatingActionButton.isHidden = true
        setIncomingTopicsBannerVisible(false, animated: false)
        setIncomingTopicsInlineBannerVisible(false)
        loadingSkeletonView.setSkeletonActive(false, animated: false)
        emptyStateView.setVisible(false, animated: false)
        activityIndicator.stopAnimating()
    }

    private func applyLoggedInChrome() {
        loginButton.isHidden = true
        loginPromptCard.isHidden = true
        headerContainer.isHidden = false
        floatingActionButton.isHidden = false
    }

    private func applyCategoryChrome() {
        categoryButton.menu = UIMenu(title: "", children: buildCategoryMenuElements())
        updateCategoryButton()
        rebuildCategoryTabs()
        updateFilterButton()
    }

    private func applyHomeContentVisibility() {
        let showsInitialSkeleton = (viewModel.isLoading || isInitialTopicLoadPending)
            && viewModel.topics.isEmpty
            && viewModel.errorMessage == nil
        loadingSkeletonView.setSkeletonActive(showsInitialSkeleton, animated: view.window != nil)
        let showsEmptyState = !showsInitialSkeleton
            && viewModel.topics.isEmpty
            && viewModel.errorMessage == nil
        emptyStateView.setVisible(showsEmptyState, animated: view.window != nil)
        tableView.isHidden = showsInitialSkeleton
            || showsEmptyState
            || (viewModel.topics.isEmpty && viewModel.errorMessage != nil)

        if let error = viewModel.errorMessage, viewModel.topics.isEmpty {
            errorLabel.text = error
            errorLabel.isHidden = false
            emptyStateView.setVisible(false, animated: view.window != nil)
        } else {
            errorLabel.isHidden = true
        }
    }

    private func applyHomeLoadingChrome() {
        let showsInitialSkeleton = (viewModel.isLoading || isInitialTopicLoadPending)
            && viewModel.topics.isEmpty
            && viewModel.errorMessage == nil
        if viewModel.isLoading && !showsInitialSkeleton && viewModel.topics.isEmpty {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        if viewModel.isLoadingMore {
            tableView.tableFooterView = footerSpinner
            footerSpinner.startAnimating()
        } else if viewModel.loadMoreErrorMessage != nil {
            footerSpinner.stopAnimating()
            if let label = loadMoreErrorFooter.viewWithTag(901) as? UILabel {
                label.text = viewModel.loadMoreErrorMessage
                    ?? String(localized: "home.load_more_failed", defaultValue: "加载更多失败，点击重试")
            }
            tableView.tableFooterView = loadMoreErrorFooter
        } else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = emptyFooterView
        }
    }
}
