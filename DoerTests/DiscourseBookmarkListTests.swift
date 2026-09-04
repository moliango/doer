import XCTest
@testable import Doer

final class DiscourseBookmarkListTests: XCTestCase {
    func testDecodesMoreBookmarksUrlForPagination() throws {
        let json = """
        {
          "user_bookmark_list": {
            "more_bookmarks_url": "/u/sam/bookmarks.json?page=1",
            "bookmarks": [
              {"id": 11, "title": "Pinned", "topic_id": 1989}
            ]
          }
        }
        """
        let list = try JSONDecoder().decode(DiscourseBookmarkList.self, from: Data(json.utf8))
        XCTAssertEqual(list.bookmarks.map(\.id), [11])
        XCTAssertEqual(list.moreBookmarksUrl, "/u/sam/bookmarks.json?page=1")
    }

    func testMissingMoreBookmarksUrlIsNil() throws {
        let json = """
        {
          "user_bookmark_list": {
            "bookmarks": [{"id": 3, "title": "Last"}]
          }
        }
        """
        let list = try JSONDecoder().decode(DiscourseBookmarkList.self, from: Data(json.utf8))
        XCTAssertEqual(list.bookmarks.count, 1)
        XCTAssertNil(list.moreBookmarksUrl)
    }

    func testSessionUsernamePrefersCurrentThenStored() {
        XCTAssertEqual(
            BookmarkSessionUsernamePolicy.readyUsername(current: " sam ", stored: "other"),
            "sam"
        )
        XCTAssertEqual(
            BookmarkSessionUsernamePolicy.readyUsername(current: "  ", stored: "alice"),
            "alice"
        )
        XCTAssertNil(BookmarkSessionUsernamePolicy.readyUsername(current: nil, stored: nil))
        XCTAssertNil(BookmarkSessionUsernamePolicy.readyUsername(current: " ", stored: ""))
    }

    func testAppearRefreshSkipsUntilIntervalElapses() {
        XCTAssertTrue(
            BookmarkSessionUsernamePolicy.shouldFetchOnAppear(hasLoadedOnce: false, lastFetch: nil)
        )
        let now = Date()
        XCTAssertFalse(
            BookmarkSessionUsernamePolicy.shouldFetchOnAppear(
                hasLoadedOnce: true,
                lastFetch: now.addingTimeInterval(-5),
                now: now
            )
        )
        XCTAssertTrue(
            BookmarkSessionUsernamePolicy.shouldFetchOnAppear(
                hasLoadedOnce: true,
                lastFetch: now.addingTimeInterval(-25),
                now: now
            )
        )
    }

    func testBookmarkRouteEncodesUsernameAndOmitsFirstPage() {
        XCTAssertEqual(
            DiscourseRouter.bookmarks(username: "sam", page: 0).path,
            "/u/sam/bookmarks.json"
        )
        XCTAssertEqual(
            DiscourseRouter.bookmarks(username: "sam", page: 2).path,
            "/u/sam/bookmarks.json?page=2"
        )
    }
}
