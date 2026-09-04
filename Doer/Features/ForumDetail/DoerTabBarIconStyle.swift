import UIKit

enum DoerTabBarIconStyle {
    private static let normalConfiguration = UIImage.SymbolConfiguration(
        pointSize: 18,
        weight: .bold,
        scale: .large
    )
    private static let selectedConfiguration = UIImage.SymbolConfiguration(
        pointSize: 19,
        weight: .heavy,
        scale: .large
    )

    static func image(identifier: String, fallbackSymbolName: String, selected: Bool) -> UIImage? {
        let symbolName = filledSymbolName(for: identifier, fallback: fallbackSymbolName)
        return image(named: symbolName, fallbackSymbolName: fallbackSymbolName, selected: selected)
    }

    static func image(named symbolName: String, selected: Bool) -> UIImage? {
        image(named: symbolName, fallbackSymbolName: symbolName, selected: selected)
    }

    static func avatarImage(_ source: UIImage, selected: Bool, accentColor: UIColor) -> UIImage {
        let canvasSize = CGSize(width: 26, height: 26)
        let ringWidth: CGFloat = selected ? 2.0 : 1.0
        let avatarRect = CGRect(x: 2.5, y: 2.5, width: 21, height: 21)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)

        return renderer.image { context in
            let cgContext = context.cgContext
            let avatarPath = UIBezierPath(ovalIn: avatarRect)
            UIColor.secondarySystemFill.setFill()
            avatarPath.fill()

            cgContext.saveGState()
            avatarPath.addClip()
            drawAspectFill(source, in: avatarRect)
            cgContext.restoreGState()

            let strokeColor = selected
                ? accentColor
                : UIColor.separator.withAlphaComponent(0.55)
            strokeColor.setStroke()
            avatarPath.lineWidth = ringWidth
            avatarPath.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    private static func image(named symbolName: String, fallbackSymbolName: String, selected: Bool) -> UIImage? {
        let configuration = selected ? selectedConfiguration : normalConfiguration
        return UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
            ?? UIImage(systemName: fallbackSymbolName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
            ?? UIImage(named: fallbackSymbolName)?.withRenderingMode(.alwaysOriginal)
    }

    private static func filledSymbolName(for identifier: String, fallback: String) -> String {
        switch identifier {
        case "home":
            return "house.fill"
        case "history":
            return "clock.fill"
        case "search":
            return "magnifyingglass.circle.fill"
        case "notifications":
            return "bell.fill"
        case "messages":
            return "envelope.fill"
        case "bookmarks":
            return "bookmark.fill"
        case "chat":
            return "bubble.left.and.bubble.right.fill"
        case "me":
            return "person.crop.circle.fill"
        default:
            return fallback
        }
    }

    private static func drawAspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(in: drawRect)
    }
}

