import SDWebImage
import UIKit

final class NotificationsViewController: ObservableViewController {
    /// topicId + optional post_number + optional post id for deep link into the right reply.
    var onTopicSelected: ((Int, Int?, Int?) -> Void)?

    private let api: DiscourseAPI
    private let viewModel: NotificationsViewModel
    private weak var authGate: AuthGating?
    private var selectedFilter: NotificationListFilter = .all
    private var filterButtons: [NotificationListFilter: UIButton] = [:]



    private let filterContainerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()

    private let filterScrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        scroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        scroll.contentInsetAdjustmentBehavior = .never
        return scroll
    }()

    private let filterStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 8
        return stack
    }()

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        TopicListCellFactory.registerCells(on: table)
        table.register(NotificationCell.self, forCellReuseIdentifier: NotificationCell.reuseIdentifier)
        table.dataSource = self
        table.delegate = self
        table.separatorStyle = .none
        table.backgroundColor = .clear
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        // Short / empty lists still need bounce so UIRefreshControl can fire.
        table.alwaysBounceVertical = true
        table.refreshControl = refreshControl
        return table
    }()

    private let refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        return control
    }()

    private let skeletonView = NotificationListSkeletonView()

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
        config.title = String(localized: "notifications.login_prompt")
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
        return stack
    }()

    init(
        api: DiscourseAPI,
        authGate: AuthGating? = nil,
        notificationCoordinator: ForumNotificationCoordinator
    ) {
        self.api = api
        self.viewModel = NotificationsViewModel(coordinator: notificationCoordinator)
        self.authGate = authGate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var filteredNotifications: [DiscourseNotification] {
        viewModel.notifications.filter { selectedFilter.matches($0) }
    }

    override func viewDidLoad() {

        super.viewDidLoad()
        observe(viewModel)
        observe(AppSettings.shared)
        title = String(localized: "notifications.title")
        applyThemeStyle()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.circle"),
            style: .plain,
            target: self,
            action: #selector(markAllReadTapped)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "notifications.mark_all_read")

        buildFilterChips()
        filterContainerView.addSubview(filterScrollView)
        filterScrollView.addSubview(filterStackView)
        view.addSubview(filterContainerView)
        view.addSubview(tableView)
        view.addSubview(skeletonView)
        view.addSubview(stateStackView)
        NSLayoutConstraint.activate([
            filterContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            filterContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterContainerView.heightAnchor.constraint(equalToConstant: 52),

            filterScrollView.topAnchor.constraint(equalTo: filterContainerView.topAnchor),
            filterScrollView.leadingAnchor.constraint(equalTo: filterContainerView.leadingAnchor),
            filterScrollView.trailingAnchor.constraint(equalTo: filterContainerView.trailingAnchor),
            filterScrollView.bottomAnchor.constraint(equalTo: filterContainerView.bottomAnchor),

            filterStackView.topAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.topAnchor, constant: 8),
            filterStackView.bottomAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.bottomAnchor, constant: -8),
            filterStackView.leadingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.leadingAnchor),
            filterStackView.trailingAnchor.constraint(equalTo: filterScrollView.contentLayoutGuide.trailingAnchor),
            filterStackView.heightAnchor.constraint(equalToConstant: 36),

            tableView.topAnchor.constraint(equalTo: filterContainerView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            skeletonView.topAnchor.constraint(equalTo: filterContainerView.bottomAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            skeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stateStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateStackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stateStackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            stateIconView.widthAnchor.constraint(equalToConstant: 52),
            stateIconView.heightAnchor.constraint(equalToConstant: 52),
        ])

        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureCloseButtonIfNeeded()
        // Tab root can appear before first layout; rebuild chips so categories never go blank.
        if filterButtons.isEmpty || filterStackView.arrangedSubviews.isEmpty {
            buildFilterChips()
        } else {
            refreshFilterChipStyles()
        }
        filterContainerView.isHidden = viewModel.requiresLogin
        view.bringSubviewToFront(filterContainerView)
        Task {
            async let catalog = BadgeCatalogStore.ensureLoaded(using: self.api)
            await viewModel.loadNotifications()
            _ = await catalog
            self.refreshFilterChipStyles()
            if !self.viewModel.notifications.isEmpty {
                self.tableView.reloadData()
            }
        }
    }

    override func updateUI() {
        // Only end the spinner when a load is not in flight. Intermediate
        // coordinator notifyChanged() calls must not cancel an active pull.
        if !viewModel.isLoading, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
        applyThemeStyle()

        let sourceEmpty = viewModel.notifications.isEmpty
        let filtered = filteredNotifications
        let hasFiltered = !filtered.isEmpty
        let showSkeleton = viewModel.isLoading && sourceEmpty
        skeletonView.isHidden = !showSkeleton
        filterContainerView.isHidden = viewModel.requiresLogin
        filterScrollView.isHidden = false
        // Keep the table visible (except over skeleton) so pull-to-refresh still
        // works on empty / filter-empty states.
        tableView.isHidden = showSkeleton
        tableView.alpha = hasFiltered ? 1 : 0.01
        stateStackView.isHidden = hasFiltered || showSkeleton
        // Keep mark-all enabled if any unread exists (global), not just current filter.
        navigationItem.rightBarButtonItem?.isEnabled = viewModel.notifications.contains { !$0.read }
            || viewModel.unreadCount > 0
        refreshFilterChipStyles()

        if viewModel.requiresLogin {
            configureState(
                iconName: "lock.circle",
                text: viewModel.errorMessage ?? String(localized: "notifications.login_prompt"),
                showLogin: true,
                showRetry: false
            )
        } else if let errorMessage = viewModel.errorMessage, sourceEmpty {
            configureState(
                iconName: "exclamationmark.triangle",
                text: errorMessage,
                showLogin: false,
                showRetry: true
            )
        } else if sourceEmpty, !viewModel.isLoading {
            configureState(
                iconName: "bell",
                text: String(localized: "notifications.empty"),
                showLogin: false,
                showRetry: false
            )
        } else if !hasFiltered, !viewModel.isLoading {
            configureState(
                iconName: "line.3.horizontal.decrease.circle",
                text: String(localized: "notifications.filter.empty", defaultValue: "当前筛选下没有通知"),
                showLogin: false,
                showRetry: false
            )
        }

        tableView.reloadData()
    }

    private func applyThemeStyle() {
        let themeStyle = AppSettings.shared.themeStyle
        let pageBackground = themeStyle.topicListBackgroundColor
        view.backgroundColor = pageBackground
        filterContainerView.backgroundColor = pageBackground
        tableView.backgroundColor = pageBackground
        tableView.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        view.tintColor = themeStyle.accentColor
        refreshControl.tintColor = themeStyle.accentColor
        skeletonView.applyThemeStyle()
        stateIconView.tintColor = themeStyle.accentColor.withAlphaComponent(0.78)
        loginButton.tintColor = themeStyle.accentColor
        retryButton.tintColor = themeStyle.accentColor
    }

    private func configureCloseButtonIfNeeded() {
        guard navigationController?.presentingViewController != nil else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }
        )
    }

    private func configureState(iconName: String, text: String, showLogin: Bool, showRetry: Bool) {
        stateIconView.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 46, weight: .regular))
        stateLabel.text = text
        loginButton.isHidden = !showLogin
        retryButton.isHidden = !showRetry
    }

    @objc private func refreshPulled() {
        Task {
            await viewModel.loadNotifications()
            if refreshControl.isRefreshing {
                refreshControl.endRefreshing()
            }
        }
    }

    @objc private func retryTapped() {
        Task {
            await viewModel.loadNotifications()
            if refreshControl.isRefreshing {
                refreshControl.endRefreshing()
            }
        }
    }

    @objc private func loginTapped() {
        authGate?.requireAuth(then: { [weak self] in
            guard let self else { return }
            Task {
                await self.viewModel.loadNotifications()
            }
        })
    }


    private func buildFilterChips() {
        filterStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        filterButtons.removeAll()
        for filter in NotificationListFilter.allCases {
            var config = UIButton.Configuration.plain()
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            config.title = filter.title
            config.baseForegroundColor = .secondaryLabel
            config.background.backgroundColor = UIColor.secondarySystemFill
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
                return outgoing
            }
            let button = UIButton(configuration: config)
            button.tag = filter.rawValue
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.addTarget(self, action: #selector(filterChipTapped(_:)), for: .touchUpInside)
            filterButtons[filter] = button
            filterStackView.addArrangedSubview(button)
        }
        refreshFilterChipStyles()
    }

    private func refreshFilterChipStyles() {
        let accent = AppSettings.shared.themeStyle.accentColor
        for filter in NotificationListFilter.allCases {
            guard let button = filterButtons[filter] else { continue }
            let selected = filter == selectedFilter
            var config = button.configuration ?? .plain()
            // Count badge in title for non-all filters.
            let count: Int = {
                switch filter {
                case .all:
                    return viewModel.notifications.count
                default:
                    return viewModel.notifications.filter { filter.matches($0) }.count
                }
            }()
            if filter == .all {
                config.title = filter.title
            } else {
                config.title = count > 0 ? "\(filter.title) \(count)" : filter.title
            }
            config.baseForegroundColor = selected ? .white : .secondaryLabel
            config.background.backgroundColor = selected
                ? accent
                : UIColor.secondarySystemFill
            button.configuration = config
        }
    }

    @objc private func filterChipTapped(_ sender: UIButton) {
        guard let filter = NotificationListFilter(rawValue: sender.tag) else { return }
        guard filter != selectedFilter else { return }
        selectedFilter = filter
        refreshFilterChipStyles()
        tableView.reloadData()
        // Re-evaluate empty/filter state without full network reload.
        updateUI()
    }

    @objc private func markAllReadTapped() {
        Task {
            await viewModel.markAllRead()
        }
    }

    private func openNotification(_ notification: DiscourseNotification) {
        if !notification.read {
            Task {
                await viewModel.markNotificationRead(id: notification.id)
            }
        }

        if notification.isChatNotification {
            openChatNotification(notification)
            return
        }

        guard let topicId = notification.topicId else { return }
        let postNumber = notification.postNumber
        let postId = notification.actingPostId
        if let onTopicSelected {
            dismiss(animated: true) {
                onTopicSelected(topicId, postNumber, postId)
            }
        } else {
            // Do not force nested/tree mode from notifications: empty nestedRows before
            // /n/topic returns paints a blank body (title header only). Flat stream +
            // deep-link floor/postId is the reliable path; user can still enable tree
            // via settings / more menu (TopicDetailFactory respects nestedReplyViewEnabled).
            let detailVC = TopicDetailFactory.make(
                api: api,
                topicId: topicId,
                initialFloor: postNumber,
                initialPostId: postId
            )
            navigationController?.pushViewController(detailVC, animated: true)
        }
    }

    private func openChatNotification(_ notification: DiscourseNotification) {
        let channelId = notification.data.chatChannelId
        let channelTitle = notification.data.chatChannelTitle
        let open = { [weak self] in
            guard let self else { return }
            if let tabBar = self.forumTabBarController() {
                tabBar.openChat(channelId: channelId, channelTitle: channelTitle)
                return
            }
            if let channelId {
                self.navigationController?.pushViewController(
                    ChatRoomViewController(
                        api: self.api,
                        channel: DiscourseChatChannel(id: channelId, title: channelTitle)
                    ),
                    animated: true
                )
            } else {
                self.navigationController?.pushViewController(
                    ChatChannelsViewController(api: self.api),
                    animated: true
                )
            }
        }
        if presentingViewController != nil {
            dismiss(animated: true, completion: open)
        } else {
            open()
        }
    }

    private func forumTabBarController() -> ForumTabBarController? {
        if let tabBar = tabBarController as? ForumTabBarController {
            return tabBar
        }
        var presenter = presentingViewController
        while let current = presenter {
            if let tabBar = current as? ForumTabBarController {
                return tabBar
            }
            if let tabBar = current.tabBarController as? ForumTabBarController {
                return tabBar
            }
            presenter = current.presentingViewController
        }
        return nil
    }
}

extension NotificationsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredNotifications.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let notification = filteredNotifications[indexPath.row]
        // Always use the dedicated FluxDo-style notification cell (avatar + type badge
        // + title/action subtitle). Chat-session rows strip the type badge chrome.
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: NotificationCell.reuseIdentifier,
            for: indexPath
        ) as? NotificationCell else {
            return UITableViewCell()
        }
        cell.configure(with: notification, baseURL: api.baseURL)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        openNotification(filteredNotifications[indexPath.row])
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let notification = filteredNotifications[indexPath.row]
        guard !notification.read else { return nil }

        let markRead = UIContextualAction(
            style: .normal,
            title: String(localized: "notifications.mark_read", defaultValue: "标为已读")
        ) { [weak self] _, _, completion in
            guard let self else {
                completion(false)
                return
            }
            Task {
                await self.viewModel.markNotificationRead(id: notification.id)
                completion(true)
            }
        }
        markRead.image = UIImage(systemName: "checkmark.circle.fill")
        markRead.backgroundColor = AppSettings.shared.themeStyle.accentColor
        let config = UISwipeActionsConfiguration(actions: [markRead])
        config.performsFirstActionWithFullSwipe = true
        return config
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        // Mirror trailing: left-swipe also marks read for one-handed use.
        self.tableView(tableView, trailingSwipeActionsConfigurationForRowAt: indexPath)
    }
}

private final class NotificationCell: UITableViewCell {
    static let reuseIdentifier = "NotificationCell"

    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = AppSettings.shared.themeStyle.topicCardBackgroundColor
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 20
        imageView.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        imageView.tintColor = .secondaryLabel
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let badgeContainer: UIView = {
        let view = UIView()
        view.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        view.layer.cornerRadius = 11
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.12
        view.layer.shadowRadius = 2
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let badgeIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let descriptionLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .tertiaryLabel
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let unreadDotView: UIView = {
        let view = UIView()
        view.backgroundColor = AppSettings.shared.themeStyle.accentColor
        view.layer.cornerRadius = 4
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(cardView)
        cardView.addSubview(avatarImageView)
        cardView.addSubview(badgeContainer)
        badgeContainer.addSubview(badgeIconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(descriptionLabel)
        cardView.addSubview(timeLabel)
        cardView.addSubview(unreadDotView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            avatarImageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            avatarImageView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            avatarImageView.widthAnchor.constraint(equalToConstant: 40),
            avatarImageView.heightAnchor.constraint(equalToConstant: 40),

            badgeContainer.topAnchor.constraint(equalTo: avatarImageView.topAnchor, constant: -3),
            badgeContainer.trailingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 3),
            badgeContainer.widthAnchor.constraint(equalToConstant: 22),
            badgeContainer.heightAnchor.constraint(equalToConstant: 22),

            badgeIconView.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            badgeIconView.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            badgeIconView.widthAnchor.constraint(equalToConstant: 14),
            badgeIconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: unreadDotView.leadingAnchor, constant: -10),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -8),
            descriptionLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),

            timeLabel.centerYAnchor.constraint(equalTo: descriptionLabel.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            unreadDotView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            unreadDotView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            unreadDotView.widthAnchor.constraint(equalToConstant: 8),
            unreadDotView.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        badgeIconView.sd_cancelCurrentImageLoad()
        badgeIconView.image = nil
        badgeIconView.tintColor = .secondaryLabel
        titleLabel.text = nil
        descriptionLabel.text = nil
        timeLabel.text = nil
    }

    func configure(with notification: DiscourseNotification, baseURL: String) {
        let themeStyle = AppSettings.shared.themeStyle
        let color = Self.color(for: notification.notificationType, themeStyle: themeStyle)
        cardView.backgroundColor = themeStyle.topicCardBackgroundColor
        avatarImageView.backgroundColor = themeStyle.topicChipBackgroundColor
        unreadDotView.backgroundColor = themeStyle.accentColor
        badgeIconView.sd_cancelCurrentImageLoad()
        // FluxDo-style type badge: always a concrete template image (boost → BoostRocket).
        badgeIconView.image = notification.badgeImage(pointSize: 13)
        badgeIconView.tintColor = notification.read ? .secondaryLabel : color
        // FluxDo: unread badge sits on surface with type color; read uses muted chip.
        badgeContainer.backgroundColor = notification.read
            ? themeStyle.topicChipBackgroundColor
            : color.withAlphaComponent(0.16)
        badgeContainer.layer.shadowColor = UIColor.black.cgColor
        badgeContainer.layer.shadowOpacity = 0.10

        titleLabel.text = notification.displayTitle
        titleLabel.textColor = .label
        titleLabel.font = .systemFont(ofSize: 15, weight: notification.read ? .regular : .semibold)
        titleLabel.numberOfLines = 2
        descriptionLabel.text = notification.displayDescription
        descriptionLabel.textColor = .secondaryLabel
        timeLabel.text = Self.formatDate(notification.createdAt)
        unreadDotView.isHidden = notification.read

        AvatarImageLoader.setImage(
            on: avatarImageView,
            url: Self.avatarURL(for: notification, baseURL: baseURL),
            placeholder: UIImage(systemName: "person.crop.circle.fill")
        )

        // Badge granted: catalog supplies type color + optional image; payload has name.
        if notification.notificationType == 12 {
            applyBadgeChrome(
                badgeId: notification.data.badgeId,
                badgeName: notification.data.badgeName,
                isRead: notification.read,
                baseURL: baseURL,
                themeStyle: themeStyle
            )
        }
    }

    private func applyBadgeChrome(
        badgeId: Int?,
        badgeName: String?,
        isRead: Bool,
        baseURL: String,
        themeStyle: AppSettings.ThemeStyle
    ) {
        let catalogBadge = badgeId.flatMap { BadgeCatalogStore.badge(id: $0, baseURL: baseURL) }
        let type = catalogBadge?.type ?? .bronze
        let medalColor = isRead ? UIColor.secondaryLabel : type.color
        let symbol = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let fallback = UIImage(systemName: "medal.fill", withConfiguration: symbol)

        badgeIconView.sd_cancelCurrentImageLoad()
        badgeIconView.tintColor = medalColor
        badgeContainer.backgroundColor = isRead
            ? themeStyle.topicChipBackgroundColor
            : type.color.withAlphaComponent(0.16)

        if let raw = catalogBadge?.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = Self.resolveURL(raw, baseURL: baseURL) {
            badgeIconView.sd_setImage(with: url, placeholderImage: fallback)
            // Keep original badge artwork colors when remote image loads.
            badgeIconView.tintColor = nil
        } else {
            badgeIconView.image = fallback
        }

        let name = badgeName ?? catalogBadge?.name
        let typeTitle = catalogBadge?.type.title
        if let name, !name.isEmpty, let typeTitle {
            descriptionLabel.text = String(localized: "notifications.action.badge_granted_typed \(typeTitle) \(name)")
        } else if let name, !name.isEmpty {
            descriptionLabel.text = String(localized: "notifications.action.badge_granted \(name)")
        } else {
            descriptionLabel.text = String(localized: "notifications.action.badge")
        }

        // Warm catalog if missing so next configure paints real chrome.
        if catalogBadge == nil, let badgeId {
            let api = DiscourseAPI(baseURL: baseURL)
            Task { @MainActor in
                _ = await BadgeCatalogStore.ensureLoaded(using: api)
                if let refreshed = BadgeCatalogStore.badge(id: badgeId, baseURL: baseURL) {
                    // Only refresh if still showing this badge id's placeholder.
                    let type = refreshed.type
                    self.badgeIconView.tintColor = isRead ? .secondaryLabel : type.color
                    self.badgeContainer.backgroundColor = isRead
                        ? themeStyle.topicChipBackgroundColor
                        : type.color.withAlphaComponent(0.16)
                    if let raw = refreshed.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !raw.isEmpty,
                       let url = Self.resolveURL(raw, baseURL: baseURL) {
                        self.badgeIconView.sd_setImage(with: url, placeholderImage: fallback)
                        self.badgeIconView.tintColor = nil
                    }
                    let typeTitle = refreshed.type.title
                    let displayName = name ?? refreshed.name
                    if !displayName.isEmpty {
                        self.descriptionLabel.text = String(
                            localized: "notifications.action.badge_granted_typed \(typeTitle) \(displayName)"
                        )
                    }
                }
            }
        }
    }

    private static func resolveURL(_ raw: String, baseURL: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if raw.hasPrefix("/") {
            return URL(string: base + raw)
        }
        return URL(string: base + "/" + raw)
    }

    static func avatarURL(for notification: DiscourseNotification, baseURL: String) -> URL? {
        guard let template = notification.actingUserAvatarTemplate ?? notification.data.avatarTemplate else { return nil }
        return AvatarImageLoader.url(from: template, baseURL: baseURL, size: 96)
    }

    static func formatDate(_ string: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        guard let date else { return "" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// FluxDo `notification_item` color map.
    private static func color(for type: Int, themeStyle: AppSettings.ThemeStyle) -> UIColor {
        if themeStyle != .systemDefault, AppSettings.shared.themeTaxonomyColorsEnabled {
            return themeStyle.topicTagColor(for: "notification-\(type)")
        }
        switch type {
        case 5, 19, 25:
            return .systemRed
        case 6, 7, 13, 29, 30, 31, 32, 33, 40:
            return .systemBlue
        case 12:
            return .systemYellow
        case 1, 15:
            return themeStyle.accentColor
        case 24, 37:
            return .systemPurple
        case 38:
            return .systemRed
        case 43:
            // FluxDo boost accent — deep purple / indigo.
            return .systemPurple
        case 800, 801, 802:
            return .systemGreen
        case 34, 35:
            return .systemOrange
        default:
            return .secondaryLabel
        }
    }
}

private final class NotificationListSkeletonView: UIView {
    private var rows: [NotificationSkeletonRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for _ in 0 ..< 8 {
            let row = NotificationSkeletonRow()
            rows.append(row)
            stack.addArrangedSubview(row)
        }
        applyThemeStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyThemeStyle() {
        let themeStyle = AppSettings.shared.themeStyle
        backgroundColor = themeStyle.topicListBackgroundColor
        rows.forEach { $0.applyThemeStyle(themeStyle) }
    }
}

private final class NotificationSkeletonRow: UIView {
    private var skeletonViews: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 76).isActive = true

        let avatar = makeSkeletonView(cornerRadius: 20)
        let title = makeSkeletonView(cornerRadius: 4)
        let titleShort = makeSkeletonView(cornerRadius: 4)
        let subtitle = makeSkeletonView(cornerRadius: 4)
        addSubview(avatar)
        addSubview(title)
        addSubview(titleShort)
        addSubview(subtitle)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            avatar.widthAnchor.constraint(equalToConstant: 40),
            avatar.heightAnchor.constraint(equalToConstant: 40),

            title.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            title.heightAnchor.constraint(equalToConstant: 14),

            titleShort.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            titleShort.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 7),
            titleShort.widthAnchor.constraint(equalToConstant: 150),
            titleShort.heightAnchor.constraint(equalToConstant: 14),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: titleShort.bottomAnchor, constant: 9),
            subtitle.widthAnchor.constraint(equalToConstant: 210),
            subtitle.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeSkeletonView(cornerRadius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        view.layer.cornerRadius = cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        skeletonViews.append(view)
        return view
    }

    func applyThemeStyle(_ themeStyle: AppSettings.ThemeStyle) {
        backgroundColor = .clear
        skeletonViews.forEach { $0.backgroundColor = themeStyle.topicChipBackgroundColor }
    }
}
