import Foundation

/// An inline-level node within a paragraph or heading.
public enum InlineNode: Sendable, Equatable {
    case text(String)
    case styledText(String, TextStyle)
    case link(href: String, children: [InlineNode])
    case image(src: String, alt: String?, width: Int?, height: Int?, isEmoji: Bool)
    case code(String)
    case lineBreak
    case mention(username: String, href: String)
    case mentionGroup(name: String, href: String)
    case hashtag(text: String, href: String, type: String?, icon: String?)
    case spoiler(children: [InlineNode])
}

public extension [InlineNode] {
    /// Trim leading and trailing whitespace/newlines from the first and last text nodes.
    func trimmedWhitespace() -> [InlineNode] {
        guard !isEmpty else { return self }
        var result = self
        // Trim leading whitespace of first text node
        for i in result.indices {
            switch result[i] {
            case .text(let t):
                let trimmed = t.replacingOccurrences(of: "^[\\s]+", with: "", options: .regularExpression)
                result[i] = .text(trimmed)
                if !trimmed.isEmpty { break }
            default: break
            }
            break
        }
        // Trim trailing whitespace of last text node
        for i in result.indices.reversed() {
            switch result[i] {
            case .text(let t):
                let trimmed = t.replacingOccurrences(of: "[\\s]+$", with: "", options: .regularExpression)
                result[i] = .text(trimmed)
                if !trimmed.isEmpty { break }
            default: break
            }
            break
        }
        return result.filter {
            if case .text(let t) = $0 { return !t.isEmpty }
            return true
        }
    }
}
