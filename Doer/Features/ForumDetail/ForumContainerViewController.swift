import Combine
import UIKit
import WebKit

final class ForumContainerViewController: UIViewController, AuthGating {
    private static let cloudflareShieldSuppressionDuration: TimeInterval = 30
    private static let launchOverlayMinimumDuration: TimeInterval = 1.15
    private static let launchOverlayMaximumDurationNanoseconds: UInt64 = 4_200_000_000

    private(set) var forum: ForumInstance
    private let api: DiscourseAPI
    private let notificationCoordinator: ForumNotificationCoordinator
    private let authManager = AuthManager.shared
    private let showsDismissButton: Bool
    private var launchOverlayStartedAt = Date()
    private var launchOverlayDismissed = false
    private var isHomeInitialContentReady = false
    private var launchOverlayObservationToken: NSObjectProtocol?
    private var launchOverlayFallbackTask: Task<Void, Never>?
    private var authObservationToken: AnyCancellable?
    private var cloudflareChallengeObservationToken: NSObjectProtocol?
    private var cloudflareCompletionObservationToken: NSObjectProtocol?
    private var cloudflareNeedsUserObservationToken: NSObjectProtocol?
    private var appUpdateObservationToken: NSObjectProtocol?
    private var appDidBecomeActiveObservationToken: NSObjectProtocol?
    private var notificationRouteObservationToken: AnyCancellable?
    private var pendingAppUpdateRetryTask: Task<Void, Never>?
    private var isPresentingCloudflareVerification = false
    private var shouldShowCloudflareShieldButton = false
    private var cloudflareShieldSuppressedUntil: Date?
    /// After the user closes a CF sheet without passing, don't auto-present again (CDK/LDC loops).
    private var cloudflareAutoPresentBlockedUntil: Date?
    private var pendingCloudflareBaseURL: URL?
    private var pendingCloudflareResponseURL: URL?
    private var cloudflareShieldButtonConstraints: [NSLayoutConstraint] = []
    private weak var cloudflareShieldButtonHostView: UIView?

    private let launchLoadingView = DoerLaunchLoadingView()
    private var tabBarViewController: ForumTabBarController?

    private let authSyncOverlayView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.78)
        view.alpha = 0
        view.isHidden = true
        view.isUserInteractionEnabled = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let authSyncCardView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.96)
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.10
        view.layer.shadowRadius = 24
        view.layer.shadowOffset = CGSize(width: 0, height: 10)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let authSyncSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    private let authSyncTitleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 17, weight: .semibold)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let authSyncMessageLabel: UILabel = {
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14, weight: .medium)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let cloudflareShieldButton: UIButton = {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        button.setImage(UIImage(systemName: "shield.lefthalf.filled", withConfiguration: config), for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = .white
        button.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.18
        button.layer.shadowRadius = 9
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.accessibilityLabel = String(localized: "settings.network.cloudflare_verify")
        button.alpha = 0
        button.isHidden = true
        return button
    }()

    init(forum: ForumInstance, showsDismissButton: Bool = true) {
        self.forum = forum
        let api = DiscourseAPI(forum: forum)
        self.api = api
        self.notificationCoordinator = ForumNotificationCoordinator(api: api)
        self.showsDismissButton = showsDismissButton
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DoerLaunchAppearance.backgroundColor
        DohDebugLog.record("forum container viewDidLoad base=\(forum.baseURL)", subsystem: "Launch")

        authManager.restoreAuthState(for: forum)
        if authManager.hasWebSession(for: forum.baseURL) {
            WebSessionRefreshService.shared.ensureInBackground(forum: forum, reason: "forum_container_loaded")
        }
        Task { @MainActor in
            await TrustLevelWidgetRefresher.refreshIfPossible()
        }

        startObservingHomeInitialContent()
        setupTabBar()
        DohDebugLog.record(
            "forum tab bar installed tabs=\(tabBarViewController?.navigationControllers.count ?? 0) selected=\(tabBarViewController?.selectedIndex ?? -1)",
            subsystem: "Launch"
        )
        setupAuthSyncOverlay()
        setupCloudflareShieldButton()
        setupLaunchLoadingOverlay()
        configureNavItems()
        startObservingAuth()
        startObservingCloudflareChallenges()
        startObservingAppUpdates()
        startObservingForumNotifications()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if shouldShowCloudflareShieldButton {
            installCloudflareShieldButtonIfNeeded()
        }
        presentPendingNotificationRouteIfPossible()
        presentPendingInAppRouteIfNeeded()
        guard !showsDismissButton else { return }
        AppUpdateCoordinator.shared.scheduleAutomaticCheckIfNeeded()
        presentPendingAppUpdateIfPossible()
    }

    private func startObservingAuth() {
        authObservationToken = authManager.objectWillChange.sink { [weak self] in
            self?.configureNavItems()
        }
    }

    private func startObservingCloudflareChallenges() {
        cloudflareChallengeObservationToken = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareChallengeDetectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudflareChallengeNotification(notification)
        }
        cloudflareCompletionObservationToken = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareVerificationCompletedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudflareVerificationCompleted(notification)
        }
        cloudflareNeedsUserObservationToken = NotificationCenter.default.addObserver(
            forName: CloudflareBackgroundVerificationService.needsUserInteractionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudflareNeedsUserInteraction(notification)
        }
    }

    @MainActor deinit {
        authObservationToken?.cancel()
        if let launchOverlayObservationToken {
            NotificationCenter.default.removeObserver(launchOverlayObservationToken)
        }
        if let cloudflareChallengeObservationToken {
            NotificationCenter.default.removeObserver(cloudflareChallengeObservationToken)
        }
        if let cloudflareCompletionObservationToken {
            NotificationCenter.default.removeObserver(cloudflareCompletionObservationToken)
        }
        if let cloudflareNeedsUserObservationToken {
            NotificationCenter.default.removeObserver(cloudflareNeedsUserObservationToken)
        }
        if let appUpdateObservationToken {
            NotificationCenter.default.removeObserver(appUpdateObservationToken)
        }
        if let appDidBecomeActiveObservationToken {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObservationToken)
        }
        notificationRouteObservationToken?.cancel()
        launchOverlayFallbackTask?.cancel()
        pendingAppUpdateRetryTask?.cancel()
        NSLayoutConstraint.deactivate(cloudflareShieldButtonConstraints)
        cloudflareShieldButton.removeFromSuperview()
    }

    private func setupTabBar() {
        let tabBarVC = ForumTabBarController(
            api: api,
            authGate: self,
            notificationCoordinator: notificationCoordinator
        )
        tabBarViewController = tabBarVC
        tabBarVC.onNavigationControllersChanged = { [weak self] in
            self?.configureNavItems()
        }
        addChild(tabBarVC)
        view.addSubview(tabBarVC.view)
        tabBarVC.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            tabBarVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            tabBarVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        tabBarVC.configureTabBarSurface()

        tabBarVC.didMove(toParent: self)
    }

    private func startObservingForumNotifications() {
        notificationCoordinator.startMonitoring()
        notificationRouteObservationToken = ForumNotificationRouteStore.shared.objectWillChange.sink { [weak self] in
            self?.presentPendingNotificationRouteIfPossible()
        }
    }

    /// Consumes a pending local-notification route for this forum (topic + floor).
    func presentPendingNotificationRouteIfPossible() {
        guard isViewLoaded, view.window != nil, presentedViewController == nil else { return }
        guard ForumOverlayManager.shared.prepareForNotificationRoute(in: self) else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 550_000_000)
                self.presentPendingNotificationRouteIfPossible()
            }
            return
        }
        guard let route = ForumNotificationRouteStore.shared.consume(baseURL: api.baseURL) else { return }
        if let notificationId = route.notificationId {
            Task { [weak self] in
                guard let self else { return }
                await self.notificationCoordinator.markNotificationRead(id: notificationId)
            }
        }
        guard let topicId = route.topicId else {
            let notificationsViewController = NotificationsViewController(
                api: api,
                authGate: self,
                notificationCoordinator: notificationCoordinator
            )
            let navigationController = UINavigationController(rootViewController: notificationsViewController)
            navigationController.modalPresentationStyle = .pageSheet
            if let sheet = navigationController.sheetPresentationController {
                sheet.detents = [.medium(), .large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 20
            }
            present(navigationController, animated: true)
            return
        }
        guard let tabBarViewController,
              let navigationController = tabBarViewController.navigationControllers.first
        else {
            ForumNotificationRouteStore.shared.enqueue(route)
            return
        }
        tabBarViewController.selectedIndex = 0
        // Same as in-app notifications list: deep-link floor/post without forcing nested
        // tree (avoids blank first paint while /n/topic is loading or unavailable).
        navigationController.pushViewController(
            TopicDetailFactory.make(
                api: api,
                topicId: topicId,
                initialFloor: route.postNumber,
                initialPostId: route.postId
            ),
            animated: true
        )
    }

    func openTopicFromExternalLink(topicId: Int, postNumber: Int?) {
        guard let tabBarViewController,
              let navigationController = tabBarViewController.navigationControllers.first
        else { return }
        tabBarViewController.selectedIndex = 0
        navigationController.pushViewController(
            TopicDetailFactory.make(api: api, topicId: topicId, initialFloor: postNumber),
            animated: true
        )
    }

    func presentPendingInAppRouteIfNeeded() {
        guard let route = DoerInAppRouteStore.shared.consume() else { return }
        handleInAppRoute(route)
    }

    func handleInAppRoute(_ route: DoerInAppRoute) {
        switch route {
        case .readLater:
            guard let tabBarViewController else {
                DoerInAppRouteStore.shared.enqueue(route)
                return
            }
            // Me tab is always last in current tab builder.
            let meIndex = max(tabBarViewController.navigationControllers.count - 1, 0)
            tabBarViewController.selectedIndex = meIndex
            let meNav = tabBarViewController.navigationControllers[meIndex]
            // Avoid stacking duplicate ReadLater pages.
            if meNav.topViewController is ReadLaterViewController {
                return
            }
            meNav.pushViewController(ReadLaterViewController(api: api), animated: true)
        case .trustLevel:
            guard let tabBarViewController else {
                DoerInAppRouteStore.shared.enqueue(route)
                return
            }
            let meIndex = max(tabBarViewController.navigationControllers.count - 1, 0)
            tabBarViewController.selectedIndex = meIndex
            let meNav = tabBarViewController.navigationControllers[meIndex]
            if meNav.topViewController is TrustRequirementsViewController {
                return
            }
            if let existing = meNav.viewControllers.first(where: { $0 is TrustRequirementsViewController }) {
                meNav.popToViewController(existing, animated: true)
                return
            }
            let username = authManager.username(for: forum.baseURL) ?? forum.username
            let trustLevel = username.flatMap {
                MeProfileCacheStore.cachedProfile(baseURL: forum.baseURL, username: $0)?.userProfile.trustLevel
            } ?? 0
            meNav.pushViewController(
                TrustRequirementsViewController(api: api, username: username, trustLevel: trustLevel),
                animated: true
            )
        }
    }

    func presentClipboardTopicLinkIfNeeded() {
        guard AppSettings.shared.clipboardTopicLinkPromptEnabled else { return }
        guard let info = ClipboardTopicLinkService.shared.check(forumBaseURL: forum.baseURL, enabled: true) else { return }
        // Defer slightly so we don't fight launch transitions.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            // Re-check in case user already navigated away / disabled.
            guard AppSettings.shared.clipboardTopicLinkPromptEnabled else { return }
            guard self.presentedViewController == nil else { return }
            let alert = UIAlertController(
                title: String(localized: "clipboard.topic.title", defaultValue: "打开话题链接？"),
                message: String(localized: "clipboard.topic.message", defaultValue: "检测到剪贴板中的论坛话题链接"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "忽略"), style: .cancel, handler: { _ in
                ClipboardTopicLinkService.shared.markPrompted(info)
            }))
            alert.addAction(UIAlertAction(title: String(localized: "clipboard.topic.open", defaultValue: "打开"), style: .default, handler: { [weak self] _ in
                ClipboardTopicLinkService.shared.markPrompted(info)
                self?.openTopicFromExternalLink(topicId: info.topicId, postNumber: info.postNumber)
            }))
            self.present(alert, animated: true)
        }
    }

    private func setupCloudflareShieldButton() {
        cloudflareShieldButton.addTarget(self, action: #selector(cloudflareShieldTapped), for: .touchUpInside)
        installCloudflareShieldButtonIfNeeded()
    }

    private func setupLaunchLoadingOverlay() {
        launchOverlayStartedAt = Date()
        launchLoadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(launchLoadingView)

        NSLayoutConstraint.activate([
            launchLoadingView.topAnchor.constraint(equalTo: view.topAnchor),
            launchLoadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            launchLoadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            launchLoadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        launchLoadingView.applyThemeStyle()
        launchLoadingView.startPresenting()
        scheduleLaunchOverlayFallbackDismiss()
        if isHomeInitialContentReady {
            dismissLaunchLoadingOverlayRespectingMinimumDuration()
        }
    }

    private func startObservingHomeInitialContent() {
        launchOverlayObservationToken = NotificationCenter.default.addObserver(
            forName: HomeViewController.initialContentReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleHomeInitialContentReady(notification)
        }
    }

    private func scheduleLaunchOverlayFallbackDismiss() {
        launchOverlayFallbackTask?.cancel()
        // Use GCD deadline in addition to Task sleep — more reliable if cooperative
        // tasks are delayed while the first frame is still installing tabs.
        let deadline = DispatchTime.now() + .milliseconds(Int(Self.launchOverlayMaximumDurationNanoseconds / 1_000_000))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(deadline.uptimeNanoseconds - DispatchTime.now().uptimeNanoseconds))
            guard !self.launchOverlayDismissed else { return }
            DohDebugLog.record("launch overlay fallback dismiss", subsystem: "Launch")
            self.dismissLaunchLoadingOverlayRespectingMinimumDuration()
        }
        launchOverlayFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.launchOverlayMaximumDurationNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.launchOverlayDismissed else { return }
                DohDebugLog.record("launch overlay task dismiss", subsystem: "Launch")
                self.dismissLaunchLoadingOverlayRespectingMinimumDuration()
            }
        }
    }

    private func handleHomeInitialContentReady(_ notification: Notification) {
        guard let baseURL = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String else { return }
        guard normalizedBaseURL(baseURL) == normalizedBaseURL(forum.baseURL) else { return }
        isHomeInitialContentReady = true
        guard launchLoadingView.superview != nil else { return }
        dismissLaunchLoadingOverlayRespectingMinimumDuration()
    }

    private func dismissLaunchLoadingOverlayRespectingMinimumDuration() {
        guard !launchOverlayDismissed else { return }
        guard launchLoadingView.superview != nil else { return }
        let elapsed = Date().timeIntervalSince(launchOverlayStartedAt)
        let delay = max(0, Self.launchOverlayMinimumDuration - elapsed)

        launchOverlayDismissed = true
        launchOverlayFallbackTask?.cancel()
        launchOverlayFallbackTask = nil

        let dismiss = { [weak self] in
            guard let self else { return }
            DohDebugLog.record("launch overlay dismissing", subsystem: "Launch")
            self.launchLoadingView.dismiss {
                self.launchLoadingView.removeFromSuperview()
                // Leave cream launch color only while the splash covers the UI.
                self.view.backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
                self.presentPendingAppUpdateIfPossible()
            }
        }

        if delay > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                dismiss()
            }
        } else {
            dismiss()
        }
    }

    private func startObservingAppUpdates() {
        guard !showsDismissButton else { return }
        appUpdateObservationToken = NotificationCenter.default.addObserver(
            forName: .appUpdateDidBecomeAvailable,
            object: AppUpdateCoordinator.shared,
            queue: .main
        ) { [weak self] _ in
            self?.presentPendingAppUpdateIfPossible()
        }
        appDidBecomeActiveObservationToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.presentPendingAppUpdateIfPossible()
        }
    }

    private func presentPendingAppUpdateIfPossible() {
        guard !showsDismissButton,
              launchOverlayDismissed,
              launchLoadingView.superview == nil,
              authSyncOverlayView.isHidden,
              !isPresentingCloudflareVerification,
              !hasBusyPresentation(in: self),
              view.window != nil
        else {
            schedulePendingAppUpdateRetryIfNeeded()
            return
        }
        AppUpdateCoordinator.shared.presentPendingIfPossible(from: self)
        schedulePendingAppUpdateRetryIfNeeded()
    }

    private func hasBusyPresentation(in viewController: UIViewController) -> Bool {
        if viewController.presentedViewController != nil ||
            viewController.isBeingPresented ||
            viewController.isBeingDismissed ||
            viewController.transitionCoordinator != nil {
            return true
        }

        if let navigationController = viewController as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return hasBusyPresentation(in: visibleViewController)
        }
        if let tabBarController = viewController as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return hasBusyPresentation(in: selectedViewController)
        }
        return viewController.children
            .filter { $0.viewIfLoaded?.window != nil }
            .contains { hasBusyPresentation(in: $0) }
    }

    private func schedulePendingAppUpdateRetryIfNeeded() {
        guard !showsDismissButton,
              AppUpdateCoordinator.shared.pendingRelease != nil,
              pendingAppUpdateRetryTask == nil
        else { return }

        pendingAppUpdateRetryTask = Task { [weak self] in
            defer { self?.pendingAppUpdateRetryTask = nil }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled, let self else { return }
                guard AppUpdateCoordinator.shared.pendingRelease != nil else { return }
                self.presentPendingAppUpdateIfPossible()
            }
        }
    }

    private func setupAuthSyncOverlay() {
        view.addSubview(authSyncOverlayView)
        authSyncOverlayView.addSubview(authSyncCardView)
        authSyncCardView.addSubview(authSyncSpinner)
        authSyncCardView.addSubview(authSyncTitleLabel)
        authSyncCardView.addSubview(authSyncMessageLabel)

        NSLayoutConstraint.activate([
            authSyncOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
            authSyncOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            authSyncOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            authSyncOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            authSyncCardView.centerXAnchor.constraint(equalTo: authSyncOverlayView.centerXAnchor),
            authSyncCardView.centerYAnchor.constraint(equalTo: authSyncOverlayView.centerYAnchor),
            authSyncCardView.leadingAnchor.constraint(greaterThanOrEqualTo: authSyncOverlayView.leadingAnchor, constant: 42),
            authSyncCardView.trailingAnchor.constraint(lessThanOrEqualTo: authSyncOverlayView.trailingAnchor, constant: -42),

            authSyncSpinner.topAnchor.constraint(equalTo: authSyncCardView.topAnchor, constant: 24),
            authSyncSpinner.centerXAnchor.constraint(equalTo: authSyncCardView.centerXAnchor),

            authSyncTitleLabel.topAnchor.constraint(equalTo: authSyncSpinner.bottomAnchor, constant: 16),
            authSyncTitleLabel.leadingAnchor.constraint(equalTo: authSyncCardView.leadingAnchor, constant: 24),
            authSyncTitleLabel.trailingAnchor.constraint(equalTo: authSyncCardView.trailingAnchor, constant: -24),

            authSyncMessageLabel.topAnchor.constraint(equalTo: authSyncTitleLabel.bottomAnchor, constant: 8),
            authSyncMessageLabel.leadingAnchor.constraint(equalTo: authSyncCardView.leadingAnchor, constant: 24),
            authSyncMessageLabel.trailingAnchor.constraint(equalTo: authSyncCardView.trailingAnchor, constant: -24),
            authSyncMessageLabel.bottomAnchor.constraint(equalTo: authSyncCardView.bottomAnchor, constant: -24),
        ])
    }

    private func installCloudflareShieldButtonIfNeeded() {
        let hostView: UIView = view.window ?? view
        if cloudflareShieldButtonHostView === hostView {
            hostView.bringSubviewToFront(cloudflareShieldButton)
            return
        }

        NSLayoutConstraint.deactivate(cloudflareShieldButtonConstraints)
        cloudflareShieldButton.removeFromSuperview()
        hostView.addSubview(cloudflareShieldButton)
        cloudflareShieldButtonHostView = hostView

        let centerYConstraint = cloudflareShieldButton.centerYAnchor.constraint(
            equalTo: hostView.safeAreaLayoutGuide.centerYAnchor,
            constant: 72
        )
        centerYConstraint.priority = UILayoutPriority.defaultHigh
        cloudflareShieldButtonConstraints = [
            cloudflareShieldButton.trailingAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            centerYConstraint,
            cloudflareShieldButton.bottomAnchor.constraint(lessThanOrEqualTo: hostView.safeAreaLayoutGuide.bottomAnchor, constant: -96),
            cloudflareShieldButton.widthAnchor.constraint(equalToConstant: 50),
            cloudflareShieldButton.heightAnchor.constraint(equalToConstant: 44),
        ]
        NSLayoutConstraint.activate(cloudflareShieldButtonConstraints)
        hostView.bringSubviewToFront(cloudflareShieldButton)
    }

    private func configureNavItems() {
        guard let tabBarVC = children.first as? ForumTabBarController else { return }

        for nav in tabBarVC.navigationControllers {
            guard let rootVC = nav.viewControllers.first else { continue }
            if rootVC.title == nil {
                rootVC.title = nav.tabBarItem.title
            }
            guard showsDismissButton else { continue }
            rootVC.navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "smallcircle.filled.circle"),
                style: .plain,
                target: self,
                action: #selector(dismissButtonTapped)
            )
        }
    }

    // MARK: - Actions

    @objc private func menuButtonTapped() {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        let store = AccountCredentialStore.forBaseURL(forum.baseURL)

        if authManager.isAuthenticated(for: baseURL) {
            if let username = authManager.username(for: baseURL) {
                alert.title = "@\(username)"
            }
            for account in store.accounts {
                let isCurrent = authManager.username(for: baseURL)?
                    .caseInsensitiveCompare(account.username) == .orderedSame
                guard !isCurrent else { continue }
                alert.addAction(UIAlertAction(
                    title: String(localized: "me.switch_account.use", defaultValue: "切换到 @\(account.username)"),
                    style: .default
                ) { [weak self] _ in
                    self?.switchAccount(preferredUsername: account.username)
                })
            }
            alert.addAction(UIAlertAction(
                title: String(localized: "me.switch_account.other", defaultValue: "登录其他账号"),
                style: .default
            ) { [weak self] _ in
                self?.switchAccount(preferredUsername: nil)
            })
            alert.addAction(UIAlertAction(title: String(localized: "me.logout"), style: .destructive) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.performLogout()
                    self?.performLogin()
                }
            })
        } else {
            alert.addAction(UIAlertAction(title: String(localized: "me.login"), style: .default) { [weak self] _ in
                self?.performLogin()
            })
        }

        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func switchAccount(preferredUsername: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLogout()
            self.requireAuth(preferredUsername: preferredUsername) {}
        }
    }

    @objc private func dismissButtonTapped() {
        ForumOverlayManager.shared.minimize()
    }

    @objc private func cloudflareShieldTapped() {
        let baseURL = pendingCloudflareBaseURL
            ?? URL(string: forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard let baseURL else {
            logCloudflareState("shield tap ignored because base URL is invalid")
            return
        }
        logCloudflareState("shield tapped; presenting foreground verification")
        cloudflareAutoPresentBlockedUntil = nil
        presentCloudflareVerification(
            baseURL: baseURL,
            responseURL: pendingCloudflareResponseURL
        )
    }

    private func handleCloudflareChallengeNotification(_ notification: Notification) {
        guard let baseURLString = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String else { return }
        guard normalizedBaseURL(baseURLString) == normalizedBaseURL(forum.baseURL) else { return }
        guard let baseURL = URL(string: baseURLString) ?? URL(string: forum.baseURL) else { return }
        let responseURL = notification.userInfo?[DiscourseAPI.cloudflareResponseURLUserInfoKey] as? URL
        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURLString) {
            logCloudflareState("challenge ignored during verification grace base=\(baseURLString)")
            setCloudflareShieldButtonVisible(false, animated: true)
            return
        }
        pendingCloudflareBaseURL = baseURL
        pendingCloudflareResponseURL = responseURL
        guard !isCloudflareShieldSuppressed() else {
            logCloudflareState("challenge ignored while shield is suppressed base=\(baseURLString)")
            setCloudflareShieldButtonVisible(false, animated: true)
            return
        }
        logCloudflareState("challenge detected; starting background verification base=\(baseURLString)")
        guard !isPresentingCloudflareVerification else {
            logCloudflareState("background verification skipped because foreground verification is active base=\(baseURLString)")
            return
        }
        setCloudflareShieldButtonVisible(true, animated: true)
        CloudflareBackgroundVerificationService.shared.ensureInBackground(
            baseURL: baseURL,
            reason: "container_challenge",
            responseURL: responseURL
        )
    }

    private func handleCloudflareNeedsUserInteraction(_ notification: Notification) {
        guard let baseURLString = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String else { return }
        guard normalizedBaseURL(baseURLString) == normalizedBaseURL(forum.baseURL) else { return }
        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURLString) {
            logCloudflareState("user-interaction prompt ignored during verification grace base=\(baseURLString)")
            return
        }
        guard let baseURL = URL(string: baseURLString) ?? URL(string: forum.baseURL) else { return }
        let responseURL = notification.userInfo?[DiscourseAPI.cloudflareResponseURLUserInfoKey] as? URL
        pendingCloudflareBaseURL = baseURL
        pendingCloudflareResponseURL = responseURL
        guard !isCloudflareShieldSuppressed(), !isCloudflareAutoPresentBlocked() else {
            logCloudflareState("needs-user ignored while shield is suppressed base=\(baseURLString)")
            setCloudflareShieldButtonVisible(!isCloudflareShieldSuppressed(), animated: true)
            return
        }
        guard !isPresentingCloudflareVerification else {
            logCloudflareState("needs-user ignored because foreground verification is already presented base=\(baseURLString)")
            return
        }
        // Background CF pass failed (API or image path). Auto-present the verification
        // sheet so the user is not stuck with blank images / only a tiny shield icon.
        logCloudflareState("background verification needs user; presenting verification sheet base=\(baseURLString)")
        setCloudflareShieldButtonVisible(true, animated: true)
        presentCloudflareVerification(baseURL: baseURL, responseURL: responseURL)
    }

    private func handleCloudflareVerificationCompleted(_ notification: Notification) {
        guard let baseURLString = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String else { return }
        guard normalizedBaseURL(baseURLString) == normalizedBaseURL(forum.baseURL) else { return }
        logCloudflareState("verification completed base=\(baseURLString)")
        CloudflareVerificationPolicy.markVerificationGrace(baseURL: baseURLString)
        pendingCloudflareBaseURL = nil
        pendingCloudflareResponseURL = nil
        suppressCloudflareShieldTemporarily()
        setCloudflareShieldButtonVisible(false, animated: true)
        api.resetSession()
        // Always clear presentation latch + dismiss leftover CF sheet so UI is not touch-blocked.
        dismissCloudflareSheetIfNeeded(animated: true)
        isPresentingCloudflareVerification = false
        // CF sheet is presented by this container, so Home never gets viewWillAppear
        // and a scroll-hidden / animation-stuck tab bar can stay gone after 出盾.
        restoreTabBarAfterCloudflareInteraction()
        // Unstick interaction on the whole container tree (transparent blockers / stuck flags).
        reenableInteractionAfterCloudflare()
        refreshVisiblePageAfterCloudflareVerification()
    }

    private func dismissCloudflareSheetIfNeeded(animated: Bool) {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            if let nav = presented as? UINavigationController,
               nav.viewControllers.contains(where: { $0 is CloudflareVerificationViewController }) {
                presented.dismiss(animated: animated)
                return
            }
            if presented is CloudflareVerificationViewController {
                presented.dismiss(animated: animated)
                return
            }
            presenter = presented
        }
    }

    private func reenableInteractionAfterCloudflare() {
        view.isUserInteractionEnabled = true
        children.forEach { child in
            child.view.isUserInteractionEnabled = true
            if let nav = child as? UINavigationController {
                nav.visibleViewController?.view.isUserInteractionEnabled = true
            }
            if let tab = child as? ForumTabBarController {
                tab.view.isUserInteractionEnabled = true
                tab.tabBar.isUserInteractionEnabled = true
                (tab.selectedViewController as? UINavigationController)?.visibleViewController?.view.isUserInteractionEnabled = true
            }
        }
        // Auth sync overlay must never stay up after CF (full-screen touch sink).
        if !authSyncOverlayView.isHidden {
            hideAuthSyncOverlay(animated: false)
        }
    }

    private func refreshVisiblePageAfterCloudflareVerification() {
        guard let tabBar = children.first as? ForumTabBarController,
              let navigation = tabBar.selectedViewController as? UINavigationController,
              let visible = navigation.visibleViewController
        else { return }
        switch visible {
        case is HomeViewController:
            break
        case let topic as TopicDetailViewController:
            // Backup path: observer may miss if VC was mid-transition during sheet dismiss.
            topic.handleCloudflareVerificationCompleted(
                Notification(
                    name: DiscourseAPI.cloudflareVerificationCompletedNotification,
                    object: nil,
                    userInfo: [DiscourseAPI.cloudflareBaseURLUserInfoKey: forum.baseURL]
                )
            )
        case let chat as ChatTopicDetailViewController:
            chat.handleCloudflareVerificationCompleted(
                Notification(
                    name: DiscourseAPI.cloudflareVerificationCompletedNotification,
                    object: nil,
                    userInfo: [DiscourseAPI.cloudflareBaseURLUserInfoKey: forum.baseURL]
                )
            )
        case let me as MeViewController:
            me.refreshAfterCloudflareVerification()
        case let search as SearchViewController:
            search.refreshAfterCloudflareVerification()
        default:
            break
        }
    }

    private func suppressCloudflareShieldTemporarily() {
        cloudflareShieldSuppressedUntil = Date().addingTimeInterval(Self.cloudflareShieldSuppressionDuration)
    }

    private func isCloudflareShieldSuppressed(now: Date = Date()) -> Bool {
        guard let suppressedUntil = cloudflareShieldSuppressedUntil else { return false }
        if now < suppressedUntil {
            return true
        }
        cloudflareShieldSuppressedUntil = nil
        return false
    }

    private func setCloudflareShieldButtonVisible(_ visible: Bool, animated: Bool) {
        guard shouldShowCloudflareShieldButton != visible else {
            updateCloudflareShieldButtonVisibility(animated: animated)
            return
        }
        shouldShowCloudflareShieldButton = visible
        updateCloudflareShieldButtonVisibility(animated: animated)
    }

    private func updateCloudflareShieldButtonVisibility(animated: Bool) {
        let isVisible = shouldShowCloudflareShieldButton
        let updates = {
            self.cloudflareShieldButton.alpha = isVisible ? 1 : 0
        }
        let completion: (Bool) -> Void = { _ in
            self.cloudflareShieldButton.isHidden = !self.shouldShowCloudflareShieldButton
        }

        if isVisible {
            installCloudflareShieldButtonIfNeeded()
            cloudflareShieldButton.isHidden = false
        }

        guard animated else {
            updates()
            completion(true)
            return
        }

        DoerMotion.animate(
            duration: DoerMotion.quick,
            animations: updates
        ) { _ in
            completion(true)
        }
    }

    private func showAuthSyncOverlay(title: String, message: String, animated: Bool = true) {
        authSyncTitleLabel.text = title
        authSyncMessageLabel.text = message
        authSyncSpinner.color = AppSettings.shared.themeStyle.accentColor
        authSyncSpinner.startAnimating()
        view.bringSubviewToFront(authSyncOverlayView)
        authSyncOverlayView.isHidden = false

        let updates = {
            self.authSyncOverlayView.alpha = 1
        }
        guard animated else {
            updates()
            return
        }
        AnimationOptimizer.animateAlpha(authSyncOverlayView, to: 1, duration: 0.18)
    }

    private func hideAuthSyncOverlay(animated: Bool = true, completion: (() -> Void)? = nil) {
        let finish = {
            self.authSyncSpinner.stopAnimating()
            self.authSyncOverlayView.isHidden = true
            completion?()
        }
        let updates = {
            self.authSyncOverlayView.alpha = 0
        }
        guard animated else {
            updates()
            finish()
            return
        }
        AnimationOptimizer.animateAlpha(authSyncOverlayView, to: 0, duration: 0.20) {
            finish()
        }
    }

    private func presentCloudflareVerification(baseURL: URL, responseURL: URL?) {
        guard !isPresentingCloudflareVerification else {
            logCloudflareState("foreground verification skipped because verification is already presented")
            return
        }
        guard view.window != nil else { return }
        guard let presenter = topMostPresenter(), !presenter.isBeingDismissed else { return }

        pendingCloudflareBaseURL = baseURL
        pendingCloudflareResponseURL = responseURL
        isPresentingCloudflareVerification = true
        setCloudflareShieldButtonVisible(false, animated: true)
        Task { @MainActor [weak self] in
            await CloudflareBackgroundVerificationService.shared.beginForegroundVerification(
                baseURL: baseURL
            )
            guard let self, self.isPresentingCloudflareVerification else {
                CloudflareBackgroundVerificationService.shared.endForegroundVerification(
                    baseURL: baseURL
                )
                return
            }
            guard !presenter.isBeingDismissed, presenter.view.window != nil else {
                CloudflareBackgroundVerificationService.shared.endForegroundVerification(
                    baseURL: baseURL
                )
                self.handleCloudflareVerificationClosed()
                return
            }

            let vc = CloudflareVerificationViewController(
                baseURL: baseURL,
                responseURL: responseURL,
                autoDismissOnSuccess: true
            ) { [weak self] in
                CloudflareBackgroundVerificationService.shared.endForegroundVerification(
                    baseURL: baseURL
                )
                self?.handleCloudflareVerificationClosed()
            }
            let nav = UINavigationController(rootViewController: vc)
            nav.modalPresentationStyle = .pageSheet
            nav.isModalInPresentation = false
            if let sheet = nav.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 20
            }
            presenter.present(nav, animated: true)
        }
    }

    private func handleCloudflareVerificationClosed() {
        isPresentingCloudflareVerification = false
        restoreTabBarAfterCloudflareInteraction()
        if let pending = pendingCloudflareBaseURL,
           CloudflareVerificationPolicy.isInVerificationGrace(baseURL: pending) {
            setCloudflareShieldButtonVisible(false, animated: true)
            return
        }
        cloudflareAutoPresentBlockedUntil = Date().addingTimeInterval(60)
        guard pendingCloudflareBaseURL != nil, !isCloudflareShieldSuppressed() else { return }
        setCloudflareShieldButtonVisible(true, animated: true)
    }

    private func isCloudflareAutoPresentBlocked(now: Date = Date()) -> Bool {
        guard let until = cloudflareAutoPresentBlockedUntil else { return false }
        if now < until {
            return true
        }
        cloudflareAutoPresentBlockedUntil = nil
        return false
    }

    private func restoreTabBarAfterCloudflareInteraction() {
        guard let tabBar = tabBarViewController ?? (children.first as? ForumTabBarController) else { return }
        tabBar.forceRevealTabBarForRootContent()
        // Prefer the visible home root. topViewController may be a pushed detail
        // (hidesBottomBarWhenPushed); still re-assert when home itself is showing.
        guard let navigation = tabBar.selectedViewController as? UINavigationController else { return }
        if let home = navigation.visibleViewController as? HomeViewController {
            home.restoreTabBarAfterCloudflareVerification()
            return
        }
        if navigation.viewControllers.count == 1,
           let home = navigation.viewControllers.first as? HomeViewController {
            home.restoreTabBarAfterCloudflareVerification()
        }
    }

    private func topMostPresenter() -> UIViewController? {
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController {
            if let nav = presented as? UINavigationController,
               nav.viewControllers.first is CloudflareVerificationViewController {
                return nil
            }
            presenter = presented
        }
        return presenter
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }


    private func logCloudflareState(_ message: String) {
        DohDebugLog.record("container \(message)", subsystem: "CF")
    }

    // MARK: - Auth Actions

    private func performLogin() {
        presentWebLogin(preferredUsername: nil, then: {})
    }

    func performLogout() async {
        let baseURL = forum.baseURL
        authManager.logout(forum: forum)
        await WebCookieStore.shared.clearWebViewAuthCookies(for: baseURL)
        refreshForumFromDatabase()
    }

    // MARK: - AuthGating

    func requireAuth(preferredUsername: String?, then action: @escaping () -> Void) {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if preferredUsername == nil, authManager.isAuthenticated(for: baseURL) {
            action()
            return
        }

        // Switching accounts always forces a fresh login sheet.
        if preferredUsername == nil, authManager.hasWebSession(for: baseURL) {
            Task { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.showAuthSyncOverlay(
                        title: String(localized: "weblogin.restore.title"),
                        message: String(localized: "weblogin.restore.message")
                    )
                }
                let didRecover = await self.authManager.refreshWebSessionUserIfPossible(forum: self.forum)
                await MainActor.run {
                    self.refreshForumFromDatabase()
                    if didRecover {
                        self.hideAuthSyncOverlay {
                            action()
                        }
                    } else {
                        self.hideAuthSyncOverlay()
                        self.presentWebLogin(preferredUsername: nil, then: action)
                    }
                }
            }
            return
        }

        presentWebLogin(preferredUsername: preferredUsername, then: action)
    }

    private func presentWebLogin(preferredUsername: String?, then action: @escaping () -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let native = NativeLoginViewController(
                forum: self.forum,
                preferredUsername: preferredUsername,
                onBrowseWelcome: { [weak self] in
                    self?.showHomeWelcomePage()
                },
                onSuccess: { [weak self] cookies, userAgent in
                    guard let self else { return }
                    self.showAuthSyncOverlay(
                        title: String(localized: "weblogin.success.title"),
                        message: String(localized: "weblogin.success.message")
                    )
                    Task { @MainActor in
                        let didLogin = await self.authManager.loginViaWeb(
                            forum: self.forum,
                            cookies: cookies,
                            userAgent: userAgent
                        )
                        self.refreshForumFromDatabase()
                        guard didLogin else {
                            self.hideAuthSyncOverlay()
                            return
                        }
                        self.hideAuthSyncOverlay {
                            action()
                        }
                    }
                }
            )
            let nav = UINavigationController(rootViewController: native)
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        }
    }

    private func showHomeWelcomePage() {
        guard let tabBar = tabBarViewController else { return }
        if let index = tabBar.navigationControllers.firstIndex(where: {
            $0.viewControllers.contains(where: { $0 is HomeViewController })
        }) {
            tabBar.selectedIndex = index
            tabBar.navigationControllers[index].popToRootViewController(animated: false)
        }
    }

    private func refreshForumFromDatabase() {
        if let forums = try? DatabaseManager.shared.fetchAllForums(),
           let updated = forums.first(where: { $0.id == forum.id })
        {
            forum = updated
        }
    }

    func isAuthenticated() -> Bool {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return authManager.isAuthenticated(for: baseURL)
    }

    func currentUsername() -> String? {
        let baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return authManager.username(for: baseURL)
    }
}
