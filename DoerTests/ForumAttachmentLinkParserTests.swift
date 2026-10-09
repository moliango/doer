import XCTest
@testable import Doer

final class ForumAttachmentLinkParserTests: XCTestCase {
    func testRealDiscourseTextAttachment() {
        let url = URL(string: "https://linux.do/uploads/short-url/8sreYeCHmxklWlWeR6AqJQIcIQi.txt")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testRelativeShortURLAttachment() {
        let url = URL(string: "/uploads/short-url/8sreYeCHmxklWlWeR6AqJQIcIQi.txt")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testShortURLWithoutExtensionIsAttachment() {
        let url = URL(string: "https://linux.do/uploads/short-url/8sreYeCHmxklWlWeR6AqJQIcIQi")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testRelativeShortURLWithoutExtensionIsAttachment() {
        let url = URL(string: "/uploads/short-url/8sreYeCHmxklWlWeR6AqJQIcIQi")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testPDFUploadPath() {
        let url = URL(string: "https://linux.do/uploads/default/original/3X/a/b/abcdef.pdf")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testExternalHTMLPageIsNotAttachment() {
        // Onebox / normal web links must open in Safari, not download-as-attachment.
        let url = URL(string: "https://www.mcearnmore.com/market/2026/04/zh-wsd-kkl/index.html")!
        XCTAssertFalse(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testExternalMarketingSiteWithoutExtensionIsNotAttachment() {
        let url = URL(string: "https://www.mcearnmore.com/market/2026/04/zh-wsd-kkl/")!
        XCTAssertFalse(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testImageUploadIsNotAttachment() {
        let url = URL(string: "https://cdn3.ldstatic.com/original/4X/6/6/d/66dfbf3bbf4fc6f3a317c04da404974a8efccfa2.jpeg")!
        XCTAssertFalse(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testImageShortURLIsNotAttachment() {
        let url = URL(string: "/uploads/short-url/eG44OOcClnOa8LoNbx3eSzi8lyi.jpeg")!
        XCTAssertFalse(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testImageExplicitDownloadQueryIsAttachment() {
        let url = URL(string: "/uploads/short-url/eG44OOcClnOa8LoNbx3eSzi8lyi.jpeg?dl=1")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testBareUploadsPathWithoutFileExtensionIsNotAttachment() {
        let url = URL(string: "https://linux.do/uploads/")!
        XCTAssertFalse(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testExternalPDFIsAttachment() {
        let url = URL(string: "https://example.com/files/report.pdf")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }

    func testSecureUploadsWithExtensionIsAttachment() {
        let url = URL(string: "https://linux.do/secure-uploads/default/original/1X/abc.zip")!
        XCTAssertTrue(ForumAttachmentLinkParser.isAttachmentURL(url))
    }
}
