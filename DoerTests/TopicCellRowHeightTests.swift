import XCTest
@testable import Doer

final class TopicCellRowHeightTests: XCTestCase {
    func testShortTitleIsOneLine() {
        let one = TopicCellRowHeight.titleBlockHeight(
            title: "短标题",
            tableWidth: 390,
            showsReplyCount: true
        )
        XCTAssertEqual(one, TopicCellRowHeight.lineHeight)
    }

    func testTitleCapsAtFourLines() {
        let long = String(repeating: "这是一个很长的话题标题需要换行", count: 12)
        let capped = TopicCellRowHeight.titleBlockHeight(
            title: long,
            tableWidth: 390,
            showsReplyCount: true
        )
        XCTAssertEqual(capped, TopicCellRowHeight.lineHeight * 4)
    }

    func testRowHeightIncludesChrome() {
        let titleHeight = TopicCellRowHeight.titleBlockHeight(
            title: "短标题",
            tableWidth: 390,
            showsReplyCount: true
        )
        let row = TopicCellRowHeight.height(
            title: "短标题",
            tableWidth: 390,
            showsReplyCount: true
        )
        XCTAssertEqual(row, titleHeight + 50)
    }

    func testHidingReplyCountDoesNotGrowAShortTitle() {
        let shown = TopicCellRowHeight.titleBlockHeight(
            title: "短标题",
            tableWidth: 390,
            showsReplyCount: true
        )
        let hidden = TopicCellRowHeight.titleBlockHeight(
            title: "短标题",
            tableWidth: 390,
            showsReplyCount: false
        )
        XCTAssertEqual(shown, hidden)
    }
}
