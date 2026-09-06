import XCTest
@testable import Doer

final class DiscourseAPIWebSessionRetryTests: XCTestCase {
    func testEmpty200DoesNotForceWebSessionRefresh() {
        XCTAssertNil(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .latestTopics(page: 0),
                statusCode: 200,
                error: nil,
                data: Data()
            )
        )
    }

    func testEmpty204DoesNotForceWebSessionRefresh() {
        XCTAssertNil(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .siteInfo,
                statusCode: 204,
                error: nil,
                data: Data()
            )
        )
    }

    func test401ForcesWebSessionRefresh() {
        XCTAssertEqual(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .latestTopics(page: 0),
                statusCode: 401,
                error: nil,
                data: Data()
            ),
            "api_auth_status_401"
        )
    }

    func test403ForcesWebSessionRefresh() {
        XCTAssertEqual(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .latestTopics(page: 0),
                statusCode: 403,
                error: nil,
                data: nil
            ),
            "api_auth_status_403"
        )
    }

    func testCurrentUserEmptyBodyIsAuthShapedFailure() {
        XCTAssertEqual(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .currentUser,
                statusCode: 200,
                error: nil,
                data: Data()
            ),
            "api_empty_auth_response"
        )
    }

    func testErrorStatusDoesNotMergeWebCookies() {
        let url = URL(string: "https://linux.do/latest.json")!
        XCTAssertTrue(
            shouldMergeWebCookieResponseHeaders(baseURL: "https://linux.do", responseURL: url, statusCode: 200)
        )
        XCTAssertFalse(
            shouldMergeWebCookieResponseHeaders(baseURL: "https://linux.do", responseURL: url, statusCode: 403)
        )
        XCTAssertFalse(
            shouldMergeWebCookieResponseHeaders(baseURL: "https://linux.do", responseURL: url, statusCode: 502)
        )
        XCTAssertFalse(WebSessionRefreshPolicy.shouldImportWebViewCookies(didFinishLoad: false))
        XCTAssertTrue(WebSessionRefreshPolicy.shouldImportWebViewCookies(didFinishLoad: true))
        XCTAssertFalse(
            WebSessionRefreshPolicy.shouldImportWebViewCookies(didFinishLoad: true, isChallengePage: true)
        )
        XCTAssertFalse(
            WebSessionRefreshPolicy.isSuccessfulRefresh(
                didFinishLoad: false,
                isChallengePage: false,
                hasSessionCookie: true
            )
        )
        XCTAssertFalse(
            WebSessionRefreshPolicy.isSuccessfulRefresh(
                didFinishLoad: true,
                isChallengePage: true,
                hasSessionCookie: true
            )
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.isSuccessfulRefresh(
                didFinishLoad: true,
                isChallengePage: false,
                hasSessionCookie: true
            )
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.isChallengePage(
                url: URL(string: "https://linux.do/cdn-cgi/challenge-platform/h/b")!,
                title: nil
            )
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.isChallengePage(
                url: URL(string: "https://linux.do/?__cf_chl_tk=abc")!,
                title: nil
            )
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.isChallengePage(url: URL(string: "https://linux.do/")!, title: "Just a moment...")
        )
        XCTAssertFalse(
            WebSessionRefreshPolicy.isChallengePage(url: URL(string: "https://linux.do/")!, title: "Latest")
        )
    }
}
