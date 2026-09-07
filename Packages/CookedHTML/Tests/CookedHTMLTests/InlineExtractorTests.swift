import XCTest
@testable import CookedHTML

final class InlineExtractorTests: XCTestCase {

    private func parseInlines(_ html: String) -> [InlineNode] {
        let blocks = CookedHTMLParser.parse(html: "<p>\(html)</p>")
        guard case .paragraph(let inlines) = blocks.first else { return [] }
        return inlines
    }

    // MARK: - Plain Text

    func testPlainText() {
        let inlines = parseInlines("Hello world")
        XCTAssertEqual(inlines, [.text("Hello world")])
    }

    // MARK: - Bold

    func testBold() {
        let inlines = parseInlines("<strong>bold</strong>")
        XCTAssertEqual(inlines, [.styledText("bold", .bold)])
    }

    func testBoldWithB() {
        let inlines = parseInlines("<b>bold</b>")
        XCTAssertEqual(inlines, [.styledText("bold", .bold)])
    }

    func testMarkdownBoldInTextNode() {
        let inlines = parseInlines("before **bold text** after")
        XCTAssertEqual(inlines, [
            .text("before "),
            .styledText("bold text", .bold),
            .text(" after"),
        ])
    }

    func testMarkdownBoldInListItemTextNode() {
        let blocks = CookedHTMLParser.parse(html: "<ul><li>**项目介绍**：是</li></ul>")
        guard case .list(_, _, let items) = blocks.first else {
            XCTFail("Expected list")
            return
        }
        XCTAssertEqual(items.first?.content, [
            .styledText("项目介绍", .bold),
            .text("：是"),
        ])
    }

    func testUnpairedMarkdownBoldAtStartOfListItem() {
        let blocks = CookedHTMLParser.parse(
            html: "<ul><li>**以上选择我承诺是永久有效的，接受社区和佬友监督：是</li></ul>"
        )
        guard case .list(_, _, let items) = blocks.first else {
            XCTFail("Expected list")
            return
        }
        XCTAssertEqual(items.first?.content, [
            .styledText("以上选择我承诺是永久有效的，接受社区和佬友监督：是", .bold),
        ])
    }

    func testMarkdownBoldWrappingLinkAcrossLineBreaks() {
        let inlines = parseInlines("**<br><a href=\"https://linux.do\">地址：点击即可</a><br>**")
        XCTAssertEqual(inlines, [
            .link(href: "https://linux.do", children: [.styledText("地址：点击即可", .bold)]),
        ])
    }

    func testTightListPreservesInlineCode() {
        let blocks = CookedHTMLParser.parse(
            html: "<ul><li>支持<code>授权登录</code>和<code>web登录</code></li></ul>"
        )
        guard case .list(_, _, let items) = blocks.first else {
            XCTFail("Expected list")
            return
        }
        XCTAssertEqual(items.first?.content, [
            .text("支持"),
            .code("授权登录"),
            .text("和"),
            .code("web登录"),
        ])
    }

    func testParagraphWrappedListItemPreservesInlineCode() {
        let blocks = CookedHTMLParser.parse(
            html: "<ul><li><p>支持<code>x</code></p></li></ul>"
        )
        guard case .list(_, _, let items) = blocks.first else {
            XCTFail("Expected list")
            return
        }
        XCTAssertEqual(items.first?.content, [
            .text("支持"),
            .code("x"),
        ])
    }

    func testListItemMarkdownBoldWithInlineCode() {
        let blocks = CookedHTMLParser.parse(
            html: "<ul><li>**项目**：<code>Dexo</code></li></ul>"
        )
        guard case .list(_, _, let items) = blocks.first else {
            XCTFail("Expected list")
            return
        }
        XCTAssertEqual(items.first?.content, [
            .styledText("项目", .bold),
            .text("："),
            .code("Dexo"),
        ])
    }

    // MARK: - Italic

    func testItalic() {
        let inlines = parseInlines("<em>italic</em>")
        XCTAssertEqual(inlines, [.styledText("italic", .italic)])
    }

    // MARK: - Strikethrough

    func testStrikethrough() {
        let inlines = parseInlines("<s>deleted</s>")
        XCTAssertEqual(inlines, [.styledText("deleted", .strikethrough)])
    }

    func testDel() {
        let inlines = parseInlines("<del>deleted</del>")
        XCTAssertEqual(inlines, [.styledText("deleted", .strikethrough)])
    }

    // MARK: - Combined Styles

    func testBoldItalic() {
        let inlines = parseInlines("<strong><em>bold italic</em></strong>")
        let expected: TextStyle = [.bold, .italic]
        XCTAssertEqual(inlines, [.styledText("bold italic", expected)])
    }

    // MARK: - Links

    func testLink() {
        let inlines = parseInlines("<a href=\"https://example.com\">click</a>")
        XCTAssertEqual(inlines, [.link(href: "https://example.com", children: [.text("click")])])
    }

    func testLinkWithBaseURL() {
        let blocks = CookedHTMLParser.parse(html: "<p><a href=\"/t/123\">topic</a></p>", baseURL: "https://linux.do")
        guard case .paragraph(let inlines) = blocks.first else {
            XCTFail("Expected paragraph")
            return
        }
        if case .link(let href, _) = inlines.first {
            XCTAssertEqual(href, "https://linux.do/t/123")
        } else {
            XCTFail("Expected link")
        }
    }

    // MARK: - Inline Code

    func testInlineCode() {
        let inlines = parseInlines("<code>let x = 1</code>")
        XCTAssertEqual(inlines, [.code("let x = 1")])
    }

    func testLeftoverMarkdownBackticksBecomeInlineCode() {
        let inlines = parseInlines("支持`授权登录`和`web登录`")
        XCTAssertEqual(inlines, [
            .text("支持"),
            .code("授权登录"),
            .text("和"),
            .code("web登录"),
        ])
    }

    func testLeftoverFullwidthBackticksBecomeInlineCode() {
        let inlines = parseInlines("支持｀表格｀")
        XCTAssertEqual(inlines, [
            .text("支持"),
            .code("表格"),
        ])
    }

    func testUnmatchedBacktickStaysLiteral() {
        let inlines = parseInlines("use `unclosed")
        XCTAssertEqual(inlines, [.text("use `unclosed")])
    }

    func testTightListLeftoverBackticksBecomeInlineCode() {
        let blocks = CookedHTMLParser.parse(
            html: "<ul><li>支持`授权登录`和`web登录`</li></ul>"
        )
        guard case .list(_, _, let items) = blocks.first else {
            XCTFail("Expected list")
            return
        }
        XCTAssertEqual(items.first?.content, [
            .text("支持"),
            .code("授权登录"),
            .text("和"),
            .code("web登录"),
        ])
    }

    // MARK: - Inline Image

    func testInlineImage() {
        let inlines = parseInlines("Hello <img src=\"emoji.png\" class=\"emoji\" alt=\":smile:\">")
        // Find the image node in the inlines
        let imageNode = inlines.first(where: {
            if case .image = $0 { return true }
            return false
        })
        if case .image(let src, let alt, _, _, let isEmoji) = imageNode {
            XCTAssertEqual(src, "emoji.png")
            XCTAssertEqual(alt, ":smile:")
            XCTAssertTrue(isEmoji)
        } else {
            XCTFail("Expected inline image, got \(inlines)")
        }
    }

    // MARK: - Line Break

    func testLineBreak() {
        let inlines = parseInlines("line1<br>line2")
        XCTAssertTrue(inlines.contains(.lineBreak))
    }

    // MARK: - Mixed Content

    func testMixedContent() {
        let inlines = parseInlines("Hello <strong>bold</strong> and <em>italic</em>")
        XCTAssertTrue(inlines.count >= 4) // text, styled, text, styled (with possible whitespace merging)
    }

    // MARK: - Text Merging

    func testAdjacentTextMerging() {
        // Nested spans should produce merged text
        let inlines = parseInlines("<span>a</span><span>b</span>")
        XCTAssertEqual(inlines, [.text("ab")])
    }

    // MARK: - Mention

    func testMention() {
        let inlines = parseInlines("<a class=\"mention\" href=\"/u/sam\">@sam</a>")
        XCTAssertEqual(inlines, [.mention(username: "sam", href: "/u/sam")])
    }

    func testMentionGroup() {
        let inlines = parseInlines("<a class=\"mention-group\" href=\"/g/admins\">@admins</a>")
        XCTAssertEqual(inlines, [.mentionGroup(name: "admins", href: "/g/admins")])
    }

    func testMentionInParagraph() {
        let inlines = parseInlines("Hello <a class=\"mention\" href=\"/u/sam\">@sam</a> how are you?")
        XCTAssertEqual(inlines, [
            .text("Hello "),
            .mention(username: "sam", href: "/u/sam"),
            .text(" how are you?"),
        ])
    }

    // MARK: - Hashtag

    func testHashtagCooked() {
        let inlines = parseInlines("<a class=\"hashtag-cooked\" href=\"/c/feature\" data-type=\"category\">#feature</a>")
        XCTAssertEqual(inlines, [.hashtag(text: "feature", href: "/c/feature", type: "category", icon: nil)])
    }

    func testHashtagLegacy() {
        let inlines = parseInlines("<a class=\"hashtag\" href=\"/tag/swift\">#swift</a>")
        XCTAssertEqual(inlines, [.hashtag(text: "swift", href: "/tag/swift", type: nil, icon: nil)])
    }

    func testHashtagCookedExtractsDiscourseIcon() {
        let html = """
        <a class="hashtag-cooked" href="/tag/%E6%8A%BD%E5%A5%96" data-type="tag">
          <span class="hashtag-icon-placeholder" data-icon="shuffle">
            <svg class="fa d-icon d-icon-shuffle svg-icon"><use href="#shuffle"></use></svg>
          </span>
          <span>抽奖</span>
        </a>
        """
        let inlines = parseInlines(html)
        XCTAssertEqual(
            inlines,
            [.hashtag(text: "抽奖", href: "/tag/%E6%8A%BD%E5%A5%96", type: "tag", icon: "shuffle")]
        )
    }

    // MARK: - Spoiler

    func testInlineSpoiler() {
        let inlines = parseInlines("<span class=\"spoiler\">secret</span>")
        XCTAssertEqual(inlines, [.spoiler(children: [.text("secret")])])
    }

    func testSpoilerWithStyledContent() {
        let inlines = parseInlines("<span class=\"spoiler\"><strong>bold secret</strong></span>")
        XCTAssertEqual(inlines, [.spoiler(children: [.styledText("bold secret", .bold)])])
    }
}
