import XCTest
@testable import Doer

final class DailyCopyLocalizationTests: XCTestCase {
    func testComposerToolTitlesLocalizeWithoutHardcodedChinese() {
        let keys: [(ComposerMarkdownTool, String)] = [
            (.media, "reply.tool.media"),
            (.inlineCode, "reply.tool.inline_code"),
            (.codeBlock, "reply.tool.code_block"),
            (.insertBlock, "reply.tool.insert_block"),
            (.toc, "reply.tool.toc"),
            (.spoiler, "reply.tool.spoiler"),
            (.imageGrid, "reply.tool.image_grid"),
            (.poll, "reply.tool.poll"),
            (.aiReview, "reply.tool.ai_review"),
        ]
        for (tool, key) in keys {
            assertCatalogPair(key, context: "\(tool)")
            XCTAssertFalse(tool.title.isEmpty, "\(tool) runtime title")
        }
        for tool in ComposerMarkdownTool.allCases {
            XCTAssertFalse(tool.title.isEmpty, "\(tool) title should not be empty")
        }
    }

    func testHomeLoginCopyLocalizesWithoutHardcodedChinese() {
        let keys = [
            "home.login.title",
            "home.login.subtitle",
            "home.login.benefit.topics",
            "home.login.benefit.replies",
            "home.login.benefit.bookmarks",
        ]
        for key in keys {
            assertCatalogPair(key)
        }
    }

    func testCatalogLeaksCoveredForEnglishLocale() {
        let keys = [
            "ai.chat.title",
            "chat.title",
            "common.save",
            "doh.status.disabled",
            "doh.provider.tencent",
            "me.read_later",
            "notifications.mark_read",
            "settings.preferences",
            "trust.widget.title",
            "wechat_chat.hold_to_talk",
            "%@ 赞了你的帖子",
            "trust.widget.empty",
            "widget.quick.title",
            "plugins.newapi.overview",
        ]
        for key in keys {
            assertCatalogPair(key)
        }
    }

    func testComposerMediaAndPollCatalogNoLongerLeaksChineseIntoEnglish() {
        let keys = [
            "reply.tool.media.audio",
            "reply.tool.media.video",
            "reply.tool.media.voice",
            "reply.tool.placeholder.spoiler",
            "reply.tool.poll.single",
            "reply.tool.poll.multiple",
        ]
        for key in keys {
            assertCatalogPair(key)
        }
    }

    private func assertCatalogPair(_ key: String, context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let label = context.isEmpty ? key : "\(context) \(key)"
        let english = String(localized: String.LocalizationValue(key), locale: Locale(identifier: "en"))
        let chinese = String(localized: String.LocalizationValue(key), locale: Locale(identifier: "zh-Hans"))
        XCTAssertFalse(english.isEmpty, "\(label) English", file: file, line: line)
        XCTAssertFalse(chinese.isEmpty, "\(label) Chinese", file: file, line: line)
        XCTAssertNotEqual(english, chinese, "\(label) en/zh-Hans should differ", file: file, line: line)
        XCTAssertFalse(
            english.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF },
            "\(label) English leaked CJK: \(english)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            chinese.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF },
            "\(label) Chinese missing CJK: \(chinese)",
            file: file,
            line: line
        )
    }
}
