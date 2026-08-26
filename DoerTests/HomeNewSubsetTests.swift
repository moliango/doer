import XCTest
@testable import Doer

final class HomeNewSubsetTests: XCTestCase {
    func testAllOmitsSubsetQuery() {
        XCTAssertNil(HomeNewSubset.all.apiValue)
        XCTAssertEqual(
            DiscourseRouter.newTopics(page: 0, subset: nil).path,
            "/new.json?page=0"
        )
    }

    func testTopicsAndRepliesAppendSubset() {
        XCTAssertEqual(HomeNewSubset.topics.apiValue, "topics")
        XCTAssertEqual(HomeNewSubset.replies.apiValue, "replies")
        XCTAssertEqual(
            DiscourseRouter.newTopics(page: 2, subset: "topics").path,
            "/new.json?page=2&subset=topics"
        )
        XCTAssertEqual(
            DiscourseRouter.categoryFilteredTopics(
                slug: "general",
                id: 4,
                filter: "new",
                page: 0,
                subset: "replies"
            ).path,
            "/c/general/4/l/new.json?page=0&subset=replies"
        )
    }
}
