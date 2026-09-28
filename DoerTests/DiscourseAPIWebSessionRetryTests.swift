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

    func testCurrentUserEmptyBodyDoesNotForceWebSessionRefresh() {
        XCTAssertNil(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .currentUser,
                statusCode: 200,
                error: nil,
                data: Data()
            )
        )
    }

    func testCurrentUser401DoesNotForceWebSessionRefresh() {
        XCTAssertNil(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .currentUser,
                statusCode: 401,
                error: nil,
                data: nil
            )
        )
    }

    func testNotLoggedInJSONDoesNotForceWebSessionRefresh() {
        let data = Data(#"{"errors":["You need to be logged in"],"error_type":"not_logged_in"}"#.utf8)
        XCTAssertNil(
            DiscourseAPI.webSessionRefreshRetryReason(
                route: .latestTopics(page: 0),
                statusCode: 403,
                error: nil,
                data: data
            )
        )
    }

    func testLoginPathIsRemoteLogoutNotChallenge() {
        XCTAssertTrue(
            WebSessionRefreshPolicy.isLoginPage(
                url: URL(string: "https://linux.do/login"),
                title: nil
            )
        )
        XCTAssertFalse(
            WebSessionRefreshPolicy.isLoginPage(
                url: URL(string: "https://linux.do/t/123"),
                title: nil
            )
        )
    }

    func testErrorStatusDoesNotMergeWebCookies() throws {
        let host = "doer-merge-cookie.test"
        let url = try XCTUnwrap(URL(string: "https://\(host)/latest.json"))
        let baseURL = "https://\(host)"
        XCTAssertFalse(
            shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: url, statusCode: 200),
            "200 still requires a web session cookie in the jar"
        )
        let auth = try XCTUnwrap(HTTPCookie(properties: [
            .name: "_t",
            .value: "session-token",
            .domain: host,
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(3600),
        ]))
        WebCookieStore.shared.setCookies([auth])
        defer { WebCookieStore.shared.clearCookies(for: baseURL) }

        XCTAssertTrue(
            shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: url, statusCode: 200)
        )
        XCTAssertFalse(
            shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: url, statusCode: 403)
        )
        XCTAssertFalse(
            shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: url, statusCode: 502)
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

    func testCfuvidDoesNotTriggerWebSessionRefresh() {
        XCTAssertFalse(
            WebSessionRefreshPolicy.shouldRefreshAfterStoredCookies(["_cfuvid", "__cfuvid", "cf_clearance"])
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.shouldRefreshAfterStoredCookies(["_cfuvid", "_t"])
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.shouldRefreshAfterStoredCookies(["_forum_session"])
        )
        XCTAssertTrue(WebSessionRefreshPolicy.shouldSkipWebViewRefresh(reason: "api_response_cookie"))
        XCTAssertFalse(WebSessionRefreshPolicy.shouldSkipWebViewRefresh(reason: "scene_enter_foreground"))
        XCTAssertFalse(WebSessionRefreshPolicy.shouldRunFingerprintAndProbes(reason: "api_response_cookie"))
        XCTAssertFalse(WebSessionRefreshPolicy.shouldRunFingerprintAndProbes(reason: "forum_container_loaded"))
        XCTAssertFalse(WebSessionRefreshPolicy.shouldRunFingerprintAndProbes(reason: "scene_enter_foreground"))
        XCTAssertFalse(
            WebSessionRefreshPolicy.shouldInvalidateSessionAfterLoginLanding(hasJarSessionCookie: true)
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.shouldInvalidateSessionAfterLoginLanding(hasJarSessionCookie: false)
        )
        XCTAssertFalse(
            WebSessionRefreshPolicy.shouldImportWebViewCookies(
                didFinishLoad: true,
                isChallengePage: false,
                isLoginPage: true
            )
        )
    }

    func testBrowserProbe429IsNotASuccessfulRefresh() {
        XCTAssertTrue(
            WebSessionRefreshPolicy.areBrowserProbesCloudflareBlocked(json: #"{"csrf":429,"current":429}"#)
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.areBrowserProbesCloudflareBlocked(json: #"{"csrf":200,"current":403}"#)
        )
        XCTAssertFalse(
            WebSessionRefreshPolicy.areBrowserProbesCloudflareBlocked(json: #"{"csrf":200,"current":200}"#)
        )
        XCTAssertFalse(WebSessionRefreshPolicy.areBrowserProbesCloudflareBlocked(json: nil))
        XCTAssertFalse(
            WebSessionRefreshPolicy.isSuccessfulRefresh(
                didFinishLoad: true,
                isChallengePage: false,
                hasSessionCookie: true,
                probesCloudflareBlocked: true
            )
        )
        XCTAssertTrue(
            WebSessionRefreshPolicy.isSuccessfulRefresh(
                didFinishLoad: true,
                isChallengePage: false,
                hasSessionCookie: true,
                probesCloudflareBlocked: false
            )
        )
    }
}
