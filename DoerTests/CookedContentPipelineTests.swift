import CookedHTML
import UIKit
import XCTest
@testable import Doer

@MainActor
final class CookedContentPipelineTests: XCTestCase {
    func testPlainTextNeverReturnsHTMLTags() {
        let cooked = "<p>Hello <strong>world</strong></p><p>Line two</p>"
        let text = CookedContentPipeline.plainText(fromCooked: cooked)
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("world"))
        XCTAssertFalse(text.contains("<p>"))
        XCTAssertFalse(text.contains("<strong>"))
    }

    func testMarkdownKeepsCodeFence() {
        let cooked = #"<pre><code class="lang-swift">print(1)</code></pre>"#
        let md = CookedContentPipeline.markdown(fromCooked: cooked)
        XCTAssertTrue(md.contains("print(1)"), md)
        // Prefer fenced output when parser recognizes code blocks.
        XCTAssertFalse(md.contains("<pre>"), md)
    }

    func testBlocksParseNonEmpty() {
        let cooked = "<p>Only paragraph</p>"
        let blocks = CookedContentPipeline.blocks(fromCooked: cooked)
        XCTAssertFalse(blocks.isEmpty)
    }

    func testPlainTextPreviewIsSingleLine() {
        let cooked = "<p>Hello</p><p>World<br>again</p>"
        let preview = CookedContentPipeline.plainTextPreview(fromCooked: cooked)
        XCTAssertFalse(preview.contains("\n"), preview)
        XCTAssertTrue(preview.contains("Hello"), preview)
        XCTAssertTrue(preview.contains("World"), preview)
        XCTAssertFalse(preview.contains("<p>"), preview)
    }

    func testHighlightedPreviewKeepsSearchHighlightClean() {
        let headline = #"Hello <span class="search-highlight">world</span> and <em>flux</em>"#
        let attr = CookedContentPipeline.highlightedPreview(
            fromCooked: headline,
            font: .systemFont(ofSize: 15, weight: .semibold),
            textColor: .label
        )
        let plain = attr.string
        XCTAssertEqual(plain, "Hello world and flux")
        XCTAssertFalse(plain.contains("<"))
        XCTAssertFalse(plain.contains("span"))

        var sawHighlight = false
        attr.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if value != nil { sawHighlight = true }
        }
        XCTAssertTrue(sawHighlight, "expected highlighted ranges for search-highlight / em")
    }

    func testHighlightedPreviewStripsTagsWhenNoHighlight() {
        let headline = "Plain <b>title</b> only"
        let attr = CookedContentPipeline.highlightedPreview(
            fromCooked: headline,
            font: .systemFont(ofSize: 15, weight: .semibold),
            textColor: .label
        )
        XCTAssertEqual(attr.string, "Plain title only")
        XCTAssertFalse(attr.string.contains("<"))
    }

    // MARK: - Linked card images (red packets / event banners)

    func testLinkedCardImageKeepsPageLinkForTap() {
        let cooked = ##"<p><a href="https://hb.unsnow.org/hb/40faa92d6a193727dd8c8839efadae66" rel="noopener nofollow ugc"><picture><source type="image/svg+xml" srcset="https://hb.unsnow.org/share/cards/40faa92d6a193727dd8c8839efadae66/753f5de1b0ac56dab34bbdfbfa78ea91.svg 1x"><img src="https://cdn3.ldstatic.com/original/4X/e/a/e/eae408e6d0da13636b3bcf26c6bf3ccbd24bdf2b.svg" data-base62-sha1="xvWi01XrkOcx2MJtTlEbSugXKVZ" width="300" height="409" alt="红包卡片"></picture></a></p>"##
        let blocks = CookedContentPipeline.blocks(fromCooked: cooked)
        guard case .image(let src, _, _, _, let href)? = blocks.first else {
            return XCTFail("expected a promoted image block, got \(blocks)")
        }
        XCTAssertTrue(src.contains("cdn3.ldstatic.com"))
        XCTAssertEqual(href, "https://hb.unsnow.org/hb/40faa92d6a193727dd8c8839efadae66")
        // The href is an HTML page, so a tap must navigate instead of opening
        // the gallery of the card bitmap itself.
        XCTAssertEqual(ImageRenderer.pageLinkURL(forHref: href)?.host, "hb.unsnow.org")
        XCTAssertNil(ImageRenderer.pageLinkURL(forHref: src))
    }

    func testCommunityCardSVGDecodesThroughFetcher() {
        let svg = ##"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="300" height="409" viewBox="0 0 300 409"><defs><linearGradient id="g"><stop offset="0" stop-color="#F52A30"/><stop offset="1" stop-color="#EF1B24"/></linearGradient></defs><rect width="300" height="409" fill="url(#g)"/></svg>"##
        let data = Data(svg.utf8)
        // UIKit alone cannot decode SVG; without the coder the card stays a gray tile.
        XCTAssertNil(UIImage(data: data))
        XCTAssertNotNil(ExternalImageFetcher.decodeSVG(data: data, mime: "image/svg+xml"))
        XCTAssertNil(ExternalImageFetcher.decodeSVG(data: Data([0xFF, 0xD8, 0xFF, 0xE0]), mime: "image/jpeg"))
    }
}
