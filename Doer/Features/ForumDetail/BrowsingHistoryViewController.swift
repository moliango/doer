import UIKit

final class BrowsingHistoryViewModel: DoerObservableObject {
    var topics: [DiscourseTopicList.Topic] = []
    var isLoading = false
    var isLoadingMore = false
    var canLoadMore = false
    var errorMessage: String?
    var requiresLogin = false

    private let api: DiscourseAPI
    private var currentPage = 0
    private var usersById: [Int: DiscourseTopicList.User] = [:]
    private var categoryIndex = DiscourseCategoryIndex()

    init(api: DiscourseAPI) {
        self.api = api
    }

    private var canBrowseTopics: Bool {
        AuthManager.shared.isAuthenticated(for: api.baseURL)
    }

    func avatarTemplate(for topic: DiscourseTopicList.Topic) -> String? {
        guard let firstPoster = topic.posters?.first else { return nil }
        return usersById[firstPoster.userId]?.avatarTemplate
    }

    func avatarUserId(for topic: DiscourseTopicList.Topic) -> Int? {
        topic.posters?.first?.userId
    }

    func category(for topic: DiscourseTopicList.Topic) -> DiscourseCategory? {
        guard let categoryId = topic.categoryId else { return nil }
        return categoryIndex[categoryId]
    }

    func categoryDisplayName(for category: DiscourseCategory?) -> String? {
        guard let category else { return nil }
        let resolved = categoryIndex[category.id] ?? category
        return resolved.displayName(parent: parentCategory(for: resolved))
    }

    func loadTopics() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        requiresLogin = false
        currentPage = 0
        notifyChanged()
        defer {
            isLoading = false
            notifyChanged()
        }
        guard await validateTopicAccess() else { return }

        do {
            let result = try await api.fetchReadTopics(page: 0)
            topics = result.topicList.topics
            canLoadMore = result.topicList.moreTopicsUrl != nil
            usersById.removeAll()
            categoryIndex = DiscourseCategoryIndex()
            indexUsers(result.users)
            indexCategories(result.categories)
        } catch {
            handle(error)
        }
    }

    func loadMoreTopics() async {
        guard canLoadMore, !isLoadingMore else { return }
        guard await validateTopicAccess() else { return }

        isLoadingMore = true
        notifyChanged()
        defer {
            isLoadingMore = false
            notifyChanged()
        }

        let nextPage = currentPage + 1
        do {
            let result = try await api.fetchReadTopics(page: nextPage)
            currentPage = nextPage
            let existingIds = Set(topics.map(\.id))
            let newTopics = result.topicList.topics.filter { !existingIds.contains($0.id) }
            topics.append(contentsOf: newTopics)
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
            indexCategories(result.categories)
        } catch {
            handle(error, clearOnAuthFailure: true)
        }
    }

    private func validateTopicAccess() async -> Bool {
        guard canBrowseTopics else {
            clearProtectedContent(invalidateSession: true)
            return false
        }
        do {
            _ = try await api.fetchCurrentUser()
            return true
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                clearProtectedContent(invalidateSession: true)
            } else if topics.isEmpty {
                errorMessage = error.localizedDescription
                notifyChanged()
            }
            return false
        }
    }

    private func handle(_ error: Error, clearOnAuthFailure: Bool = false) {
        if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
            clearProtectedContent(invalidateSession: true)
            return
        }
        if clearOnAuthFailure, topics.isEmpty {
            errorMessage = error.localizedDescription
        } else if !clearOnAuthFailure {
            errorMessage = error.localizedDescription
        }
    }

    private func clearProtectedContent(invalidateSession: Bool = false) {
        topics = []
        isLoading = false
        isLoadingMore = false
        canLoadMore = false
        errorMessage = String(localized: "login.required.message")
        requiresLogin = true
        currentPage = 0
        usersById.removeAll()
        categoryIndex = DiscourseCategoryIndex()
        if invalidateSession {
            AuthManager.shared.invalidateWebSession(for: api.baseURL)
        }
        notifyChanged()
    }

    private func indexUsers(_ users: [DiscourseTopicList.User]?) {
        guard let users else { return }
        for user in users {
            usersById[user.id] = user
        }
    }

    private func indexCategories(_ categories: [DiscourseCategory]?) {
        categoryIndex.merge(categories, source: .topicList)
    }

    private func parentCategory(for category: DiscourseCategory) -> DiscourseCategory? {
        guard let parentId = category.parentCategoryId else { return nil }
        return categoryIndex[parentId]
    }
}

final class BrowsingHistoryViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: BrowsingHistoryViewModel
    private weak var authGate: AuthGating?
    private var topicPreviewLongPressHandler: TopicPreviewLongPressHandler?

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        TopicListCellFactory.registerCells(on: table)
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        table.showsVerticalScrollIndicator = false
        // Short / empty lists still need bounce so UIRefreshControl can fire.
        table.alwaysBounceVertical = true
        return table
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = {
        UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { [weak self] tableView, indexPath, topicId in
            guard let self,
                  let topic = self.viewModel.topics.first(where: { $0.id == topicId })
            else {
                return UITableViewCell()
            }

            let baseURL = self.api.baseURL
            let avatarURL = AvatarImageLoader.url(
                from: self.viewModel.avatarTemplate(for: topic),
                baseURL: baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
            let category = self.viewModel.category(for: topic)
            let categoryColor = category.flatMap { Self.color(fromHex: $0.color) }
            return TopicListCellFactory.makeTopicCell(
                tableView: tableView,
                indexPath: indexPath,
                context: TopicListTopicContext(
                    topic: topic,
                    avatarURL: avatarURL,
                    avatarUserId: self.viewModel.avatarUserId(for: topic),
                    categoryName: self.viewModel.categoryDisplayName(for: category),
                    categoryColor: categoryColor,
                    tags: topic.tags ?? [],
                    categoryBaseURL: baseURL
                )
            )
        }
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private let stateIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .tertiaryLabel
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let loginButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "me.login")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let retryButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.title = String(localized: "action.retry")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var stateStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [stateIconView, stateLabel, loginButton, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    private let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    private let emptyFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return control
    }()

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = BrowsingHistoryViewModel(api: api)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "tab.history")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        observe(AppSettings.shared)
        applyThemeStyle()
        tableView.tableFooterView = emptyFooterView
        tableView.refreshControl = refreshControl

        view.addSubview(tableView)
        topicPreviewLongPressHandler = TopicPreviewMenu.installLongPress(on: tableView) { [weak self] point in
            self?.presentTopicPreview(at: point)
        }
        view.addSubview(activityIndicator)
        view.addSubview(stateStackView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            stateStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateStackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stateStackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            stateIconView.widthAnchor.constraint(equalToConstant: 58),
            stateIconView.heightAnchor.constraint(equalToConstant: 58),
        ])

        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        Task {
            await viewModel.loadTopics()
        }
    }

    override func updateUI() {
        if !viewModel.isLoading, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
        applyThemeStyle()

        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        var seen = Set<Int>()
        let uniqueIds = viewModel.topics.compactMap { topic -> Int? in
            guard seen.insert(topic.id).inserted else { return nil }
            return topic.id
        }
        snapshot.appendItems(uniqueIds, toSection: 0)
        let currentIds = Set(dataSource.snapshot().itemIdentifiers)
        let reconfigurableIds = uniqueIds.filter { currentIds.contains($0) }
        if !reconfigurableIds.isEmpty {
            snapshot.reconfigureItems(reconfigurableIds)
        }
        dataSource.apply(snapshot, animatingDifferences: view.window != nil)
        prefetchAvatars(for: viewModel.topics)

        let hasTopics = !viewModel.topics.isEmpty
        if viewModel.isLoading && !hasTopics {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        // Keep the table visible so empty-state pull-to-refresh still works.
        tableView.isHidden = false
        tableView.alpha = hasTopics ? 1 : 0.01
        stateStackView.isHidden = hasTopics || viewModel.isLoading

        if viewModel.requiresLogin {
            configureState(
                iconName: "lock.circle",
                text: viewModel.errorMessage ?? String(localized: "login.required.message"),
                showLogin: authGate != nil,
                showRetry: authGate == nil
            )
        } else if let errorMessage = viewModel.errorMessage, !hasTopics {
            configureState(
                iconName: "exclamationmark.triangle",
                text: errorMessage,
                showLogin: false,
                showRetry: true
            )
        } else if !hasTopics, !viewModel.isLoading {
            configureState(
                iconName: "clock.arrow.circlepath",
                text: String(localized: "me.discourse_history.empty", defaultValue: "还没有论坛浏览记录"),
                showLogin: false,
                showRetry: false
            )
        }

        if viewModel.isLoadingMore {
            tableView.tableFooterView = footerSpinner
            footerSpinner.startAnimating()
        } else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = emptyFooterView
        }
    }

    private func prefetchAvatars(for topics: [DiscourseTopicList.Topic]) {
        let limit = AppSettings.shared.avatarLoadingProfile.homeAvatarPrefetchLimit
        let urls = topics.prefix(limit).compactMap { topic -> URL? in
            AvatarImageLoader.url(
                from: viewModel.avatarTemplate(for: topic),
                baseURL: api.baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
        }
        AvatarImageLoader.prefetch(urls: urls, cloudflareBaseURL: api.baseURL)
    }

    private func applyThemeStyle() {
        tableView.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight

        let themeStyle = AppSettings.shared.themeStyle
        let pageBackground = themeStyle.topicListBackgroundColor
        view.backgroundColor = pageBackground
        tableView.backgroundColor = pageBackground
        view.tintColor = themeStyle.accentColor
        refreshControl.tintColor = themeStyle.accentColor
        activityIndicator.color = themeStyle.accentColor
        footerSpinner.color = themeStyle.accentColor
        stateIconView.tintColor = themeStyle.accentColor.withAlphaComponent(0.78)
        loginButton.tintColor = themeStyle.accentColor
        retryButton.tintColor = themeStyle.accentColor
    }

    private func configureState(iconName: String, text: String, showLogin: Bool, showRetry: Bool) {
        stateIconView.image = UIImage(
            systemName: iconName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 50, weight: .regular)
        )
        stateLabel.text = text
        loginButton.isHidden = !showLogin
        retryButton.isHidden = !showRetry
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadTopics()
            if refreshControl.isRefreshing {
                refreshControl.endRefreshing()
            }
        }
    }

    @objc private func retryTapped() {
        Task {
            await viewModel.loadTopics()
            if refreshControl.isRefreshing {
                refreshControl.endRefreshing()
            }
        }
    }

    @objc private func loginTapped() {
        authGate?.requireAuth(then: { [weak self] in
            guard let self else { return }
            Task {
                await self.viewModel.loadTopics()
            }
        })
    }

    private static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension BrowsingHistoryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return }
        let detailVC = TopicDetailFactory.make(api: api, topicId: topicId)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    private func presentTopicPreview(at point: CGPoint) {
        guard let indexPath = tableView.indexPathForRow(at: point),
              let topicId = dataSource.itemIdentifier(for: indexPath),
              let topic = viewModel.topics.first(where: { $0.id == topicId })
        else { return }
        let previewTarget = tableView.cellForRow(at: indexPath).map { TopicPreviewMenu.targetView(in: $0) }
        TopicPreviewMenu.present(
            topic: topic,
            api: api,
            categoryName: viewModel.categoryDisplayName(for: viewModel.category(for: topic)),
            actions: [
                TopicPreviewAction(
                    title: String(localized: "topic.preview.open", defaultValue: "打开话题"),
                    image: UIImage(systemName: "arrow.up.right.square")
                ) { [weak self] in
                    guard let self else { return }
                    let detailVC = TopicDetailFactory.make(api: self.api, topicId: topicId)
                    self.navigationController?.pushViewController(detailVC, animated: true)
                },
            ],
            sourceView: previewTarget,
            from: self
        )
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = tableView.numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 5 {
            Task {
                await viewModel.loadMoreTopics()
            }
        }
    }
}
