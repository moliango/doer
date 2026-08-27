import CookedHTML
import UIKit
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

    @MainActor
    func testCarouselFirstPageHasSizeAfterZeroWidthLayout() {
        let images = [
            ImageGridItem(src: "https://example.com/a.jpg", alt: nil, width: 800, height: 450, href: nil),
            ImageGridItem(src: "https://example.com/b.jpg", alt: nil, width: 800, height: 450, href: nil),
        ]
        let view = ImageGridRenderer.render(
            .imageGrid(images: images, columns: 1, mode: .carousel),
            config: .default(contentWidth: 390, baseURL: "https://example.com"),
            delegate: nil
        )

        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        let width = view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            width,
        ])
        host.layoutIfNeeded()

        width.constant = 390
        host.layoutIfNeeded()

        guard let scrollView = firstScrollView(in: view) else {
            return XCTFail("expected paging scroll view")
        }
        XCTAssertEqual(scrollView.bounds.width, 390, accuracy: 0.5)
        XCTAssertEqual(scrollView.contentSize.width, 780, accuracy: 1)
        XCTAssertEqual(scrollView.contentOffset.x, 0, accuracy: 0.5)

        guard let stack = firstStack(in: scrollView),
              let firstPage = stack.arrangedSubviews.first else {
            return XCTFail("expected page stack")
        }
        XCTAssertEqual(firstPage.bounds.width, 390, accuracy: 0.5)
        XCTAssertGreaterThan(firstPage.bounds.height, 1)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }

    private func firstStack(in view: UIView) -> UIStackView? {
        if let stack = view as? UIStackView { return stack }
        for child in view.subviews {
            if let found = firstStack(in: child) { return found }
        }
        return nil
    }
}
