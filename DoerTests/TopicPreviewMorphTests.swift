import XCTest
@testable import Doer

final class TopicPreviewMorphTests: XCTestCase {
    func testXiaohongshuRowIdentifierMapsLeftAndRightTopics() {
        let ids = [10, 20, 30, 40, 50]
        let row0 = XiaohongshuHomeTopicListLayout.rowIdentifier(for: 0)
        XCTAssertEqual(XiaohongshuHomeTopicListLayout.rowIndex(from: row0), 0)
        XCTAssertEqual(
            XiaohongshuPreviewSelection.topic(in: ids, rowIdentifier: row0, side: .left),
            10
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.topic(in: ids, rowIdentifier: row0, side: .right),
            20
        )

        let row1 = XiaohongshuHomeTopicListLayout.rowIdentifier(for: 1)
        XCTAssertEqual(
            XiaohongshuPreviewSelection.topic(in: ids, rowIdentifier: row1, side: .left),
            30
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.topic(in: ids, rowIdentifier: row1, side: .right),
            40
        )

        let row2 = XiaohongshuHomeTopicListLayout.rowIdentifier(for: 2)
        XCTAssertEqual(
            XiaohongshuPreviewSelection.topic(in: ids, rowIdentifier: row2, side: .left),
            50
        )
        XCTAssertNil(
            XiaohongshuPreviewSelection.topic(in: ids, rowIdentifier: row2, side: .right)
        )
    }

    func testPositiveTopicIdIsNotAXiaohongshuRow() {
        XCTAssertNil(XiaohongshuHomeTopicListLayout.rowIndex(from: 42))
        XCTAssertNil(
            XiaohongshuPreviewSelection.topic(in: [1, 2], rowIdentifier: 42, side: .left)
        )
    }

    func testHitTestSplitsCardsAtMidX() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(
            XiaohongshuPreviewSelection.side(at: CGPoint(x: 10, y: 40), in: bounds),
            .left
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.side(at: CGPoint(x: 150, y: 40), in: bounds),
            .right
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.side(at: CGPoint(x: 100, y: 40), in: bounds),
            .right
        )
        XCTAssertNil(XiaohongshuPreviewSelection.side(at: CGPoint(x: -1, y: 40), in: bounds))
        XCTAssertNil(XiaohongshuPreviewSelection.side(at: CGPoint(x: 201, y: 40), in: bounds))
        XCTAssertNil(
            XiaohongshuPreviewSelection.side(
                at: CGPoint(x: 10, y: 40),
                in: .zero
            )
        )
    }

    func testUnpinnedTopicIndexMatchesPairOrder() {
        XCTAssertEqual(
            XiaohongshuPreviewSelection.unpinnedTopicIndex(rowIndex: 0, side: .left),
            0
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.unpinnedTopicIndex(rowIndex: 0, side: .right),
            1
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.unpinnedTopicIndex(rowIndex: 3, side: .left),
            6
        )
        XCTAssertEqual(
            XiaohongshuPreviewSelection.unpinnedTopicIndex(rowIndex: 3, side: .right),
            7
        )
    }
}
