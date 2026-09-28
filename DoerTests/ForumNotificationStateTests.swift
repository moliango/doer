import XCTest
@testable import Doer

@MainActor
final class ForumNotificationStateTests: XCTestCase {
    func testCurrentUserDecodesOfficialUnreadNotificationCounts() throws {
        let data = Data(
            #"{"current_user":{"id":7,"username":"naine","unread_notifications":3,"unread_high_priority_notifications":2,"all_unread_notifications_count":5,"seen_notification_id":40,"notification_channel_position":99}}"#.utf8
        )

        let user = try XCTUnwrap(JSONDecoder().decode(DiscourseCurrentUserResponse.self, from: data).currentUser)

        XCTAssertEqual(user.unreadNotifications, 3)
        XCTAssertEqual(user.unreadHighPriorityNotifications, 2)
        XCTAssertEqual(user.allUnreadNotificationsCount, 5)
        XCTAssertEqual(user.seenNotificationId, 40)
        XCTAssertEqual(user.notificationChannelPosition, 99)
        XCTAssertEqual(user.effectiveUnreadNotificationCount, 5)
    }

    func testMissingOfficialUnreadCountFallsBackToAvailableCounts() throws {
        let data = Data(
            #"{"current_user":{"id":7,"username":"naine","unread_notifications":3,"unread_high_priority_notifications":2}}"#.utf8
        )

        let user = try XCTUnwrap(JSONDecoder().decode(DiscourseCurrentUserResponse.self, from: data).currentUser)

        XCTAssertEqual(user.effectiveUnreadNotificationCount, 5)
    }

    func testChannelPositionChangeForcesListRefreshEvenWhenUnreadCountIsStable() {
        XCTAssertTrue(ForumNotificationRefreshPolicy.shouldFetchList(
            forceList: false,
            notificationsAreEmpty: false,
            previousUnreadCount: 3,
            officialUnreadCount: 3,
            previousChannelPosition: 20,
            currentChannelPosition: 21,
            listRefreshExpired: false
        ))
    }

    func testDeliveryStoreEstablishesBaselineThenCommitsDeliveredNotifications() throws {
        let suiteName = "ForumNotificationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ForumNotificationDeliveryStore(defaults: defaults)

        let baseline = try decodeNotifications(idsAndReadState: [(42, false)])
        store.establishBaselineIfNeeded(
            baseline,
            baseURL: "https://linux.do/",
            username: "Naine"
        )

        let updated = try decodeNotifications(idsAndReadState: [
            (45, false),
            (44, false),
            (43, false),
            (42, false),
        ])
        let pending = store.reservePendingNotifications(
            updated,
            baseURL: "https://linux.do",
            username: "naine",
            limit: 3
        )
        XCTAssertEqual(pending.map(\.id), [43, 44, 45])
        XCTAssertTrue(store.reservePendingNotifications(
            updated,
            baseURL: "https://linux.do",
            username: "naine",
            limit: 3
        ).isEmpty)

        store.completeDeliveryAttempt(
            requested: pending,
            delivered: pending,
            baseURL: "https://linux.do",
            username: "naine"
        )
        XCTAssertTrue(store.reservePendingNotifications(
            updated,
            baseURL: "https://linux.do",
            username: "naine",
            limit: 3
        ).isEmpty)
    }

    func testFailedDeliveryReleasesReservationForNextAttempt() throws {
        let suiteName = "ForumNotificationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ForumNotificationDeliveryStore(defaults: defaults)
        let baseline = try decodeNotifications(idsAndReadState: [(42, false)])
        store.establishBaselineIfNeeded(baseline, baseURL: "https://linux.do", username: "naine")
        let updated = try decodeNotifications(idsAndReadState: [(43, false), (42, false)])

        let firstAttempt = store.reservePendingNotifications(
            updated,
            baseURL: "https://linux.do",
            username: "naine",
            limit: 3
        )
        store.completeDeliveryAttempt(
            requested: firstAttempt,
            delivered: [],
            baseURL: "https://linux.do",
            username: "naine"
        )
        let secondAttempt = store.reservePendingNotifications(
            updated,
            baseURL: "https://linux.do",
            username: "naine",
            limit: 3
        )

        XCTAssertEqual(firstAttempt.map(\.id), [43])
        XCTAssertEqual(secondAttempt.map(\.id), [43])
    }

    func testBadgeStateReplacesAccountForSameForumAndRetainsEligibleForums() {
        var state = ForumNotificationBadgeState(unreadCountsByScope: [
            "https://linux.do|old": 2,
            "https://example.com|alice": 4,
        ])

        state.replace(3, baseURL: "https://linux.do/", username: "new")
        XCTAssertEqual(state.totalUnreadCount, 7)
        XCTAssertNil(state.unreadCountsByScope["https://linux.do|old"])
        XCTAssertEqual(state.unreadCountsByScope["https://linux.do|new"], 3)

        state.retainBaseURLs(["https://linux.do"])
        XCTAssertEqual(state.unreadCountsByScope, ["https://linux.do|new": 3])
        XCTAssertEqual(state.totalUnreadCount, 3)

        state.remove(baseURL: "https://linux.do/")
        XCTAssertTrue(state.unreadCountsByScope.isEmpty)
        XCTAssertEqual(state.totalUnreadCount, 0)
    }

    func testBackgroundAuthorizationPolicyNeverRequestsPermission() {
        XCTAssertFalse(
            ForumNotificationAuthorizationPolicy.existingOnly
                .allowsAuthorizationRequest(isApplicationActive: true)
        )
        XCTAssertFalse(
            ForumNotificationAuthorizationPolicy.requestIfNeeded
                .allowsAuthorizationRequest(isApplicationActive: false)
        )
        XCTAssertTrue(
            ForumNotificationAuthorizationPolicy.requestIfNeeded
                .allowsAuthorizationRequest(isApplicationActive: true)
        )
    }

    func testBackgroundRefreshPolicyUsesFifteenMinuteEarliestDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            BackgroundNotificationRefreshPolicy.earliestBeginDate(now: now),
            now.addingTimeInterval(15 * 60)
        )
        XCTAssertTrue(BackgroundNotificationRefreshPolicy.completionSuccess(
            workSucceeded: true,
            didExpire: false
        ))
        XCTAssertFalse(BackgroundNotificationRefreshPolicy.completionSuccess(
            workSucceeded: true,
            didExpire: true
        ))
        XCTAssertFalse(BackgroundNotificationRefreshPolicy.completionSuccess(
            workSucceeded: false,
            didExpire: false
        ))
    }

    func testBackgroundSyncResultOnlyFailsTaskForTransientErrorsOrCancellation() {
        let authenticationFailure = BackgroundNotificationSyncFailure(
            baseURL: "https://linux.do",
            kind: .authentication,
            message: "expired"
        )
        let transientFailure = BackgroundNotificationSyncFailure(
            baseURL: "https://linux.do",
            kind: .transient,
            message: "offline"
        )

        XCTAssertTrue(BackgroundNotificationSyncResult(
            eligibleBaseURLs: ["https://linux.do"],
            snapshots: [],
            failures: [authenticationFailure],
            wasCancelled: false
        ).taskSucceeded)
        XCTAssertFalse(BackgroundNotificationSyncResult(
            eligibleBaseURLs: ["https://linux.do"],
            snapshots: [],
            failures: [transientFailure],
            wasCancelled: false
        ).taskSucceeded)
        XCTAssertFalse(BackgroundNotificationSyncResult(
            eligibleBaseURLs: [],
            snapshots: [],
            failures: [],
            wasCancelled: true
        ).taskSucceeded)
    }

    func testBackgroundSyncSkipsTrustWidgetAfterCloudflareFailure() {
        let cloudflareFailure = BackgroundNotificationSyncFailure(
            baseURL: "https://linux.do",
            kind: .cloudflare,
            message: "challenge"
        )
        let transientFailure = BackgroundNotificationSyncFailure(
            baseURL: "https://linux.do",
            kind: .transient,
            message: "offline"
        )

        XCTAssertTrue(BackgroundNotificationSyncResult(
            eligibleBaseURLs: ["https://linux.do"],
            snapshots: [],
            failures: [],
            wasCancelled: false
        ).shouldRefreshTrustWidget)
        XCTAssertFalse(BackgroundNotificationSyncResult(
            eligibleBaseURLs: ["https://linux.do"],
            snapshots: [],
            failures: [cloudflareFailure],
            wasCancelled: false
        ).shouldRefreshTrustWidget)
        XCTAssertTrue(BackgroundNotificationSyncResult(
            eligibleBaseURLs: ["https://linux.do"],
            snapshots: [],
            failures: [transientFailure],
            wasCancelled: false
        ).shouldRefreshTrustWidget)
        XCTAssertFalse(BackgroundNotificationSyncResult(
            eligibleBaseURLs: [],
            snapshots: [],
            failures: [],
            wasCancelled: true
        ).shouldRefreshTrustWidget)
    }

    func testOnlyNotificationAuthenticationFailureClearsBadge() {
        let notificationFailure = BackgroundNotificationSyncFailure(
            baseURL: "https://linux.do",
            kind: .authentication,
            scope: .notifications,
            message: "expired"
        )
        let topicFailure = BackgroundNotificationSyncFailure(
            baseURL: "https://linux.do",
            kind: .authentication,
            scope: .topics,
            message: "forbidden"
        )

        XCTAssertTrue(notificationFailure.shouldClearBadge)
        XCTAssertFalse(topicFailure.shouldClearBadge)
    }

    func testBackgroundAPIContextDisablesInteractiveWebRecovery() {
        XCTAssertTrue(DiscourseAPIExecutionContext.foreground.allowsInteractiveWebRecovery)
        XCTAssertFalse(DiscourseAPIExecutionContext.backgroundRefresh.allowsInteractiveWebRecovery)
    }

    func testNotificationRouteMatchesForumUsingNormalizedBaseURL() throws {
        let linuxDo = ForumInstance.new(title: "Linux.do", baseURL: "https://linux.do/")
        let example = ForumInstance.new(title: "Example", baseURL: "https://example.com")

        let matched = try XCTUnwrap(ForumNotificationRoutePresenter.matchingForum(
            baseURL: "HTTPS://LINUX.DO",
            forums: [example, linuxDo]
        ))

        XCTAssertEqual(matched.title, "Linux.do")
    }

    func testNotificationRouteDoesNotOpenUnknownForum() {
        let forums = [ForumInstance.new(title: "Linux.do", baseURL: "https://linux.do")]

        XCTAssertNil(ForumNotificationRoutePresenter.matchingForum(
            baseURL: "https://unknown.example",
            forums: forums
        ))
    }

    func testNotificationRouteParsesNSNumberUserInfoAndPostId() {
        let userInfo: [AnyHashable: Any] = [
            ForumNotificationRoute.UserInfoKey.baseURL: "https://linux.do",
            ForumNotificationRoute.UserInfoKey.notificationId: NSNumber(value: 88),
            ForumNotificationRoute.UserInfoKey.topicId: NSNumber(value: 12345),
            ForumNotificationRoute.UserInfoKey.postNumber: NSNumber(value: 17),
            ForumNotificationRoute.UserInfoKey.postId: NSNumber(value: 999001),
        ]

        let route = ForumNotificationRoute.from(userInfo: userInfo)

        XCTAssertEqual(route?.baseURL, "https://linux.do")
        XCTAssertEqual(route?.notificationId, 88)
        XCTAssertEqual(route?.topicId, 12345)
        XCTAssertEqual(route?.postNumber, 17)
        XCTAssertEqual(route?.postId, 999001)
    }

    func testNotificationDecodesActingPostIdAndPostNumber() throws {
        let json = """
        {
          "notifications": [{
            "id": 9,
            "notification_type": 2,
            "read": false,
            "high_priority": true,
            "created_at": "2026-07-19T00:00:00.000Z",
            "post_number": 42,
            "topic_id": 1001,
            "data": {
              "topic_title": "Reply target",
              "display_username": "bob",
              "original_post_id": 556677,
              "original_username": "bob"
            }
          }]
        }
        """
        let list = try JSONDecoder().decode(
            DiscourseNotificationList.self,
            from: Data(json.utf8)
        )
        let notification = try XCTUnwrap(list.notifications.first)

        XCTAssertEqual(notification.topicId, 1001)
        XCTAssertEqual(notification.postNumber, 42)
        XCTAssertEqual(notification.actingPostId, 556677)
    }

    func testChatMentionNotificationDecodesChannelAndTitle() throws {
        let json = """
        {
          "notifications": [{
            "id": 88,
            "notification_type": 29,
            "read": false,
            "high_priority": true,
            "created_at": "2026-08-22T14:16:00.000Z",
            "topic_id": null,
            "data": {
              "mentioned_by_username": "alice",
              "chat_message_id": 9001,
              "chat_channel_id": 3,
              "chat_channel_title": "常规频道"
            }
          }]
        }
        """
        let list = try JSONDecoder().decode(
            DiscourseNotificationList.self,
            from: Data(json.utf8)
        )
        let notification = try XCTUnwrap(list.notifications.first)

        XCTAssertTrue(notification.isChatNotification)
        XCTAssertEqual(notification.data.chatChannelId, 3)
        XCTAssertEqual(notification.data.chatMessageId, 9001)
        XCTAssertEqual(notification.data.chatChannelTitle, "常规频道")
        XCTAssertEqual(notification.displayTitle, "常规频道")
        XCTAssertEqual(notification.actorName, "alice")
        XCTAssertTrue(NotificationListFilter.chat.matches(notification))
        XCTAssertTrue(NotificationListFilter.mentions.matches(notification))
        XCTAssertFalse(NotificationListFilter.messages.matches(notification))
        XCTAssertFalse(NotificationListFilter.system.matches(notification))
    }

    func testChatMessageNotificationStringDataDecodes() throws {
        let json = """
        {
          "notifications": [{
            "id": 89,
            "notification_type": 30,
            "read": true,
            "created_at": "2026-08-22T14:16:00.000Z",
            "data": "{\\"display_username\\":\\"bob\\",\\"chat_channel_id\\":7,\\"chat_channel_title\\":\\"Lounge\\",\\"chat_message_id\\":12}"
          }]
        }
        """
        let list = try JSONDecoder().decode(
            DiscourseNotificationList.self,
            from: Data(json.utf8)
        )
        let notification = try XCTUnwrap(list.notifications.first)
        XCTAssertTrue(notification.isChatNotification)
        XCTAssertEqual(notification.data.chatChannelId, 7)
        XCTAssertEqual(notification.displayTitle, "Lounge")
        XCTAssertTrue(NotificationListFilter.chat.matches(notification))
        XCTAssertFalse(NotificationListFilter.mentions.matches(notification))
    }

    func testNotificationListSkipsMalformedItems() throws {
        let json = """
        {
          "notifications": [
            {"id": "bad"},
            {
              "id": 2,
              "notification_type": 29,
              "read": false,
              "created_at": "2026-08-22T00:00:00.000Z",
              "data": {"chat_channel_id": 1, "chat_channel_title": "常规频道"}
            }
          ]
        }
        """
        let list = try JSONDecoder().decode(
            DiscourseNotificationList.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(list.notifications.count, 1)
        XCTAssertEqual(list.notifications.first?.id, 2)
        XCTAssertTrue(list.notifications.first?.isChatNotification == true)
    }

    func testChatNotificationsRouteUsesFilterByTypes() {
        XCTAssertTrue(DiscourseRouter.notifications.path.contains("limit=60"))
        XCTAssertTrue(DiscourseRouter.chatNotifications.path.contains("filter_by_types="))
        XCTAssertTrue(DiscourseRouter.chatNotifications.path.contains("chat_mention"))
    }

    func testNotificationListMergesChatTypesById() throws {
        let mainJSON = """
        {"notifications":[{"id":1,"notification_type":2,"read":true,"created_at":"2026-08-21T00:00:00.000Z","topic_id":9,"data":{"topic_title":"A"}}]}
        """
        let chatJSON = """
        {"notifications":[{"id":8,"notification_type":29,"read":false,"created_at":"2026-08-22T00:00:00.000Z","data":{"chat_channel_title":"常规频道","chat_channel_id":3}}]}
        """
        let main = try JSONDecoder().decode(DiscourseNotificationList.self, from: Data(mainJSON.utf8))
        let chat = try JSONDecoder().decode(DiscourseNotificationList.self, from: Data(chatJSON.utf8))
        let merged = main.merging(chat)
        XCTAssertEqual(merged.notifications.count, 2)
        XCTAssertEqual(merged.notifications.first?.id, 8)
        XCTAssertTrue(merged.notifications.contains(where: { $0.isChatNotification }))
    }

    private func decodeNotifications(idsAndReadState: [(Int, Bool)]) throws -> [DiscourseNotification] {
        let entries = idsAndReadState.map { id, read in
            """
            {
              "id": \(id),
              "notification_type": 2,
              "read": \(read),
              "high_priority": false,
              "created_at": "2026-07-19T00:00:00.000Z",
              "topic_id": 17,
              "data": {"topic_title": "Topic \(id)", "username": "alice"}
            }
            """
        }.joined(separator: ",")
        let data = Data("{\"notifications\":[\(entries)]}".utf8)
        return try JSONDecoder().decode(DiscourseNotificationList.self, from: data).notifications
    }
}
