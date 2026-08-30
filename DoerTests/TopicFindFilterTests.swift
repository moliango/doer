import XCTest
@testable import Doer

final class TopicFindFilterTests: XCTestCase {
    func testUsernameMatchIsCaseInsensitive() {
        XCTAssertTrue(TopicUsernameFilterPolicy.usernamesMatch("Alice", "alice"))
        XCTAssertFalse(TopicUsernameFilterPolicy.usernamesMatch("Alice", "bob"))
        XCTAssertTrue(TopicUsernameFilterPolicy.usernamesMatch(nil, nil))
        XCTAssertFalse(TopicUsernameFilterPolicy.usernamesMatch("Alice", nil))
    }

    func testNormalizedTrimsAndDropsEmpty() {
        XCTAssertEqual(TopicUsernameFilterPolicy.normalized("  alice  "), "alice")
        XCTAssertNil(TopicUsernameFilterPolicy.normalized("   "))
        XCTAssertNil(TopicUsernameFilterPolicy.normalized(nil))
    }

    func testIsFilteringOPOnlyWhenUsernamesMatch() {
        XCTAssertTrue(
            TopicUsernameFilterPolicy.isFilteringOP(filterUsername: "op", opUsername: "OP")
        )
        XCTAssertFalse(
            TopicUsernameFilterPolicy.isFilteringOP(filterUsername: "bob", opUsername: "op")
        )
        XCTAssertFalse(
            TopicUsernameFilterPolicy.isFilteringOP(filterUsername: nil, opUsername: "op")
        )
    }

    func testPostMatchesKeepsOnlyFilteredUser() {
        XCTAssertTrue(TopicUsernameFilterPolicy.postMatches(username: "bob", filterUsername: nil))
        XCTAssertTrue(TopicUsernameFilterPolicy.postMatches(username: "Bob", filterUsername: "bob"))
        XCTAssertFalse(TopicUsernameFilterPolicy.postMatches(username: "alice", filterUsername: "bob"))
        XCTAssertFalse(TopicUsernameFilterPolicy.postMatches(username: "op", filterUsername: "bob"))
    }

    func testTogglingSameUserClearsAndDifferentUserReplaces() {
        XCTAssertEqual(TopicUsernameFilterPolicy.toggling(current: nil, requested: "bob"), "bob")
        XCTAssertNil(TopicUsernameFilterPolicy.toggling(current: "bob", requested: "BOB"))
        XCTAssertEqual(TopicUsernameFilterPolicy.toggling(current: "bob", requested: "alice"), "alice")
    }

    func testOPFilterAndOtherUserAreMutuallyExclusiveStates() {
        let op = "op"
        var filter: String? = op
        XCTAssertTrue(TopicUsernameFilterPolicy.isFilteringOP(filterUsername: filter, opUsername: op))

        filter = TopicUsernameFilterPolicy.toggling(current: filter, requested: "bob")
        XCTAssertEqual(filter, "bob")
        XCTAssertFalse(TopicUsernameFilterPolicy.isFilteringOP(filterUsername: filter, opUsername: op))

        filter = TopicUsernameFilterPolicy.normalized(op)
        XCTAssertTrue(TopicUsernameFilterPolicy.isFilteringOP(filterUsername: filter, opUsername: op))
        XCTAssertFalse(TopicUsernameFilterPolicy.usernamesMatch(filter, "bob"))
    }

    func testFindNavigationWrapsAndEmptyIsNil() {
        XCTAssertNil(TopicFindNavigation.nextIndex(current: 0, count: 0))
        XCTAssertNil(TopicFindNavigation.previousIndex(current: 0, count: 0))
        XCTAssertNil(TopicFindNavigation.clampedIndex(0, count: 0))

        XCTAssertEqual(TopicFindNavigation.nextIndex(current: 0, count: 3), 1)
        XCTAssertEqual(TopicFindNavigation.nextIndex(current: 2, count: 3), 0)
        XCTAssertEqual(TopicFindNavigation.previousIndex(current: 0, count: 3), 2)
        XCTAssertEqual(TopicFindNavigation.previousIndex(current: 1, count: 3), 0)
        XCTAssertEqual(TopicFindNavigation.clampedIndex(9, count: 3), 2)
        XCTAssertEqual(TopicFindNavigation.clampedIndex(-1, count: 3), 0)
    }

    func testTopicRouterOmitsUsernameFiltersWhenEmpty() {
        XCTAssertEqual(
            DiscourseRouter.topic(id: 42, trackVisit: false).path,
            "/t/42.json"
        )
        XCTAssertEqual(
            DiscourseRouter.topic(id: 42, trackVisit: true).path,
            "/t/42.json?track_visit=true"
        )
        XCTAssertEqual(
            DiscourseRouter.topic(id: 42, trackVisit: false, usernameFilters: "").path,
            "/t/42.json"
        )
        XCTAssertEqual(
            DiscourseRouter.topic(id: 42, trackVisit: false, usernameFilters: nil).path,
            "/t/42.json"
        )
    }

    func testTopicRouterAppendsUsernameFiltersWithTrackVisit() {
        XCTAssertEqual(
            DiscourseRouter.topic(id: 42, trackVisit: false, usernameFilters: "bob").path,
            "/t/42.json?username_filters=bob"
        )
        XCTAssertEqual(
            DiscourseRouter.topic(id: 42, trackVisit: true, usernameFilters: "bob").path,
            "/t/42.json?track_visit=true&username_filters=bob"
        )
        XCTAssertEqual(
            DiscourseRouter.topic(id: 7, trackVisit: false, usernameFilters: "a b").path,
            "/t/7.json?username_filters=a%20b"
        )
    }

    func testUsernameFilterTookEffectIgnoresOpeningPost() {
        let posts = [
            (postNumber: 1, username: "op"),
            (postNumber: 4, username: "bob"),
            (postNumber: 9, username: "bob"),
        ]
        XCTAssertTrue(
            TopicUsernameFilterPolicy.usernameFilterTookEffectExcludingOpeningPost(
                posts: posts,
                filterUsername: "bob"
            )
        )
        XCTAssertTrue(
            TopicUsernameFilterPolicy.usernameFilterTookEffectExcludingOpeningPost(
                posts: [(postNumber: 1, username: "op")],
                filterUsername: "bob"
            )
        )
        XCTAssertFalse(
            TopicUsernameFilterPolicy.usernameFilterTookEffectExcludingOpeningPost(
                posts: posts + [(postNumber: 5, username: "alice")],
                filterUsername: "bob"
            )
        )
        XCTAssertTrue(
            TopicUsernameFilterPolicy.usernameFilterTookEffectExcludingOpeningPost(
                posts: posts,
                filterUsername: nil
            )
        )
    }

    func testClearingUsernameFilterReloadsUnlessNested() {
        XCTAssertTrue(
            TopicUsernameFilterPolicy.shouldFetchUnfilteredTopicView(
                hadUsernameFilter: true,
                showingNested: false
            )
        )
        XCTAssertFalse(
            TopicUsernameFilterPolicy.shouldFetchUnfilteredTopicView(
                hadUsernameFilter: true,
                showingNested: true
            )
        )
        XCTAssertFalse(
            TopicUsernameFilterPolicy.shouldFetchUnfilteredTopicView(
                hadUsernameFilter: false,
                showingNested: false
            )
        )
    }
}
