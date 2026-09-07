#if canImport(UIKit)
import UIKit

/// Custom attribute key for image URLs that need async loading.
public extension NSAttributedString.Key {
    static let cookedHTMLImageURL = NSAttributedString.Key("cookedHTMLImageURL")
    static let cookedHTMLSpoiler = NSAttributedString.Key("cookedHTMLSpoiler")
    static let cookedHTMLSpoilerOriginalColor = NSAttributedString.Key("cookedHTMLSpoilerOriginalColor")
}

/// Configuration for NSAttributedString rendering.
public struct AttributedStringConfig: Sendable {
    public let baseFont: UIFont
    public let baseColor: UIColor
    public let linkColor: UIColor
    public let codeFont: UIFont
    public let codeBackgroundColor: UIColor
    public let mentionColor: UIColor
    public let hashtagColor: UIColor
    public let spoilerColor: UIColor

    public init(
        baseFont: UIFont = .systemFont(ofSize: 16),
        baseColor: UIColor = .label,
        linkColor: UIColor = .link,
        codeFont: UIFont = .monospacedSystemFont(ofSize: 15, weight: .regular),
        codeBackgroundColor: UIColor = .secondarySystemBackground,
        mentionColor: UIColor = .link,
        hashtagColor: UIColor = .link,
        spoilerColor: UIColor = .secondarySystemBackground
    ) {
        self.baseFont = baseFont
        self.baseColor = baseColor
        self.linkColor = linkColor
        self.codeFont = codeFont
        self.codeBackgroundColor = codeBackgroundColor
        self.mentionColor = mentionColor
        self.hashtagColor = hashtagColor
        self.spoilerColor = spoilerColor
    }
}

public extension [InlineNode] {
    /// Convert an array of inline nodes to an `NSAttributedString`.
    func attributedString(config: AttributedStringConfig = .init()) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for node in self {
            result.append(node.attributedString(config: config))
        }
        return result
    }

    /// Convenience: convert with just a base font.
    func attributedString(baseFont: UIFont) -> NSAttributedString {
        attributedString(config: AttributedStringConfig(baseFont: baseFont))
    }
}

public extension InlineNode {
    /// Convert a single inline node to an `NSAttributedString`.
    func attributedString(config: AttributedStringConfig = .init()) -> NSAttributedString {
        switch self {
        case .text(let text):
            return NSAttributedString(string: text, attributes: [
                .font: config.baseFont,
                .foregroundColor: config.baseColor,
            ])

        case .styledText(let text, let style):
            let font = config.baseFont.applying(style: style)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: config.baseColor,
            ]
            if style.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return NSAttributedString(string: text, attributes: attrs)

        case .link(let href, let children):
            let result = NSMutableAttributedString()
            for child in children {
                result.append(child.attributedString(config: config))
            }
            let range = NSRange(location: 0, length: result.length)
            result.addAttribute(.link, value: href, range: range)
            result.addAttribute(.foregroundColor, value: config.linkColor, range: range)
            return result

        case .image(let src, _, let width, let height, let isEmoji):
            if isEmoji {
                let emojiSize = config.baseFont.pointSize
                let yOffset = (config.baseFont.capHeight - emojiSize) / 2
                let attachment = NSTextAttachment()
                attachment.bounds = CGRect(x: 0, y: yOffset, width: emojiSize, height: emojiSize)
                attachment.image = UIImage()
                let attrStr = NSMutableAttributedString(attachment: attachment)
                let range = NSRange(location: 0, length: attrStr.length)
                attrStr.addAttribute(.cookedHTMLImageURL, value: src, range: range)
                attrStr.addAttribute(.font, value: config.baseFont, range: range)
                return attrStr
            }
            // Non-emoji inline image: create a placeholder attachment
            let lineHeight = config.baseFont.lineHeight
            let attachment = NSTextAttachment()
            if let w = width, let h = height, w > 0 {
                let scale = lineHeight / CGFloat(h)
                let scaledWidth = CGFloat(w) * scale
                attachment.bounds = CGRect(x: 0, y: -2, width: scaledWidth, height: lineHeight)
            } else {
                attachment.bounds = CGRect(x: 0, y: -2, width: lineHeight, height: lineHeight)
            }
            let attrStr = NSMutableAttributedString(attachment: attachment)
            let range = NSRange(location: 0, length: attrStr.length)
            attrStr.addAttribute(.cookedHTMLImageURL, value: src, range: range)
            return attrStr

        case .code(let text):
            return NSAttributedString(string: text, attributes: [
                .font: config.codeFont,
                .foregroundColor: config.baseColor,
                .backgroundColor: config.codeBackgroundColor,
            ])

        case .lineBreak:
            return NSAttributedString(string: "\n")

        case .mention(let username, let href):
            return NSAttributedString(string: "@\(username)", attributes: [
                .font: config.baseFont,
                .foregroundColor: config.mentionColor,
                .link: href,
            ])

        case .mentionGroup(let name, let href):
            return NSAttributedString(string: "@\(name)", attributes: [
                .font: config.baseFont,
                .foregroundColor: config.mentionColor,
                .link: href,
            ])

        case .hashtag(let text, let href, _, _):
            return NSAttributedString(string: "#\(text)", attributes: [
                .font: config.baseFont,
                .foregroundColor: config.hashtagColor,
                .link: href,
            ])

        case .spoiler(let children):
            let result = NSMutableAttributedString()
            for child in children {
                result.append(child.attributedString(config: config))
            }
            let range = NSRange(location: 0, length: result.length)
            // Mark as spoiler — the view layer handles the visual blur
            result.addAttribute(.cookedHTMLSpoiler, value: true, range: range)
            // Remove links so they aren't tappable while hidden
            result.removeAttribute(.link, range: range)
            return result
        }
    }
}

// MARK: - UIFont + TextStyle

private extension UIFont {
    func applying(style textStyle: CookedHTML.TextStyle) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = fontDescriptor.symbolicTraits
        if textStyle.contains(.bold) { traits.insert(.traitBold) }
        if textStyle.contains(.italic) { traits.insert(.traitItalic) }

        if let descriptor = fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: 0)
        }
        return self
    }
}

#endif
