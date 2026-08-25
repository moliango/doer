import XCTest
@testable import Doer

@MainActor
final class ThemeStyleOLEDTests: XCTestCase {
    func testOLEDUsesStandardLayoutAndNotChatChrome() {
        let style = AppSettings.ThemeStyle.oled
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: style).kind, .standard)
        XCTAssertFalse(style.usesChatTopicDetail)
        XCTAssertFalse(style.usesChatHomeList)
        XCTAssertFalse(style.prefersOpaqueChrome)
    }

    func testOLEDDarkSurfacesAreTrueBlack() {
        let style = AppSettings.ThemeStyle.oled
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertRGB(style.contentBackgroundColor.resolvedColor(with: dark), r: 0, g: 0, b: 0)
        assertRGB(style.topicCardBackgroundColor.resolvedColor(with: dark), r: 0, g: 0, b: 0)
        assertRGB(style.topicListBackgroundColor.resolvedColor(with: dark), r: 0, g: 0, b: 0)
    }

    func testOLEDLightSurfacesStayWhite() {
        let style = AppSettings.ThemeStyle.oled
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(style.contentBackgroundColor.resolvedColor(with: light), .white)
        XCTAssertEqual(style.topicCardBackgroundColor.resolvedColor(with: light), .white)
        XCTAssertEqual(style.topicListBackgroundColor.resolvedColor(with: light), .white)
    }

    func testOLEDCanvasIsSRGBTrueBlack() {
        assertRGB(AppSettings.ThemeStyle.oledCanvasColor, r: 0, g: 0, b: 0)
    }

    private func assertRGB(
        _ color: UIColor,
        r: CGFloat,
        g: CGFloat,
        b: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), file: file, line: line)
        XCTAssertEqual(red, r, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(green, g, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(blue, b, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, 1, accuracy: 0.001, file: file, line: line)
    }
}
