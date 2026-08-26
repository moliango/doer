import SDWebImage
import UIKit

final class MeViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let viewModel: MeViewModel
    private weak var authGate: AuthGating?

    private let statsPreferences = MeStatsPreferences()
    private let accountFunctionPreferences = MeAccountFunctionPreferences()
    private let profileCard = MeProfileCardView()
    private let statsCard = MeStatsCardView()
    private let balanceCard = MeBalanceCardView()
    private let quickActionsCard = MeQuickActionsCardView()
    private let actionsCard = MeActionCardView()
    private let loadingSkeletonView = MeDashboardSkeletonView()
    private var balanceCache: LinuxDoExtensionCache?
    private var balanceRefreshTask: Task<Void, Never>?
    private var connectingServices = Set<LinuxDoExtensionService>()

    private lazy var scrollView: UIScrollView = {
        let sv = MeDashboardScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        sv.showsVerticalScrollIndicator = false
        sv.delaysContentTouches = false
        sv.canCancelContentTouches = true
        return sv
    }()

    private let contentStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    init(api: DiscourseAPI, authGate: AuthGating? = nil) {
        self.api = api
        self.viewModel = MeViewModel(api: api)
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
        observe(AuthManager.shared)
        title = String(localized: "tab.me")
        applyThemeStyle()

        setupLayout()
        setupActions()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(miniProgramCatalogDidChange),
            name: MiniProgramStore.catalogDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accountFunctionsDidChange),
            name: MeAccountFunctionPreferences.didChangeNotification,
            object: nil
        )
        loadData()
    }

    @MainActor
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateUI()
    }

    override func updateUI() {
        applyThemeStyle()
        if !viewModel.isLoading, refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
        activityIndicator.stopAnimating()

        let isLoggedIn = (authGate?.isAuthenticated() ?? false) && !viewModel.requiresLogin
        let showsInitialSkeleton = viewModel.isLoading
            && isLoggedIn
            && viewModel.currentUser == nil
            && viewModel.userProfile == nil
        loadingSkeletonView.setSkeletonActive(showsInitialSkeleton, animated: view.window != nil)
        scrollView.isHidden = showsInitialSkeleton

        if let error = viewModel.errorMessage {
            loadingSkeletonView.setSkeletonActive(false, animated: view.window != nil)
            scrollView.isHidden = false
            DoerFeedback.presentToast(error, on: self)
            viewModel.errorMessage = nil
        }

        if isLoggedIn {
            profileCard.configure(
                user: viewModel.currentUser,
                profile: viewModel.userProfile,
                baseURL: api.baseURL
            )
            statsCard.configure(
                items: makeStatItems(),
                isLoggedIn: true,
                layout: statsPreferences.configuration.layout
            )
        } else {
            profileCard.configure(user: nil, profile: nil, baseURL: api.baseURL)
            statsCard.configure(items: [], isLoggedIn: false, layout: .grid)
        }

        configureActionRows(isLoggedIn: isLoggedIn)
        configureQuickActions(isLoggedIn: isLoggedIn)
        configureBalanceCard(isLoggedIn: isLoggedIn)
    }

    private func setupLayout() {
        scrollView.refreshControl = refreshControl

        view.addSubview(scrollView)
        view.addSubview(loadingSkeletonView)
        view.addSubview(activityIndicator)
        scrollView.addSubview(contentStackView)

        contentStackView.addArrangedSubview(profileCard)
        contentStackView.addArrangedSubview(statsCard)
        contentStackView.addArrangedSubview(balanceCard)
        contentStackView.addArrangedSubview(quickActionsCard)
        contentStackView.addArrangedSubview(actionsCard)
        contentStackView.addArrangedSubview(makeAuthButtonContainer())

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingSkeletonView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            loadingSkeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            loadingSkeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            loadingSkeletonView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28),

            contentStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            contentStackView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStackView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupActions() {
        profileCard.onLoginTapped = { [weak self] in
            self?.loginTapped()
        }
        profileCard.onProfileTapped = { [weak self] in
            self?.openCurrentUserProfile()
        }
        statsCard.onCustomizeTapped = { [weak self] in
            self?.showStatsCustomizer()
        }
        balanceCard.onSelect = { [weak self] service in
            self?.handleBalanceServiceTap(service)
        }
        actionsCard.onCustomizeTapped = { [weak self] in
            self?.showAccountFunctionCustomizer()
        }
    }

    private func applyThemeStyle() {
        let themeStyle = AppSettings.shared.themeStyle
        view.backgroundColor = themeStyle.topicListBackgroundColor
        scrollView.backgroundColor = themeStyle.topicListBackgroundColor
        refreshControl.tintColor = themeStyle.accentColor
        activityIndicator.color = themeStyle.accentColor
        loadingSkeletonView.applyThemeStyle()
    }

    private func makeAuthButtonContainer() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.addTarget(self, action: #selector(authButtonTapped), for: .touchUpInside)
        button.tag = 9001

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return container
    }

    private func configureActionRows(isLoggedIn: Bool) {
        let trustLevel = viewModel.userProfile?.trustLevel ?? 0
        let rowsByFunction: [MeAccountFunction: MeActionRow] = [
            .messages: MeActionRow(
                title: String(localized: "messages.title"),
                subtitle: String(localized: "me.action.messages.subtitle"),
                symbolName: "envelope.fill",
                tintColor: .systemIndigo,
                isEnabled: isLoggedIn,
                action: { [weak self] in self?.openMessages() }
            ),
            .chat: MeActionRow(
                title: String(localized: "chat.title", defaultValue: "站内聊天"),
                subtitle: String(localized: "me.action.chat.subtitle", defaultValue: "频道与私聊"),
                symbolName: "bubble.left.and.bubble.right.fill",
                tintColor: .systemPurple,
                isEnabled: isLoggedIn,
                action: { [weak self] in self?.openChat() }
            ),
            .browser: MeActionRow(
                title: String(localized: "me.browser.home", defaultValue: "网页浏览"),
                subtitle: String(localized: "me.action.browser.subtitle", defaultValue: "收藏、历史与内置浏览器"),
                symbolName: "safari.fill",
                tintColor: .systemCyan,
                isEnabled: true,
                action: { [weak self] in self?.openBrowser() }
            ),
            .aiModelService: MeActionRow(
                title: String(localized: "ai.service.title", defaultValue: "AI 模型服务"),
                subtitle: String(localized: "me.action.ai.subtitle", defaultValue: "管理 AI 供应商与模型"),
                symbolName: "cpu.fill",
                tintColor: .systemTeal,
                isEnabled: true,
                action: { [weak self] in self?.openAIModelService() }
            ),
            .badges: MeActionRow(
                title: String(localized: "me.badges"),
                subtitle: String(localized: "me.action.badges.subtitle"),
                symbolName: "medal.fill",
                tintColor: .systemYellow,
                isEnabled: isLoggedIn,
                action: { [weak self] in self?.openBadges() }
            ),
            .trustRequirements: MeActionRow(
                title: String(localized: "me.trust_requirements"),
                subtitle: String(localized: "me.action.trust.subtitle"),
                symbolName: "checkmark.shield.fill",
                tintColor: .systemGreen,
                isEnabled: isLoggedIn,
                action: { [weak self] in self?.openTrustRequirements() }
            ),
            .inviteLinks: MeActionRow(
                title: String(localized: "me.invite_links"),
                subtitle: trustLevel >= 3 ? String(localized: "me.action.invites.subtitle") : String(localized: "me.invite_links.requires_level"),
                symbolName: "link.circle.fill",
                tintColor: .systemCyan,
                isEnabled: isLoggedIn && trustLevel >= 3,
                action: { [weak self] in self?.openInviteLinks() }
            ),
            .exportHistory: MeActionRow(
                title: String(localized: "topic.export.history", defaultValue: "导出历史"),
                subtitle: String(localized: "me.action.export_history.subtitle", defaultValue: "查看并再次分享话题导出文件"),
                symbolName: "square.and.arrow.up.on.square.fill",
                tintColor: .systemGreen,
                isEnabled: true,
                action: { [weak self] in self?.openExportHistory() }
            ),
            .pendingPosts: MeActionRow(
                title: String(localized: "pending.title", defaultValue: "待审内容"),
                subtitle: String(localized: "pending.subtitle", defaultValue: "查看送审中的主题与回复"),
                symbolName: "hourglass",
                tintColor: .systemOrange,
                isEnabled: isLoggedIn,
                action: { [weak self] in self?.openPendingPosts() }
            ),
            .notionSync: MeActionRow(
                title: String(localized: "notion.settings.title", defaultValue: "Notion 同步"),
                subtitle: String(localized: "notion.settings.subtitle", defaultValue: "配置 Token 并把话题同步到 Notion"),
                symbolName: "tray.and.arrow.up.fill",
                tintColor: .systemGray,
                isEnabled: true,
                action: { [weak self] in self?.openNotionSettings() }
            ),
            .settings: MeActionRow(
                title: String(localized: "me.settings"),
                subtitle: String(localized: "me.action.settings.subtitle"),
                symbolName: "gearshape.fill",
                tintColor: .systemBlue,
                isEnabled: true,
                action: { [weak self] in self?.openSettings() }
            ),
        ]

        let rows = accountFunctionPreferences.visibleFunctions.compactMap { rowsByFunction[$0] }
        actionsCard.configure(title: String(localized: "me.actions.title"), rows: rows)

        if let authButton = (contentStackView.arrangedSubviews.last?.subviews.first as? UIButton) {
            let title = isLoggedIn
                ? String(localized: "me.account_actions", defaultValue: "账号与切换")
                : String(localized: "me.login")
            authButton.setTitle(title, for: .normal)
            authButton.setTitleColor(isLoggedIn ? .systemRed : .tintColor, for: .normal)
        }
    }

    private func loadData() {
        guard authGate?.isAuthenticated() == true else {
            MeProfileCacheStore.clear(baseURL: api.baseURL)
            viewModel.clearSessionState(requiresLogin: true)
            return
        }
        Task {
            await viewModel.loadProfile()
        }
    }

    func refreshAfterCloudflareVerification() {
        loadData()
    }

    @objc private func pullToRefresh() {
        Task {
            if authGate?.isAuthenticated() == true {
                await viewModel.reload()
            }
            refreshControl.endRefreshing()
        }
    }

    @objc private func authButtonTapped() {
        if authGate?.isAuthenticated() == true {
            presentAccountActions()
        } else {
            loginTapped()
        }
    }

    private func loginTapped() {
        authGate?.requireAuth { [weak self] in
            self?.reloadAfterLogin()
        }
    }

    private func reloadAfterLogin() {
        viewModel.requiresLogin = false
        viewModel.isLoading = viewModel.currentUser == nil && viewModel.userProfile == nil
        updateUI()
        Task {
            await viewModel.loadProfile()
        }
    }

    /// Logged-in auth button opens Switch Account / Log Out instead of only logout.
    private func presentAccountActions() {
        let store = AccountCredentialStore.forBaseURL(api.baseURL)
        let sheet = UIAlertController(
            title: authGate?.currentUsername().map { "@\($0)" },
            message: nil,
            preferredStyle: .actionSheet
        )

        for account in store.accounts {
            let isCurrent = authGate?.currentUsername()?.caseInsensitiveCompare(account.username) == .orderedSame
            let title = isCurrent
                ? String(localized: "me.switch_account.current", defaultValue: "当前：@\(account.username)")
                : String(localized: "me.switch_account.use", defaultValue: "切换到 @\(account.username)")
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self, !isCurrent else { return }
                self.switchToSavedAccount(username: account.username)
            })
        }

        sheet.addAction(UIAlertAction(
            title: String(localized: "me.switch_account.other", defaultValue: "登录其他账号"),
            style: .default
        ) { [weak self] _ in
            self?.switchToOtherAccount()
        })

        sheet.addAction(UIAlertAction(
            title: String(localized: "me.logout"),
            style: .destructive
        ) { [weak self] _ in
            self?.logoutTapped()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))

        if let pop = sheet.popoverPresentationController,
           let button = contentStackView.arrangedSubviews.last?.subviews.first {
            pop.sourceView = button
            pop.sourceRect = button.bounds
        }
        present(sheet, animated: true)
    }

    private func switchToSavedAccount(username: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.authGate?.performLogout()
            self.viewModel.clearSessionState(requiresLogin: true)
            self.updateUI()
            self.authGate?.requireAuth(preferredUsername: username) { [weak self] in
                self?.reloadAfterLogin()
            }
        }
    }

    private func switchToOtherAccount() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.authGate?.performLogout()
            self.viewModel.clearSessionState(requiresLogin: true)
            self.updateUI()
            self.authGate?.requireAuth(preferredUsername: nil) { [weak self] in
                self?.reloadAfterLogin()
            }
        }
    }

    private func logoutTapped() {
        let alert = UIAlertController(
            title: String(localized: "me.logout.confirm.title"),
            message: String(localized: "me.logout.confirm.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "me.logout"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.authGate?.performLogout()
                self.viewModel.clearSessionState(requiresLogin: true)
                self.updateUI()
                self.authGate?.requireAuth { [weak self] in
                    self?.reloadAfterLogin()
                }
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func makeStatItems() -> [MeStatItem] {
        statsPreferences.selectedStats.compactMap { type in
            switch type {
            case .topicCount:
                return MeStatItem(type: type, value: viewModel.summary?.topicCount)
            case .postCount:
                return MeStatItem(type: type, value: viewModel.summary?.postCount)
            case .likesReceived:
                return MeStatItem(type: type, value: viewModel.summary?.likesReceived)
            case .likesGiven:
                return MeStatItem(type: type, value: viewModel.summary?.likesGiven)
            case .daysVisited:
                return MeStatItem(type: type, value: viewModel.summary?.daysVisited)
            case .timeRead:
                return MeStatItem(type: type, valueText: formatDuration(seconds: viewModel.userProfile?.timeRead))
            case .profileViews:
                return MeStatItem(type: type, value: viewModel.userProfile?.profileViewCount)
            case .badges:
                return MeStatItem(type: type, value: viewModel.userProfile?.badgeCount)
            }
        }
    }

    private func formatDuration(seconds: Int?) -> String? {
        guard let seconds else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds))
    }

    private func showStatsCustomizer() {
        let editor = ProfileStatsEditorViewController(configuration: statsPreferences.configuration)
        editor.onChange = { [weak self] configuration in
            guard let self else { return }
            self.statsPreferences.configuration = configuration
            self.statsCard.configure(
                items: self.makeStatItems(),
                isLoggedIn: self.authGate?.isAuthenticated() == true,
                layout: configuration.layout
            )
        }
        navigationController?.pushViewController(editor, animated: true)
    }

    private func showAccountFunctionCustomizer() {
        navigationController?.pushViewController(AccountFunctionsEditorViewController(), animated: true)
    }

    private func openCurrentUserProfile() {
        guard let username = viewModel.currentUser?.username else { return }
        let vc = UserProfileViewController(api: api, username: username)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openChat() {
        guard authGate?.isAuthenticated() == true else {
            authGate?.requireAuth { [weak self] in self?.openChat() }
            return
        }
        navigationController?.pushViewController(ChatChannelsViewController(api: api), animated: true)
    }

    private func openMessages() {
        guard authGate?.isAuthenticated() == true else {
            loginTapped()
            return
        }
        let vc = MessagesViewController(api: api, authGate: authGate)
        navigationController?.pushViewController(vc, animated: true)
    }


    private func configureQuickActions(isLoggedIn: Bool) {
        quickActionsCard.configure(items: [
            MeQuickActionItem(
                title: String(localized: "me.quick.topics", defaultValue: "我的话题"),
                symbolName: "doc.text.fill",
                tintColor: .systemBlue,
                action: { [weak self] in self?.openMyTopics() }
            ),
            MeQuickActionItem(
                title: String(localized: "me.quick.bookmarks", defaultValue: "我的书签"),
                symbolName: "bookmark.fill",
                tintColor: .systemOrange,
                action: { [weak self] in self?.openBookmarks() }
            ),
            MeQuickActionItem(
                title: String(localized: "me.quick.read_later", defaultValue: "稍后阅读"),
                symbolName: "square.stack.3d.up.fill",
                tintColor: .systemIndigo,
                action: { [weak self] in self?.openReadLater() }
            ),
            MeQuickActionItem(
                title: String(localized: "me.quick.drafts", defaultValue: "我的草稿"),
                symbolName: "envelope.fill",
                tintColor: .systemTeal,
                action: { [weak self] in self?.openDrafts() }
            ),
            MeQuickActionItem(
                title: String(localized: "me.quick.history", defaultValue: "浏览历史"),
                symbolName: "clock.fill",
                tintColor: .systemPurple,
                action: { [weak self] in self?.openDiscourseHistory() }
            ),
        ])
        quickActionsCard.alpha = isLoggedIn ? 1 : 0.55
        quickActionsCard.isUserInteractionEnabled = true
    }

    private func configureBalanceCard(isLoggedIn: Bool) {
        guard isLoggedIn, let username = viewModel.currentUser?.username ?? authGate?.currentUsername() else {
            balanceCard.isHidden = true
            balanceRefreshTask?.cancel()
            return
        }
        let cache = LinuxDoExtensionCache(baseURL: api.baseURL, username: username)
        balanceCache = cache
        var rows: [MeBalanceRowModel] = []

        if MiniProgramStore.shared.program(id: MiniProgramID.ldc)?.isVisible == true {
            let info = cache.userInfo(.ldc)
            let connected = cache.isEnabled(.ldc)
            let income = Self.dailyIncomeText(
                gamificationScore: viewModel.userProfile?.gamificationScore,
                communityBalance: info?.communityBalance
            )
            rows.append(
                MeBalanceRowModel(
                    service: .ldc,
                    title: String(localized: "me.balance.ldc", defaultValue: "LDC 余额"),
                    valueText: connected ? (info?.balanceText ?? "--") : String(localized: "extensions.connect", defaultValue: "点击连接"),
                    dailyIncomeText: connected && !connectingServices.contains(.ldc) ? income : nil,
                    isLoading: connectingServices.contains(.ldc),
                    isConnected: connected
                )
            )
        }
        if MiniProgramStore.shared.program(id: MiniProgramID.cdk)?.isVisible == true {
            let info = cache.userInfo(.cdk)
            let connected = cache.isEnabled(.cdk)
            rows.append(
                MeBalanceRowModel(
                    service: .cdk,
                    title: String(localized: "me.balance.cdk", defaultValue: "CDK 积分"),
                    valueText: connected ? (info?.balanceText ?? "--") : String(localized: "extensions.connect", defaultValue: "点击连接"),
                    dailyIncomeText: nil,
                    isLoading: connectingServices.contains(.cdk),
                    isConnected: connected
                )
            )
        }
        balanceCard.configure(rows: rows)
        if connectingServices.isEmpty {
            refreshBalancesIfNeeded(username: username)
        }
    }

    private static func dailyIncomeText(gamificationScore: Int?, communityBalance: String?) -> String? {
        guard let score = gamificationScore,
              let community = communityBalance,
              let balance = Double(community)
        else { return nil }
        let income = Int((Double(score) - balance).rounded())
        if income > 0 { return "+\(income)" }
        if income < 0 { return "\(income)" }
        return "+0"
    }

    private func refreshBalancesIfNeeded(username: String) {
        balanceRefreshTask?.cancel()
        let services = [LinuxDoExtensionService.ldc, .cdk].filter {
            MiniProgramStore.shared.program(id: miniProgramID(for: $0))?.isVisible == true
                && (balanceCache?.isEnabled($0) == true)
        }
        guard !services.isEmpty else { return }
        balanceRefreshTask = Task { [weak self] in
            guard let self else { return }
            for service in services {
                let infoURL = service.baseURL.appendingPathComponent("api/v1/oauth/user-info")
                if LinuxDoExtensionCFGate.shouldSkipUserInfoRefresh(for: infoURL) {
                    continue
                }
                do {
                    let info = try await LinuxDoExtensionOAuthCoordinator(
                        service: service,
                        forumBaseURL: self.api.baseURL
                    ).fetchUserInfo()
                    self.balanceCache?.setUserInfo(info, service: service)
                } catch {
                    // 保持缓存展示，静默失败
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.configureBalanceCard(isLoggedIn: true)
            }
        }
    }

    private func handleBalanceServiceTap(_ service: LinuxDoExtensionService) {
        guard let username = viewModel.currentUser?.username ?? authGate?.currentUsername() else {
            loginTapped()
            return
        }
        let cache = balanceCache ?? LinuxDoExtensionCache(baseURL: api.baseURL, username: username)
        balanceCache = cache
        if cache.isEnabled(service) {
            let browser = InAppBrowserViewController(
                api: api,
                username: username,
                initialURL: service.dashboardURL
            )
            navigationController?.pushViewController(browser, animated: true)
            return
        }
        guard connectingServices.insert(service).inserted else { return }
        configureBalanceCard(isLoggedIn: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DoerFeedback.presentLoadingHUD(Self.connectingMessage(for: service), on: self)
        // 未连接：FluxDo 同款原生授权确认，不先打开内置浏览器。
        Task { [weak self] in
            guard let self else { return }
            var presentedFollowUp = false
            defer {
                if !presentedFollowUp {
                    self.finishBalanceConnecting(service)
                }
            }
            do {
                let info = try await LinuxDoExtensionOAuthCoordinator(
                    service: service,
                    forumBaseURL: self.api.baseURL
                ).authorize(from: self)
                guard let info else { return }
                cache.setEnabled(true, service: service)
                cache.setUserInfo(info, service: service)
            } catch LinuxDoExtensionError.cloudflare {
                presentedFollowUp = true
                self.finishBalanceConnecting(service)
                let verifier = CloudflareVerificationViewController(
                    baseURL: service.baseURL,
                    responseURL: nil,
                    verificationURL: service.baseURL,
                    autoDismissOnSuccess: true
                ) { [weak self] in
                    self?.handleBalanceServiceTap(service)
                }
                let nav = UINavigationController(rootViewController: verifier)
                nav.modalPresentationStyle = .pageSheet
                self.present(nav, animated: true)
            } catch {
                presentedFollowUp = true
                self.finishBalanceConnecting(service)
                let alert = UIAlertController(
                    title: nil,
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func finishBalanceConnecting(_ service: LinuxDoExtensionService) {
        DoerFeedback.dismissLoadingHUD(on: self)
        connectingServices.remove(service)
        configureBalanceCard(isLoggedIn: true)
    }

    private static func connectingMessage(for service: LinuxDoExtensionService) -> String {
        switch service {
        case .ldc:
            return String(localized: "extensions.connecting.ldc", defaultValue: "正在连接 LDC…")
        case .cdk:
            return String(localized: "extensions.connecting.cdk", defaultValue: "正在连接 CDK…")
        }
    }

    private func openMyTopics() {
        guard let username = viewModel.currentUser?.username else {
            loginTapped()
            return
        }
        let vc = PagedTopicListViewController(
            api: api,
            title: String(localized: "me.my_topics", defaultValue: "我的主题"),
            emptyMessage: String(localized: "me.my_topics.empty", defaultValue: "还没有创建过话题"),
            searchQuery: "@\(username) order:latest",
            loader: { [api] page in
                try await api.fetchCreatedTopics(username: username, page: page)
            }
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openDiscourseHistory() {
        guard authGate?.isAuthenticated() == true else {
            loginTapped()
            return
        }
        let vc = PagedTopicListViewController(
            api: api,
            title: String(localized: "me.discourse_history", defaultValue: "浏览历史"),
            emptyMessage: String(localized: "me.discourse_history.empty", defaultValue: "还没有论坛浏览记录"),
            fixedSearchQualifier: "in:seen",
            loader: { [api] page in
                try await api.fetchReadTopics(page: page)
            }
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openDrafts() {
        guard authGate?.isAuthenticated() == true else {
            loginTapped()
            return
        }
        navigationController?.pushViewController(DraftsViewController(api: api), animated: true)
    }

    private func openReadLater() {
        let vc = ReadLaterViewController(api: api)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openBookmarks() {
        guard let username = viewModel.currentUser?.username else {
            loginTapped()
            return
        }
        let vc = BookmarksViewController(api: api, username: username, authGate: authGate)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openBrowser() {
        let vc = WebBrowsingHomeViewController(
            api: api,
            username: viewModel.currentUser?.username ?? authGate?.currentUsername()
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func miniProgramCatalogDidChange() {
        updateUI()
    }

    @objc private func accountFunctionsDidChange() {
        updateUI()
    }

    private func miniProgramID(for service: LinuxDoExtensionService) -> String {
        switch service {
        case .ldc: return MiniProgramID.ldc
        case .cdk: return MiniProgramID.cdk
        }
    }

    private func openMetaverseServices() {
        guard let username = viewModel.currentUser?.username ?? authGate?.currentUsername() else {
            loginTapped()
            return
        }
        navigationController?.pushViewController(
            MetaverseServicesViewController(api: api, username: username),
            animated: true
        )
    }

    private func openExportHistory() {
        let vc = ExportHistoryViewController(
            baseURL: api.baseURL,
            username: viewModel.currentUser?.username ?? authGate?.currentUsername()
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openPendingPosts() {
        guard let username = viewModel.currentUser?.username ?? authGate?.currentUsername() else {
            loginTapped()
            return
        }
        navigationController?.pushViewController(
            PendingPostsViewController(api: api, username: username),
            animated: true
        )
    }

    private func openNotionSettings() {
        let vc = NotionSettingsViewController(
            baseURL: api.baseURL,
            username: viewModel.currentUser?.username ?? authGate?.currentUsername()
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openBadges() {
        guard let username = viewModel.currentUser?.username else {
            loginTapped()
            return
        }
        let vc = UserBadgesViewController(api: api, username: username)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openTrustRequirements() {
        let vc = TrustRequirementsViewController(
            api: api,
            username: viewModel.currentUser?.username,
            trustLevel: viewModel.userProfile?.trustLevel ?? 0
        )
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openInviteLinks() {
        guard let username = viewModel.currentUser?.username else {
            loginTapped()
            return
        }
        let vc = InviteLinksViewController(api: api, username: username)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openSettings() {
        let vc = SettingsViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    private func openAIModelService() {
        navigationController?.pushViewController(AIModelServiceViewController(api: api), animated: true)
    }

    private func openUserWebPath(_ path: String) {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let baseURL = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        openExternalURL(baseURL + normalizedPath)
    }

    private func openExternalURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            showInfoAlert(String(localized: "me.web.open_error"))
            return
        }
        DoerSafariPresenter.present(
            url: url,
            from: self,
            api: api,
            username: viewModel.currentUser?.username ?? authGate?.currentUsername()
        )
    }

    private func showInfoAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

private final class MeDashboardScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Instant highlight (delaysContentTouches = false) still has to yield to
        // dragging: the dashboard is almost entirely UIControls, so refusing to
        // cancel them makes vertical pans feel stuck.
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }
}
