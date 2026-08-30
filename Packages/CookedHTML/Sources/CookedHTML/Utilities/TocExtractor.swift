import Foundation

/// One heading in a DiscoTOC-style outline.
public struct TocEntry: Sendable, Equatable {
    public let id: String
    public let text: String
    public let level: Int
    public let children: [TocEntry]

    public init(id: String, text: String, level: Int, children: [TocEntry] = []) {
        self.id = id
        self.text = text
        self.level = level
        self.children = children
    }
}

/// Nested outline plus preorder flattening (same order as DiscoTOC `TocData.flat`).
public struct TocData: Sendable, Equatable {
    public let tree: [TocEntry]
    public let flat: [TocEntry]

    public init(tree: [TocEntry], flat: [TocEntry]) {
        self.tree = tree
        self.flat = flat
    }

    public var isEmpty: Bool { flat.isEmpty }
}

/// Builds a topic outline from first-post `ContentBlock`s.
///
/// Display gate matches DiscoTOC:
/// - cooked contains `data-theme-toc="true"` → at least 1 heading
/// - otherwise heading count ≥ `minHeadings` (default 3)
public enum TocExtractor {
    public static let minHeadings = 3
    public static let tocMarker = "data-theme-toc=\"true\""

    public static func build(
        blocks: [ContentBlock],
        postId: Int,
        cooked: String? = nil,
        minHeadings: Int = minHeadings,
        shouldInclude: ((Int, String) -> Bool)? = nil
    ) -> TocData? {
        let include = shouldInclude ?? { _, _ in true }
        let collected = collectHeadings(in: blocks, shouldInclude: include)
        let threshold: Int
        if let cooked, cooked.contains(tocMarker) {
            threshold = 1
        } else {
            threshold = minHeadings
        }
        guard collected.count >= threshold else { return nil }

        var slugCounts: [String: Int] = [:]
        let assigned: [AssignedHeading] = collected.map { heading in
            let id = makeAnchorId(postId: postId, text: heading.text, counts: &slugCounts)
            return AssignedHeading(id: id, text: heading.text, level: heading.level)
        }
        let tree = buildTree(assigned)
        return TocData(tree: tree, flat: flatten(tree))
    }

    /// DiscoTOC-style id: `p-{postId}-h-{slug}-{n}`.
    public static func makeAnchorId(
        postId: Int,
        text: String,
        counts: inout [String: Int]
    ) -> String {
        let slug = slugify(text)
        counts[slug, default: 0] += 1
        return "p-\(postId)-h-\(slug)-\(counts[slug]!)"
    }

    public static func slugify(_ text: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !out.isEmpty {
                    out.append("-")
                }
                pendingHyphen = false
                out.append(Character(scalar))
            } else {
                pendingHyphen = true
            }
        }
        return out.isEmpty ? "heading" : out
    }

    public static func flatten(_ tree: [TocEntry]) -> [TocEntry] {
        var out: [TocEntry] = []
        func walk(_ items: [TocEntry]) {
            for item in items {
                out.append(item)
                walk(item.children)
            }
        }
        walk(tree)
        return out
    }

    // MARK: - Collect

    private struct RawHeading {
        let level: Int
        let text: String
    }

    private struct AssignedHeading {
        let id: String
        let text: String
        let level: Int
    }

    private static func collectHeadings(
        in blocks: [ContentBlock],
        shouldInclude: (Int, String) -> Bool
    ) -> [RawHeading] {
        var out: [RawHeading] = []
        func walk(_ blocks: [ContentBlock]) {
            for block in blocks {
                switch block {
                case .heading(let level, let inlines):
                    let text = plainText(from: inlines)
                    guard !text.isEmpty, shouldInclude(level, text) else { continue }
                    out.append(RawHeading(level: level, text: text))
                case .details(_, let content), .spoiler(let content), .blockquote(let content):
                    walk(content)
                case .discourseQuote(_, _, _, _, _, _, _, let content):
                    walk(content)
                case .policy(let policy):
                    walk(policy.content)
                case .list(_, _, let items):
                    for item in items { walk(item.children) }
                case .table(let headers, let rows):
                    for cell in headers { walk(cell) }
                    for row in rows {
                        for cell in row { walk(cell) }
                    }
                default:
                    break
                }
            }
        }
        walk(blocks)
        return out
    }

    private static func plainText(from inlines: [InlineNode]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let text), .styledText(let text, _), .code(let text):
                return text
            case .link(_, let children), .spoiler(let children):
                return plainText(from: children)
            case .mention(let username, _):
                return "@\(username)"
            case .mentionGroup(let name, _):
                return "@\(name)"
            case .hashtag(let text, _, _):
                return text
            case .image(_, let alt, _, _, _):
                return alt ?? ""
            case .lineBreak:
                return "\n"
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
    }

    // MARK: - Tree

    private final class Node {
        let id: String
        let text: String
        let level: Int
        var children: [Node] = []

        init(id: String, text: String, level: Int) {
            self.id = id
            self.text = text
            self.level = level
        }

        func freeze() -> TocEntry {
            TocEntry(id: id, text: text, level: level, children: children.map { $0.freeze() })
        }
    }

    private static func buildTree(_ items: [AssignedHeading]) -> [TocEntry] {
        var roots: [Node] = []
        var stack: [Node] = []
        for item in items {
            let node = Node(id: item.id, text: item.text, level: item.level)
            while let last = stack.last, last.level >= node.level {
                stack.removeLast()
            }
            if let parent = stack.last {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
            stack.append(node)
        }
        return roots.map { $0.freeze() }
    }
}
