import Foundation

@MainActor
final class BackgroundNotificationDeliveryPipeline {
    static let shared = BackgroundNotificationDeliveryPipeline(
        syncEngine: .shared,
        presenter: ForumLocalNotificationPresenter.shared,
        deliveryStore: .shared
    )

    private let syncEngine: BackgroundNotificationSyncEngine
    private let presenter: ForumLocalNotificationPresenting
    private let deliveryStore: ForumNotificationDeliveryStore

    private init(
        syncEngine: BackgroundNotificationSyncEngine,
        presenter: ForumLocalNotificationPresenting,
        deliveryStore: ForumNotificationDeliveryStore
    ) {
        self.syncEngine = syncEngine
        self.presenter = presenter
        self.deliveryStore = deliveryStore
    }

    func refreshInBackground() async -> Bool {
        let result = await syncEngine.refreshEligibleForums()
        guard !result.wasCancelled, !Task.isCancelled else { return false }

        retainBadgeBaseURLs(result.eligibleBaseURLs)
        for failure in result.failures where failure.shouldClearBadge {
            presenter.removeApplicationBadge(baseURL: failure.baseURL)
        }
        for snapshot in result.snapshots {
            guard !Task.isCancelled else { return false }
            if let latestTopics = snapshot.latestTopics {
                BackgroundTopicUpdateStore.shared.processBackgroundSnapshot(
                    latestTopics,
                    baseURL: snapshot.forum.baseURL
                )
            }
            presenter.replaceApplicationBadge(
                snapshot.unreadCount,
                baseURL: snapshot.forum.baseURL,
                username: snapshot.username
            )

            deliveryStore.establishBaselineIfNeeded(
                snapshot.notifications,
                baseURL: snapshot.forum.baseURL,
                username: snapshot.username
            )
            let filter = AppSettings.shared.localNotificationFilter
            let filtered = snapshot.notifications.filter { filter.allows($0) }
            let candidates = deliveryStore.reservePendingNotifications(
                filtered,
                baseURL: snapshot.forum.baseURL,
                username: snapshot.username,
                limit: 3
            )
            guard !candidates.isEmpty else { continue }
            guard !Task.isCancelled else {
                deliveryStore.completeDeliveryAttempt(
                    requested: candidates,
                    delivered: [],
                    baseURL: snapshot.forum.baseURL,
                    username: snapshot.username
                )
                return false
            }
            let delivered = await presenter.deliver(
                notifications: candidates,
                baseURL: snapshot.forum.baseURL,
                authorizationPolicy: .existingOnly
            )
            deliveryStore.completeDeliveryAttempt(
                requested: candidates,
                delivered: delivered,
                baseURL: snapshot.forum.baseURL,
                username: snapshot.username
            )
            guard !Task.isCancelled else { return false }
        }

        if result.shouldRefreshTrustWidget {
            await TrustLevelWidgetRefresher.refreshIfPossible(executionContext: .backgroundRefresh)
        }
        return result.taskSucceeded
    }

    func retainBadgeBaseURLs(_ baseURLs: Set<String>) {
        presenter.retainApplicationBadgeBaseURLs(baseURLs)
    }
}
