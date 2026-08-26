import XCTest
@testable import CookedHTML

final class ImageURLDetectorTests: XCTestCase {
    func testGitHubBlobPageIsNotAnImage() {
        let url = "https://github.com/czm15053/linuxdo-idea-ui/blob/main/snapshot/detail.png"
        XCTAssertFalse(ImageURLDetector.isImageURL(url))
    }

    func testGitHubRawPathIsAnImage() {
        let url = "https://github.com/czm15053/linuxdo-idea-ui/raw/main/snapshot/detail.png"
        XCTAssertTrue(ImageURLDetector.isImageURL(url))
    }

    func testRawGitHubUserContentIsAnImage() {
        let url = "https://raw.githubusercontent.com/czm15053/linuxdo-idea-ui/main/snapshot/detail.png"
        XCTAssertTrue(ImageURLDetector.isImageURL(url))
    }

    func testPreferredResourceURLKeepsCDNSrcForGitHubBlobHref() {
        let src = "https://cdn3.ldstatic.com/original/4X/9/4/3/943aa351d5a76ad949f237fb776e0250611ebcb9.jpeg"
        let href = "https://github.com/czm15053/linuxdo-idea-ui/blob/main/snapshot/detail.png"
        XCTAssertEqual(ImageURLDetector.preferredResourceURL(src: src, href: href), src)
    }

    func testPreferredResourceURLUsesLightboxOriginal() {
        let src = "https://cdn.example.com/optimized/thumb.jpg"
        let href = "https://cdn.example.com/original/full.jpg"
        XCTAssertEqual(ImageURLDetector.preferredResourceURL(src: src, href: href), href)
    }

    func testImageGridLightboxURLIgnoresGitHubBlobHref() {
        let src = "https://cdn3.ldstatic.com/original/4X/9/4/3/943aa351d5a76ad949f237fb776e0250611ebcb9.jpeg"
        let item = ImageGridItem(
            src: src,
            alt: "帖子详情",
            width: 690,
            height: 423,
            href: "https://github.com/czm15053/linuxdo-idea-ui/blob/main/snapshot/detail.png"
        )
        XCTAssertEqual(item.lightboxURL, src)
    }
}
