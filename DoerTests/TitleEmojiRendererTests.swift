import CookedHTML
import XCTest
@testable import Doer

final class TitleEmojiRendererTests: XCTestCase {
    override func tearDown() {
        EmojiStore.clearCache()
        super.tearDown()
    }

    func testContainsShortcode() {
        XCTAssertTrue(TitleEmojiRenderer.containsShortcode("hello :smile: world"))
        XCTAssertFalse(TitleEmojiRenderer.containsShortcode("hello world"))
        XCTAssertFalse(TitleEmojiRenderer.containsShortcode("no colons here"))
    }

    func testResolvedURLPrefersLookupMap() {
        let base = "https://linux.do"
        EmojiStore.save(
            [DiscourseEmojiEntry(name: "custom_dog", url: "/images/emoji/custom_dog.png", searchAliases: ["doggo"])],
            for: base
        )

        let custom = EmojiStore.resolvedURLString(for: "custom_dog", baseURL: base)
        XCTAssertEqual(custom, "https://linux.do/images/emoji/custom_dog.png")

        let alias = EmojiStore.resolvedURLString(for: "doggo", baseURL: base)
        XCTAssertEqual(alias, "https://linux.do/images/emoji/custom_dog.png")
    }

    func testResolvedURLFallsBackToStandardPathWhenMapEmpty() {
        EmojiStore.clearCache()
        // Prefer a code unlikely to be remapped by aliases.json.
        let url = EmojiStore.resolvedURLString(for: "rocket", baseURL: "https://linux.do")
        XCTAssertEqual(url, "https://linux.do/images/emoji/twitter/rocket.png?v=12")

        // Alias shortcodes still resolve through the canonical name.
        let aliased = EmojiStore.resolvedURLString(for: "smile", baseURL: "https://linux.do")
        XCTAssertEqual(
            aliased,
            "https://linux.do/images/emoji/twitter/grinning_face_with_smiling_eyes.png?v=12"
        )
    }

    func testResolvedURLFallsBackDeterministicallyAfterMapLoaded() {
        let base = "https://linux.do"
        EmojiStore.save(
            [DiscourseEmojiEntry(name: "only_one", url: "/images/emoji/only_one.png", searchAliases: nil)],
            for: base
        )
        // FluxDo always synthesizes a twitter path when custom map misses.
        let missingCustom = EmojiStore.resolvedURLString(for: "totally_unknown_custom_emoji_zzz", baseURL: base)
        XCTAssertEqual(
            missingCustom,
            "https://linux.do/images/emoji/twitter/totally_unknown_custom_emoji_zzz.png?v=12"
        )
    }

    func testPlainTitleRecoversShortcodesFromFancyHTML() {
        let fancy = #"Hello <img src="/images/emoji/twitter/smile.png" class="emoji" alt=":smile:" title=":smile:"> world"#
        let plain = TitleEmojiRenderer.plainTitle(fancyTitle: fancy, title: "Hello :smile: world")
        XCTAssertTrue(plain.contains(":smile:"))
        XCTAssertFalse(plain.contains("<img"))
    }

    func testAttributedTitleReplacesCustomNameWithDots() {
        // FluxDo allows non-word shortcode bodies such as `+1`.
        let base = "https://linux.do"
        EmojiStore.clearCache()
        let attributed = TitleEmojiRenderer.attributedTitle(
            "hi :+1: there",
            font: .systemFont(ofSize: 16),
            baseURL: base
        )
        var foundAttachment = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value is EmojiTextAttachment {
                foundAttachment = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(foundAttachment)
    }

    func testAttributedTitleReplacesShortcodeWithAttachment() {
        let base = "https://linux.do"
        EmojiStore.save(
            [DiscourseEmojiEntry(name: "smile", url: "/images/emoji/twitter/smile.png", searchAliases: nil)],
            for: base
        )
        let attributed = TitleEmojiRenderer.attributedTitle(
            "hi :smile: there",
            font: .systemFont(ofSize: 16),
            baseURL: base
        )
        var foundAttachment = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value is EmojiTextAttachment {
                foundAttachment = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(foundAttachment)
        XCTAssertFalse(attributed.string.contains(":smile:"))
    }

    func testReplacingShortcodesLeavesInlineCodeUntouched() {
        let font = UIFont.systemFont(ofSize: 16)
        let codeFont = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let attributed = NSAttributedString(
            string: ":rocket:",
            attributes: [.font: codeFont]
        )
        let result = TitleEmojiRenderer.replacingShortcodes(
            in: attributed,
            font: font,
            baseURL: "https://linux.do",
            skippingFont: codeFont
        )
        XCTAssertEqual(result.string, ":rocket:")
    }

    func testReplacingShortcodesAttachesRocketInBodyText() {
        let font = UIFont.systemFont(ofSize: 16)
        let attributed = NSAttributedString(
            string: "🔥 :rocket:起飞咯~",
            attributes: [.font: font]
        )
        let result = TitleEmojiRenderer.replacingShortcodes(
            in: attributed,
            font: font,
            baseURL: "https://linux.do"
        )
        XCTAssertFalse(result.string.contains(":rocket:"))
        var foundURL: String?
        result.enumerateAttribute(
            .cookedHTMLImageURL,
            in: NSRange(location: 0, length: result.length)
        ) { value, _, stop in
            foundURL = value as? String
            stop.pointee = true
        }
        XCTAssertEqual(foundURL, "https://linux.do/images/emoji/twitter/rocket.png?v=12")
    }

    func testAttributedTitleAttachesUnknownShortcodeForDeterministicFetch() {
        let base = "https://linux.do"
        EmojiStore.save(
            [DiscourseEmojiEntry(name: "smile", url: "/images/emoji/twitter/smile.png", searchAliases: nil)],
            for: base
        )
        let title = "hi :not_a_real_custom_emoji_zzz: there"
        let attributed = TitleEmojiRenderer.attributedTitle(
            title,
            font: .systemFont(ofSize: 16),
            baseURL: base
        )
        // Attachment replaces shortcode text; image may later 404 and stay blank,
        // but shortcode English text must not remain.
        XCTAssertFalse(attributed.string.contains(":not_a_real_custom_emoji_zzz:"))
        var found = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value is EmojiTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(found)
    }

    func testDecodeHTMLEntitiesHellip() {
        let fancy = "A出 bug, 服务不崩&hellip;&hellip;,难道?"
        // When raw title is empty, fancy is used and entities decode.
        let plain = TitleEmojiRenderer.plainTitle(fancyTitle: fancy, title: "")
        XCTAssertEqual(plain, "A出 bug, 服务不崩……,难道?")
        XCTAssertFalse(plain.contains("&hellip;"))
    }

    func testPreferRawTitleOverFancyArtifacts() {
        // fancy_title sometimes gains an extra ASCII period during cook.
        let fancy = "服务不崩&hellip;&hellip;.难道?"
        let raw = "服务不崩……难道?"
        let plain = TitleEmojiRenderer.plainTitle(fancyTitle: fancy, title: raw)
        XCTAssertEqual(plain, "服务不崩……难道?")
        XCTAssertFalse(plain.contains("&hellip;"))
        XCTAssertFalse(plain.contains("……."))
    }

    func testDecodeNumericHTMLEntities() {
        // &#8230; is …
        let fancy = "hello&#8230;world"
        let plain = TitleEmojiRenderer.decodeHTMLEntities(fancy)
        XCTAssertEqual(plain, "hello…world")
    }

}
