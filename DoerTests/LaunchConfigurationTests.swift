import XCTest
import UIKit
import ImageIO
@testable import Doer

@MainActor
final class LaunchConfigurationTests: XCTestCase {
    func testSystemLaunchScreenUsesTheRuntimeLaunchBackground() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("Doer/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let launchScreen = try XCTUnwrap(root["UILaunchScreen"] as? [String: Any])

        XCTAssertEqual(
            launchScreen["UIColorName"] as? String,
            DoerLaunchAppearance.backgroundColorName
        )
        XCTAssertNil(launchScreen["UIToolbar"])
    }

    func testAlternateAppIconsAreDeclaredAndShipped() throws {
        XCTAssertNil(AppSettings.AppIconStyle.primary.alternateIconName)
        XCTAssertEqual(AppSettings.AppIconStyle.purple.alternateIconName, "AppIconPurple")
        XCTAssertEqual(AppSettings.AppIconStyle.allCases.count, 7)

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = projectRoot.appendingPathComponent("Doer/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let icons = try XCTUnwrap(root["CFBundleIcons"] as? [String: Any])
        let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
        let primaryFiles = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String])
        XCTAssertEqual(primaryFiles, ["AppIconOriginal"])
        for suffix in ["", "@2x", "@3x"] {
            let png = projectRoot.appendingPathComponent("Doer/AppIcons/AppIconOriginal\(suffix).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), png.lastPathComponent)
            assertOpaqueRGBPNG(png)
        }
        for name in [
            "Doer/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
            "Doer/Assets.xcassets/AppIcon.appiconset/AppIcon-Dark.png",
            "Doer/Assets.xcassets/AppIcon.appiconset/AppIcon-Tinted.png",
        ] {
            assertOpaqueRGBPNG(projectRoot.appendingPathComponent(name))
        }

        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for style in AppSettings.AppIconStyle.allCases where style != .primary {
            let name = try XCTUnwrap(style.alternateIconName)
            XCTAssertNotNil(alternates[name])
            for suffix in ["", "@2x", "@3x"] {
                let png = projectRoot.appendingPathComponent("Doer/AppIcons/\(name)\(suffix).png")
                XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), png.lastPathComponent)
                assertOpaqueRGBPNG(png)
            }
            let fullBleed = projectRoot.appendingPathComponent("Doer/AppIcons/\(name).png")
            let image = try XCTUnwrap(UIImage(contentsOfFile: fullBleed.path), name)
            let corner = try XCTUnwrap(rgbaPixel(in: image, x: 0, y: 0), name)
            // Pre-rounded icons composite to white on the Home Screen. Corners must
            // be the icon fill, not the canvas.
            if style == .white {
                XCTAssertLessThan(corner.white, 0.985, name)
            } else {
                XCTAssertLessThan(corner.white, 0.9, name)
            }
            XCTAssertGreaterThanOrEqual(corner.alpha, 0.99, name)
        }
    }

    private func assertOpaqueRGBPNG(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent, file: file, line: line)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            XCTFail("Unable to read \(url.lastPathComponent)", file: file, line: line)
            return
        }
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        XCTAssertFalse(hasAlpha, "\(url.lastPathComponent) must be opaque RGB", file: file, line: line)
    }

    private func rgbaPixel(in image: UIImage, x: Int, y: Int) -> (white: CGFloat, alpha: CGFloat)? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        return pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let r = CGFloat(buffer[0]) / 255
            let g = CGFloat(buffer[1]) / 255
            let b = CGFloat(buffer[2]) / 255
            let a = CGFloat(buffer[3]) / 255
            return ((r + g + b) / 3, a)
        }
    }

    func testLaunchBackgroundColorAssetExists() {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetURL = projectRoot.appendingPathComponent(
            "Doer/Assets.xcassets/LaunchBackground.colorset/Contents.json"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: assetURL.path))
        XCTAssertNotNil(UIColor(named: DoerLaunchAppearance.backgroundColorName))
    }

    func testLaunchBackgroundColorAssetIncludesDarkAppearance() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetURL = projectRoot.appendingPathComponent(
            "Doer/Assets.xcassets/LaunchBackground.colorset/Contents.json"
        )
        let data = try Data(contentsOf: assetURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(root["colors"] as? [[String: Any]])

        var darkRed: CGFloat?
        var darkGreen: CGFloat?
        var darkBlue: CGFloat?
        for color in colors {
            let appearances = color["appearances"] as? [[String: Any]] ?? []
            let isDark = appearances.contains {
                $0["appearance"] as? String == "luminosity" && $0["value"] as? String == "dark"
            }
            guard isDark,
                  let payload = color["color"] as? [String: Any],
                  let components = payload["components"] as? [String: String]
            else { continue }
            darkRed = CGFloat(Double(components["red"] ?? "") ?? 1)
            darkGreen = CGFloat(Double(components["green"] ?? "") ?? 1)
            darkBlue = CGFloat(Double(components["blue"] ?? "") ?? 1)
        }

        XCTAssertNotNil(darkRed, "LaunchBackground.colorset must include a dark appearance")
        let luminance = 0.2126 * (darkRed ?? 1) + 0.7152 * (darkGreen ?? 1) + 0.0722 * (darkBlue ?? 1)
        XCTAssertLessThan(luminance, 0.08, "Dark launch background must be near black, not cream")
    }

    func testLaunchBackgroundResolvesDarkerThanCreamInDarkTraitCollection() throws {
        let named = try XCTUnwrap(UIColor(named: DoerLaunchAppearance.backgroundColorName))
        let dark = named.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let light = named.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))

        var darkRed: CGFloat = 0
        var darkGreen: CGFloat = 0
        var darkBlue: CGFloat = 0
        var darkAlpha: CGFloat = 0
        XCTAssertTrue(dark.getRed(&darkRed, green: &darkGreen, blue: &darkBlue, alpha: &darkAlpha))
        let darkLuminance = 0.2126 * darkRed + 0.7152 * darkGreen + 0.0722 * darkBlue
        XCTAssertLessThan(darkLuminance, 0.2, "Dark LaunchBackground must not be cream")

        var lightRed: CGFloat = 0
        var lightGreen: CGFloat = 0
        var lightBlue: CGFloat = 0
        var lightAlpha: CGFloat = 0
        XCTAssertTrue(light.getRed(&lightRed, green: &lightGreen, blue: &lightBlue, alpha: &lightAlpha))
        let lightLuminance = 0.2126 * lightRed + 0.7152 * lightGreen + 0.0722 * lightBlue
        XCTAssertGreaterThan(lightLuminance, 0.85)
        XCTAssertGreaterThan(lightLuminance - darkLuminance, 0.5)
    }
}
