import UIKit

/// Fixed home-row height for the standard topic card.
/// Title wraps to at most four lines; scrolling never measures the cell.
enum TopicCellRowHeight {
    static let maxTitleLines = 4

    /// Card insets plus the single-line badge row under the title.
    /// Matches `TopicCell` constraints: 4+9 + 7+18+8 + 4.
    private static let verticalChrome: CGFloat = 50
    private static let cardHorizontalInset: CGFloat = 32
    private static let avatarBlock: CGFloat = 58
    private static let titleToBadgeGap: CGFloat = 10
    private static let badgeTrailingInset: CGFloat = 12
    private static let minimumBadgeWidth: CGFloat = 38

    static var titleFont: UIFont {
        TopicListTypography.font(for: .title, weight: .semibold)
    }

    static var lineHeight: CGFloat {
        ceil(titleFont.lineHeight)
    }

    static var titleCap: CGFloat {
        lineHeight * CGFloat(maxTitleLines)
    }

    static func height(title: String, tableWidth: CGFloat, showsReplyCount: Bool) -> CGFloat {
        let titleHeight = titleBlockHeight(title: title, tableWidth: tableWidth, showsReplyCount: showsReplyCount)
        return verticalChrome + titleHeight
    }

    static func titleBlockHeight(title: String, tableWidth: CGFloat, showsReplyCount: Bool) -> CGFloat {
        let badgeWidth = showsReplyCount ? minimumBadgeWidth + titleToBadgeGap : 0
        let titleWidth = max(80, tableWidth - cardHorizontalInset - avatarBlock - titleToBadgeGap - badgeWidth - badgeTrailingInset)
        let measured = (title as NSString).boundingRect(
            with: CGSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: titleFont],
            context: nil
        ).height
        let line = lineHeight
        guard line > 0 else { return titleCap }
        let rawLines = Int(ceil(measured / line - 0.01))
        let lines = min(maxTitleLines, max(1, rawLines))
        return line * CGFloat(lines)
    }
}
