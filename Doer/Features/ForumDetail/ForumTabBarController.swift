import Combine
import UIKit

final class ForumTabBarController: UITabBarController {
    private let api: DiscourseAPI
    private let notificationCoordinator: ForumNotificationCoordinator
    private weak var authGate: AuthGating?
    private(set) var navigationControllers: [UINavigationController] = []
    var onNavigationControllersChanged: (() -> Void)?

    private var isTabBarHiddenByScroll = false
    private var isAnimatingScrollTabBar = false
    private var scrollTabBarAnimationID = 0
    private var settingsObservationToken: AnyCancellable?
    private var authObservationToken: AnyCancellable?
    private var pluginObservationToken: NSObjectProtocol?
    private var appLifecycleObservationToken: NSObjectProtocol?
    private var notificationObservationToken: AnyCancellable?
    private var meAvatarLoadTask: Task<Void, Never>?
    private var chatBadgeTask: Task<Void, Never>?
    private var lastChatBadgeCount = 0
    private var renderedMeAvatarKey: String?
    private var pendingMeAvatarKey: String?
    private var tabIdentifiers: [String] = []
    private var visibleTabItemIDs: [String] = []
    private var renderedLanguage = AppSettings.shared.appLanguage
    private var scrollExpandedLayoutSnapshots: [ObjectIdentifier: ScrollExpandedLayoutSnapshot] = [:]
    private var popGestureEnablers: [ObjectIdentifier: NavigationPopGestureEnabler] = [:]

    private var pluginScope: PluginScope {
        PluginScope(
            baseURL: api.baseURL,
            username: authGate?.currentUsername() ?? AuthManager.shared.username(for: api.baseURL)
        )
    }

    init(
        api: DiscourseAPI,
        authGate: AuthGating? = nil,
        notificationCoordinator: ForumNotificationCoordinator
    ) {
        self.api = api
        self.authGate = authGate
        self.notificationCoordinator = notificationCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor

        rebuildTabs(preservingIdentifier: nil)
        startObservingSettings()
        startObservingAuth()
        startObservingPlugins()
        startObservingApplicationLifecycle()
        startObservingNotifications()
        configureTabBarSurface()
        refreshMeTabAvatarIcon()
        applyNotificationBadge()
    }

    deinit {
        settingsObservationToken?.cancel()
        authObservationToken?.cancel()
        if let pluginObservationToken {
            NotificationCenter.default.removeObserver(pluginObservationToken)
        }
        if let appLifecycleObservationToken {
            NotificationCenter.default.removeObserver(appLifecycleObservationToken)
        }
        notificationObservationToken?.cancel()
        meAvatarLoadTask?.cancel()
        chatBadgeTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !isAnimatingScrollTabBar else { return }
        applyCurrentTabBarLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Only unstick *broken* visible state. Do NOT undo intentional scroll-hide
        // (isTabBarHiddenByScroll == true), otherwise after CF sheet / refresh the bar
        // refuses to auto-hide on the next upward scroll.
        guard !shouldHideTabBarForCurrentContent else { return }
        let transformStuck = tabBar.transform != .identity
        let brokenVisibleState = isTabBarHiddenByScroll == false
            && (tabBar.isHidden || isAnimatingScrollTabBar || transformStuck)
        if brokenVisibleState {
            // Quiet restore: forceReveal's delayed reassert pops on ProMotion.
            quietlyRestoreTabBarAfterOverlay()
            ensureTabBarOrderingAfterOverlay()
        }
    }

    func setTabBarHiddenByScroll(_ hidden: Bool, animated: Bool) {
        // Also recover when flag says visible but tabBar was left hidden by a
        // interrupted animation / layout pass (first-launch flakiness).
        let alreadyAligned = isTabBarHiddenByScroll == hidden
            && (hidden || (!tabBar.isHidden && tabBar.transform == .identity))
        guard !alreadyAligned else { return }
        isTabBarHiddenByScroll = hidden

        guard animated else {
            scrollTabBarAnimationID += 1
            isAnimatingScrollTabBar = false
            applyCurrentTabBarLayout()
            return
        }

        guard !shouldHideTabBarForCurrentContent else {
            scrollTabBarAnimationID += 1
            isAnimatingScrollTabBar = false
            applyCurrentTabBarLayout()
            return
        }

        let hiddenTransform = CGAffineTransform(translationX: 0, y: tabBarTotalHeight + 8)
        isAnimatingScrollTabBar = true
        scrollTabBarAnimationID += 1
        let animationID = scrollTabBarAnimationID

        let completion: (UIViewAnimatingPosition) -> Void = { [weak self] _ in
            guard let self, self.scrollTabBarAnimationID == animationID else { return }
            self.isAnimatingScrollTabBar = false
            guard self.isTabBarHiddenByScroll == hidden else { return }
            self.tabBar.isUserInteractionEnabled = !hidden
            if hidden {
                self.applyCurrentTabBarLayout()
            } else {
                self.configureTabBarSurface()
                self.applyCurrentTabBarLayout()
            }
        }

        if hidden {
            tabBar.isHidden = false
            tabBar.alpha = 1
            tabBar.transform = .identity
            tabBar.frame = tabBarFrame(hidden: false)
            tabBar.isUserInteractionEnabled = false
            view.bringSubviewToFront(tabBar)

            DoerMotion.animate(
                duration: DoerMotion.standard,
                animations: {
                    self.tabBar.transform = hiddenTransform
                    self.expandSelectedContentIntoTabBarArea()
                    self.view.layoutIfNeeded()
                },
                completion: completion
            )
        } else {
            tabBar.isHidden = false
            tabBar.alpha = 1
            tabBar.frame = tabBarFrame(hidden: false)
            tabBar.transform = hiddenTransform
            configureTabBarSurface()
            view.bringSubviewToFront(tabBar)

            DoerMotion.animate(
                duration: DoerMotion.standard,
                animations: {
                    self.restoreScrollExpandedContentLayout()
                    self.tabBar.transform = .identity
                    self.view.layoutIfNeeded()
                },
                completion: completion
            )
        }
    }

    func configureTabBarSurface() {
        let settings = AppSettings.shared
        let themeStyle = settings.themeStyle
        view.backgroundColor = themeStyle.topicListBackgroundColor

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()

        if themeStyle.prefersOpaqueChrome {
            appearance.backgroundColor = themeStyle.chromeBackgroundColor
            appearance.shadowColor = UIColor.separator.withAlphaComponent(0.45)
        } else if themeStyle == .systemDefault || themeStyle == .oled {
            appearance.backgroundColor = .systemBackground
            appearance.shadowColor = UIColor.separator.withAlphaComponent(0.35)
        } else {
            appearance.backgroundColor = themeStyle.contentBackgroundColor
            appearance.shadowColor = UIColor.separator.withAlphaComponent(0.35)
        }

        let normalTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: settings.tabBarItemFont(selected: false),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        let selectedTitleAttributes: [NSAttributedString.Key: Any] = [
            .font: settings.tabBarItemFont(selected: true),
            .foregroundColor: themeStyle.accentColor,
        ]
        [
            appearance.stackedLayoutAppearance,
            appearance.inlineLayoutAppearance,
            appearance.compactInlineLayoutAppearance,
        ].forEach { itemAppearance in
            itemAppearance.normal.titleTextAttributes = normalTitleAttributes
            itemAppearance.selected.titleTextAttributes = selectedTitleAttributes
            itemAppearance.normal.iconColor = UIColor.secondaryLabel.withAlphaComponent(0.78)
            itemAppearance.selected.iconColor = themeStyle.accentColor
        }

        let newColor = appearance.backgroundColor
        let applyBarColors = {
            self.tabBar.standardAppearance = appearance
            self.tabBar.scrollEdgeAppearance = appearance
            self.tabBar.backgroundColor = newColor
            self.tabBar.barTintColor = newColor
        }
        // Animating to true-black can blank the window until process restart.
        if themeStyle == .oled {
            applyBarColors()
        } else {
            let animator = DoerMotion.propertyAnimator(
                duration: DoerMotion.standard,
                timingParameters: DoerMotion.softSpring
            )
            animator.addAnimations(applyBarColors)
            animator.startAnimation()
        }

        tabBar.tintColor = themeStyle.accentColor
        tabBar.unselectedItemTintColor = UIColor.secondaryLabel.withAlphaComponent(0.78)
        tabBar.isOpaque = true
        tabBar.isTranslucent = false
        tabBar.alpha = 1
    }

    var visibleTabBarHeight: CGFloat {
        guard !isTabBarHiddenByScroll, !shouldHideTabBarForCurrentContent, !tabBar.isHidden else { return 0 }
        return tabBarTotalHeight
    }

    func syncTabBarVisibilityForCurrentContent() {
        scrollTabBarAnimationID += 1
        isAnimatingScrollTabBar = false
        applyCurrentTabBarLayout()
    }

    func reassertTabBarLayoutAfterApplicationActivation() {
        guard isViewLoaded else { return }
        scrollTabBarAnimationID += 1
        isAnimatingScrollTabBar = false
        tabBar.layer.removeAllAnimations()
        configureTabBarSurface()
        applyCurrentTabBarLayout()

        // UIKit may perform a delayed UITabBarController layout pass after app
        // activation. Re-apply our scroll-hidden state so it does not leave a
        // stale bottom safe-area slab while the tab bar is still hidden.
        Task { @MainActor in
            self.reassertCurrentTabBarLayoutIfLoaded()
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.reassertCurrentTabBarLayoutIfLoaded()
        }
    }

    /// Force the root tab bar back on screen after parent-presented modals
    /// (Cloudflare verification sheet, etc.) that never deliver viewWillAppear
    /// to Home, and after interrupted scroll-hide animations leave the bar stuck.
    func forceRevealTabBarForRootContent() {
        guard !shouldHideTabBarForCurrentContent else {
            scrollTabBarAnimationID += 1
            isAnimatingScrollTabBar = false
            applyCurrentTabBarLayout()
            return
        }
        scrollTabBarAnimationID += 1
        isAnimatingScrollTabBar = false
        isTabBarHiddenByScroll = false
        // Hard reset any in-flight hide animation / expanded content coverage.
        tabBar.layer.removeAllAnimations()
        tabBar.transform = .identity
        tabBar.alpha = 1
        tabBar.isHidden = false
        tabBar.isUserInteractionEnabled = true
        applyVisibleTabBarLayout()
        view.bringSubviewToFront(tabBar)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        // CF sheet dismiss / system layout can thrash frames one beat later.
        Task { @MainActor in
            self.reassertVisibleTabBarIfNeeded()
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.reassertVisibleTabBarIfNeeded()
        }
    }

    /// Mini-program drawer/host dismiss path: restore bar geometry without the
    /// delayed async reassert / bring-to-front thrash that reads as a post-close pop.
    func quietlyRestoreTabBarAfterOverlay() {
        guard !shouldHideTabBarForCurrentContent else {
            scrollTabBarAnimationID += 1
            isAnimatingScrollTabBar = false
            applyCurrentTabBarLayout()
            return
        }
        scrollTabBarAnimationID += 1
        isAnimatingScrollTabBar = false
        isTabBarHiddenByScroll = false
        tabBar.layer.removeAllAnimations()
        tabBar.transform = .identity
        tabBar.alpha = 1
        tabBar.isHidden = false
        tabBar.isUserInteractionEnabled = true
        // Full-bleed content under bar; skip applyVisibleTabBarLayout's async
        // bringSubviewToFront pass (it pops the bar over an animating drawer).
        fillSelectedContentUnderTabBar()
        tabBar.frame = tabBarFrame(hidden: false)
        configureTabBarSurface()
    }

    /// After an overlay (drawer) is fully hidden, put the bar above content once.
    func ensureTabBarOrderingAfterOverlay() {
        guard !isTabBarHiddenByScroll, !shouldHideTabBarForCurrentContent else { return }
        guard !tabBar.isHidden else { return }
        view.bringSubviewToFront(tabBar)
    }

    private func reassertVisibleTabBarIfNeeded() {
        guard !isTabBarHiddenByScroll, !shouldHideTabBarForCurrentContent else { return }
        tabBar.layer.removeAllAnimations()
        tabBar.isHidden = false
        tabBar.alpha = 1
        tabBar.transform = .identity
        tabBar.isUserInteractionEnabled = true
        // Keep page full-bleed under the bar; never shrink content above it.
        fillSelectedContentUnderTabBar()
        tabBar.frame = tabBarFrame(hidden: false)
        configureTabBarSurface()
        view.bringSubviewToFront(tabBar)
    }

    var tabBarTotalHeight: CGFloat {
        return max(tabBar.bounds.height, tabBar.frame.height, 49 + view.safeAreaInsets.bottom)
    }

    private var shouldHideTabBarForCurrentContent: Bool {
        guard let navigationController = selectedViewController as? UINavigationController,
              let visibleViewController = navigationController.visibleViewController
        else {
            return false
        }
        if let browser = visibleViewController as? InAppBrowserViewController,
           browser.hidesHostTabBarAtRoot {
            return true
        }
        guard visibleViewController !== navigationController.viewControllers.first else { return false }
        return visibleViewController.hidesBottomBarWhenPushed
    }

    private var shouldExpandContentForHiddenRootTabBar: Bool {
        guard let navigationController = selectedViewController as? UINavigationController,
              let browser = navigationController.visibleViewController as? InAppBrowserViewController
        else { return false }
        return browser.hidesHostTabBarAtRoot
    }

    private func applyCurrentTabBarLayout() {
        if shouldHideTabBarForCurrentContent {
            applyHiddenTabBarLayout(expandsSelectedContent: shouldExpandContentForHiddenRootTabBar)
        } else if isTabBarHiddenByScroll {
            applyHiddenTabBarLayout(expandsSelectedContent: true)
        } else {
            applyVisibleTabBarLayout()
        }
    }

    private func applyHiddenTabBarLayout(expandsSelectedContent: Bool) {
        tabBar.isHidden = true
        tabBar.alpha = 1
        tabBar.transform = .identity
        tabBar.frame = tabBarFrame(hidden: true)
        tabBar.isUserInteractionEnabled = false
        if expandsSelectedContent {
            expandSelectedContentIntoTabBarArea()
        } else {
            restoreScrollExpandedContentLayout()
        }
    }

    private func applyVisibleTabBarLayout() {
        // Scroll-hide model: page content is always full-bleed under the tab bar.
        // Home pads the list with contentInset.bottom = visibleTabBarHeight.
        // Shrinking the selected container to sit *above* the bar while still
        // applying that inset produced a permanent blank strip ("高出一块").
        fillSelectedContentUnderTabBar()
        tabBar.isHidden = false
        tabBar.alpha = 1
        tabBar.transform = .identity
        tabBar.frame = tabBarFrame(hidden: false)
        tabBar.isUserInteractionEnabled = true
        view.bringSubviewToFront(tabBar)
        // No async second pass: on ProMotion devices the delayed bring-to-front
        // after mini-program / modal dismiss reads as a bottom pop.
    }

    /// Make the selected tab's container fill the tab bar controller bounds so
    /// the bar overlays content. Clears scroll-hide snapshots that may point at
    /// a short "above bar" frame from an older layout pass.
    private func fillSelectedContentUnderTabBar() {
        scrollExpandedLayoutSnapshots.removeAll()
        let bounds = view.bounds
        // Normalize *all* tab containers. Scroll-hide expand can leave a non-selected
        // tab with clipsToBounds=false / oversized frame; that peeks as a gray edge
        // strip on 通知 / 我的 / 浏览历史 / 书签 ("上去了一块").
        for controller in viewControllers ?? [] {
            normalizeTabContentFrame(controller, bounds: bounds, isSelected: controller === selectedViewController)
        }
    }

    private func normalizeTabContentFrame(
        _ viewController: UIViewController,
        bounds: CGRect,
        isSelected: Bool
    ) {
        var didChangeFrame = false
        if let container = viewController.view.superview, container !== view {
            if container.frame != bounds {
                container.frame = bounds
                didChangeFrame = true
            }
            container.clipsToBounds = true
            if viewController.view.frame != container.bounds {
                viewController.view.frame = container.bounds
                didChangeFrame = true
            }
        } else if viewController.view.frame != bounds {
            viewController.view.frame = bounds
            didChangeFrame = true
        }
        viewController.view.clipsToBounds = true

        guard isSelected,
              let navigationController = viewController as? UINavigationController,
              let visibleView = navigationController.visibleViewController?.view
        else {
            if didChangeFrame {
                viewController.view.setNeedsLayout()
            }
            return
        }

        let navBounds = navigationController.view.bounds
        if let wrapperView = visibleView.superview, wrapperView !== navigationController.view {
            if wrapperView.frame != navBounds {
                wrapperView.frame = navBounds
                didChangeFrame = true
            }
            wrapperView.clipsToBounds = true
            if visibleView.frame != wrapperView.bounds {
                visibleView.frame = wrapperView.bounds
                didChangeFrame = true
            }
        } else if visibleView.frame != navBounds {
            visibleView.frame = navBounds
            didChangeFrame = true
        }
        visibleView.clipsToBounds = true
        if didChangeFrame {
            visibleView.setNeedsLayout()
            viewController.view.setNeedsLayout()
        }
    }

    private func tabBarFrame(hidden: Bool) -> CGRect {
        let height = tabBarTotalHeight
        let y = hidden ? view.bounds.maxY : view.bounds.maxY - height
        return CGRect(x: 0, y: y, width: view.bounds.width, height: height)
    }

    private func expandSelectedContentIntoTabBarArea() {
        guard let selectedView = selectedViewController?.view else { return }
        // Keep non-selected tabs clipped so they never leak a gray edge over siblings.
        for controller in viewControllers ?? [] where controller !== selectedViewController {
            controller.view.clipsToBounds = true
            controller.view.superview?.clipsToBounds = true
        }
        if let contentContainer = selectedView.superview {
            storeScrollExpandedLayoutSnapshot(for: contentContainer)
            storeScrollExpandedLayoutSnapshot(for: selectedView)
            contentContainer.clipsToBounds = false
            contentContainer.frame = view.bounds
            view.bringSubviewToFront(contentContainer)
            selectedView.frame = contentContainer.bounds
        } else {
            storeScrollExpandedLayoutSnapshot(for: selectedView)
            selectedView.frame = view.bounds
        }
        selectedView.clipsToBounds = false
        selectedView.setNeedsLayout()
        selectedView.layoutIfNeeded()

        if let navigationController = selectedViewController as? UINavigationController,
           let visibleView = navigationController.visibleViewController?.view {
            expandNavigationContentView(visibleView, in: navigationController.view.bounds)
        }
        view.bringSubviewToFront(tabBar)
    }

    private func expandNavigationContentView(_ contentView: UIView, in bounds: CGRect) {
        if let wrapperView = contentView.superview {
            storeScrollExpandedLayoutSnapshot(for: wrapperView)
            storeScrollExpandedLayoutSnapshot(for: contentView)
            wrapperView.clipsToBounds = false
            wrapperView.frame = bounds
            contentView.frame = wrapperView.bounds
        } else {
            storeScrollExpandedLayoutSnapshot(for: contentView)
            contentView.frame = bounds
        }
        contentView.clipsToBounds = false
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
    }

    private func storeScrollExpandedLayoutSnapshot(for view: UIView) {
        let identifier = ObjectIdentifier(view)
        guard scrollExpandedLayoutSnapshots[identifier] == nil else { return }
        scrollExpandedLayoutSnapshots[identifier] = ScrollExpandedLayoutSnapshot(
            view: view,
            frame: view.frame,
            clipsToBounds: view.clipsToBounds
        )
    }

    private func restoreScrollExpandedContentLayout() {
        guard !scrollExpandedLayoutSnapshots.isEmpty else { return }
        let snapshots = scrollExpandedLayoutSnapshots.values
        scrollExpandedLayoutSnapshots.removeAll()
        for snapshot in snapshots {
            guard let view = snapshot.view else { continue }
            view.frame = snapshot.frame
            view.clipsToBounds = snapshot.clipsToBounds
            view.setNeedsLayout()
        }
        selectedViewController?.view.setNeedsLayout()
        selectedViewController?.view.layoutIfNeeded()
    }

}

private extension ForumTabBarController {
    struct ScrollExpandedLayoutSnapshot {
        weak var view: UIView?
        let frame: CGRect
        let clipsToBounds: Bool
    }

    struct TabSpec {
        let identifier: String
        let title: String
        let symbolName: String
        let makeViewController: () -> UIViewController
    }

    func startObservingSettings() {
        settingsObservationToken = AppSettings.shared.objectWillChange.sink { [weak self] in
            self?.handleSettingsChanged()
        }
    }

    func startObservingAuth() {
        authObservationToken = AuthManager.shared.objectWillChange.sink { [weak self] in
            guard let self else { return }
            self.refreshMeTabAvatarIcon(forceRefresh: true)
            self.rebuildTabs(preservingIdentifier: self.selectedTabIdentifier())
        }
    }

    func startObservingPlugins() {
        pluginObservationToken = NotificationCenter.default.addObserver(
            forName: PluginStateStore.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let changedScope = notification.userInfo?[PluginStateStore.scopeUserInfoKey] as? String,
               changedScope != self.pluginScope.storageKey {
                return
            }
            self.rebuildTabs(preservingIdentifier: self.selectedTabIdentifier())
        }
    }

    func startObservingApplicationLifecycle() {
        appLifecycleObservationToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reassertTabBarLayoutAfterApplicationActivation()
            self?.refreshChatTabBadge()
        }
    }

    func reassertCurrentTabBarLayoutIfLoaded() {
        guard isViewLoaded, view.window != nil else { return }
        applyCurrentTabBarLayout()
    }

    func startObservingNotifications() {
        notificationObservationToken = notificationCoordinator.objectWillChange.sink { [weak self] in
            self?.applyNotificationBadge()
        }
    }

    func handleSettingsChanged() {
        resetScrollHiddenTabBarForSettingsChange()
        configureTabBarSurface()
        applyCurrentTabBarLayout()
        let currentLanguage = AppSettings.shared.appLanguage
        let languageChanged = currentLanguage != renderedLanguage
        renderedLanguage = currentLanguage

        let newVisibleItems = AppSettings.shared.forumVisibleConfiguredTabItemIDs
        if newVisibleItems != visibleTabItemIDs {
            rebuildTabs(preservingIdentifier: selectedTabIdentifier())
            return
        }
        if languageChanged {
            refreshLocalizedTabTitles()
        }
    }

    func resetScrollHiddenTabBarForSettingsChange() {
        scrollTabBarAnimationID += 1
        isAnimatingScrollTabBar = false
        isTabBarHiddenByScroll = false
    }

    func rebuildTabs(preservingIdentifier preferredIdentifier: String?) {
        let specs = buildTabSpecs()
        let existingControllers = Dictionary(uniqueKeysWithValues: zip(tabIdentifiers, navigationControllers))
        var controllers: [UINavigationController] = []
        var identifiers: [String] = []

        for (index, spec) in specs.enumerated() {
            let navigationController: UINavigationController
            if let existingController = existingControllers[spec.identifier] {
                navigationController = existingController
                navigationController.viewControllers.first?.title = spec.title
            } else {
                let rootViewController = spec.makeViewController()
                rootViewController.title = spec.title
                navigationController = UINavigationController(rootViewController: rootViewController)
            }
            navigationController.delegate = self
            let enabler = popGestureEnablers[ObjectIdentifier(navigationController)] ?? NavigationPopGestureEnabler()
            enabler.attach(to: navigationController)
            popGestureEnablers[ObjectIdentifier(navigationController)] = enabler
            navigationController.tabBarItem.title = spec.title
            if spec.identifier != "me" || renderedMeAvatarKey == nil {
                navigationController.tabBarItem.image = DoerTabBarIconStyle.image(
                    identifier: spec.identifier,
                    fallbackSymbolName: spec.symbolName,
                    selected: false
                )
                navigationController.tabBarItem.selectedImage = DoerTabBarIconStyle.image(
                    identifier: spec.identifier,
                    fallbackSymbolName: spec.symbolName,
                    selected: true
                )
            }
            navigationController.tabBarItem.tag = index
            navigationController.tabBarItem.imageInsets = UIEdgeInsets(top: -1, left: 0, bottom: 1, right: 0)
            navigationController.tabBarItem.accessibilityIdentifier = "forum.tab.\(spec.identifier)"
            controllers.append(navigationController)
            identifiers.append(spec.identifier)
        }

        navigationControllers = controllers
        tabIdentifiers = identifiers
        visibleTabItemIDs = AppSettings.shared.forumVisibleConfiguredTabItemIDs

        // Use the classic API on every supported OS. A controller returned by a custom
        // `UITab` cannot also be owned by the tabs synthesized from `viewControllers`.
        viewControllers = controllers

        let selectedIdentifier = preferredIdentifier ?? "home"
        if let selectedIndex = identifiers.firstIndex(of: selectedIdentifier) {
            self.selectedIndex = selectedIndex
        } else {
            self.selectedIndex = 0
        }

        configureTabBarSurface()
        refreshMeTabAvatarIcon()
        applyNotificationBadge()
        applyChatTabBadge(lastChatBadgeCount)
        refreshChatTabBadge()
        onNavigationControllersChanged?()
    }

    func selectedTabIdentifier() -> String? {
        guard selectedIndex >= 0, selectedIndex < tabIdentifiers.count else { return nil }
        return tabIdentifiers[selectedIndex]
    }

    func refreshMeTabAvatarIcon(forceRefresh: Bool = false) {
        guard let meIndex = tabIdentifiers.firstIndex(of: "me"),
              meIndex < navigationControllers.count
        else { return }

        let authManager = AuthManager.shared
        guard authManager.isAuthenticated(for: api.baseURL) else {
            meAvatarLoadTask?.cancel()
            meAvatarLoadTask = nil
            pendingMeAvatarKey = nil
            renderedMeAvatarKey = nil
            applyDefaultMeTabIcon(at: meIndex)
            return
        }

        let username = authManager.username(for: api.baseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let avatarKey = meAvatarKey(username: username)

        if !forceRefresh, renderedMeAvatarKey == avatarKey {
            return
        }

        if let username, !username.isEmpty,
           let cachedEntry = MeProfileCacheStore.cachedProfile(baseURL: api.baseURL, username: username) {
            let avatarTemplate = cachedEntry.userProfile.avatarTemplate ?? cachedEntry.currentUser.avatarTemplate
            applyMeTabAvatar(template: avatarTemplate, at: meIndex, avatarKey: avatarKey)
            return
        }

        guard pendingMeAvatarKey != avatarKey else { return }
        pendingMeAvatarKey = avatarKey
        meAvatarLoadTask?.cancel()
        meAvatarLoadTask = Task { [weak self, api] in
            do {
                let currentUser = try await api.fetchCurrentUser()
                await MainActor.run {
                    guard let self else { return }
                    self.pendingMeAvatarKey = nil
                    self.meAvatarLoadTask = nil
                    guard AuthManager.shared.isAuthenticated(for: self.api.baseURL) else {
                        self.renderedMeAvatarKey = nil
                        self.applyDefaultMeTabIcon(at: meIndex)
                        return
                    }
                    self.applyMeTabAvatar(
                        template: currentUser.avatarTemplate,
                        at: meIndex,
                        avatarKey: self.meAvatarKey(username: currentUser.username)
                    )
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.pendingMeAvatarKey = nil
                    self.meAvatarLoadTask = nil
                    if !AuthManager.shared.isAuthenticated(for: self.api.baseURL) {
                        self.renderedMeAvatarKey = nil
                        self.applyDefaultMeTabIcon(at: meIndex)
                    }
                }
            }
        }
    }

    func applyMeTabAvatar(template: String?, at index: Int, avatarKey: String) {
        guard let url = AvatarImageLoader.url(from: template, baseURL: api.baseURL, size: 96) else {
            renderedMeAvatarKey = nil
            applyDefaultMeTabIcon(at: index)
            return
        }

        let requestedKey = avatarKey
        ForumImageLoader.loadImage(with: url) { [weak self] image in
            guard let self, let image else { return }
            guard AuthManager.shared.isAuthenticated(for: self.api.baseURL) else { return }
            let currentUsername = AuthManager.shared.username(for: self.api.baseURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let currentUsername, !currentUsername.isEmpty,
               self.meAvatarKey(username: currentUsername) != requestedKey {
                return
            }
            let normalImage = DoerTabBarIconStyle.avatarImage(
                image,
                selected: false,
                accentColor: AppSettings.shared.themeStyle.accentColor
            )
            let selectedImage = DoerTabBarIconStyle.avatarImage(
                image,
                selected: true,
                accentColor: AppSettings.shared.themeStyle.accentColor
            )
            self.applyMeTabImages(normalImage: normalImage, selectedImage: selectedImage, at: index)
            self.renderedMeAvatarKey = requestedKey
        }
    }

    func applyDefaultMeTabIcon(at index: Int) {
        let normalImage = DoerTabBarIconStyle.image(identifier: "me", fallbackSymbolName: "person", selected: false)
        let selectedImage = DoerTabBarIconStyle.image(identifier: "me", fallbackSymbolName: "person", selected: true)
        applyMeTabImages(normalImage: normalImage, selectedImage: selectedImage, at: index)
    }

    func applyMeTabImages(normalImage: UIImage?, selectedImage: UIImage?, at index: Int) {
        guard index >= 0, index < navigationControllers.count else { return }
        guard let tabBarItem = navigationControllers[index].tabBarItem else { return }
        tabBarItem.image = normalImage
        tabBarItem.selectedImage = selectedImage
        tabBarItem.imageInsets = UIEdgeInsets(top: -1, left: 0, bottom: 1, right: 0)
        tabBar.setNeedsLayout()
    }

    func meAvatarKey(username: String?) -> String {
        let baseURL = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let userPart = username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(baseURL)|\(userPart?.isEmpty == false ? userPart! : "_authenticated")"
    }

    func refreshLocalizedTabTitles() {
        let specs = buildTabSpecs()
        for (index, navigationController) in navigationControllers.enumerated() where index < specs.count {
            let spec = specs[index]
            navigationController.tabBarItem.title = spec.title
            navigationController.viewControllers.first?.title = spec.title
        }
        refreshMeTabAvatarIcon()
        onNavigationControllersChanged?()
    }

    func buildTabSpecs() -> [TabSpec] {
        var specs: [TabSpec] = [
            TabSpec(
                identifier: "home",
                title: String(localized: "tab.home"),
                symbolName: "house"
            ) { [api, authGate, notificationCoordinator] in
                HomeViewController(
                    api: api,
                    authGate: authGate,
                    notificationCoordinator: notificationCoordinator
                )
            },
        ]

        let pluginTabs = Dictionary(uniqueKeysWithValues: DoerPluginRuntime.shared.registry
            .contributions(of: .forumTab, for: pluginScope)
            .map { registration in
                (AppSettings.pluginForumTabItemID(
                    pluginID: registration.plugin.id,
                    contributionID: registration.contribution.id
                ), registration)
            })
        pruneStalePluginTabItemIDs(validPluginTabs: pluginTabs)
        let configuredSpecs = AppSettings.shared.forumVisibleConfiguredTabItemIDs.compactMap { itemID -> TabSpec? in
            if let systemItem = AppSettings.ForumDynamicTabItem.storedValue(itemID) {
                return dynamicTabSpec(for: systemItem)
            }
            guard let registration = pluginTabs[itemID] else { return nil }
            return pluginTabSpec(for: registration)
        }
        specs.append(contentsOf: configuredSpecs)

        specs.append(
            TabSpec(
                identifier: "me",
                title: String(localized: "tab.me"),
                symbolName: "person"
            ) { [api, authGate] in
                MeViewController(api: api, authGate: authGate)
            }
        )

        return specs
    }

    func pruneStalePluginTabItemIDs(validPluginTabs: [String: PluginContributionRegistration]) {
        let retiredFirstPartyIDs = [
            BuiltInPluginID.newAPICheckIn,
            BuiltInPluginID.ldcStore,
        ]
        let current = AppSettings.shared.forumConfiguredTabItemIDs
        let pruned = current.filter { itemID in
            if AppSettings.ForumDynamicTabItem.storedValue(itemID) != nil {
                return true
            }
            // NewAPI / LD 士多 are first-party Me mini-programs — never resurrect as tabs.
            if retiredFirstPartyIDs.contains(where: { itemID.contains($0) }) {
                return false
            }
            return validPluginTabs[itemID] != nil
        }
        if pruned != current {
            AppSettings.shared.forumConfiguredTabItemIDs = pruned
        }
    }

    func pluginTabSpec(for registration: PluginContributionRegistration) -> TabSpec? {
        // NewAPI / LD 士多 no longer contribute forum.tab; they launch as mini-programs from Me.
        // Keep this hook for any future real forum.tab plugins.
        let identifier = "plugin.\(registration.plugin.id).\(registration.contribution.id)"
        let title = registration.contribution.titleFallback ?? registration.plugin.displayName
        _ = (identifier, title, registration)
        return nil
    }

    func dynamicTabSpec(for item: AppSettings.ForumDynamicTabItem) -> TabSpec {
        TabSpec(
            identifier: item.rawValue,
            title: item.title,
            symbolName: item.symbolName
        ) { [api, authGate, notificationCoordinator] in
            switch item {
            case .history:
                return BrowsingHistoryViewController(api: api, authGate: authGate)
            case .search:
                return SearchViewController(api: api)
            case .notifications:
                return NotificationsViewController(
                    api: api,
                    authGate: authGate,
                    notificationCoordinator: notificationCoordinator
                )
            case .messages:
                let controller = MessagesViewController(api: api, authGate: authGate)
                controller.hidesBottomBarWhenPushed = false
                return controller
            case .bookmarks:
                return BookmarksViewController(api: api, authGate: authGate)
            }
        }
    }

    func applyNotificationBadge() {
        for identifier in ["home", "notifications"] {
            guard let index = tabIdentifiers.firstIndex(of: identifier),
                  index < navigationControllers.count
            else { continue }
            navigationControllers[index].tabBarItem.badgeValue = nil
        }

        let targetIdentifier = tabIdentifiers.contains("notifications") ? "notifications" : "home"
        guard let index = tabIdentifiers.firstIndex(of: targetIdentifier),
              index < navigationControllers.count
        else { return }
        let unreadCount = notificationCoordinator.unreadCount
        let badgeValue = unreadCount > 0 ? (unreadCount > 99 ? "99+" : String(unreadCount)) : nil
        navigationControllers[index].tabBarItem.badgeValue = badgeValue
        navigationControllers[index].tabBarItem.badgeColor = .systemRed
    }

    func refreshChatTabBadge() {
        chatBadgeTask?.cancel()
        chatBadgeTask = Task { [weak self, api] in
            guard let self else { return }
            let authenticated = AuthManager.shared.isAuthenticated(for: api.baseURL)
            guard authenticated else {
                await MainActor.run { self.applyChatTabBadge(0) }
                return
            }
            do {
                let count = try await api.fetchChatChannels().entryBadgeCount
                guard !Task.isCancelled else { return }
                await MainActor.run { self.applyChatTabBadge(count) }
            } catch {
                // Keep the last known chat badge on a transient miss.
            }
        }
    }

    func applyChatTabBadge(_ count: Int) {
        lastChatBadgeCount = count
        guard let index = tabIdentifiers.firstIndex(of: "me"),
              index < navigationControllers.count
        else { return }
        let item = navigationControllers[index].tabBarItem
        item?.badgeValue = DiscourseChatChannelsResponse.badgeText(for: count)
        item?.badgeColor = .systemRed
    }
}

extension ForumTabBarController: UITabBarControllerDelegate {
    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        // Drop scroll-hide residue so non-home tabs never inherit Home's expanded chrome.
        isTabBarHiddenByScroll = false
        isAnimatingScrollTabBar = false
        scrollTabBarAnimationID += 1
        applyCurrentTabBarLayout()
        view.bringSubviewToFront(tabBar)
    }
}

extension ForumTabBarController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        switch operation {
        case .push where toVC is TopicDetailViewController:
            return TopicDetailNavigationAnimator(operation: .push)
        default:
            return nil
        }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        TopicDetailTransitionGeometry.normalize(viewController.view)
        let allowsSystemPop = navigationController.viewControllers.count > 1
        navigationController.interactivePopGestureRecognizer?.isEnabled = allowsSystemPop
        if allowsSystemPop {
            popGestureEnablers[ObjectIdentifier(navigationController)]?.attach(to: navigationController)
        }
        if navigationController.viewControllers.count > 1 {
            isTabBarHiddenByScroll = false
        }
        isAnimatingScrollTabBar = false
        applyCurrentTabBarLayout()
    }
}
