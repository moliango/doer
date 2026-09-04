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

    func testBoldWrapSelectsInnerAndTogglesOff() {
        let wrapped = ExperimentalComposerWrapPolicy.wrap(
            inner: "hello",
            start: "**",
            end: "**",
            placeholder: "粗体"
        )
        XCTAssertEqual(wrapped.raw, "**hello**")
        XCTAssertEqual(wrapped.selectedInner, "hello")
        XCTAssertEqual(wrapped.marker, "**")

        let toggled = ExperimentalComposerWrapPolicy.wrap(
            inner: "**hello**",
            start: "**",
            end: "**",
            placeholder: "粗体"
        )
        XCTAssertEqual(toggled.raw, "hello")
        XCTAssertEqual(toggled.selectedInner, "hello")
        XCTAssertEqual(toggled.marker, "")

        let empty = ExperimentalComposerWrapPolicy.wrap(
            inner: "",
            start: "**",
            end: "**",
            placeholder: "粗体"
        )
        XCTAssertEqual(empty.raw, "**粗体**")
        XCTAssertEqual(empty.selectedInner, "粗体")
    }

    func testCaretGeometryEnforcesReadableInsertionPoint() {
        let font = UIFont.systemFont(ofSize: 16)
        let minHeight = ComposerCaretGeometry.minHeight(for: font)
        XCTAssertGreaterThanOrEqual(minHeight, 18)

        let collapsed = ComposerCaretGeometry.normalized(
            CGRect(x: 0, y: 4, width: 1, height: 2),
            font: font,
            bounds: CGRect(x: 0, y: 0, width: 320, height: 40)
        )
        XCTAssertEqual(collapsed.width, ComposerCaretGeometry.minWidth)
        XCTAssertEqual(collapsed.height, minHeight)

        let clipped = ComposerCaretGeometry.normalized(
            CGRect(x: -3, y: 0, width: 2, height: minHeight),
            font: font,
            bounds: CGRect(x: 0, y: 0, width: 320, height: 40)
        )
        XCTAssertEqual(clipped.origin.x, 0)

        let empty = ComposerCaretGeometry.normalized(
            .zero,
            font: font,
            bounds: CGRect(x: 0, y: 0, width: 320, height: 40)
        )
        XCTAssertEqual(empty.height, minHeight)
        XCTAssertEqual(empty.width, ComposerCaretGeometry.minWidth)
    }

    func testHarvestSkipsMarkedText() {
        XCTAssertFalse(ExperimentalComposerEditingPolicy.shouldHarvest(hasMarkedText: true))
        XCTAssertTrue(ExperimentalComposerEditingPolicy.shouldHarvest(hasMarkedText: false))
    }

    func testImageInsertGetsTrailingParagraphAndFocus() {
        let blocks: [ExperimentalComposerBlock] = [
            .paragraph("hello"),
            .image(alt: "a", url: "https://example.com/a.png", title: nil),
        ]
        XCTAssertTrue(
            ExperimentalComposerEditingPolicy.needsTrailingParagraph(
                in: blocks,
                insertAt: 1,
                insertedCount: 1
            )
        )
        let withTail = ExperimentalComposerEditingPolicy.ensuringEditableTail(blocks)
        XCTAssertEqual(withTail.last, .paragraph(""))
        XCTAssertEqual(
            ExperimentalComposerEditingPolicy.focusIndexAfterInsert(
                in: withTail,
                insertAt: 1,
                insertedCount: 1
            ),
            2
        )
    }

    func testQuoteCardLoadGetsEditableTail() {
        let raw = "[quote=\"alice, post:1, topic:2\"]\nhello\n[/quote]"
        let parsed = ExperimentalComposerDocument.parse(raw)
        let tailed = ExperimentalComposerEditingPolicy.ensuringEditableTail(parsed.blocks)
        XCTAssertEqual(tailed.count, 2)
        XCTAssertEqual(tailed.last, .paragraph(""))
    }

    func testMentionQueryRequiresBoundaryAndCapturesTerm() {
        let hit = ComposerMentionQuery.activeMentionQuery(in: "hello @al", cursor: 9)
        XCTAssertEqual(hit?.term, "al")
        XCTAssertNil(ComposerMentionQuery.activeMentionQuery(in: "mail@al", cursor: 7))
        XCTAssertEqual(
            ComposerMentionQuery.filterSeeds(
                [
                    DiscourseMentionUser(username: "alice", name: "Alice", avatarTemplate: nil),
                    DiscourseMentionUser(username: "bob", name: "Bob", avatarTemplate: nil),
                ],
                term: "al"
            ).map(\.username),
            ["alice"]
        )
    }

    func testHistoryUndoRedoRestoresSnapshot() {
        let first = ExperimentalComposerSnapshot(markdown: "a", focusedIndex: 0, caret: 1)
        let second = ExperimentalComposerSnapshot(markdown: "ab", focusedIndex: 0, caret: 2)
        let pushed = ExperimentalComposerHistory.pushing(first, undo: [], redo: [second])
        XCTAssertEqual(pushed.undo, [first])
        XCTAssertEqual(pushed.redo, [])
        let undone = ExperimentalComposerHistory.undo(current: second, undo: pushed.undo, redo: pushed.redo)
        XCTAssertEqual(undone?.current, first)
        XCTAssertEqual(undone?.redo, [second])
        let redone = ExperimentalComposerHistory.redo(
            current: first,
            undo: undone?.undo ?? [],
            redo: undone?.redo ?? []
        )
        XCTAssertEqual(redone?.current, second)
    }

    func testQuotePolicyNestsByParsingInnerArrowsAndUnwraps() {
        XCTAssertEqual(
            ExperimentalComposerQuotePolicy.cycling(.paragraph("hi")),
            .quote("hi")
        )
        XCTAssertEqual(
            ExperimentalComposerQuotePolicy.cycling(.quote("hi")),
            .paragraph("hi")
        )
        XCTAssertEqual(
            ExperimentalComposerQuotePolicy.cycling(.quote("> nested")),
            .quote("nested")
        )
    }

    func testBlockRangeConvertToListAndMarkdown() {
        let blocks: [ExperimentalComposerBlock] = [
            .paragraph("a"),
            .paragraph("b"),
            .paragraph("c"),
        ]
        let listed = ExperimentalComposerBlockRangePolicy.convertingToList(
            blocks,
            range: 0..<2,
            ordered: false
        )
        XCTAssertEqual(listed[0], .listItem(ordered: false, text: "a"))
        XCTAssertEqual(listed[1], .listItem(ordered: false, text: "b"))
        XCTAssertEqual(listed[2], .paragraph("c"))
        let toggled = ExperimentalComposerBlockRangePolicy.convertingToList(
            listed,
            range: 0..<2,
            ordered: false
        )
        XCTAssertEqual(toggled[0], .paragraph("a"))
        XCTAssertEqual(
            ExperimentalComposerBlockRangePolicy.markdown(of: listed, range: 0..<2),
            "- a\n- b"
        )
    }

    func testPollPolicyPrefersFocusedLiteral() {
        let poll = "[poll name=test]\n- a\n- b\n[/poll]"
        XCTAssertTrue(
            ExperimentalComposerPollPolicy.shouldReplaceFocusedBlock(
                focusedRaw: poll,
                selectedRaw: ""
            )
        )
        XCTAssertFalse(
            ExperimentalComposerPollPolicy.shouldReplaceFocusedBlock(
                focusedRaw: "hello",
                selectedRaw: "hello"
            )
        )
    }

    func testFormattingMarksHeadingAndPoll() {
        let heading = ExperimentalComposerFormatting.marks(
            block: .heading(2, "Title"),
            selectedRaw: "",
            isBold: false,
            isItalic: false,
            isStrike: false
        )
        XCTAssertEqual(heading.headingLevel, 2)
        let poll = ExperimentalComposerFormatting.marks(
            block: .literal("[poll name=x]\n- a\n[/poll]"),
            selectedRaw: "",
            isBold: true,
            isItalic: false,
            isStrike: false
        )
        XCTAssertTrue(poll.isPoll)
        XCTAssertTrue(poll.isBold)
        XCTAssertTrue(poll.isCode)
    }

    func testParagraphAfterIslandDoesNotDuplicateTail() {
        let blocks: [ExperimentalComposerBlock] = [
            .quoteCard(
                username: "alice",
                displayName: nil,
                postNumber: 1,
                topicId: 2,
                full: false,
                inner: "hello"
            ),
            .paragraph("already"),
        ]
        XCTAssertFalse(
            ExperimentalComposerEditingPolicy.needsTrailingParagraph(
                in: blocks,
                insertAt: 0,
                insertedCount: 1
            )
        )
        XCTAssertEqual(ExperimentalComposerEditingPolicy.ensuringEditableTail(blocks), blocks)
    }

    private func assertRoundTrip(_ raw: String) {
        let back = ExperimentalComposerDocument.parse(raw).markdown
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(back, raw)
    }
}
