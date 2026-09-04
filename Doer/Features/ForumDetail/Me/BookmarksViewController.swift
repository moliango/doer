import UIKit

final class BookmarksViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: BookmarksViewModel
    private weak var authGate: AuthGating?

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        TopicListCellFactory.registerCells(on: tv)
        tv.register(BookmarkCell.self, forCellReuseIdentifier: BookmarkCell.reuseIdentifier)
        tv.delegate = self
        tv.dataSource = self
        tv.separatorStyle = .none
        tv.backgroundColor = .clear
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        tv.showsVerticalScrollIndicator = false
        // Empty / login states still need bounce so UIRefreshControl can fire.
        tv.alwaysBounceVertical = true
        return tv
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
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
        button.isHidden = true
        return button
    }()

    private let retryButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.title = String(localized: "action.retry")
        config.cornerStyle = .medium
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
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

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    private lazy var loadingFooter: UIView = {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        footer.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        return footer
    }()

    private lazy var loadMoreErrorFooter: UIView = {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 68))
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "me.topic_list.load_more_failed", defaultValue: "加载更多失败，点击重试")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(String(localized: "action.retry"), for: .normal)
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

    private let emptyFooter = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
    private var loadGeneration = 0
    private var hasLoadedOnce = false
    private var lastFetchAt: Date?

    init(api: DiscourseAPI, username: String, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = BookmarksViewModel(api: api, username: username)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    init(api: DiscourseAPI, authGate: AuthGating?) {
        self.api = api
        self.viewModel = BookmarksViewModel(api: api, username: authGate?.currentUsername())
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        observe(AppSettings.shared)
        title = String(localized: "me.bookmarks")
        applyThemeStyle()

        tableView.refreshControl = refreshControl

        view.addSubview(tableView)
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard BookmarkSessionUsernamePolicy.shouldFetchOnAppear(
            hasLoadedOnce: hasLoadedOnce,
            lastFetch: lastFetchAt
        ) else { return }
        Task {
            await loadBookmarks(force: false)
        }
    }

    override func updateUI() {
        if !viewModel.isLoading, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
        applyThemeStyle()

        let hasBookmarks = !viewModel.bookmarks.isEmpty
        let showSpinner = viewModel.isLoading && !hasBookmarks
        if showSpinner {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        // Keep the table visible so pull-to-refresh still works after login
        // when the first fetch races session/current and comes back empty.
        tableView.isHidden = false
        tableView.alpha = hasBookmarks ? 1 : 0.01
        let animated = view.window != nil
        AnimationOptimizer.setVisible(stateStackView, !hasBookmarks && !viewModel.isLoading, animated: animated)

        if viewModel.requiresLogin {
            configureState(
                iconName: "lock.circle",
                text: viewModel.errorMessage ?? String(localized: "login.required.message"),
                showLogin: authGate != nil,
                showRetry: authGate == nil
            )
        } else if let errorMessage = viewModel.errorMessage, !hasBookmarks {
            configureState(
                iconName: "exclamationmark.triangle",
                text: errorMessage,
                showLogin: false,
                showRetry: true
            )
        } else if !hasBookmarks, !viewModel.isLoading {
            configureState(
                iconName: "bookmark",
                text: String(localized: "me.bookmarks.empty"),
                showLogin: false,
                showRetry: false
            )
        }

        if viewModel.isLoadingMore {
            tableView.tableFooterView = loadingFooter
        } else if viewModel.loadMoreErrorMessage != nil {
            tableView.tableFooterView = loadMoreErrorFooter
        } else {
            tableView.tableFooterView = emptyFooter
        }

        tableView.reloadData()
        prefetchAvatars()
    }

    private func prefetchAvatars() {
        let limit = AppSettings.shared.avatarLoadingProfile.homeAvatarPrefetchLimit
        let urls = viewModel.bookmarks.prefix(limit).compactMap { bookmark -> URL? in
            AvatarImageLoader.url(
                from: bookmark.avatarTemplate,
                baseURL: api.baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
        }
        AvatarImageLoader.prefetch(urls: urls, cloudflareBaseURL: api.baseURL)
    }

    private func applyThemeStyle() {
        let themeStyle = AppSettings.shared.themeStyle
        let pageBackground = themeStyle.topicListBackgroundColor
        view.backgroundColor = pageBackground
        tableView.backgroundColor = pageBackground
        tableView.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        view.tintColor = themeStyle.accentColor
        refreshControl.tintColor = themeStyle.accentColor
        activityIndicator.color = themeStyle.accentColor
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

    private func loadBookmarks(force: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration

        if let authGate, authGate.isAuthenticated() {
            if let username = BookmarkSessionUsernamePolicy.readyUsername(
                current: authGate.currentUsername(),
                stored: viewModel.storedUsername()
            ) {
                viewModel.updateUsername(username)
            } else {
                viewModel.markLoadingIfEmpty()
                let username = await waitForSessionUsername(authGate)
                guard generation == loadGeneration else { return }
                viewModel.updateUsername(username)
            }
        } else if authGate != nil {
            viewModel.updateUsername(nil)
        }

        guard generation == loadGeneration else { return }
        await viewModel.loadBookmarks(showLoading: force || viewModel.bookmarks.isEmpty)
        guard generation == loadGeneration else { return }
        hasLoadedOnce = true
        lastFetchAt = Date()
    }

    /// Cookie login returns as soon as `_t` exists; username lands later via
    /// `/session/current`. Only refresh when we do not already know the user.
    private func waitForSessionUsername(_ authGate: AuthGating) async -> String? {
        if let ready = BookmarkSessionUsernamePolicy.readyUsername(
            current: authGate.currentUsername(),
            stored: viewModel.storedUsername()
        ) {
            return ready
        }
        let didRefresh = await authGate.refreshSessionUser()
        if let ready = BookmarkSessionUsernamePolicy.readyUsername(
            current: authGate.currentUsername(),
            stored: viewModel.storedUsername()
        ) {
            return ready
        }
        if !didRefresh, !authGate.isAuthenticated() {
            return nil
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await authGate.refreshSessionUser()
        return BookmarkSessionUsernamePolicy.readyUsername(
            current: authGate.currentUsername(),
            stored: viewModel.storedUsername()
        )
    }

    @objc private func pullToRefresh() {
        Task {
            await loadBookmarks(force: true)
        }
    }

    @objc private func retryTapped() {
        Task {
            await loadBookmarks(force: true)
        }
    }

    @objc private func loadMoreRetryTapped() {
        Task {
            await viewModel.loadMore()
        }
    }

    @objc private func loginTapped() {
        authGate?.requireAuth(then: { [weak self] in
            guard let self else { return }
            Task {
                await self.loadBookmarks(force: true)
            }
        })
    }
}

// MARK: - UITableViewDataSource

extension BookmarksViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        viewModel.bookmarks.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let bookmark = viewModel.bookmarks[indexPath.row]
        let layout = TopicListLayoutKind.current
        if layout.usesChatSessionRows {
            let excerpt = bookmark.excerpt
                .map { CookedContentPipeline.plainTextPreview(fromCooked: $0) }
                .flatMap { text -> String? in
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
            let time: String? = {
                guard let createdAt = bookmark.createdAt else { return nil }
                return BookmarkCell.formatDatePublic(createdAt)
            }()
            let item = TopicListSessionItem(
                title: bookmark.title ?? bookmark.name ?? "#\(bookmark.id)",
                subtitle: excerpt ?? bookmark.name,
                timeText: time,
                avatarTemplate: bookmark.avatarTemplate,
                isEmphasized: false,
                badgeText: nil,
                baseURL: api.baseURL
            )
            return TopicListCellFactory.makeSessionCell(
                tableView: tableView,
                indexPath: indexPath,
                item: item,
                layout: layout
            )
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: BookmarkCell.reuseIdentifier,
            for: indexPath
        ) as? BookmarkCell else {
            return UITableViewCell()
        }
        cell.configure(with: bookmark, baseURL: api.baseURL)
        return cell
    }
}

// MARK: - UITableViewDelegate

extension BookmarksViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let bookmark = viewModel.bookmarks[indexPath.row]
        if let topicId = bookmark.topicId {
            let detailVC = TopicDetailFactory.make(api: api, topicId: topicId)
            navigationController?.pushViewController(detailVC, animated: true)
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row >= viewModel.bookmarks.count - 5 else { return }
        Task { await viewModel.loadMore() }
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let bookmark = viewModel.bookmarks[indexPath.row]
        guard let topicId = bookmark.topicId else { return nil }
        let titleText = bookmark.title ?? bookmark.name ?? "#\(topicId)"
        let remind = UIContextualAction(
            style: .normal,
            title: String(localized: "reminder.action", defaultValue: "提醒")
        ) { [weak self] _, _, completion in
            self?.presentBookmarkReminder(topicId: topicId, title: titleText)
            completion(true)
        }
        remind.image = UIImage(systemName: "alarm")
        remind.backgroundColor = .systemPurple

        let toMini = UIContextualAction(
            style: .normal,
            title: String(localized: "mini_program.convert_from_bookmark", defaultValue: "转小程序")
        ) { [weak self] _, _, completion in
            self?.convertBookmarkToMiniProgram(bookmark)
            completion(true)
        }
        toMini.image = UIImage(systemName: "app.badge.fill")
        toMini.backgroundColor = .systemGreen

        return UISwipeActionsConfiguration(actions: [toMini, remind])
    }

    private func convertBookmarkToMiniProgram(_ bookmark: DiscourseBookmark) {
        guard let topicId = bookmark.topicId else { return }
        let base = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/t/\(topicId)") else { return }
        let name = bookmark.title ?? bookmark.name ?? "Topic \(topicId)"
        do {
            let store = MiniProgramStore.shared
            let programID = try store.addCustomProgram(
                name: name,
                url: url,
                categoryID: MiniProgramCategoryID.other,
                icon: .none
            )
            store.addFavorite(programID)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DoerFeedback.presentToast(
                String(localized: "mini_program.added", defaultValue: "已添加到小程序"),
                on: self
            )
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }

    private func presentBookmarkReminder(topicId: Int, title: String) {
        let sheet = UIAlertController(
            title: String(localized: "reminder.pick", defaultValue: "设置提醒"),
            message: title,
            preferredStyle: .actionSheet
        )
        for preset in LocalReminderScheduler.presetDates() {
            sheet.addAction(UIAlertAction(title: preset.title, style: .default) { [weak self] _ in
                guard let self else { return }
                Task {
                    let ok = await LocalReminderScheduler.schedule(
                        .init(
                            kind: .bookmark,
                            topicId: topicId,
                            baseURL: self.api.baseURL,
                            title: title,
                            fireAt: preset.date
                        )
                    )
                    await MainActor.run {
                        let msg = ok
                            ? String(localized: "reminder.scheduled", defaultValue: "已设置本地提醒")
                            : String(localized: "reminder.denied", defaultValue: "未获得通知权限")
                        let alert = UIAlertController(title: msg, message: nil, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
                        self.present(alert, animated: true)
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(
            title: String(localized: "reminder.cancel_existing", defaultValue: "取消已有提醒"),
            style: .destructive
        ) { [weak self] _ in
            guard let self else { return }
            LocalReminderScheduler.cancel(kind: .bookmark, topicId: topicId, baseURL: self.api.baseURL)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = view.bounds
        }
        present(sheet, animated: true)
    }
}
