import XCTest
@testable import Doer

final class ComposerPollSpecTests: XCTestCase {
    func testRoundTripRegularPoll() {
        var spec = ComposerPollSpec.blank()
        spec.options = ["甲", "乙", "丙"]
        spec.isPublic = true
        spec.chart = .pie
        spec.results = .onVote
        let parsed = ComposerPollSpec.parse(from: spec.bbcode)
        XCTAssertEqual(parsed?.kind, .regular)
        XCTAssertEqual(parsed?.options, ["甲", "乙", "丙"])
        XCTAssertEqual(parsed?.chart, .pie)
        XCTAssertEqual(parsed?.results, .onVote)
        XCTAssertEqual(parsed?.isPublic, true)
    }

    func testParseExistingSelection() {
        let raw = """
        [poll type=multiple results=always public=true chartType=bar]
        - 红
        - 蓝
        [/poll]
        """
        let parsed = ComposerPollSpec.parse(from: raw)
        XCTAssertEqual(parsed?.kind, .multiple)
        XCTAssertEqual(parsed?.options, ["红", "蓝"])
    }

    func testNumberPollOmitsOptions() {
        var spec = ComposerPollSpec.blank()
        spec.kind = .number
        spec.minValue = 1
        spec.maxValue = 5
        spec.step = 1
        XCTAssertTrue(spec.bbcode.contains("type=number"))
        XCTAssertFalse(spec.bbcode.contains("- "))
    }

    func testReplaceExistingPoll() {
        let raw = "[poll type=regular]\n- a\n- b\n[/poll]"
        var spec = ComposerPollSpec.blank()
        spec.options = ["新A", "新B"]
        let updated = ComposerPollSpec.replacingPoll(in: raw, with: spec)
        XCTAssertTrue(updated.contains("新A"))
        XCTAssertFalse(updated.contains("- a"))
    }
}

final class GitHubProxyTests: XCTestCase {
    func testNormalizeAddsTrailingSlash() {
        XCTAssertEqual(GitHubProxy.normalize("https://ghproxy.com"), "https://ghproxy.com/")
        XCTAssertEqual(GitHubProxy.normalize(""), "")
    }

    func testInvalidPrefixRejected() {
        XCTAssertFalse(GitHubProxy.isValid("not a url"))
        XCTAssertTrue(GitHubProxy.isValid(""))
        XCTAssertTrue(GitHubProxy.isValid("https://mirror.example/"))
    }

    func testApplyDoesNotDoublePrefix() {
        let original = URL(string: "https://api.github.com/repos/moliango/doer/releases/latest")!
        let prefix = "https://ghproxy.com/"
        let once = GitHubProxy.apply(to: original, prefix: prefix)
        XCTAssertEqual(once.absoluteString, prefix + original.absoluteString)
        let twice = GitHubProxy.apply(to: once, prefix: prefix)
        XCTAssertEqual(twice, once)
    }

    func testEmptyPrefixIsIdentity() {
        let original = URL(string: "https://github.com/moliango/doer")!
        XCTAssertEqual(GitHubProxy.apply(to: original, prefix: ""), original)
    }

    func testApplyIfValidRejectsGarbageWithoutRewriting() {
        let original = URL(string: "https://api.github.com/repos/moliango/doer/releases/latest")!
        XCTAssertThrowsError(try GitHubProxy.applyIfValid(to: original, prefix: "not a url")) { error in
            XCTAssertEqual(error as? GitHubProxyError, .invalidPrefix)
        }
        XCTAssertEqual(
            try GitHubProxy.applyIfValid(to: original, prefix: ""),
            original
        )
    }
}

final class SeekingStoreTests: XCTestCase {
    func testAddNormalizeAndDedupe() {
        let key = "https://seeking.test"
        SeekingStore.setUsernames([], for: key)
        _ = SeekingStore.add(" @Ada ", for: key)
        _ = SeekingStore.add("ada", for: key)
        XCTAssertEqual(SeekingStore.usernames(for: key), ["Ada"])
        _ = SeekingStore.remove("ADA", for: key)
        XCTAssertTrue(SeekingStore.usernames(for: key).isEmpty)
    }
}
