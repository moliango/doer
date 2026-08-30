import XCTest
import CookedHTML
@testable import Doer

final class TopicReadStateTests: XCTestCase {
    func testTopicListDecodesDiscourseReadState() throws {
        let topic = try decodeTopic(
            extra: #", "unseen": false, "unread_posts": 0, "last_read_post_number": 4, "highest_post_number": 4"#
        )

        XCTAssertFalse(topic.unseen)
        XCTAssertEqual(topic.unreadPosts, 0)
        XCTAssertEqual(topic.lastReadPostNumber, 4)
        XCTAssertEqual(topic.highestPostNumber, 4)
        XCTAssertFalse(topic.isUnreadForDisplay)
    }

    func testMissingReadStateStaysVisuallyUnread() throws {
        let topic = try decodeTopic()

        XCTAssertTrue(topic.isUnreadForDisplay)
    }

    func testNewReplyMakesPreviouslyReadTopicUnread() throws {
        let topic = try decodeTopic(
            extra: #", "unseen": false, "unread_posts": 1, "last_read_post_number": 4, "highest_post_number": 5"#
        )

        XCTAssertTrue(topic.isUnreadForDisplay)
    }

    func testIncomingTopicDetectionContinuesPastFirstServerPageWithoutFixedLimit() {
        XCTAssertTrue(IncomingTopicPageTraversal.shouldContinue(
            reachedCurrentFirstTopic: false,
            moreTopicsURL: "/latest?page=1",
            pageAddedNewTopicIds: true
        ))
        XCTAssertFalse(IncomingTopicPageTraversal.shouldContinue(
            reachedCurrentFirstTopic: true,
            moreTopicsURL: "/latest?page=2",
            pageAddedNewTopicIds: true
        ))
        XCTAssertFalse(IncomingTopicPageTraversal.shouldContinue(
            reachedCurrentFirstTopic: false,
            moreTopicsURL: nil,
            pageAddedNewTopicIds: true
        ))
    }

    func testIncomingMergeKeepsPinnedTopicsAboveNewRows() throws {
        let pinned = try decodeTopic(id: 1, extra: #", "pinned": true"#)
        let older = try decodeTopic(id: 2)
        let incoming = try decodeTopic(id: 3)

        let merged = HomeTopicListOrdering.mergeIncoming(
            incoming: [incoming],
            existing: [pinned, older],
            pinnedIds: [1]
        )

        XCTAssertEqual(merged.topics.map(\.id), [1, 3, 2])
        XCTAssertEqual(merged.pinnedIds, [1])
    }

    func testLaterPagePinsStayInServerOrder() throws {
        let first = try decodeTopic(id: 1)
        let laterPinned = try decodeTopic(id: 2, extra: #", "pinned": true"#)
        let topics = [first, laterPinned]
        let ordered = HomeTopicListOrdering.withPinnedFirst(topics, pinnedIds: [2])

        XCTAssertEqual(ordered.map(\.id), [1, 2])
        XCTAssertEqual(HomeTopicListOrdering.leadingPinnedIds(topics), [])
        XCTAssertFalse(HomeTopicListOrdering.isPinned(laterPinned, pinnedIds: []))
    }

    func testLeadingPrefixStopsAtFirstUnpinnedTopic() throws {
        let first = try decodeTopic(id: 1, extra: #", "pinned": true"#)
        let second = try decodeTopic(id: 2, extra: #", "pinned": true"#)
        let regular = try decodeTopic(id: 3)
        let categoryPin = try decodeTopic(id: 4, extra: #", "pinned": true"#)

        XCTAssertEqual(
            HomeTopicListOrdering.leadingPinnedIds([first, second, regular, categoryPin]),
            [1, 2]
        )
    }

    func testUnpinnedFlagIsExcludedFromCompactPins() throws {
        let topic = try decodeTopic(id: 5, extra: #", "pinned": true, "unpinned": true"#)
        XCTAssertFalse(HomeTopicListOrdering.isActivelyPinned(topic))
        XCTAssertEqual(HomeTopicListOrdering.leadingPinnedIds([topic]), [])
    }

    func testNewAndUnreadListsDropStaleLeadingPins() throws {
        let stalePin = try decodeTopic(
            id: 1,
            extra: #", "pinned": true, "unseen": false, "unread_posts": 0, "last_read_post_number": 1, "highest_post_number": 1"#
        )
        let anotherStalePin = try decodeTopic(
            id: 2,
            extra: #", "pinned": true, "unseen": false, "unread_posts": 0, "last_read_post_number": 2, "highest_post_number": 2"#
        )
        let fresh = try decodeTopic(
            id: 3,
            extra: #", "unseen": true, "unread_posts": 0"#
        )
        let topics = [stalePin, anotherStalePin, fresh]

        XCTAssertEqual(
            HomeTopicListOrdering.prepared(topics, mode: .newTopics).map(\.id),
            [3]
        )
        XCTAssertEqual(
            HomeTopicListOrdering.prepared(topics, mode: .unread).map(\.id),
            [3]
        )
        XCTAssertEqual(
            HomeTopicListOrdering.prepared(topics, mode: .latest).map(\.id),
            [1, 2, 3]
        )
        XCTAssertEqual(HomeTopicListOrdering.compactPinIds(in: topics, mode: .newTopics), [])
        XCTAssertEqual(HomeTopicListOrdering.compactPinIds(in: topics, mode: .unread), [])
        XCTAssertEqual(HomeTopicListOrdering.compactPinIds(in: topics, mode: .latest), [1, 2])
    }

    func testNewListKeepsPinnedTopicThatIsActuallyUnread() throws {
        let unreadPin = try decodeTopic(
            id: 8,
            extra: #", "pinned": true, "unseen": false, "unread_posts": 2, "last_read_post_number": 3, "highest_post_number": 5"#
        )
        let fresh = try decodeTopic(id: 9, extra: #", "unseen": true"#)
        let prepared = HomeTopicListOrdering.prepared([unreadPin, fresh], mode: .newTopics)
        XCTAssertEqual(prepared.map(\.id), [8, 9])
        XCTAssertEqual(HomeTopicListOrdering.compactPinIds(in: prepared, mode: .newTopics), [])
    }

    func testIncomingMergeDoesNotPromoteIncomingPins() throws {
        let pinned = try decodeTopic(id: 1, extra: #", "pinned": true"#)
        let older = try decodeTopic(id: 2)
        let incomingPin = try decodeTopic(id: 9, extra: #", "pinned": true"#)

        let merged = HomeTopicListOrdering.mergeIncoming(
            incoming: [incomingPin],
            existing: [pinned, older],
            pinnedIds: [1]
        )

        XCTAssertEqual(merged.topics.map(\.id), [1, 9, 2])
        XCTAssertEqual(merged.pinnedIds, [1])
    }

    @MainActor
    func testHomeTopicLookupUsesIdIndex() throws {
        let viewModel = HomeViewModel(api: DiscourseAPI(baseURL: "https://linux.do"))
        viewModel.topics = [
            try decodeTopic(id: 1),
            try decodeTopic(id: 2),
        ]

        XCTAssertEqual(viewModel.topic(id: 2)?.id, 2)
        XCTAssertNil(viewModel.topic(id: 99))

        viewModel.topics = []
        XCTAssertNil(viewModel.topic(id: 2))
    }

    @MainActor
    func testHomeReadProgressUpdateClearsUnreadOnlyThroughHighestSeen() throws {
        let viewModel = HomeViewModel(api: DiscourseAPI(baseURL: "https://linux.do"))
        viewModel.topics = [try decodeTopic(
            extra: #", "unseen": true, "unread_posts": 5, "last_read_post_number": 1, "highest_post_number": 6"#
        )]

        XCTAssertTrue(viewModel.updateTopicReadProgress(topicId: 17, highestSeen: 4))
        XCTAssertFalse(viewModel.topics[0].unseen)
        XCTAssertEqual(viewModel.topics[0].lastReadPostNumber, 4)
        XCTAssertEqual(viewModel.topics[0].unreadPosts, 2)
        XCTAssertTrue(viewModel.topics[0].isUnreadForDisplay)

        XCTAssertTrue(viewModel.updateTopicReadProgress(topicId: 17, highestSeen: 6))
        XCTAssertEqual(viewModel.topics[0].unreadPosts, 0)
        XCTAssertFalse(viewModel.topics[0].isUnreadForDisplay)
    }

    @MainActor
    func testHomeUIScopeCoalescesBeforeFlush() {
        let viewModel = HomeViewModel(api: DiscourseAPI(baseURL: "https://linux.do"))
        XCTAssertEqual(viewModel.consumePendingUIScope(), .all)

        viewModel.notifyChanged(.list)
        viewModel.notifyChanged(.incoming)
        let coalesced = viewModel.consumePendingUIScope()
        XCTAssertEqual(coalesced, [.list, .incoming])
        XCTAssertEqual(viewModel.consumePendingUIScope(), .all)
    }

    @MainActor
    func testHomeTopicListLayoutFactoryMatchesTheme() {
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: .systemDefault).kind, .standard)
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: .eyeCare).kind, .standard)
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: .xiaohongshu).kind, .xiaohongshu)
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: .weChat).kind, .weChat)
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: .telegram).kind, .telegram)
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: .oled).kind, .standard)
    }

    @MainActor
    func testChatTopicDetailSubclassesFreezeThemeHooks() {
        let api = DiscourseAPI(baseURL: "https://linux.do")
        let wechat = WeChatTopicDetailViewController(api: api, topicId: 1)
        let telegram = TelegramTopicDetailViewController(api: api, topicId: 1)
        XCTAssertTrue(wechat is ChatTopicDetailViewController)
        XCTAssertTrue(telegram is ChatTopicDetailViewController)
        XCTAssertEqual(wechat.chatThemeStyle(), .weChat)
        XCTAssertEqual(telegram.chatThemeStyle(), .telegram)
        XCTAssertEqual(wechat.incomingLinkColor(defaultColor: .red), .red)
        XCTAssertEqual(telegram.incomingLinkColor(defaultColor: .red), ChatTopicStyle.telegram.accentColor)
        XCTAssertEqual(wechat.estimatedChatRowHeight(), 140)
        XCTAssertEqual(telegram.estimatedChatRowHeight(), 168)
        XCTAssertEqual(wechat.jumpScrollPosition(), .middle)
        XCTAssertEqual(telegram.jumpScrollPosition(), .bottom)
        XCTAssertTrue(wechat.scrollsToBottomWhenOpeningLatest())
        XCTAssertTrue(telegram.scrollsToBottomWhenOpeningLatest())
        XCTAssertFalse(wechat.animatesCanvasColorChange())
        XCTAssertTrue(telegram.animatesCanvasColorChange())
        XCTAssertEqual(WeChatChatPostCell().dateChipCornerRadius(), 4)
        XCTAssertEqual(TelegramChatPostCell().dateChipCornerRadius(), 11)
        XCTAssertEqual(ChatTopicStyle.weChat.actionTintColor(isActive: true), ChatTopicStyle.weChat.accentColor)
        XCTAssertEqual(ChatTopicStyle.telegram.actionTintColor(isActive: true), ChatTopicStyle.telegram.accentColor)
        XCTAssertEqual(ChatActionBarChrome.likeTitle(count: 3), "3")
        XCTAssertNil(ChatActionBarChrome.likeTitle(count: 0))
    }

    func testUnopenedTopicOpensAtTopInsteadOfFirstPaintTail() {
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: nil,
                lastRead: 0,
                totalFloors: 80,
                pinLatestWhenFullyRead: true
            ),
            .top
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: nil,
                lastRead: 1,
                totalFloors: 80,
                pinLatestWhenFullyRead: false
            ),
            .top
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: nil,
                lastRead: 12,
                totalFloors: 80,
                pinLatestWhenFullyRead: true
            ),
            .floor(13)
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: nil,
                lastRead: 80,
                totalFloors: 80,
                pinLatestWhenFullyRead: true
            ),
            .floor(80)
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: nil,
                lastRead: 80,
                totalFloors: 80,
                pinLatestWhenFullyRead: false
            ),
            .top
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: 1,
                lastRead: 0,
                totalFloors: 80,
                pinLatestWhenFullyRead: false
            ),
            .top
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: 99,
                initialFloor: 1,
                lastRead: 0,
                totalFloors: 80,
                pinLatestWhenFullyRead: false
            ),
            .top
        )
        XCTAssertTrue(
            TopicDetailOpenAnchor.shouldStayAtOpeningPost(
                isOpeningPostTarget: true,
                contentOffsetY: 0
            )
        )
        XCTAssertFalse(
            TopicDetailOpenAnchor.shouldStayAtOpeningPost(
                isOpeningPostTarget: true,
                contentOffsetY: 400
            )
        )
        XCTAssertTrue(TopicDetailOpenAnchor.isOpeningPostTarget(floor: 1, postNumber: nil, postId: nil, openingPostId: nil))
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: 16,
                lastRead: 0,
                totalFloors: 80,
                pinLatestWhenFullyRead: false
            ),
            .floor(16)
        )
        XCTAssertEqual(
            TopicDetailOpenAnchor.resolve(
                initialPostId: nil,
                initialFloor: nil,
                lastRead: 1,
                totalFloors: 1,
                pinLatestWhenFullyRead: true
            ),
            .top
        )
    }

    func testNavigationPopGesturePriorityYieldsHorizontalEdgeSwipeButKeepsVerticalScroll() {
        XCTAssertTrue(
            NavigationPopGesturePriority.shouldYieldScrollPanToSystemPop(
                locationX: 12,
                translation: CGPoint(x: 8, y: 1),
                velocity: .zero
            )
        )
        XCTAssertFalse(
            NavigationPopGesturePriority.shouldYieldScrollPanToSystemPop(
                locationX: 12,
                translation: CGPoint(x: 1, y: 10),
                velocity: .zero
            )
        )
        XCTAssertFalse(
            NavigationPopGesturePriority.shouldYieldScrollPanToSystemPop(
                locationX: 80,
                translation: CGPoint(x: 12, y: 0),
                velocity: .zero
            )
        )
        XCTAssertFalse(
            NavigationPopGesturePriority.shouldYieldScrollPanToSystemPop(
                locationX: 12,
                translation: .zero,
                velocity: .zero
            )
        )
    }

    func testChatAvatarTimestampIncludesDateOnTodayAndCompactIsSingleLine() {
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = formatter.string(from: now)
        let twoLine = ChatAvatarTimestamp.text(forCreatedAt: iso, now: now)
        XCTAssertTrue(twoLine.contains("\n"))
        XCTAssertTrue(twoLine.contains("/"))
        let compact = ChatAvatarTimestamp.compactText(forCreatedAt: iso, now: now)
        XCTAssertFalse(compact.contains("\n"))
        XCTAssertTrue(compact.contains(" "))
        XCTAssertTrue(compact.contains("/"))
    }

    func testChatDateSeparatorHidesOnSameCalendarDay() {
        let morning = "2026-01-15T02:00:00.000Z"
        let evening = "2026-01-15T18:00:00.000Z"
        let nextDay = "2026-01-16T02:00:00.000Z"
        XCTAssertNotNil(ChatDateSeparator.text(forCreatedAt: morning, previousCreatedAt: nil))
        XCTAssertNil(ChatDateSeparator.text(forCreatedAt: evening, previousCreatedAt: morning))
        XCTAssertNotNil(ChatDateSeparator.text(forCreatedAt: nextDay, previousCreatedAt: evening))
    }

    private func decodeTopic(id: Int = 17, extra: String = "") throws -> DiscourseTopicList.Topic {
        let json = """
        {
          "topic_list": {
            "topics": [{
              "id": \(id),
              "fancy_title": "Topic",
              "title": "Topic",
              "posts_count": 6,
              "reply_count": 5,
              "views": 20,
              "created_at": "2026-07-11T00:00:00.000Z"\(extra)
            }]
          }
        }
        """
        return try JSONDecoder().decode(DiscourseTopicList.self, from: Data(json.utf8)).topicList.topics[0]
    }
}

final class ChatReplyQuoteTests: XCTestCase {
    func testLineIncludesAnySenderNotOnlySelf() {
        XCTAssertEqual(
            ChatReplyQuoteFormatting.line(
                displayName: "男人药帅",
                preview: "20x 才七百多就太不正常了吧"
            ),
            "男人药帅: 20x 才七百多就太不正常了吧"
        )
        XCTAssertEqual(
            ChatReplyQuoteFormatting.line(displayName: "呆逼", preview: "比如用的人太多"),
            "呆逼: 比如用的人太多"
        )
    }

    func testTruncatesLongPreview() {
        let long = String(repeating: "啊", count: 80)
        let clipped = ChatReplyQuoteFormatting.truncatedPreview(long)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertEqual(clipped.count, 73)
    }

    func testCollapsesWhitespace() {
        XCTAssertEqual(
            ChatReplyQuoteFormatting.truncatedPreview("hello\n\n  world"),
            "hello world"
        )
    }

    func testEmptyNameFallsBackToPreview() {
        XCTAssertEqual(ChatReplyQuoteFormatting.line(displayName: "  ", preview: "原文"), "原文")
        XCTAssertEqual(ChatReplyQuoteFormatting.line(displayName: "甲", preview: "  "), "甲")
    }

    func testDropsLeadingDiscourseQuoteWhenReplyChipIsShown() {
        let quote = AnnotatedBlock(
            block: .discourseQuote(
                username: "甲",
                avatarURL: nil,
                topicTitle: nil,
                topicURL: nil,
                categoryName: nil,
                categoryURL: nil,
                quotePostNumber: 2,
                content: []
            ),
            sourceHTML: "<aside></aside>"
        )
        let body = AnnotatedBlock(block: .paragraph([.text("不正常的可太多了")]), sourceHTML: "<p>不正常的可太多了</p>")
        let dropped = WeChatChatPostCell.droppingLeadingDiscourseQuotes([quote, body], enabled: true)
        XCTAssertEqual(dropped.count, 1)
        if case .paragraph = dropped[0].block {
        } else {
            XCTFail("Expected remaining paragraph")
        }
        XCTAssertEqual(
            WeChatChatPostCell.droppingLeadingDiscourseQuotes([quote, body], enabled: false).count,
            2
        )
    }

    func testVisibleReactionsKeepEmojiAndCount() throws {
        let json = Data("""
        [
          {"id":"heart","type":"emoji","count":3},
          {"id":"+1","type":"emoji","count":2},
          {"id":"laughing","type":"emoji","count":1},
          {"id":"tada","type":"emoji","count":1},
          {"id":"empty","type":"emoji","count":0}
        ]
        """.utf8)
        let reactions = try JSONDecoder().decode([DiscourseTopicDetail.Reaction].self, from: json)
        XCTAssertEqual(
            ChatActionBarChrome.summaryReactions(reactions).map(\.id),
            ["heart", "+1", "laughing"]
        )
        XCTAssertEqual(ChatActionBarChrome.summaryCount(reactions: reactions, fallback: 0), 7)
        XCTAssertEqual(ChatActionBarChrome.likeTitle(count: 7), "7")
    }
}
