import XCTest
@testable import Doer

final class ExperimentalComposerDocumentTests: XCTestCase {
    func testEmptyParsesToParagraph() {
        let document = ExperimentalComposerDocument.parse("")
        XCTAssertEqual(document.blocks, [.paragraph("")])
        XCTAssertEqual(document.markdown, "")
    }

    func testPlainParagraphRoundTrip() {
        assertRoundTrip("hello world")
    }

    func testHeadingQuoteRoundTrip() {
        let raw = "# Title\n\n> quoted"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(document.blocks, [.heading(1, "Title"), .quote("quoted")])
        XCTAssertEqual(document.markdown, raw)
    }

    func testListItemsStayAdjacent() {
        let document = ExperimentalComposerDocument.parse("- one\n- two")
        XCTAssertEqual(
            document.blocks,
            [.listItem(ordered: false, text: "one"), .listItem(ordered: false, text: "two")]
        )
        XCTAssertEqual(document.markdown, "- one\n- two")
    }

    func testOrderedListNumbersIncrement() {
        let raw = "1. one\n2. two\n3. three"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(
            document.blocks,
            [
                .listItem(ordered: true, text: "one"),
                .listItem(ordered: true, text: "two"),
                .listItem(ordered: true, text: "three"),
            ]
        )
        XCTAssertEqual(document.markdown, raw)
        XCTAssertEqual(ExperimentalComposerDocument.orderedOrdinal(in: document.blocks, at: 0), 1)
        XCTAssertEqual(ExperimentalComposerDocument.orderedOrdinal(in: document.blocks, at: 1), 2)
        XCTAssertEqual(ExperimentalComposerDocument.orderedOrdinal(in: document.blocks, at: 2), 3)
    }

    func testOrderedListResetsAfterBreak() {
        let document = ExperimentalComposerDocument(blocks: [
            .listItem(ordered: true, text: "a"),
            .paragraph("mid"),
            .listItem(ordered: true, text: "b"),
        ])
        XCTAssertEqual(document.markdown, "1. a\n\nmid\n\n1. b")
        XCTAssertEqual(ExperimentalComposerDocument.orderedOrdinal(in: document.blocks, at: 2), 1)
    }

    func testOrderedListNormalizesRepeatedOnes() {
        let document = ExperimentalComposerDocument.parse("1. a\n1. b")
        XCTAssertEqual(document.markdown, "1. a\n2. b")
    }

    func testFencedCodeRoundTrip() {
        let raw = "```swift\nlet a = 1\n```"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(document.blocks, [.code(language: "swift", code: "let a = 1")])
        XCTAssertEqual(document.markdown, raw)
    }

    func testPollLiteralRoundTrip() {
        let raw = """
        [poll type=regular results=always]
        - Red
        - Blue
        [/poll]
        """
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(document.blocks, [.literal(raw)])
        XCTAssertEqual(document.markdown, raw)
    }

    func testPollSurvivesSurroundingParagraphs() {
        let poll = """
        [poll name=color]
        - Red
        [/poll]
        """
        let raw = "before\n\n\(poll)\n\nafter"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks[0], .paragraph("before"))
        XCTAssertEqual(document.blocks[1], .literal(poll))
        XCTAssertEqual(document.blocks[2], .paragraph("after"))
        XCTAssertEqual(document.markdown, raw)
    }

    func testQuoteTagBecomesQuoteCard() {
        let raw = "[quote=\"alice, post:1, topic:2\"]\nhello\n[/quote]"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(
            document.blocks,
            [
                .quoteCard(
                    username: "alice",
                    displayName: nil,
                    postNumber: 1,
                    topicId: 2,
                    full: false,
                    inner: "hello"
                ),
            ]
        )
        XCTAssertEqual(document.markdown, raw)
    }

    func testQuoteCardKeepsDisplayNameAndUsername() {
        let raw = "[quote=\"Alice, post:7, topic:42, username:alice\"]\nhi\n[/quote]"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(
            document.blocks,
            [
                .quoteCard(
                    username: "alice",
                    displayName: "Alice",
                    postNumber: 7,
                    topicId: 42,
                    full: false,
                    inner: "hi"
                ),
            ]
        )
        XCTAssertEqual(document.markdown, raw)
    }

    func testStandaloneImageBecomesIsland() {
        let raw = "before\n\n![cat](https://example.com/cat.png)\n\nafter"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks[0], .paragraph("before"))
        XCTAssertEqual(
            document.blocks[1],
            .image(alt: "cat", url: "https://example.com/cat.png", title: nil)
        )
        XCTAssertEqual(document.blocks[2], .paragraph("after"))
        XCTAssertEqual(document.markdown, raw)
    }

    func testImageWithTitleRoundTrips() {
        let raw = "![logo](https://example.com/a.png \"Brand\")"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(
            document.blocks,
            [.image(alt: "logo", url: "https://example.com/a.png", title: "Brand")]
        )
        XCTAssertEqual(document.markdown, raw)
    }

    func testPreviewImageURLResolvesUploadAndRelative() {
        XCTAssertEqual(
            ExperimentalComposerDocument.previewImageURL(
                from: "upload://abc123.png",
                baseURL: "https://linux.do/"
            )?.absoluteString,
            "https://linux.do/uploads/short-url/abc123.png"
        )
        XCTAssertEqual(
            ExperimentalComposerDocument.previewImageURL(
                from: "/uploads/default/original/1X/a.png",
                baseURL: "https://linux.do"
            )?.absoluteString,
            "https://linux.do/uploads/default/original/1X/a.png"
        )
        XCTAssertEqual(
            ExperimentalComposerDocument.previewImageURL(
                from: "//cdn.example.com/a.png",
                baseURL: "https://linux.do"
            )?.absoluteString,
            "https://cdn.example.com/a.png"
        )
        XCTAssertEqual(
            ExperimentalComposerDocument.previewImageURL(
                from: "https://img.example.com/a.png",
                baseURL: "https://linux.do"
            )?.absoluteString,
            "https://img.example.com/a.png"
        )
    }

    func testPolicyAndGridStayLiteral() {
        let policy = "[policy group=trust_level_0]\nbe nice\n[/policy]"
        let grid = "[grid]\n![](https://example.com/a.png)\n[/grid]"
        XCTAssertEqual(ExperimentalComposerDocument.parse(policy).blocks, [.literal(policy)])
        XCTAssertEqual(ExperimentalComposerDocument.parse(policy).markdown, policy)
        XCTAssertEqual(ExperimentalComposerDocument.parse(grid).blocks, [.literal(grid)])
        XCTAssertEqual(ExperimentalComposerDocument.parse(grid).markdown, grid)
    }

    func testInlineBoldSurvivesParagraphExport() {
        let raw = "hello **world**"
        let document = ExperimentalComposerDocument.parse(raw)
        XCTAssertEqual(document.blocks, [.paragraph(raw)])
        XCTAssertEqual(document.markdown, raw)
    }

    private func assertRoundTrip(_ raw: String) {
        let back = ExperimentalComposerDocument.parse(raw).markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(back, raw)
    }
}
