import XCTest
@testable import Doer

final class DiscourseTopicLinkParserTests: XCTestCase {
    func testParseIdOnlyAndFloor() {
        let info = DiscourseTopicLinkParser.firstTopicLink(
            in: "see https://linux.do/t/12345/3 please",
            forumBaseURL: "https://linux.do"
        )
        XCTAssertEqual(info?.topicId, 12345)
        XCTAssertEqual(info?.postNumber, 3)
    }

    func testParseSlugForm() {
        let info = DiscourseTopicLinkParser.firstTopicLink(
            in: "https://linux.do/t/some-topic-title/99901",
            forumBaseURL: "https://linux.do"
        )
        XCTAssertEqual(info?.topicId, 99901)
        XCTAssertEqual(info?.slug, "some-topic-title")
        XCTAssertNil(info?.postNumber)
    }

    func testRejectOtherHost() {
        let info = DiscourseTopicLinkParser.firstTopicLink(
            in: "https://example.com/t/12345",
            forumBaseURL: "https://linux.do"
        )
        XCTAssertNil(info)
    }

    func testSchemeRelativeAndPathOnly() {
        let a = DiscourseTopicLinkParser.firstTopicLink(
            in: "//linux.do/t/42",
            forumBaseURL: "https://linux.do"
        )
        XCTAssertEqual(a?.topicId, 42)

        let b = DiscourseTopicLinkParser.firstTopicLink(
            in: "/t/777/2",
            forumBaseURL: "https://linux.do"
        )
        XCTAssertEqual(b?.topicId, 777)
        XCTAssertEqual(b?.postNumber, 2)
    }

    @MainActor
    func testServiceSkipsAlreadyHandledClipboardRevision() async {
        let suite = "clipboard.topic.link.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = ClipboardTopicLinkService(defaults: defaults)
        service.markHandled()

        let pending = await service.hasUnhandledClipboardLink()
        XCTAssertFalse(pending, "A handled clipboard revision must not prompt again")
    }
}
