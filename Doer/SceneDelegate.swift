import UIKit

enum DoerLaunchAppearance {
    static let backgroundColorName = "LaunchBackground"
    static let backgroundColor = UIColor(named: backgroundColorName)
        ?? UIColor(red: 0.946, green: 0.944, blue: 0.922, alpha: 1)
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        let window = UIWindow(windowScene: windowScene)
        self.window = window
        AppSettings.shared.applyAppearance()
        window.backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
        let defaultForum = DatabaseManager.shared.defaultForum()
        DohDebugLog.record(
            "scene willConnect forum=\(defaultForum.baseURL) theme=\(AppSettings.shared.themeStyle.rawValue)",
            subsystem: "Launch"
        )
        window.rootViewController = ForumContainerViewController(forum: defaultForum, showsDismissButton: false)
        window.makeKeyAndVisible()

        // Cold-start from notification tap (in addition to UNUserNotificationCenterDelegate).
        if let response = connectionOptions.notificationResponse {
            enqueueNotificationRoute(from: response.notification.request.content.userInfo)
            ForumNotificationRoutePresenter.presentPendingRouteIfNeeded(in: window)
        }
        // Cold-start / warm URL contexts (doer:// or https://forum/t/…).
        for context in connectionOptions.urlContexts {
            handleIncomingURL(context.url)
        }
        if let activity = connectionOptions.userActivities.first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb }),
           let url = activity.webpageURL {
            handleIncomingURL(url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            handleIncomingURL(context.url)
        }
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL {
            handleIncomingURL(url)
        }
    }

    private func handleIncomingURL(_ url: URL) {
        let baseURL = DatabaseManager.shared.defaultForum().baseURL
        _ = DoerDeepLinkRouter.handle(url, defaultBaseURL: baseURL)
        if let window {
            ForumNotificationRoutePresenter.presentPendingRouteIfNeeded(in: window)
            DoerInAppRoutePresenter.presentPendingIfNeeded(in: window)
        }
    }

    private func enqueueNotificationRoute(from userInfo: [AnyHashable: Any]) {
        guard let route = ForumNotificationRoute.from(userInfo: userInfo) else { return }
        ForumNotificationRouteStore.shared.enqueue(route)
    }

    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {
        refreshWebSessionAfterForeground(reason: "scene_did_become_active")
        if let window {
            ForumNotificationRoutePresenter.presentPendingRouteIfNeeded(in: window)
            if let container = window.rootViewController as? ForumContainerViewController {
                container.presentClipboardTopicLinkIfNeeded()
                container.presentPendingInAppRouteIfNeeded()
            } else if let container = window.rootViewController?.children.compactMap({ $0 as? ForumContainerViewController }).first {
                container.presentClipboardTopicLinkIfNeeded()
                container.presentPendingInAppRouteIfNeeded()
            }
            DoerInAppRoutePresenter.presentPendingIfNeeded(in: window)
        }
    }
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {
        LightweightDohProxyService.shared.ensureProxyAlive()
        ConnectivityService.shared.check()
        refreshWebSessionAfterForeground(reason: "scene_will_enter_foreground")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
//        ProxyManager.shared.stop()
        BackgroundNotificationRefreshService.shared.scheduleIfNeeded()
    }

    private func refreshWebSessionAfterForeground(reason: String) {
        let forum = DatabaseManager.shared.defaultForum()
        guard AuthManager.shared.hasWebSession(for: forum.baseURL) else { return }
        WebSessionRefreshService.shared.ensureInBackground(forum: forum, reason: reason)
    }
}
