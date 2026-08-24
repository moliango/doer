import XCTest
@testable import Doer

final class ForumInternalLinkParserTests: XCTestCase {
    private let baseURL = "https://linux.do"

    func testMentionPathOpensUserProfile() {
        let url = URL(string: "/u/Naine")!
        let normalized = ForumInternalLinkParser.normalizedURL(from: url, baseURL: baseURL)
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: normalized),
            .user(username: "Naine")
        )
    }

    func testAbsoluteUserURLOpensUserProfile() {
        let url = URL(string: "https://linux.do/u/Naine")!
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url),
            .user(username: "Naine")
        )
    }

    func testUserSummarySubpathStillOpensProfile() {
        let url = URL(string: "https://linux.do/u/Naine/summary")!
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url),
            .user(username: "Naine")
        )
    }

    func testUsersByIdPathOpensProfile() {
        let url = URL(string: "https://linux.do/users/by-id/42/Naine")!
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url),
            .user(username: "Naine")
        )
    }

    func testSearchUsersRouteIsNotAProfile() {
        let url = URL(string: "https://linux.do/u/search/users")!
        XCTAssertNil(ForumInternalLinkParser.destination(for: url))
    }

    func testTopicLinkStillWins() {
        let url = URL(string: "https://linux.do/t/hello/123/4")!
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url),
            .topic(id: 123, postNumber: 4)
        )
            .topic(id: 123, postNumber: 4)
        )
    }
    func testTagURLBuilderPercentEncodesName() {
        let url = ForumInternalLinkParser.tagURL(name: "公益推广", baseURL: baseURL)
        XCTAssertEqual(
            url?.absoluteString,
            "https://linux.do/tag/%E5%85%AC%E7%9B%8A%E6%8E%A8%E5%B9%BF"
        )
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url!),
            .tag(name: "公益推广")
        )
    }
    func testTagPathOpensTagTopics() {
        let url = URL(string: "https://linux.do/tag/公益推广")!
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url),
            .tag(name: "公益推广")
        )
    }

    func testRelativeTagPathNormalizesAndOpensTagTopics() {
        let url = URL(string: "/tag/swift")!
        let normalized = ForumInternalLinkParser.normalizedURL(from: url, baseURL: baseURL)
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: normalized),
            .tag(name: "swift")
        )
    }

    func testTagURLBuilderPercentEncodesName() {
        let url = ForumInternalLinkParser.tagURL(name: "公益推广", baseURL: baseURL)
        XCTAssertEqual(
            url?.absoluteString,
            "https://linux.do/tag/%E5%85%AC%E7%9B%8A%E6%8E%A8%E5%B9%BF"
        )
        XCTAssertEqual(
            ForumInternalLinkParser.destination(for: url!),
            .tag(name: "公益推广")
        )
    }
}
