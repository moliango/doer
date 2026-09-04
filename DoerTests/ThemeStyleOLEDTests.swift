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

    func testKraftPaperUsesStandardReadingLayout() {
        let style = AppSettings.ThemeStyle.kraftPaper
        XCTAssertEqual(HomeTopicListLayoutFactory.make(style: style).kind, .standard)
        XCTAssertFalse(style.usesChatTopicDetail)
        XCTAssertFalse(style.usesChatHomeList)
        XCTAssertTrue(style.prefersOpaqueChrome)
        XCTAssertEqual(style.webAccentHex, "#b43d26")
        XCTAssertEqual(style.webBackgroundHex, "#f6f2e9")
    }

    func testKraftPaperLightSurfacesMatchNewsNookInk() {
        let style = AppSettings.ThemeStyle.kraftPaper
        let light = UITraitCollection(userInterfaceStyle: .light)
        assertRGB(style.contentBackgroundColor.resolvedColor(with: light), r: 246 / 255, g: 242 / 255, b: 233 / 255)
        assertRGB(style.topicCardBackgroundColor.resolvedColor(with: light), r: 1, g: 252 / 255, b: 245 / 255)
        assertRGB(style.accentColor.resolvedColor(with: light), r: 180 / 255, g: 61 / 255, b: 38 / 255)
    }

    func testKraftPaperDarkSurfacesStayWarmInk() {
        let style = AppSettings.ThemeStyle.kraftPaper
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        assertRGB(style.contentBackgroundColor.resolvedColor(with: dark), r: 14 / 255, g: 15 / 255, b: 18 / 255)
        assertRGB(style.accentColor.resolvedColor(with: dark), r: 196 / 255, g: 92 / 255, b: 74 / 255)
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
