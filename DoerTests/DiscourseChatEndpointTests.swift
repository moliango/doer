import XCTest
@testable import Doer

final class DiscourseChatEndpointTests: XCTestCase {
    func testSendUsesLegacyCreateRoute() {
        XCTAssertEqual(DiscourseChatEndpoint.sendMessage(channelId: 42), "/chat/42")
    }

    func testModernSendAndReadStayOnChatAPI() {
        XCTAssertEqual(
            DiscourseChatEndpoint.sendMessageModern(channelId: 42),
            "/chat/api/channels/42/messages"
        )
        XCTAssertEqual(
            DiscourseChatEndpoint.messages(channelId: 42, pageSize: 50),
            "/chat/api/channels/42/messages?page_size=50"
        )
        XCTAssertEqual(DiscourseChatEndpoint.channels(), "/chat/api/me/channels")
    }

    func testPublicChannelDecodesCategoryLogoObject() throws {
        let json = """
        {
          "id": 7,
          "title": "公告",
          "chatable_type": "Category",
          "chatable": {
            "name": "公告",
            "color": "E45735",
            "uploaded_logo": { "url": "/uploads/default/original/1X/logo.png" }
          }
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(
            channel.avatarURL(baseURL: "https://example.com")?.absoluteString,
            "https://example.com/uploads/default/original/1X/logo.png"
        )
        XCTAssertEqual(channel.monogramLetter, "#")
        XCTAssertTrue(channel.isPublicChannel)
        XCTAssertEqual(channel.accentHexColor, "E45735")
    }

    func testPublicChannelWithoutLogoUsesHashMonogram() throws {
        let json = """
        {
          "id": 3,
          "title": "水区",
          "chatable_type": "Category",
          "chatable": { "name": "水区", "color": "F5D76E" }
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertNil(channel.avatarURL(baseURL: "https://example.com"))
        XCTAssertEqual(channel.monogramLetter, "#")
        XCTAssertEqual(channel.accentHexColor, "F5D76E")
    }

    func testChannelEmojiAndIconAliasDecode() throws {
        let json = """
        {
          "id": 9,
          "title": "闲聊",
          "emoji": "💬",
          "icon": { "url": "/uploads/icon.png" },
          "chatable_type": "Category",
          "chatable": { "color": "0088CC" }
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(channel.monogramLetter, "💬")
        XCTAssertEqual(
            channel.avatarURL(baseURL: "https://example.com")?.absoluteString,
            "https://example.com/uploads/icon.png"
        )
    }

    func testShortcodeEmojiUsesTwemojiAvatarForPublicChannel() throws {
        EmojiStore.clearCache()
        let json = """
        {
          "id": 10,
          "title": "常规频道",
          "emoji": ":speech_balloon:",
          "chatable_type": "Category"
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(channel.namedEmojiCode, "speech_balloon")
        XCTAssertEqual(channel.monogramLetter, "#")
        XCTAssertEqual(
            channel.avatarURL(baseURL: "https://example.com")?.absoluteString,
            "https://example.com/images/emoji/twitter/speech_balloon.png?v=12"
        )
    }

    func testBareEmojiNameUsesTwemojiAvatar() throws {
        EmojiStore.clearCache()
        let json = """
        {
          "id": 12,
          "title": "常规频道",
          "emoji": "speech_balloon",
          "chatable_type": "Category"
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(channel.namedEmojiCode, "speech_balloon")
        XCTAssertEqual(
            channel.avatarURL(baseURL: "https://linux.do")?.absoluteString,
            "https://linux.do/images/emoji/twitter/speech_balloon.png?v=12"
        )
    }

    func testPublicChannelDecodesUploadedLogoString() throws {
        let json = """
        {
          "id": 8,
          "title": "General",
          "chatable": {
            "uploaded_logo": "/uploads/logo.png"
          }
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(
            channel.avatarURL(baseURL: "https://forum.example")?.absoluteString,
            "https://forum.example/uploads/logo.png"
        )
        XCTAssertEqual(channel.monogramLetter, "G")
    }

    func testProtocolRelativeS3LogoDoesNotProxyThroughForumOrigin() throws {
        let json = """
        {
          "id": 4,
          "title": "开发调优",
          "chatable_type": "Category",
          "chatable": {
            "uploaded_logo": {
              "url": "//linuxdo-uploads.s3.ldstatic.com/original/3X/c/5/c59e612cafa47255927d8c73f90e8dac05f78b5c.png"
            }
          }
        }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(
            channel.avatarURL(baseURL: "https://linux.do")?.absoluteString,
            "https://linuxdo-uploads.s3.ldstatic.com/original/3X/c/5/c59e612cafa47255927d8c73f90e8dac05f78b5c.png"
        )
        XCTAssertEqual(
            DiscourseChatMediaURL.resolve(
                "//linuxdo-uploads.s3.ldstatic.com/original/3X/c/5/c59e612cafa47255927d8c73f90e8dac05f78b5c.png",
                baseURL: "https://linux.do/"
            )?.absoluteString,
            "https://linuxdo-uploads.s3.ldstatic.com/original/3X/c/5/c59e612cafa47255927d8c73f90e8dac05f78b5c.png"
        )
    }

    func testChatableIntegerDoesNotDropTheChannel() throws {
        let json = """
        { "id": 11, "title": "Lounge", "chatable_type": "Category", "chatable": 4 }
        """.data(using: .utf8)!
        let channel = try JSONDecoder().decode(DiscourseChatChannel.self, from: json)
        XCTAssertEqual(channel.id, 11)
        XCTAssertNil(channel.chatable)
        XCTAssertEqual(channel.monogramLetter, "#")
    }

    func testFormatSendTimeTodayYesterdayAndOlder() {
        let calendar = Calendar.current
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let today = DiscourseChatMessage.formatSendTime(formatter.string(from: now), now: now)
        XCTAssertFalse(today.isEmpty)
        XCTAssertTrue(today.contains("\n"))
        XCTAssertTrue(today.contains("/"))
        XCTAssertTrue(today.contains(":"))

        let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)!
        let yesterday = DiscourseChatMessage.formatSendTime(formatter.string(from: yesterdayDate), now: now)
        XCTAssertTrue(yesterday.contains("\n"))
        XCTAssertTrue(yesterday.contains("/"))
        XCTAssertTrue(yesterday.contains(":"))

        let olderDate = calendar.date(byAdding: .day, value: -5, to: now)!
        let older = DiscourseChatMessage.formatSendTime(formatter.string(from: olderDate), now: now)
        XCTAssertTrue(older.contains("/"))
        XCTAssertTrue(older.contains("\n"))

        let lastYearDate = calendar.date(byAdding: .year, value: -1, to: now)!
        let lastYear = DiscourseChatMessage.formatSendTime(formatter.string(from: lastYearDate), now: now)
        XCTAssertTrue(lastYear.contains(String(calendar.component(.year, from: lastYearDate))))

        let sixDigit = DiscourseChatMessage.formatSendTime("2024-01-02T03:04:05.123456Z", now: now)
        XCTAssertFalse(sixDigit.isEmpty)
        XCTAssertTrue(sixDigit.contains("\n"))
    }

    func testUploadResponseDecodesChatUploadId() throws {
        let json = """
        {
          "id": 88,
          "short_url": "upload://abc.png",
          "original_filename": "photo.png",
          "width": 100,
          "height": 80
        }
        """.data(using: .utf8)!
        let upload = try JSONDecoder().decode(DiscourseUploadResponse.self, from: json)
        XCTAssertEqual(upload.id, 88)
        XCTAssertEqual(upload.shortURL, "upload://abc.png")
    }

    func testChatMessageDecodesUploadsAndResolvesCDNURL() throws {
        let json = """
        {
          "id": 12,
          "message": "![image](upload://abc.png)",
          "cooked": "<p></p>",
          "uploads": [
            {
              "id": 88,
              "url": "//cdn.example.com/original/1X/photo.png",
              "original_filename": "photo.png",
              "extension": "png",
              "width": 800,
              "height": 600
            }
          ]
        }
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(DiscourseChatMessage.self, from: json)
        XCTAssertEqual(message.displayBody, "")
        XCTAssertEqual(
            message.displayImageURLs(baseURL: "https://linux.do").map(\.absoluteString),
            ["https://cdn.example.com/original/1X/photo.png"]
        )
    }

    func testChatMessageFallsBackToCookedLightboxImage() throws {
        let json = """
        {
          "id": 13,
          "message": "",
          "cooked": "<p><a href=\\"https://cdn.example.com/full.jpg\\" class=\\"lightbox\\"><img src=\\"/uploads/thumb.jpg\\"></a></p>"
        }
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(DiscourseChatMessage.self, from: json)
        XCTAssertEqual(message.displayBody, "")
        XCTAssertEqual(
            message.displayImageURLs(baseURL: "https://linux.do").map(\.absoluteString),
            ["https://cdn.example.com/full.jpg"]
        )
    }

    func testTemplatesResponseDecodesWrappedAndBareArrays() throws {
        let wrapped = """
        {
          "templates": [
            { "id": 1, "title": "问候", "content": "你好" }
          ]
        }
        """.data(using: .utf8)!
        let wrappedDecoded = try JSONDecoder().decode(DiscourseTemplatesResponse.self, from: wrapped)
        XCTAssertEqual(wrappedDecoded.templates.count, 1)
        XCTAssertEqual(wrappedDecoded.templates[0].content, "你好")

        let bare = """
        [{ "id": 2, "title": "签到", "content": "打卡" }]
        """.data(using: .utf8)!
        let bareDecoded = try JSONDecoder().decode(DiscourseTemplatesResponse.self, from: bare)
        XCTAssertEqual(bareDecoded.templates.map(\.id), [2])
    }

    func testTemplateRouterPaths() {
        XCTAssertEqual(DiscourseRouter.discourseTemplates.path, "/discourse_templates")
        XCTAssertEqual(DiscourseRouter.discourseTemplates.method, .get)
        XCTAssertEqual(DiscourseRouter.useDiscourseTemplate(id: 9).path, "/discourse_templates/9/use")
        XCTAssertEqual(DiscourseRouter.useDiscourseTemplate(id: 9).method, .post)
    }

    func testDateMarkdownMatchesDiscourseLocalDateSyntax() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 24
        components.hour = 9
        components.minute = 5
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = zone
        let date = calendar.date(from: components)!
        XCTAssertEqual(
            DiscourseDateMarkdown.make(date: date, includeTime: true, timeZone: zone),
            "[date=2026-08-24 time=09:05:00 timezone=\"Asia/Shanghai\"]"
        )
        XCTAssertEqual(
            DiscourseDateMarkdown.make(date: date, includeTime: false, timeZone: zone),
            "[date=2026-08-24 timezone=\"Asia/Shanghai\"]"
        )
    }

    func testEntryBadgeCountsDMUnreadAndPublicMentionsOnly() throws {
        let json = """
        {
          "public_channels": [
            {
              "id": 1,
              "title": "大厅",
              "chatable_type": "Category",
              "current_user_membership": { "following": true, "muted": false }
            },
            {
              "id": 2,
              "title": "静音",
              "chatable_type": "Category",
              "current_user_membership": { "following": true, "muted": true }
            }
          ],
          "direct_message_channels": [
            {
              "id": 9,
              "title": "alice",
              "chatable_type": "DirectMessage",
              "current_user_membership": { "following": true, "muted": false }
            }
          ],
          "tracking": {
            "channel_tracking": {
              "1": { "unread_count": 12, "mention_count": 2 },
              "2": { "unread_count": 8, "mention_count": 3 },
              "9": { "unread_count": 4, "mention_count": 1 }
            }
          }
        }
        """
        let response = try JSONDecoder().decode(DiscourseChatChannelsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.entryBadgeCount, 7)
        XCTAssertEqual(response.unreadCount(for: response.publicChannels[0]), 12)
        XCTAssertEqual(response.unreadCount(for: response.directMessageChannels[0]), 4)
    }

    func testEntryBadgeFallsBackToMembershipWhenTrackingMissing() throws {
        let json = """
        {
          "public_channels": [
            {
              "id": 1,
              "chatable_type": "Category",
              "current_user_membership": { "unread_count": 9, "unread_mentions": 1 }
            }
          ],
          "direct_message_channels": [
            {
              "id": 2,
              "chatable_type": "DirectMessage",
              "current_user_membership": { "unread_count": 3, "unread_mentions": 2 }
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(DiscourseChatChannelsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.entryBadgeCount, 6)
    }

    func testBadgeTextCapsAtNinetyNine() {
        XCTAssertNil(DiscourseChatChannelsResponse.badgeText(for: 0))
        XCTAssertEqual(DiscourseChatChannelsResponse.badgeText(for: 7), "7")
        XCTAssertEqual(DiscourseChatChannelsResponse.badgeText(for: 99), "99")
        XCTAssertEqual(DiscourseChatChannelsResponse.badgeText(for: 100), "99+")
    }
}
