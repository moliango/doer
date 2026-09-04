import UIKit

/// Read-later queue rendered like Home topic items, with CF refresh + retry.
final class ReadLaterViewController: ObservableViewController {
    private let api: DiscourseAPI
    private var entries: [TopicReadLaterStore.Entry] = []
    private var topicsById: [Int: DiscourseTopicList.Topic] = [:]
    private var usersById: [Int: DiscourseTopicList.User] = [:]
    private var categoriesById: [Int: DiscourseCategory] = [:]
    private var isLoading = false
    private var errorMessage: String?
    private var observer: NSObjectProtocol?
    private var cloudflareObserver: NSObjectProtocol?
    private var topicPreviewLongPressHandler: TopicPreviewLongPressHandler?

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        TopicListCellFactory.registerCells(on: table)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        table.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        table.refreshControl = refreshControl
        return table
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return control
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
        let stack = UIStackView(arrangedSubviews: [stateIconView, stateLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        return stack
    }()

    init(api: DiscourseAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let cloudflareObserver { NotificationCenter.default.removeObserver(cloudflareObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(AppSettings.shared)
        title = String(localized: "me.read_later", defaultValue: "稍后阅读")
        applyTheme()

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
            stateIconView.widthAnchor.constraint(equalToConstant: 48),
            stateIconView.heightAnchor.constraint(equalToConstant: 48),
        ])

        retryButton.addTarget(self, action: #selector(pullToRefresh), for: .touchUpInside)

        observer = NotificationCenter.default.addObserver(
            forName: .topicReadLaterDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.reload(forceNetwork: false) }
        }
        cloudflareObserver = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareVerificationCompletedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let base = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String {
                let normalized = base.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                let mine = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                guard normalized == mine else { return }
            }
            // After CF pass: resume hydration without blocking the whole page on image gate.
            Task { await self.reload(forceNetwork: true) }
        }

        Task { await reload(forceNetwork: true) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await reload(forceNetwork: topicsById.isEmpty) }
    }

    override func updateUI() {
        applyTheme()
        tableView.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        tableView.reloadData()
        updateStateChrome()
    }

    @objc private func pullToRefresh() {
        Task { await reload(forceNetwork: true) }
    }

    private func applyTheme() {
        let theme = AppSettings.shared.themeStyle
        view.backgroundColor = theme.topicListBackgroundColor
        tableView.backgroundColor = theme.topicListBackgroundColor
        tableView.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        view.tintColor = theme.accentColor
    }

    private func reload(forceNetwork: Bool) async {
        let username = AuthManager.shared.username(for: api.baseURL)
        entries = TopicReadLaterStore.shared.entries(baseURL: api.baseURL, username: username)

        guard !entries.isEmpty else {
            topicsById = [:]
            errorMessage = nil
            isLoading = false
            refreshControl.endRefreshing()
            updateStateChrome()
            tableView.reloadData()
            return
        }

        // Always show local entries immediately — never blank the page waiting on network/CF.
        tableView.reloadData()
        updateStateChrome()

        guard forceNetwork || topicsById.isEmpty else {
            refreshControl.endRefreshing()
            return
        }

        isLoading = topicsById.isEmpty
        errorMessage = nil
        updateStateChrome()

        let ids = entries.map(\.topicId)
        var loaded: [Int: DiscourseTopicList.Topic] = [:]
        var users: [Int: DiscourseTopicList.User] = [:]
        var categories: [Int: DiscourseCategory] = [:]
        var lastError: String?

        // Batch like Home incoming topics — image gate must not block row chrome.
        for start in stride(from: 0, to: ids.count, by: 50) {
            let end = min(start + 50, ids.count)
            let batch = Array(ids[start..<end])
            do {
                let result = try await api.fetchTopicsByIds(batch)
                for topic in result.topicList.topics {
                    let merged = TopicReadProgressStore.shared.applyLocalProgress(
                        to: topic,
                        baseURL: api.baseURL,
                        username: username
                    )
                    loaded[topic.id] = merged
                }
                for user in result.users ?? [] {
                    users[user.id] = user
                }
                for category in result.categories ?? [] {
                    categories[category.id] = category
                }
            } catch {
                lastError = error.localizedDescription
                // Keep going for other batches; partial hydrate is better than total fail.
            }
        }

        topicsById.merge(loaded) { _, new in new }
        usersById.merge(users) { _, new in new }
        categoriesById.merge(categories) { _, new in new }
        // Drop stale topic payloads for removed entries.
        let liveIds = Set(ids)
        topicsById = topicsById.filter { liveIds.contains($0.key) }

        errorMessage = loaded.isEmpty ? lastError : nil
        isLoading = false
        refreshControl.endRefreshing()
        tableView.reloadData()
        updateStateChrome()
    }

    private func updateStateChrome() {
        let empty = entries.isEmpty
        let showError = errorMessage != nil && topicsById.isEmpty && !empty
        let showLoading = isLoading && topicsById.isEmpty && !empty

        if empty {
            stateStackView.isHidden = false
            tableView.isHidden = true
            activityIndicator.stopAnimating()
            stateIconView.image = UIImage(systemName: "square.stack.3d.up")
            stateLabel.text = String(
                localized: "me.read_later.empty",
                defaultValue: "还没有稍后阅读\n在话题菜单或列表右滑可加入"
            )
            retryButton.isHidden = true
            return
        }

        tableView.isHidden = false
        if showLoading {
            activityIndicator.startAnimating()
            stateStackView.isHidden = true
        } else if showError {
            activityIndicator.stopAnimating()
            stateStackView.isHidden = false
            // Don't hide the table — local titles still show under a compact error banner state.
            // Use overlay only when we have zero hydrated topics.
            stateIconView.image = UIImage(systemName: "exclamationmark.triangle")
            stateLabel.text = errorMessage
            retryButton.isHidden = false
            if topicsById.isEmpty {
                tableView.isHidden = true
            } else {
                stateStackView.isHidden = true
            }
        } else {
            activityIndicator.stopAnimating()
            stateStackView.isHidden = true
        }
    }

    private func avatarURL(for topic: DiscourseTopicList.Topic) -> URL? {
        guard let firstPoster = topic.posters?.first,
              let user = usersById[firstPoster.userId]
        else { return nil }
        return AvatarImageLoader.url(
            from: user.avatarTemplate,
            baseURL: api.baseURL,
            size: AvatarImageLoader.primaryAvatarPixelSize
        )
    }

    private func avatarUserId(for topic: DiscourseTopicList.Topic) -> Int? {
        topic.posters?.first?.userId
    }

    private static func color(fromHex hex: String?) -> UIColor? {
        guard let hex else { return nil }
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

extension ReadLaterViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let topic: DiscourseTopicList.Topic
        let categoryName: String?
        let categoryColor: UIColor?
        let avatar: URL?
        let avatarUser: Int?

        if let hydrated = topicsById[entry.topicId] {
            topic = hydrated
            let category = hydrated.categoryId.flatMap { categoriesById[$0] }
            categoryName = category?.name
            categoryColor = Self.color(fromHex: category?.color)
            avatar = avatarURL(for: hydrated)
            avatarUser = avatarUserId(for: hydrated)
        } else {
            // Local-only fallback until network hydrate finishes (or after CF).
            topic = DiscourseTopicList.Topic.readLaterPlaceholder(
                id: entry.topicId,
                title: entry.title,
                lastReadPostNumber: entry.lastReadPostNumber
            )
            categoryName = nil
            categoryColor = nil
            avatar = nil
            avatarUser = nil
        }

        return TopicListCellFactory.makeTopicCell(
            tableView: tableView,
            indexPath: indexPath,
            context: TopicListTopicContext(
                topic: topic,
                avatarURL: avatar,
                avatarUserId: avatarUser,
                categoryName: categoryName,
                categoryColor: categoryColor,
                tags: topic.tags ?? [],
                categoryBaseURL: api.baseURL
            )
        )
    }

    private func presentTopicPreview(at point: CGPoint) {
        guard let indexPath = tableView.indexPathForRow(at: point),
              entries.indices.contains(indexPath.row)
        else { return }

        let entry = entries[indexPath.row]
        let topic = topicsById[entry.topicId] ?? DiscourseTopicList.Topic.readLaterPlaceholder(
            id: entry.topicId,
            title: entry.title,
            lastReadPostNumber: entry.lastReadPostNumber
        )
        let previewTarget = tableView.cellForRow(at: indexPath).map { TopicPreviewMenu.targetView(in: $0) }
        TopicPreviewMenu.present(
            topic: topic,
            api: api,
            categoryName: topic.categoryId.flatMap { categoriesById[$0]?.name },
            actions: [
                TopicPreviewAction(
                    title: String(localized: "topic.preview.open", defaultValue: "打开话题"),
                    image: UIImage(systemName: "arrow.up.right.square")
                ) { [weak self] in
                    self?.openReadLaterEntry(at: indexPath)
                },
            ],
            sourceView: previewTarget,
            from: self
        )
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openReadLaterEntry(at: indexPath)
    }

    private func openReadLaterEntry(at indexPath: IndexPath) {
        guard entries.indices.contains(indexPath.row) else { return }
        let entry = entries[indexPath.row]
        let username = AuthManager.shared.username(for: api.baseURL)
        let topic = topicsById[entry.topicId]
        let merged = TopicReadProgressStore.shared.mergedLastRead(
            serverLastRead: topic?.lastReadPostNumber ?? entry.lastReadPostNumber,
            topicId: entry.topicId,
            baseURL: api.baseURL,
            username: username
        )
        let resume: Int? = {
            guard merged > 1 else { return nil }
            let highest = topic?.highestPostNumber ?? topic?.postsCount ?? 0
            if highest > 0, merged >= highest { return nil }
            return merged + 1
        }()
        let detail = TopicDetailFactory.make(
            api: api,
            topicId: entry.topicId,
            initialFloor: resume,
            lastReadPostNumber: merged > 0 ? merged : nil
        )
        navigationController?.pushViewController(detail, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let entry = entries[indexPath.row]
        // Leading action order: first = full-swipe (左滑删除).
        let remove = UIContextualAction(
            style: .destructive,
            title: String(localized: "me.read_later.remove", defaultValue: "移除")
        ) { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            TopicReadLaterStore.shared.remove(
                topicId: entry.topicId,
                baseURL: entry.baseURL,
                username: entry.username
            )
            LocalReminderScheduler.cancel(kind: .readLater, topicId: entry.topicId, baseURL: entry.baseURL)
            self.entries = TopicReadLaterStore.shared.entries(
                baseURL: self.api.baseURL,
                username: AuthManager.shared.username(for: self.api.baseURL)
            )
            tableView.deleteRows(at: [indexPath], with: .automatic)
            self.updateStateChrome()
            completion(true)
        }
        remove.image = UIImage(systemName: "trash.fill")
        remove.backgroundColor = .systemRed

        let remind = UIContextualAction(
            style: .normal,
            title: String(localized: "reminder.action", defaultValue: "提醒")
        ) { [weak self] _, _, completion in
            self?.presentReminderPicker(for: entry)
            completion(true)
        }
        remind.image = UIImage(systemName: "alarm")
        remind.backgroundColor = AppSettings.shared.themeStyle.accentColor
        let config = UISwipeActionsConfiguration(actions: [remove, remind])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        // Mirror trailing so both directions can remove (one-handed).
        self.tableView(tableView, trailingSwipeActionsConfigurationForRowAt: indexPath)
    }

    private func presentReminderPicker(for entry: TopicReadLaterStore.Entry) {
        let sheet = UIAlertController(
            title: String(localized: "reminder.pick", defaultValue: "设置提醒"),
            message: entry.title,
            preferredStyle: .actionSheet
        )
        for preset in LocalReminderScheduler.presetDates() {
            sheet.addAction(UIAlertAction(title: preset.title, style: .default) { [weak self] _ in
                guard let self else { return }
                Task {
                    let ok = await LocalReminderScheduler.schedule(
                        .init(
                            kind: .readLater,
                            topicId: entry.topicId,
                            baseURL: entry.baseURL,
                            title: entry.title,
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
        ) { _ in
            LocalReminderScheduler.cancel(kind: .readLater, topicId: entry.topicId, baseURL: entry.baseURL)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.bounds
        }
        present(sheet, animated: true)
    }
}

private extension DiscourseTopicList.Topic {
    /// Minimal topic shell so TopicCell can render before network hydrate.
    static func readLaterPlaceholder(id: Int, title: String, lastReadPostNumber: Int?) -> DiscourseTopicList.Topic {
        // Use decoder via a tiny JSON payload to avoid exposing private memberwise init.
        let payload: [String: Any] = [
            "id": id,
            "fancy_title": title,
            "title": title,
            "posts_count": 1,
            "reply_count": 0,
            "views": 0,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "unseen": false,
            "unread_posts": 0,
            "last_read_post_number": lastReadPostNumber as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let topic = try? JSONDecoder().decode(DiscourseTopicList.Topic.self, from: data)
        else {
            // Last resort — should not hit if CodingKeys stay stable.
            return (try! JSONDecoder().decode(
                DiscourseTopicList.Topic.self,
                from: Data(#"{"id":\#(id),"fancy_title":"\#(title.replacingOccurrences(of: "\"", with: ""))","title":"\#(title.replacingOccurrences(of: "\"", with: ""))","posts_count":1,"reply_count":0,"views":0,"created_at":"2020-01-01T00:00:00Z"}"#.utf8)
            ))
        }
        return topic
    }
}
