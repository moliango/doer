import Foundation

/// A single item in a list, which may contain nested sub-lists.
public struct ListItem: Sendable, Equatable {
    public let content: [InlineNode]
    public let children: [ContentBlock]

    public init(content: [InlineNode], children: [ContentBlock] = []) {
        self.content = content
        self.children = children
    }
}

public struct PollOption: Sendable, Equatable {
    public let id: String?
    public let text: String
    public let voteCount: Int?
    public let percentageText: String?
    public let isSelected: Bool

    public init(
        id: String?,
        text: String,
        voteCount: Int? = nil,
        percentageText: String? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.text = text
        self.voteCount = voteCount
        self.percentageText = percentageText
        self.isSelected = isSelected
    }
}

public struct PollBlock: Sendable, Equatable {
    public let name: String?
    public let status: String?
    public let type: String?
    public let options: [PollOption]
    public let votersText: String?
    public let votersCount: Int?
    public let minSelections: Int?
    public let maxSelections: Int?
    public let resultsMode: String?
    public let isPublic: Bool

    public init(
        name: String?,
        status: String?,
        type: String?,
        options: [PollOption],
        votersText: String?,
        votersCount: Int? = nil,
        minSelections: Int? = nil,
        maxSelections: Int? = nil,
        resultsMode: String? = nil,
        isPublic: Bool = false
    ) {
        self.name = name
        self.status = status
        self.type = type
        self.options = options
        self.votersText = votersText
        self.votersCount = votersCount
        self.minSelections = minSelections
        self.maxSelections = maxSelections
        self.resultsMode = resultsMode
        self.isPublic = isPublic
    }
}

public struct PolicyBlock: Sendable, Equatable {
    public let acceptLabel: String
    public let revokeLabel: String
    public let version: String?
    public let groups: String?
    public let accepted: Bool
    public let content: [ContentBlock]

    public init(
        acceptLabel: String,
        revokeLabel: String,
        version: String?,
        groups: String?,
        accepted: Bool,
        content: [ContentBlock]
    ) {
        self.acceptLabel = acceptLabel
        self.revokeLabel = revokeLabel
        self.version = version
        self.groups = groups
        self.accepted = accepted
        self.content = content
    }
}

/// A content block annotated with its original source HTML.
public struct AnnotatedBlock: Sendable {
    public let block: ContentBlock
    public let sourceHTML: String

    public init(block: ContentBlock, sourceHTML: String) {
        self.block = block
        self.sourceHTML = sourceHTML
    }
}

public struct ImageGridItem: Sendable, Equatable {
    public let src: String
    public let alt: String?
    public let width: Int?
    public let height: Int?
    public let href: String?

    public init(src: String, alt: String?, width: Int?, height: Int?, href: String? = nil) {
        self.src = src
        self.alt = alt
        self.width = width
        self.height = height
        self.href = href
    }

    public var lightboxURL: String {
        ImageURLDetector.preferredResourceURL(src: src, href: href)
    }
}

public enum ImageGridMode: Sendable, Equatable {
    case grid
    case carousel
}

/// A block-level content element extracted from Discourse `cooked` HTML.
public enum ContentBlock: Sendable, Equatable {
    case paragraph([InlineNode])
    case heading(level: Int, content: [InlineNode])
    case codeBlock(language: String?, code: String)
    case blockquote(blocks: [ContentBlock])
    case discourseQuote(username: String?, avatarURL: String?, topicTitle: String?, topicURL: String?, categoryName: String?, categoryURL: String?, quotePostNumber: Int?, content: [ContentBlock])
    case image(src: String, alt: String?, width: Int?, height: Int?, href: String? = nil)
    /// Discourse `[grid]` / `<div class="d-image-grid">` (grid or carousel).
    case imageGrid(images: [ImageGridItem], columns: Int, mode: ImageGridMode)
    case onebox(sourceURL: String?, title: String?, description: String?, imageURL: String?, imageWidth: Int?, imageHeight: Int?, faviconURL: String? = nil)
    case video(url: String, thumbnailURL: String?, title: String?, width: Int?, height: Int?, videoId: String?, provider: String?)
    /// - Parameters:
    ///   - ordered: `true` for `<ol>`, `false` for `<ul>`.
    ///   - start: 1-based index for the first item (from `<ol start="N">`, or continued
    ///     across Discourse list fragments split by `<details>`). Defaults to `1`.
    ///   - items: list items in document order.
    case list(ordered: Bool, start: Int, items: [ListItem])
    case poll(PollBlock)
    case policy(PolicyBlock)
    case table(headers: [[ContentBlock]], rows: [[[ContentBlock]]])
    case details(summary: [InlineNode], content: [ContentBlock])
    case spoiler(blocks: [ContentBlock])
    case divider
    case rawHTML(String)
}

public extension AnnotatedBlock {
    var imageSourceURLs: [String] {
        block.imageSourceURLs
    }
}

public extension ContentBlock {
    var imageSourceURLs: [String] {
        switch self {
        case .paragraph(let inlines), .heading(_, let inlines):
            return inlines.imageSourceURLs
        case .blockquote(let blocks), .spoiler(let blocks):
            return blocks.imageSourceURLs
        case .discourseQuote(_, let avatarURL, _, _, _, _, _, let content):
            return [avatarURL].compactMap { $0 } + content.imageSourceURLs
        case .image(let src, _, _, _, _):
            return [src]
        case .imageGrid(let images, _, _):
            return images.map(\.src)
        case .onebox(_, _, _, let imageURL, _, _, let faviconURL):
            return [imageURL, faviconURL].compactMap { $0 }
        case .video(_, let thumbnailURL, _, _, _, _, _):
            return [thumbnailURL].compactMap { $0 }
        case .list(_, _, let items):
            return items.flatMap(\.imageSourceURLs)
        case .table(let headers, let rows):
            return headers.flatMap(\.imageSourceURLs)
                + rows.flatMap { row in row.flatMap(\.imageSourceURLs) }
        case .details(let summary, let content):
            return summary.imageSourceURLs + content.imageSourceURLs
        case .policy(let policy):
            return policy.content.imageSourceURLs
        case .codeBlock, .poll, .divider, .rawHTML:
            return []
        }
    }
}

public extension ListItem {
    var imageSourceURLs: [String] {
        content.imageSourceURLs + children.imageSourceURLs
    }
}

public extension Array where Element == AnnotatedBlock {
    var imageSourceURLs: [String] {
        flatMap(\.imageSourceURLs)
    }
}

public extension Array where Element == ContentBlock {
    var imageSourceURLs: [String] {
        flatMap(\.imageSourceURLs)
    }
}

public extension Array where Element == InlineNode {
    var imageSourceURLs: [String] {
        flatMap(\.imageSourceURLs)
    }
}

public extension InlineNode {
    var imageSourceURLs: [String] {
        switch self {
        case .image(let src, _, _, _, _):
            return [src]
        case .link(_, let children), .spoiler(let children):
            return children.imageSourceURLs
        case .text, .styledText, .code, .lineBreak, .mention, .mentionGroup, .hashtag:
            return []
        }
    }
}
