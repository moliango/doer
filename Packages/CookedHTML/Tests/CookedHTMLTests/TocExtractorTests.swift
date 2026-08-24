import XCTest
@testable import CookedHTML

final class TocExtractorTests: XCTestCase {

    func testBelowThresholdReturnsNil() {
        let html = "<h2>One</h2><h2>Two</h2>"
        let blocks = CookedHTMLParser.parse(html: html)
        XCTAssertNil(TocExtractor.build(blocks: blocks, postId: 10))
    }

    func testMarkerRelaxesThreshold() {
        let html = """
        <div data-theme-toc="true"></div>
        <h2>Only one</h2>
        <p>body</p>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        let data = TocExtractor.build(blocks: blocks, postId: 42, cooked: html)
        XCTAssertEqual(data?.flat.count, 1)
        XCTAssertEqual(data?.flat.first?.text, "Only one")
        XCTAssertEqual(data?.flat.first?.id, "p-42-h-only-one-1")
    }

    func testBuildsNestedTreeAndFlatOrder() {
        let html = """
        <h2>Intro</h2>
        <h3>Why</h3>
        <h3>How</h3>
        <h2>Appendix</h2>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        let data = TocExtractor.build(blocks: blocks, postId: 7, minHeadings: 1)
        XCTAssertEqual(data?.tree.count, 2)
        XCTAssertEqual(data?.tree.first?.text, "Intro")
        XCTAssertEqual(data?.tree.first?.children.map(\.text), ["Why", "How"])
        XCTAssertEqual(data?.tree.last?.text, "Appendix")
        XCTAssertEqual(data?.flat.map(\.text), ["Intro", "Why", "How", "Appendix"])
    }

    func testDuplicateSlugsGetOccurrenceSuffix() {
        let html = "<h2>Same</h2><h2>Same</h2><h2>Other</h2>"
        let blocks = CookedHTMLParser.parse(html: html)
        let data = TocExtractor.build(blocks: blocks, postId: 1, minHeadings: 1)
        XCTAssertEqual(data?.flat.map(\.id), [
            "p-1-h-same-1",
            "p-1-h-same-2",
            "p-1-h-other-1",
        ])
    }

    func testIncludesHeadingsInsideDetails() {
        let html = """
        <h2>Top</h2>
        <details><summary>more</summary><h3>Hidden</h3></details>
        <h2>End</h2>
        """
        let blocks = CookedHTMLParser.parse(html: html)
        let data = TocExtractor.build(blocks: blocks, postId: 3, minHeadings: 1)
        XCTAssertEqual(data?.flat.map(\.text), ["Top", "Hidden", "End"])
        XCTAssertEqual(data?.tree.first?.children.first?.text, "Hidden")
    }

    func testShouldIncludeFiltersTagLikeHeadings() {
        let html = "<h1>swift</h1><h2>Real</h2><h2>Also</h2><h2>Third</h2>"
        let blocks = CookedHTMLParser.parse(html: html)
        let data = TocExtractor.build(blocks: blocks, postId: 9) { level, text in
            !(level == 1 && text.lowercased() == "swift")
        }
        XCTAssertEqual(data?.flat.map(\.text), ["Real", "Also", "Third"])
    }

    func testChineseSlugKeepsLetters() {
        XCTAssertEqual(TocExtractor.slugify("安装指南"), "安装指南")
        XCTAssertEqual(TocExtractor.slugify("Hello, World!"), "hello-world")
        XCTAssertEqual(TocExtractor.slugify("   "), "heading")
    }
}
