import XCTest
@testable import Doer

@MainActor
final class UserProfileModelsTests: XCTestCase {
    func testTrustLevelFormattingHidesMissingAndUnsupportedLevels() {
        XCTAssertNil(UserProfileFormatting.trustLevelText(nil) as String?)
        XCTAssertNil(UserProfileFormatting.trustLevelText(-1) as String?)
        XCTAssertNil(UserProfileFormatting.trustLevelText(5) as String?)
    }

    func testTrustLevelFormattingShowsSupportedLevels() {
        XCTAssertNotNil(UserProfileFormatting.trustLevelText(0))
        XCTAssertNotNil(UserProfileFormatting.trustLevelText(4))
    }

    func testContentPresentationMapsLinkClicks() throws {
        let data = Data(#"{"url":"https://example.test","title":"Example","clicks":4}"#.utf8)
        let link = try JSONDecoder().decode(DiscourseUserSummaryLink.self, from: data)
        let presentation = UserProfileContentPresentation.make(from: .summaryLink(link))
        XCTAssertEqual(presentation.title, "Example")
        XCTAssertEqual(presentation.symbol, "link")
        XCTAssertTrue(presentation.subtitle?.contains("4") == true)
    }

    func testContentPresentationMapsSummaryTopicChrome() {
        let topic = DiscourseUserSummaryTopic(
            id: 17,
            title: "Topic",
            likesCount: 6,
            postsCount: 3,
            views: nil,
            slug: nil,
            categoryId: nil,
            createdAt: nil
        )
        let presentation = UserProfileContentPresentation.make(from: .summaryTopic(topic))
        XCTAssertEqual(presentation.title, "Topic")
        XCTAssertEqual(presentation.symbol, "text.bubble.fill")
        XCTAssertNil(presentation.avatarTemplate)
        XCTAssertTrue(presentation.subtitle?.contains("6") == true)

        let withAvatar = UserProfileContentPresentation.make(
            from: .summaryTopic(topic),
            fallbackAvatarTemplate: "/user_avatar/{size}/1.png"
        )
        XCTAssertEqual(withAvatar.avatarTemplate, "/user_avatar/{size}/1.png")
    }

    func testCardLayoutKeepsNameBesideOverflowingAvatar() {
        XCTAssertEqual(UserProfileCardLayout.identityLeading, UserProfileCardLayout.avatarDiameter + 8)
        XCTAssertEqual(UserProfileCardLayout.avatarDiameter, 76)
        XCTAssertLessThan(UserProfileCardLayout.avatarOverflow, UserProfileCardLayout.avatarRadius)
    }

    func testCleanBioKeepsPlainEmojiShortcodes() {
        XCTAssertEqual(
            UserProfileFormatting.cleanBio("你好，我是马里奥 :face_without_mouth:"),
            "你好，我是马里奥 :face_without_mouth:"
        )
    }

    func testCleanBioRecoversEmojiShortcodesFromImg() {
        let html = """
        <p>你好 <img src="/images/emoji/twitter/face_without_mouth.png" class="emoji" alt=":face_without_mouth:"></p>
        """
        let cleaned = UserProfileFormatting.cleanBio(html)
        XCTAssertEqual(cleaned?.contains(":face_without_mouth:"), true)
        XCTAssertEqual(cleaned?.contains("<img"), false)
    }

    func testCardDefaultsMissingCapabilitiesToNil() throws {
        let data = Data(#"{"user":{"id":1,"username":"sam","trust_level":2}}"#.utf8)

        let response = try JSONDecoder().decode(DiscourseUserCardResponse.self, from: data)

        XCTAssertEqual(response.user.username, "sam")
        XCTAssertNil(response.user.canFollow)
        XCTAssertNil(response.user.canSendPrivateMessageToUser)
        XCTAssertNil(response.user.muted)
        XCTAssertNil(response.user.ignored)
    }

    func testUserActionsDecodeServerKeys() throws {
        let data = Data(#"{"user_actions":[{"action_type":4,"topic_id":19,"title":"A topic","post_number":1,"acting_username":"sam","acting_at":"2026-07-10T10:00:00.000Z"}]}"#.utf8)

        let response = try JSONDecoder().decode(DiscourseUserActionResponse.self, from: data)

        XCTAssertEqual(response.userActions.count, 1)
        XCTAssertEqual(response.userActions[0].actionType, 4)
        XCTAssertEqual(response.userActions[0].topicId, 19)
        XCTAssertEqual(response.userActions[0].username, "sam")
    }

    func testReactionsDecodeTopLevelArray() throws {
        let data = Data(#"[{"id":8,"post_id":31,"created_at":"2026-07-10T10:00:00.000Z","reaction":{"reaction_value":"heart"},"post":{"topic_id":17,"post_number":3,"topic_title":"Topic","excerpt":"Reply"}}]"#.utf8)

        let response = try JSONDecoder().decode(DiscourseUserReactionResponse.self, from: data)

        XCTAssertEqual(response.reactions.count, 1)
        XCTAssertEqual(response.reactions[0].topicId, 17)
        XCTAssertEqual(response.reactions[0].reactionValue, "heart")
        XCTAssertNil(response.reactions[0].avatarTemplate)
    }

    func testReactionsDecodeNestedUserAvatar() throws {
        let data = Data(#"[{"id":8,"post_id":31,"user":{"username":"sam","avatar_template":"/user_avatar/linux.do/sam/{size}/9.png"},"post":{"topic_id":17,"topic_title":"Topic","user":{"username":"alice","avatar_template":"/user_avatar/linux.do/alice/{size}/1.png"}},"reaction":{"reaction_value":"heart"}}]"#.utf8)

        let response = try JSONDecoder().decode(DiscourseUserReactionResponse.self, from: data)
        XCTAssertEqual(response.reactions[0].avatarTemplate, "/user_avatar/linux.do/sam/{size}/9.png")

        let presentation = UserProfileContentPresentation.make(
            from: .reaction(response.reactions[0]),
            fallbackAvatarTemplate: "/fallback/{size}.png"
        )
        XCTAssertEqual(presentation.avatarTemplate, "/user_avatar/linux.do/sam/{size}/9.png")
    }

    func testFollowUsersDecodeArray() throws {
        let data = Data(#"[{"id":4,"username":"alice","name":"Alice","avatar_template":"/user_avatar/linux.do/alice/{size}/1.png"}]"#.utf8)

        let users = try JSONDecoder().decode([DiscourseFollowUser].self, from: data)

        XCTAssertEqual(users.first?.username, "alice")
        XCTAssertEqual(users.first?.name, "Alice")
        XCTAssertEqual(users.first?.avatarTemplate, "/user_avatar/linux.do/alice/{size}/1.png")

        let avatarURL = AvatarImageLoader.url(
            from: users.first?.avatarTemplate,
            baseURL: "https://linux.do",
            size: AvatarImageLoader.primaryAvatarPixelSize
        )
        XCTAssertEqual(
            avatarURL?.absoluteString,
            "https://linux.do/user_avatar/linux.do/alice/\(AvatarImageLoader.primaryAvatarPixelSize)/1.png"
        )
    }


    func testDraftDecodesJSONStringDataAndReplyKey() throws {
        let data = Data(#"{"drafts":[{"draft_key":"topic_17_post_3","draft_sequence":7,"title":"Topic","data":"{\"reply\":\"saved reply\",\"action\":\"reply\"}"}],"has_more":false}"#.utf8)

        let response = try JSONDecoder().decode(DiscourseDraftListResponse.self, from: data)

        XCTAssertEqual(response.drafts.count, 1)
        XCTAssertEqual(response.drafts[0].data.reply, "saved reply")
        XCTAssertEqual(response.drafts[0].topicId, 17)
        XCTAssertEqual(response.drafts[0].replyToPostNumber, 3)
    }

    func testSummaryDecodesSideloadedSections() throws {
        let data = Data(#"{"user_summary":{"days_visited":10,"posts_read_count":20,"likes_received":30,"likes_given":5,"topic_count":2,"post_count":9,"time_read":600,"bookmark_count":1,"topics_entered":7,"recent_time_read":100,"replies":[{"topic_id":17,"post_number":3,"like_count":2}],"links":[{"url":"https://example.test","clicks":4,"topic_id":17}],"most_replied_to_users":[{"id":2,"username":"alice","count":3}],"top_categories":[{"id":5,"name":"Dev","topic_count":2,"post_count":4}]},"topics":[{"id":17,"title":"Topic","like_count":6}],"badges":[{"id":1,"name":"Badge","badge_type_id":3}]}"#.utf8)

        let response = try JSONDecoder().decode(DiscourseUserSummaryResponse.self, from: data)

        XCTAssertEqual(response.userSummary.postsReadCount, 20)
        XCTAssertEqual(response.userSummary.replies.first?.topic?.title, "Topic")
        XCTAssertEqual(response.userSummary.links.first?.clicks, 4)
        XCTAssertEqual(response.userSummary.mostRepliedToUsers.first?.username, "alice")
        XCTAssertEqual(response.userSummary.topCategories.first?.name, "Dev")
        XCTAssertEqual(response.userSummary.badges.first?.name, "Badge")
    }

    func testSummaryUsesSideloadedBadgeDefinitionsWhenEmbeddedBadgesAreReferences() throws {
        let data = Data(#"{"user_summary":{"badges":[{"badge_id":1,"count":2}]},"badges":[{"id":1,"name":"Anniversary","badge_type_id":3}]}"#.utf8)

        let response = try JSONDecoder().decode(DiscourseUserSummaryResponse.self, from: data)

        XCTAssertEqual(response.userSummary.badges.count, 1)
        XCTAssertEqual(response.userSummary.badges.first?.id, 1)
        XCTAssertEqual(response.userSummary.badges.first?.name, "Anniversary")
    }

    func testUserRoutesUseExpectedPathsAndMethods() {
        XCTAssertEqual(DiscourseRouter.userCard(username: "sam").path, "/u/sam/card.json")
        XCTAssertEqual(DiscourseRouter.follow(username: "sam").path, "/follow/sam")
        XCTAssertEqual(DiscourseRouter.follow(username: "sam").method, .put)
        XCTAssertEqual(DiscourseRouter.unfollow(username: "sam").method, .delete)
        XCTAssertEqual(
            DiscourseRouter.userNotificationLevel(username: "sam").path,
            "/u/sam/notification_level.json"
        )
        XCTAssertEqual(
            DiscourseRouter.userActions(username: "sam", filter: "4,5", offset: 30).path,
            "/user_actions.json?username=sam&filter=4,5&offset=30"
        )
        XCTAssertEqual(
            DiscourseRouter.userReactions(username: "sam", beforeReactionUserId: 9).path,
            "/discourse-reactions/posts/reactions.json?username=sam&before_reaction_user_id=9"
        )
        XCTAssertEqual(DiscourseRouter.following(username: "sam").path, "/u/sam/follow/following")
        XCTAssertEqual(DiscourseRouter.followers(username: "sam").path, "/u/sam/follow/followers")
        XCTAssertEqual(DiscourseRouter.drafts(offset: 20, limit: 20).path, "/drafts.json?offset=20&limit=20")
        XCTAssertEqual(
            DiscourseRouter.deleteDraft(key: "topic_17", sequence: 7).path,
            "/drafts/topic_17.json?sequence=7"
        )
        XCTAssertEqual(DiscourseRouter.deleteDraft(key: "topic_17", sequence: 7).method, .delete)
        XCTAssertEqual(
            DiscourseRouter.createdTopics(username: "sam", page: 2).path,
            "/topics/created-by/sam.json?page=2"
        )
    }
}
