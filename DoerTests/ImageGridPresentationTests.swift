import CookedHTML
import XCTest
@testable import Doer

final class ImageGridPresentationTests: XCTestCase {
    func testGroupsConsecutiveImagesIntoCarousel() {
        let blocks: [ContentBlock] = [
            .paragraph([.text("hello")]),
            .image(src: "https://example.com/a.jpg", alt: "a", width: 800, height: 450, href: "https://example.com/a.jpg"),
            .image(src: "https://example.com/b.jpg", alt: "b", width: 800, height: 450, href: "https://example.com/b.jpg"),
            .image(src: "https://example.com/c.jpg", alt: "c", width: 800, height: 450, href: nil),
            .paragraph([.text("tail")]),
        ]

        let prepared = ImageGridPresentation.preparedBlocks(blocks, usesCarousel: true)
        XCTAssertEqual(prepared.count, 3)
        guard case let .imageGrid(images, _, mode) = prepared[1] else {
            return XCTFail("expected carousel grid, got \(prepared[1])")
        }
        XCTAssertEqual(mode, .carousel)
        XCTAssertEqual(images.count, 3)
        XCTAssertEqual(images[0].src, "https://example.com/a.jpg")
        XCTAssertEqual(images[2].src, "https://example.com/c.jpg")
    }

    func testDoesNotGroupWhenCarouselDisabled() {
        let blocks: [ContentBlock] = [
            .image(src: "https://example.com/a.jpg", alt: nil, width: nil, height: nil, href: nil),
            .image(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil, href: nil),
        ]
        let prepared = ImageGridPresentation.preparedBlocks(blocks, usesCarousel: false)
        XCTAssertEqual(prepared.count, 2)
        guard case .image = prepared[0], case .image = prepared[1] else {
            return XCTFail("expected stacked images")
        }
    }

    func testExpandsExplicitGridWhenCarouselDisabled() {
        let grid = ContentBlock.imageGrid(
            images: [
                ImageGridItem(src: "https://example.com/a.jpg", alt: nil, width: nil, height: nil, href: nil),
                ImageGridItem(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil, href: nil),
            ],
            columns: 2,
            mode: .grid
        )
        let prepared = ImageGridPresentation.preparedBlocks([grid], usesCarousel: false)
        XCTAssertEqual(prepared.count, 2)
        guard case .image = prepared[0], case .image = prepared[1] else {
            return XCTFail("expected expanded stacked images")
        }
    }

    func testSkipsEmptyParagraphsBetweenImages() {
        let blocks: [ContentBlock] = [
            .image(src: "https://example.com/a.jpg", alt: nil, width: nil, height: nil, href: nil),
            .paragraph([.text("  "), .lineBreak]),
            .image(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil, href: nil),
        ]
        let prepared = ImageGridPresentation.preparedBlocks(blocks, usesCarousel: true)
        XCTAssertEqual(prepared.count, 1)
        guard case let .imageGrid(images, _, mode) = prepared[0] else {
            return XCTFail("expected grouped carousel")
        }
        XCTAssertEqual(mode, .carousel)
        XCTAssertEqual(images.count, 2)
    }

    func testLeavesBadgeCardsOutOfCarousel() {
        let badge = "https://prompt.iwooji.com/badge?u=a&t=linux-do"
        let blocks: [ContentBlock] = [
            .image(src: badge, alt: nil, width: nil, height: nil, href: badge),
            .image(src: "https://example.com/a.jpg", alt: nil, width: nil, height: nil, href: nil),
            .image(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil, href: nil),
        ]
        let prepared = ImageGridPresentation.preparedBlocks(blocks, usesCarousel: true)
        XCTAssertEqual(prepared.count, 2)
        guard case .image(let src, _, _, _, _) = prepared[0] else {
            return XCTFail("expected badge image to stay standalone")
        }
        XCTAssertTrue(src.contains("iwooji.com/badge"))
        guard case let .imageGrid(images, _, _) = prepared[1] else {
            return XCTFail("expected remaining images grouped")
        }
        XCTAssertEqual(images.count, 2)
    }

    func testAnnotatedPathGroupsAcrossBlocks() {
        let items = [
            AnnotatedBlock(
                block: .image(src: "https://example.com/a.jpg", alt: nil, width: nil, height: nil, href: nil),
                sourceHTML: "<img src=a>"
            ),
            AnnotatedBlock(
                block: .image(src: "https://example.com/b.jpg", alt: nil, width: nil, height: nil, href: nil),
                sourceHTML: "<img src=b>"
            ),
        ]
        let prepared = ImageGridPresentation.preparedAnnotatedBlocks(items, usesCarousel: true)
        XCTAssertEqual(prepared.count, 1)
        guard case let .imageGrid(images, _, mode) = prepared[0].block else {
            return XCTFail("expected grouped annotated carousel")
        }
        XCTAssertEqual(mode, .carousel)
        XCTAssertEqual(images.count, 2)
    }
}
