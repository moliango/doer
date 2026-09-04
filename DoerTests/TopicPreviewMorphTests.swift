import XCTest
@testable import Doer

final class TopicPreviewMorphTests: XCTestCase {
    @MainActor
    func testTopicPreviewLaysOutInitialContent() {
        let topic = DiscourseTopicList.Topic.makeRecommendation(
            id: 10,
            title: "Preview title",
            fancyTitle: nil,
            postsCount: 3,
            replyCount: 2,
            categoryId: nil,
            createdAt: "2026-01-01T00:00:00.000Z",
            lastPostedAt: nil,
            tags: [],
            excerpt: "Initial preview content"
        )
        let controller = TopicPreviewViewController(
            api: DiscourseAPI(baseURL: "https://preview.invalid"),
            topic: topic,
            categoryName: nil,
            firstPostLoader: { nil }
        )

        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()

        let labels = allLabels(in: controller.view)
        XCTAssertTrue(labels.contains(where: { $0.text == "Initial preview content" }))
        XCTAssertTrue(controller.children.isEmpty)
        XCTAssertGreaterThan(controller.view.bounds.height, 0)
    }

    @MainActor
    func testPreviewLinkPolicyKeepsSameTopicInPlace() {
        XCTAssertEqual(
            TopicPreviewLinkPolicy.behavior(
                destination: .topic(id: 10, postNumber: 4),
                currentTopicId: 10
            ),
            .stay
        )
        XCTAssertEqual(
            TopicPreviewLinkPolicy.behavior(
                destination: .topic(id: 11, postNumber: 1),
                currentTopicId: 10
            ),
            .navigateOut
        )
        XCTAssertEqual(
            TopicPreviewLinkPolicy.behavior(
                destination: .user(username: "alice"),
                currentTopicId: 10
            ),
            .navigateOut
        )
    }

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

    private func allLabels(in view: UIView) -> [UILabel] {
        var labels: [UILabel] = []
        for subview in view.subviews {
            if let label = subview as? UILabel {
                labels.append(label)
            }
            labels.append(contentsOf: allLabels(in: subview))
        }
        return labels
    }
}
