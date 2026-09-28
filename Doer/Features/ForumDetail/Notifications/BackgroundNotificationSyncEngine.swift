import Foundation

struct BackgroundNotificationSyncSnapshot {
    let forum: ForumInstance
    let username: String
    let unreadCount: Int
    let unreadHighPriorityCount: Int
    let notifications: [DiscourseNotification]
    let latestTopics: [DiscourseTopicList.Topic]?
}

struct BackgroundNotificationSyncFailure {
    enum Kind: Equatable {
        case authentication
        case cloudflare
        case transient
    }

    enum Scope: Equatable {
        case notifications
        case topics
    }

    let baseURL: String
    let kind: Kind
    let scope: Scope
    let message: String

    init(
        baseURL: String,
        kind: Kind,
        scope: Scope = .notifications,
        message: String
    ) {
        self.baseURL = baseURL
        self.kind = kind
        self.scope = scope
        self.message = message
    }

    var shouldClearBadge: Bool {
        kind == .authentication && scope == .notifications
    }
}

struct BackgroundNotificationSyncResult {
    let eligibleBaseURLs: Set<String>
    let snapshots: [BackgroundNotificationSyncSnapshot]
    let failures: [BackgroundNotificationSyncFailure]
    let wasCancelled: Bool

    var taskSucceeded: Bool {
        !wasCancelled && !failures.contains { $0.kind == .transient }
    }

    /// Widget summary uses a live DiscourseAPI. A Cloudflare 429 there presents the
    /// human sheet, so skip it when this background pass already hit CF.
    var shouldRefreshTrustWidget: Bool {
        !wasCancelled && !failures.contains { $0.kind == .cloudflare }
    }

    static let noWork = BackgroundNotificationSyncResult(
        eligibleBaseURLs: [],
        snapshots: [],
        failures: [],
        wasCancelled: false
    )
}

@MainActor
final class BackgroundNotificationSyncEngine {
    static let shared = BackgroundNotificationSyncEngine()

    private var activeAPI: DiscourseAPI?

    private init() {}

    func eligibleForums() -> [ForumInstance] {
        let forums = (try? DatabaseManager.shared.fetchAllForums()) ?? []
        var seenBaseURLs = Set<String>()
        return forums.filter { forum in
            let baseURL = ForumInstance.normalizedBaseURL(forum.baseURL)
            guard !baseURL.isEmpty,
                  seenBaseURLs.insert(baseURL).inserted,
                  let url = URL(string: baseURL),
                  WebCookieStore.shared.hasDiscourseWebSessionCookie(for: url)
            else { return false }
            return true
        }
    }

    func hasEligibleForums() -> Bool {
        !eligibleForums().isEmpty
    }

    func refreshEligibleForums() async -> BackgroundNotificationSyncResult {
        let forums = eligibleForums()
        guard !forums.isEmpty else { return .noWork }

        let eligibleBaseURLs = Set(forums.map { ForumInstance.normalizedBaseURL($0.baseURL) })
        var snapshots: [BackgroundNotificationSyncSnapshot] = []
        var failures: [BackgroundNotificationSyncFailure] = []

        for forum in forums {
            if Task.isCancelled {
                activeAPI?.cancelPendingRequests()
                activeAPI = nil
                return BackgroundNotificationSyncResult(
                    eligibleBaseURLs: eligibleBaseURLs,
                    snapshots: snapshots,
                    failures: failures,
                    wasCancelled: true
                )
            }

            let api = DiscourseAPI(forum: forum, executionContext: .backgroundRefresh)
            activeAPI = api
            do {
                let currentUser = try await api.fetchCurrentUser()
                try Task.checkCancellation()
                let list = try await api.fetchNotifications()
                try Task.checkCancellation()
                let unreadCount = currentUser.hasOfficialUnreadNotificationCount
                    ? currentUser.effectiveUnreadNotificationCount
                    : list.notifications.filter { !$0.read }.count

                var latestTopics: [DiscourseTopicList.Topic]?
                do {
                    let topicsFetch = try await api.fetchLatestTopicsWithRawData(page: 0)
                    latestTopics = topicsFetch.list.topicList.topics
                    TopicListCacheFacade.save(topicsFetch.rawData, baseURL: forum.baseURL)
                    try Task.checkCancellation()
                } catch {
                    if Task.isCancelled || error is CancellationError || DiscourseAPI.isExplicitlyCancelledRequest(error) {
                        activeAPI = nil
                        return BackgroundNotificationSyncResult(
                            eligibleBaseURLs: eligibleBaseURLs,
                            snapshots: snapshots,
                            failures: failures,
                            wasCancelled: true
                        )
                    }
                    let failure = Self.failure(baseURL: forum.baseURL, error: error, scope: .topics)
                    failures.append(failure)
                    DohDebugLog.record(
                        "topic update refresh failed base=\(forum.baseURL) kind=\(failure.kind) error=\(failure.message)",
                        subsystem: "BackgroundRefresh"
                    )
                }
                snapshots.append(
                    BackgroundNotificationSyncSnapshot(
                        forum: forum,
                        username: currentUser.username,
                        unreadCount: unreadCount,
                        unreadHighPriorityCount: max(currentUser.unreadHighPriorityNotifications ?? 0, 0),
                        notifications: list.notifications,
                        latestTopics: latestTopics
                    )
                )
            } catch {
                if Task.isCancelled || error is CancellationError || DiscourseAPI.isExplicitlyCancelledRequest(error) {
                    activeAPI = nil
                    return BackgroundNotificationSyncResult(
                        eligibleBaseURLs: eligibleBaseURLs,
                        snapshots: snapshots,
                        failures: failures,
                        wasCancelled: true
                    )
                }
                let failure = Self.failure(baseURL: forum.baseURL, error: error)
                failures.append(failure)
                DohDebugLog.record(
                    "notification refresh failed base=\(forum.baseURL) kind=\(failure.kind) error=\(failure.message)",
                    subsystem: "BackgroundRefresh"
                )
            }
            activeAPI = nil
        }

        return BackgroundNotificationSyncResult(
            eligibleBaseURLs: eligibleBaseURLs,
            snapshots: snapshots,
            failures: failures,
            wasCancelled: false
        )
    }

    func cancelCurrentRefresh() {
        activeAPI?.cancelPendingRequests()
        activeAPI = nil
    }

    private static func failure(
        baseURL: String,
        error: Error,
        scope: BackgroundNotificationSyncFailure.Scope = .notifications
    ) -> BackgroundNotificationSyncFailure {
        if let apiError = error as? DiscourseAPIError {
            if apiError.isCloudflareChallenge {
                return BackgroundNotificationSyncFailure(
                    baseURL: baseURL,
                    kind: .cloudflare,
                    scope: scope,
                    message: error.localizedDescription
                )
            }
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: baseURL) {
                return BackgroundNotificationSyncFailure(
                    baseURL: baseURL,
                    kind: .authentication,
                    scope: scope,
                    message: error.localizedDescription
                )
            }
        }
        return BackgroundNotificationSyncFailure(
            baseURL: baseURL,
            kind: .transient,
            scope: scope,
            message: error.localizedDescription
        )
    }
}
