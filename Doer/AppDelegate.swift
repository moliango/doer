//
//  AppDelegate.swift
//  doer
//
//  Created by Eilgnaw on 3/21/26.
//

import SDWebImage
import UIKit
import UserNotifications

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Repair Library/Caches if a file occupies a directory path (ENOTDIR / Code=512),
        // and pin SDWebImage disk root before any shared cache access.
        AppStorageBootstrap.prepareAtLaunch()
        AppSettings.shared.applyLanguage()
        AppSettings.shared.installGlobalFontSupport()
        BackgroundNotificationRefreshService.shared.register()
        BackgroundNotificationRefreshService.shared.scheduleIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        APNsPushRegistration.register()
        MitmTrust.installWKWebViewHook()
        LightweightDohProxyService.shared.configureFromSettings()
        AvatarImageLoader.configureGlobalImageLoading()
        // Only wipe caches when the user explicitly enabled "clear on launch".
        // Otherwise process + disk avatar caches persist across launches.
        if AppSettings.shared.clearImageCacheOnLaunch {
            AvatarImageLoader.clearAllCaches()
        }
        // FluxDo-style connectivity: path monitor + offline retry/backoff.
        ConnectivityService.shared.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        APNsPushRegistration.storeDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DohDebugLog.record("apns register failed \(error.localizedDescription)", subsystem: "Push")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        APNsPushRegistration.handleRemoteNotification(
            userInfo: userInfo,
            fetchCompletionHandler: completionHandler
        )
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let route = ForumNotificationRoute.from(userInfo: userInfo) else { return }
        await MainActor.run {
            ForumNotificationRouteStore.shared.enqueue(route)
            ForumNotificationRoutePresenter.presentPendingRouteIfNeeded()
        }
    }
}
