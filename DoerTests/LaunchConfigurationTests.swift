import XCTest
import UIKit
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
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        for style in AppSettings.AppIconStyle.allCases where style != .primary {
            let name = try XCTUnwrap(style.alternateIconName)
            XCTAssertNotNil(alternates[name])
            for suffix in ["", "@2x", "@3x"] {
                let png = projectRoot.appendingPathComponent("Doer/AppIcons/\(name)\(suffix).png")
                XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), png.lastPathComponent)
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
}
