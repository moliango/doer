import UIKit

/// FluxDo `boost_list` chip sizing: measure the real title/count so the bubble
/// expands to the text instead of clipping the label or count badge.
enum BoostChipLayout {
    static let bubbleHeight: CGFloat = 28
    static let stripHeight: CGFloat = 34
    static let avatarSize: CGFloat = 20
    static let avatarOverlap: CGFloat = 12
    static let singleTextMaxWidth: CGFloat = 220
    static let groupedTextMaxWidth: CGFloat = 180
    static let chevronWidth: CGFloat = 10
    static let leadingPadding: CGFloat = 4
    static let trailingPadding: CGFloat = 6
    static let avatarTextSpacing: CGFloat = 5
    static let textCountSpacing: CGFloat = 5
    static let countChevronSpacing: CGFloat = 4
    static let textChevronSpacing: CGFloat = 4
    static let countHorizontalPadding: CGFloat = 12
    static let countMinWidth: CGFloat = 18

    private static let shortcodeRegex = try! NSRegularExpression(pattern: ":([^\\s:]+(?::t\\d)?):")

    static func titleFont() -> UIFont {
        TopicDetailTypography.interfaceFont(ofSize: 12, weight: .regular)
    }

    static func countFont() -> UIFont {
        .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    }

    static func avatarStackWidth(userCount: Int) -> CGFloat {
        let visible = min(max(userCount, 1), 3)
        return visible <= 1 ? avatarSize : avatarSize + CGFloat(visible - 1) * avatarOverlap
    }

    /// FluxDo replaces `:shortcode:` with a circle so emoji-only chips don't
    /// inflate to the raw shortcode string width.
    static func measurementText(from displayText: String) -> String {
        let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "Boost" : trimmed
        let ns = source as NSString
        return shortcodeRegex.stringByReplacingMatches(
            in: source,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "\u{25EF}"
        )
    }

    static func measuredTextWidth(_ text: String, font: UIFont, maxWidth: CGFloat) -> CGFloat {
        let sample = measurementText(from: text)
        let bounds = (sample as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: font.lineHeight),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return min(ceil(bounds.width), maxWidth)
    }

    static func countBadgeWidth(count: Int) -> CGFloat {
        let width = measuredTextWidth("\(count)", font: countFont(), maxWidth: 80)
        return max(countMinWidth, width + countHorizontalPadding)
    }

    static func titleMaxWidth(boostCount: Int) -> CGFloat {
        boostCount > 1 ? groupedTextMaxWidth : singleTextMaxWidth
    }

    static func bubbleWidth(
        displayText: String,
        uniqueUserCount: Int,
        boostCount: Int,
        showsChevron: Bool = true
    ) -> CGFloat {
        let textWidth = measuredTextWidth(
            displayText,
            font: titleFont(),
            maxWidth: titleMaxWidth(boostCount: boostCount)
        )
        var width = leadingPadding
            + avatarStackWidth(userCount: uniqueUserCount)
            + avatarTextSpacing
            + textWidth
        if boostCount > 1 {
            width += textCountSpacing + countBadgeWidth(count: boostCount) + countChevronSpacing
        } else {
            width += textChevronSpacing
        }
        if showsChevron {
            width += chevronWidth
        }
        width += trailingPadding
        return ceil(width)
    }
}

/// FluxDo `boost_flag_sheet` / `BoostActions` permission helpers.
enum BoostActionPolicy {
    static func boostAlreadyReported(
        boost: DiscourseTopicDetail.Boost,
        currentUsername: String?
    ) -> Bool {
        guard let currentUsername, !currentUsername.isEmpty else { return false }
        if currentUsername.caseInsensitiveCompare(boost.user.username) == .orderedSame {
            return false
        }
        return (boost.userFlagStatus ?? 0) > 0
    }

    static func canDelete(
        boost: DiscourseTopicDetail.Boost,
        currentUsername: String?
    ) -> Bool {
        guard let currentUsername, !currentUsername.isEmpty else { return false }
        let isOwn = currentUsername.caseInsensitiveCompare(boost.user.username) == .orderedSame
        return isOwn || boost.canDelete
    }

    static func canFlag(
        boost: DiscourseTopicDetail.Boost,
        currentUsername: String?
    ) -> Bool {
        guard let currentUsername, !currentUsername.isEmpty else { return false }
        if boostAlreadyReported(boost: boost, currentUsername: currentUsername) {
            return false
        }
        let isOwn = currentUsername.caseInsensitiveCompare(boost.user.username) == .orderedSame
        return !isOwn && boost.canFlag
    }

    static func canViewAuthor(boost: DiscourseTopicDetail.Boost) -> Bool {
        !boost.user.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func canShowActionSheet(
        boost: DiscourseTopicDetail.Boost,
        currentUsername: String?
    ) -> Bool {
        canViewAuthor(boost: boost)
            || canDelete(boost: boost, currentUsername: currentUsername)
            || canFlag(boost: boost, currentUsername: currentUsername)
    }

    static func shouldFetchActionState(
        boost: DiscourseTopicDetail.Boost,
        currentUsername: String?
    ) -> Bool {
        guard let currentUsername, !currentUsername.isEmpty else { return false }
        if currentUsername.caseInsensitiveCompare(boost.user.username) == .orderedSame {
            return false
        }
        if boost.canFlag && boost.availableFlags == nil {
            return true
        }
        return !boost.canDelete
            && !boost.canFlag
            && boost.availableFlags == nil
            && boost.userFlagStatus == nil
    }

    static func filterFlagTypes(
        _ allFlagTypes: [DiscourseFlagType],
        availableFlags: [String]?
    ) -> [DiscourseFlagType] {
        guard let availableFlags else { return [] }
        let allowed = Set(
            availableFlags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !allowed.isEmpty else { return [] }

        let enabled = allFlagTypes.filter { $0.isFlag && $0.enabled }
        let base = enabled.isEmpty ? DiscourseFlagType.defaultTypes : enabled
        let matched = base.filter { allowed.contains($0.nameKey) }
        let result = matched.isEmpty
            ? DiscourseFlagType.defaultTypes.filter { allowed.contains($0.nameKey) }
            : matched
        return result.sorted { $0.position < $1.position }
    }
}

/// WeChat / Telegram: like lives on the under-bubble action bar.
/// Bubble tap / like tap toggle the current reaction. Long-press on like
/// opens the personality reaction strip (classic topic-detail parity).
enum ChatBubbleInteractionPolicy {
    enum Trigger {
        case tap
        case longPress
        case actionButton
    }

    static func shouldPresentReactionSheet(on trigger: Trigger) -> Bool {
        switch trigger {
        case .longPress:
            return true
        case .tap, .actionButton:
            return false
        }
    }

    static func canPresentReactionPicker(isOwnPost: Bool, validReactions: [String]) -> Bool {
        shouldPresentReactionSheet(on: .longPress)
            && !isOwnPost
            && !validReactions.isEmpty
    }
}
