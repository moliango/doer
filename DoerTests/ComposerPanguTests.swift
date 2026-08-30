import XCTest
@testable import Doer

final class ComposerPanguTests: XCTestCase {
    func testCJKLatinBoundaries() {
        XCTAssertEqual(ComposerPangu.spacing("中文english中文"), "中文 english 中文")
    }

    func testCJKDigitBoundaries() {
        XCTAssertEqual(ComposerPangu.spacing("一共3个"), "一共 3 个")
    }

    func testExistingSpacesAreNotDoubled() {
        XCTAssertEqual(ComposerPangu.spacing("中文 english 中文"), "中文 english 中文")
        XCTAssertEqual(ComposerPangu.spacing("中文  english"), "中文  english")
    }

    func testFencedCodeIsUnchanged() {
        let raw = "前言\n```\n中文english中文\n```\n后记"
        let spaced = ComposerPangu.spacing(raw)
        XCTAssertTrue(spaced.contains("```\n中文english中文\n```"))
        XCTAssertTrue(spaced.contains("前言"))
        XCTAssertTrue(spaced.contains("后记"))
        XCTAssertFalse(spaced.contains("中文 english 中文\n```"))
    }

    func testInlineCodeIsUnchanged() {
        XCTAssertEqual(ComposerPangu.spacing("见`中文english`即可"), "见 `中文english` 即可")
    }

    func testHTTPURLIsUnchanged() {
        XCTAssertEqual(
            ComposerPangu.spacing("打开http://example.com/path看"),
            "打开 http://example.com/path 看"
        )
        XCTAssertEqual(
            ComposerPangu.spacing("见https://example.com/a_b-c?x=1即可"),
            "见 https://example.com/a_b-c?x=1 即可"
        )
    }

    func testLatinOnlyIsUnchanged() {
        XCTAssertEqual(ComposerPangu.spacing("hello world"), "hello world")
    }

    func testEmptyIsUnchanged() {
        XCTAssertEqual(ComposerPangu.spacing(""), "")
    }
}
