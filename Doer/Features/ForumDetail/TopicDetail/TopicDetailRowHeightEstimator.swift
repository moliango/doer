import CookedHTML
import UIKit

/// Cheap off-main-thread-safe height guess for Diffable `estimatedHeightForRowAt`.
/// Prefers stability over accuracy — real heights still come from cell layout + cache.
enum TopicDetailRowHeightEstimator {
    /// Card chrome: avatar header + action bar + padding (reply card).
    private static let replyChrome: CGFloat = 108
    /// First post has no outer card inset but often a taller body.
    private static let firstPostChrome: CGFloat = 96

    static func estimate(
        blocks: [AnnotatedBlock],
        isFirstPost: Bool,
        contentWidth: CGFloat
    ) -> CGFloat {
        let prepared = ImageGridPresentation.preparedBlocks(blocks.map(\.block))
        let width = max(contentWidth, 200)
        var body: CGFloat = 0
        let limit = min(prepared.count, 48)
        for index in 0..<limit {
            body += estimateBlock(prepared[index], contentWidth: width)
        }
        if prepared.count > limit {
            body += CGFloat(prepared.count - limit) * 18
        }
        let chrome = isFirstPost ? firstPostChrome : replyChrome
        let total = chrome + body
        let floor: CGFloat = isFirstPost ? 280 : 160
        return min(max(total, floor), 2_400)
    }

    private static func estimateBlock(_ block: ContentBlock, contentWidth: CGFloat) -> CGFloat {
        switch block {
        case .paragraph(let inlines):
            return estimateTextLines(approxInlineCount: inlines.count, lineHeight: 22)
        case .heading:
            return 32
        case .codeBlock(_, let code):
            let lines = max(code.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
            return min(CGFloat(lines) * 18 + 24, 320)
        case .blockquote(let nested), .spoiler(let nested):
            return nested.reduce(0) { $0 + estimateBlock($1, contentWidth: contentWidth) } + 12
        case .discourseQuote(_, _, _, _, _, _, _, let nested):
            return nested.reduce(0) { $0 + estimateBlock($1, contentWidth: contentWidth) } + 36
        case .image(_, _, let width, let height, _):
            return estimateImageHeight(width: width, height: height, contentWidth: contentWidth)
        case .imageGrid(_, _, let mode):
            return mode == .carousel ? 332 : estimateImageHeight(width: nil, height: nil, contentWidth: contentWidth)
        case .onebox:
            return 96
        case .video(_, _, _, let width, let height, _, _):
            return estimateImageHeight(width: width, height: height, contentWidth: contentWidth) + 8
        case .list(_, _, let items):
            return CGFloat(max(items.count, 1)) * 22 + 8
        case .poll:
            return 120
        case .policy:
            return 160
        case .table(let headers, let rows):
            return CGFloat(headers.count + rows.count) * 28 + 16
        case .details(_, let content):
            return 28 + content.prefix(6).reduce(0) { $0 + estimateBlock($1, contentWidth: contentWidth) }
        case .divider:
            return 16
        case .rawHTML:
            return 80
        }
    }

    private static func estimateTextLines(approxInlineCount: Int, lineHeight: CGFloat) -> CGFloat {
        // Rough: ~40 inline nodes per visual line at typical post width.
        let lines = max(CGFloat(approxInlineCount) / 40, 1)
        return min(lines, 12) * lineHeight + 6
    }

    private static func estimateImageHeight(width: Int?, height: Int?, contentWidth: CGFloat) -> CGFloat {
        if let w = width, let h = height, w > 0, h > 0 {
            let displayW = min(contentWidth, contentWidth * min(CGFloat(w) / 690, 1))
            return max(displayW * CGFloat(h) / CGFloat(w), 36) + 8
        }
        // 16:9 placeholder matches `TappableImageContainer` default when attrs missing.
        return contentWidth * 9.0 / 16.0 + 8
    }
}
