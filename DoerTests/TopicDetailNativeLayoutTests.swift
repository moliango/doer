import CookedHTML
import XCTest
@testable import Doer

@MainActor
final class TopicDetailNativeLayoutTests: XCTestCase {
    func testCodeBlockDarkPaletteUsesBlackBackgroundAndReadableForeground() {
        let palette = CodeBlockThemePalette.palette(for: .dark)
        let background = palette.background.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )
        let foreground = palette.foreground.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark)
        )

        XCTAssertEqual(background, .black)
        XCTAssertGreaterThan(foreground.relativeLuminanceForTesting, 0.7)
    }

    func testTopicDetailPushDoesNotShiftRootViewHorizontally() {
        XCTAssertEqual(TopicDetailTransitionGeometry.pushInitialTransform.tx, 0, accuracy: 0.001)
    }

    func testTimelinePaginationDoesNotStartOppositeDirectionConcurrently() {
        XCTAssertFalse(TopicDetailPaginationPolicy.canStartEarlier(isLoadingEarlier: false, isLoadingMore: true, isJumping: false))
        XCTAssertFalse(TopicDetailPaginationPolicy.canStartMore(isLoadingEarlier: true, isLoadingMore: false, isJumping: false))
        XCTAssertFalse(TopicDetailPaginationPolicy.canStartEarlier(isLoadingEarlier: false, isLoadingMore: false, isJumping: true))
        XCTAssertTrue(TopicDetailPaginationPolicy.canStartEarlier(isLoadingEarlier: false, isLoadingMore: false, isJumping: false))
    }

    func testForwardWindowKeepsOnePageReadyPastViewport() {
        // visible at 0 → want end 21 (index 0 + 1 + 20)
        XCTAssertEqual(
            TopicDetailPaginationPolicy.desiredLoadedEnd(visibleStreamIndex: 0, totalCount: 100),
            21
        )
        // near end clamps to total
        XCTAssertEqual(
            TopicDetailPaginationPolicy.desiredLoadedEnd(visibleStreamIndex: 95, totalCount: 100),
            100
        )
        // empty topic
        XCTAssertEqual(
            TopicDetailPaginationPolicy.desiredLoadedEnd(visibleStreamIndex: 0, totalCount: 0),
            0
        )
    }

    func testJumpWindowIncludesLookbackWithoutExceedingBounds() {
        let mid = TopicDetailPaginationPolicy.jumpWindow(targetIndex: 50, totalCount: 200)
        XCTAssertEqual(mid.lowerBound, 45)
        XCTAssertEqual(mid.upperBound, 65)

        let head = TopicDetailPaginationPolicy.jumpWindow(targetIndex: 2, totalCount: 200)
        XCTAssertEqual(head.lowerBound, 0)
        XCTAssertGreaterThan(head.upperBound, 2)

        let tail = TopicDetailPaginationPolicy.jumpWindow(targetIndex: 198, totalCount: 200)
        XCTAssertLessThanOrEqual(tail.upperBound, 200)
        XCTAssertTrue(tail.contains(198))
    }

    func testFirstPaintSplitKeepsRemainderForScrollLoad() {
        XCTAssertLessThan(
            TopicDetailPaginationPolicy.firstPaintPostCount,
            TopicDetailPaginationPolicy.pageSize
        )
        let items = Array(1...20)
        let split = TopicDetailPaginationPolicy.firstPaintSplit(items)
        XCTAssertEqual(split.immediate, Array(1...6))
        XCTAssertEqual(split.deferred, Array(7...20))

        let short = TopicDetailPaginationPolicy.firstPaintSplit([1, 2])
        XCTAssertEqual(short.immediate, [1, 2])
        XCTAssertTrue(short.deferred.isEmpty)
    }

    /// Jump mid-thread then prepend earlier floors must keep stream order
    /// (regression: #16 appearing above #1 after load-earlier).
    func testStreamOrderSortKeepsLowerFloorsBeforeHigher() {
        let streamIds = [101, 102, 116, 117, 118] // floors 1,2,16,17,18
        let idOrder = Dictionary(uniqueKeysWithValues: streamIds.enumerated().map { ($1, $0) })
        // Simulate a corrupted posts array: mid-thread head first, then earlier floors.
        let scrambled = [116, 117, 118, 101, 102]
        let sorted = scrambled.sorted { (idOrder[$0] ?? Int.max) < (idOrder[$1] ?? Int.max) }
        XCTAssertEqual(sorted, streamIds)
        XCTAssertLessThan(
            idOrder[101] ?? Int.max,
            idOrder[116] ?? Int.max,
            "floor 1 must sort before floor 16"
        )
    }

    func testJumpWindowAroundFloorSixteenDoesNotIncludeOPUnlessNearHead() {
        // Floor 16 → stream index 15
        let window = TopicDetailPaginationPolicy.jumpWindow(targetIndex: 15, totalCount: 28)
        XCTAssertFalse(window.contains(0), "mid-thread jump must not pull floor 1 into the window")
        XCTAssertTrue(window.contains(15))
        XCTAssertEqual(window.lowerBound, 10) // 15 - lookback 5
    }

    func testBoostChipWidthGrowsWithTextAndKeepsCountVisible() {
        let short = BoostChipLayout.bubbleWidth(
            displayText: "赞",
            uniqueUserCount: 1,
            boostCount: 1
        )
        let long = BoostChipLayout.bubbleWidth(
            displayText: "这个 Boost 文案比较长所以需要更宽",
            uniqueUserCount: 1,
            boostCount: 1
        )
        XCTAssertGreaterThan(long, short)

        let grouped = BoostChipLayout.bubbleWidth(
            displayText: "赞",
            uniqueUserCount: 2,
            boostCount: 12
        )
        let singleSameText = BoostChipLayout.bubbleWidth(
            displayText: "赞",
            uniqueUserCount: 2,
            boostCount: 1
        )
        XCTAssertGreaterThan(grouped, singleSameText)
        XCTAssertGreaterThanOrEqual(BoostChipLayout.countBadgeWidth(count: 12), BoostChipLayout.countMinWidth)
        XCTAssertLessThanOrEqual(
            BoostChipLayout.measuredTextWidth(
                String(repeating: "长", count: 40),
                font: BoostChipLayout.titleFont(),
                maxWidth: BoostChipLayout.singleTextMaxWidth
            ),
            BoostChipLayout.singleTextMaxWidth
        )
    }

    func testBoostFlagPolicyMatchesFluxDo() {
        let selfBoost = DiscourseTopicDetail.Boost(
            id: 1,
            cooked: "self",
            user: DiscourseTopicDetail.BoostUser(id: 1, username: "alice", name: nil, avatarTemplate: nil),
            canDelete: false,
            canFlag: true
        )
        let otherBoost = DiscourseTopicDetail.Boost(
            id: 2,
            cooked: "other",
            user: DiscourseTopicDetail.BoostUser(id: 2, username: "bob", name: nil, avatarTemplate: nil),
            canDelete: false,
            canFlag: true
        )
        XCTAssertTrue(BoostActionPolicy.canDelete(boost: selfBoost, currentUsername: "alice"))
        XCTAssertFalse(BoostActionPolicy.canFlag(boost: selfBoost, currentUsername: "alice"))
        XCTAssertTrue(BoostActionPolicy.canFlag(boost: otherBoost, currentUsername: "alice"))
        XCTAssertFalse(BoostActionPolicy.canFlag(boost: otherBoost, currentUsername: nil))

        let reported = otherBoost.replacingActionState(userFlagStatus: 1)
        XCTAssertTrue(BoostActionPolicy.boostAlreadyReported(boost: reported, currentUsername: "alice"))
        XCTAssertFalse(BoostActionPolicy.canFlag(boost: reported, currentUsername: "alice"))

        let types = BoostActionPolicy.filterFlagTypes(
            DiscourseFlagType.defaultTypes,
            availableFlags: ["spam", "notify_moderators"]
        )
        XCTAssertEqual(types.map(\.nameKey), ["spam", "notify_moderators"])
        XCTAssertTrue(BoostActionPolicy.filterFlagTypes(DiscourseFlagType.defaultTypes, availableFlags: nil).isEmpty)
    }

    func testChatBubbleTapDoesNotPresentReactionSheet() {
        XCTAssertFalse(ChatBubbleInteractionPolicy.shouldPresentReactionSheet(on: .tap))
        XCTAssertTrue(ChatBubbleInteractionPolicy.shouldPresentReactionSheet(on: .longPress))
        XCTAssertFalse(ChatBubbleInteractionPolicy.shouldPresentReactionSheet(on: .actionButton))
    }

    func testEarlierLoadAnchorIsConsumedOnlyAfterLoadingFinishes() {
        XCTAssertFalse(TopicDetailPaginationPolicy.shouldRestoreEarlierAnchor(
            hasAnchor: true,
            isLoadingEarlier: true,
            snapshotChanged: false
        ))
        XCTAssertTrue(TopicDetailPaginationPolicy.shouldRestoreEarlierAnchor(
            hasAnchor: true,
            isLoadingEarlier: false,
            snapshotChanged: true
        ))
    }

    func testHeadingUsesTagBadgeOnlyForCurrentTopicTags() {
        let topicTags: Set<String> = ["纯水", "VPS"]

        XCTAssertTrue(
            HeadingPresentationPolicy.shouldRenderTagBadge(
                level: 1,
                text: "纯水",
                topicTagNames: topicTags
            )
        )
        XCTAssertTrue(
            HeadingPresentationPolicy.shouldRenderTagBadge(
                level: 1,
                text: " vps ",
                topicTagNames: topicTags
            )
        )
        XCTAssertFalse(
            HeadingPresentationPolicy.shouldRenderTagBadge(
                level: 1,
                text: "UU远程",
                topicTagNames: topicTags
            )
        )
        XCTAssertFalse(
            HeadingPresentationPolicy.shouldRenderTagBadge(
                level: 1,
                text: "ToDesk",
                topicTagNames: topicTags
            )
        )
        XCTAssertFalse(
            HeadingPresentationPolicy.shouldRenderTagBadge(
                level: 2,
                text: "纯水",
                topicTagNames: topicTags
            )
        )
    }

    func testRegularHeadingDoesNotUseQuoteStyleAccentRail() {
        XCTAssertFalse(HeadingPresentationPolicy.usesAccentRail)
    }

    func testHeadingUsesCategoryBadgeOnlyForCurrentCategory() {
        XCTAssertTrue(
            HeadingPresentationPolicy.shouldRenderCategoryBadge(
                level: 1,
                text: " 公益推广 ",
                categoryName: "公益推广"
            )
        )
        XCTAssertFalse(
            HeadingPresentationPolicy.shouldRenderCategoryBadge(
                level: 1,
                text: "开源项目介绍",
                categoryName: "公益推广"
            )
        )
        XCTAssertFalse(
            HeadingPresentationPolicy.shouldRenderCategoryBadge(
                level: 2,
                text: "公益推广",
                categoryName: "公益推广"
            )
        )
    }

    func testStyledAttributedStringReplacesEmojiShortcodes() {
        let config = NativeRenderConfig.default(
            contentWidth: 320,
            baseURL: "https://linux.do"
        )
        let attributed = config.styledAttributedString(from: [
            .text("🔥 :rocket:起飞咯~"),
        ])

        XCTAssertFalse(attributed.string.contains(":rocket:"))
        var foundAttachment = false
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if value is EmojiTextAttachment {
                foundAttachment = true
                stop.pointee = true
            }
        }
        XCTAssertTrue(foundAttachment)
    }

    func testStyledAttributedStringKeepsShortcodesInsideInlineCode() {
        let config = NativeRenderConfig.default(
            contentWidth: 320,
            baseURL: "https://linux.do"
        )
        let attributed = config.styledAttributedString(from: [
            .code(":rocket:"),
        ])
        XCTAssertTrue(attributed.string.contains(":rocket:"))
    }

    func testInlineTopicHashtagUsesIconAndTextInsteadOfHashPrefix() {
        let config = NativeRenderConfig.default(
            contentWidth: 320,
            baseURL: "https://linux.do",
            topicTagNames: ["公益推广"]
        )
        let attributed = config.styledAttributedString(from: [
            .hashtag(
                text: "公益推广",
                href: "https://linux.do/tag/公益推广",
                type: "tag"
            ),
        ])

        XCTAssertFalse(attributed.string.hasPrefix("#"))
        XCTAssertTrue(attributed.string.hasSuffix("公益推广"))
        XCTAssertNotNil(attributed.attribute(.link, at: 0, effectiveRange: nil))
        XCTAssertGreaterThan(attributed.length, "公益推广".utf16.count)
    }

    func testLinkedHashTextUsesTopicTagIconRendering() {
        let config = NativeRenderConfig.default(
            contentWidth: 320,
            baseURL: "https://linux.do",
            topicTagNames: ["公益推广"]
        )
        let attributed = config.styledAttributedString(from: [
            .link(
                href: "https://linux.do/tag/公益推广",
                children: [.text("#公益推广")]
            ),
        ])

        XCTAssertFalse(attributed.string.hasPrefix("#"))
        XCTAssertTrue(attributed.string.hasSuffix("公益推广"))
        XCTAssertGreaterThan(attributed.length, "公益推广".utf16.count)
    }

    func testRegularTaxonomyBadgeUsesCompactRoundedRectangle() {
        XCTAssertEqual(TopicTaxonomyBadgeView.Variant.regular.cornerRadius, 9)
    }

    func testListRendererAppliesInlineTopicTagIconRendering() throws {
        let config = NativeRenderConfig.default(
            contentWidth: 320,
            baseURL: "https://linux.do",
            topicTagNames: ["公益推广"]
        )
        let block = ContentBlock.list(
            ordered: false,
            start: 1,
            items: [
                ListItem(content: [
                    .text("我的帖子已经打上 "),
                    .link(
                        href: "https://linux.do/tag/公益推广",
                        children: [.text("#公益推广")]
                    ),
                    .text(" 标签：是"),
                ]),
            ]
        )

        let view = ListRenderer.render(block, config: config, delegate: nil)
        let textView = try XCTUnwrap(view as? LinkTextView)
        let rendered = try XCTUnwrap(textView.attributedText)
        let glyph = try XCTUnwrap(
            TopicTagIconCatalog.presentation(for: "公益推广")
                .flatMap { DiscourseFontAwesomeIcon.glyph(for: $0.iconName) }
        )

        XCTAssertFalse(rendered.string.contains("#公益推广"))
        XCTAssertTrue(rendered.string.contains("公益推广"))
        XCTAssertTrue(rendered.string.contains(glyph))
        XCTAssertNil(textView.linkTextAttributes[.foregroundColor])

        let tagRange = (rendered.string as NSString).range(of: "公益推广")
        let renderedColor = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: tagRange.location, effectiveRange: nil) as? UIColor
        )
        XCTAssertEqual(renderedColor, TopicTagVisualStyle.color(for: "公益推广"))
        let glyphRange = (rendered.string as NSString).range(of: glyph)
        let glyphColor = try XCTUnwrap(
            rendered.attribute(.foregroundColor, at: glyphRange.location, effectiveRange: nil) as? UIColor
        )
        let iconColor = try XCTUnwrap(
            TopicTagIconCatalog.presentation(for: "公益推广")
                .flatMap { TopicTaxonomyColor.resolve(hex: $0.colorHex) }
        )
        XCTAssertEqual(glyphColor, iconColor)
        XCTAssertNil(rendered.attribute(.link, at: glyphRange.location, effectiveRange: nil))
        XCTAssertNotNil(rendered.attribute(.link, at: tagRange.location, effectiveRange: nil))
    }

    func testPostActionAreaKeepsStableWidthAfterPaginationReuse() throws {
        let cell = PostNativeCell(style: .default, reuseIdentifier: PostNativeCell.reuseIdentifier)
        cell.frame = CGRect(x: 0, y: 0, width: 402, height: 320)

        configure(
            cell,
            post: try decodePost(includesActionMetadata: true)
        )
        cell.layoutIfNeeded()
        let initialActions = try XCTUnwrap(actionStack(in: cell))
        let initialReactions = try XCTUnwrap(
            view(in: cell, accessibilityIdentifier: "post.reactions.summary")
        )
        XCTAssertFalse(initialReactions.isHidden)
        XCTAssertEqual(
            initialActions.arrangedSubviews.first?.accessibilityIdentifier,
            "post.reactions.summary"
        )
        let initialWidth = initialActions.bounds.width
        XCTAssertGreaterThan(initialWidth, 194)

        cell.prepareForReuse()
        configure(cell, post: try decodePost(includesActionMetadata: false))
        cell.layoutIfNeeded()
        let reusedActions = try XCTUnwrap(actionStack(in: cell))
        let reusedReactions = try XCTUnwrap(
            view(in: cell, accessibilityIdentifier: "post.reactions.summary")
        )
        let reusedSupplementary = try XCTUnwrap(
            view(in: cell, accessibilityIdentifier: "post.supplementary.footer")
        )

        XCTAssertEqual(reusedActions.bounds.width, 194, accuracy: 0.5)
        XCTAssertTrue(reusedReactions.isHidden)
        XCTAssertTrue(reusedSupplementary.isHidden)

        let reusedButtons = descendants(in: reusedActions).compactMap { $0 as? PostActionButton }
        XCTAssertEqual(reusedButtons.count, 5)
        for button in reusedButtons {
            XCTAssertEqual(button.fixedIconView.bounds.size, PostActionButton.iconSize)
            XCTAssertEqual(button.bounds.height, PostNativeCell.bottomBarHeight, accuracy: 0.5)
        }
    }

    func testPostFooterKeepsSingleRowWithSupplementaryActions() throws {
        let cell = PostNativeCell(style: .default, reuseIdentifier: PostNativeCell.reuseIdentifier)
        cell.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
        configure(
            cell,
            post: try decodePost(includesActionMetadata: true, replyCount: 2),
            sharedIssue: .init(topicId: 99, canCreate: true, count: 12, userCreated: false)
        )
        cell.layoutIfNeeded()

        let supplementary = try XCTUnwrap(view(in: cell, accessibilityIdentifier: "post.supplementary.footer"))
        let actions = try XCTUnwrap(view(in: cell, accessibilityIdentifier: "post.action.footer"))
        let reactions = try XCTUnwrap(view(in: cell, accessibilityIdentifier: "post.reactions.summary"))

        // Shared-issue sits on its own row (FluxDo). Replies stay left of action icons.
        XCTAssertFalse(supplementary.isHidden)
        XCTAssertEqual(supplementary.frame.midY, actions.frame.midY, accuracy: 1)
        XCTAssertLessThanOrEqual(supplementary.frame.maxX, actions.frame.minX + 0.5)
        XCTAssertLessThanOrEqual(actions.frame.maxX, actions.superview?.bounds.maxX ?? 0)

        // Reaction icons must remain fully visible — not half-clipped by shared-issue.
        XCTAssertFalse(reactions.isHidden)
        XCTAssertGreaterThan(reactions.bounds.width, 1)
        XCTAssertEqual(reactions.frame.minX, reactions.superview?.bounds.minX ?? -1, accuracy: 0.5)
    }

    func testSharedIssueSitsAboveActionRowSoReactionsAreNotClipped() throws {
        let cell = PostNativeCell(style: .default, reuseIdentifier: PostNativeCell.reuseIdentifier)
        cell.frame = CGRect(x: 0, y: 0, width: 320, height: 360)
        configure(
            cell,
            post: try decodePost(includesActionMetadata: true, replyCount: 0),
            sharedIssue: .init(topicId: 99, canCreate: true, count: 1, userCreated: false)
        )
        cell.layoutIfNeeded()

        let actions = try XCTUnwrap(view(in: cell, accessibilityIdentifier: "post.action.footer"))
        let reactions = try XCTUnwrap(view(in: cell, accessibilityIdentifier: "post.reactions.summary"))

        // Find the shared-issue button by accessibility label.
        let sharedIssue = descendants(in: cell).first {
            ($0 as? UIButton)?.accessibilityLabel == String(localized: "shared_issue.title")
                || ($0 as? UIButton)?.accessibilityLabel == String(localized: "shared_issue.author_title")
        }
        let button = try XCTUnwrap(sharedIssue as? UIButton)
        XCTAssertFalse(button.isHidden)
        XCTAssertLessThan(button.frame.maxY, actions.frame.minY + 0.5)
        XCTAssertFalse(reactions.isHidden)
        XCTAssertGreaterThan(reactions.frame.width, 8)
    }

    func testPostSnapshotUpdatesAreQueuedWhileAnApplyIsInFlight() {
        XCTAssertEqual(
            TopicDetailSnapshotPolicy.decision(
                isApplying: true,
                currentItemIDs: [1, 2],
                requestedItemIDs: [1, 2, 3]
            ),
            .queue
        )
        XCTAssertEqual(
            TopicDetailSnapshotPolicy.decision(
                isApplying: false,
                currentItemIDs: [1, 2],
                requestedItemIDs: [1, 2]
            ),
            .skip
        )
        XCTAssertEqual(
            TopicDetailSnapshotPolicy.decision(
                isApplying: false,
                currentItemIDs: [1, 2],
                requestedItemIDs: [1, 2, 3]
            ),
            .apply
        )
    }

    func testLinkTextViewMeasuresWrappedAttachmentBeforeFirstLayout() {
        let textView = LinkTextView()
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(
            string: "新鲜 grok cpa 第二弹 2000 个号 7z（1001.5 KB）",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        textView.preferredMeasurementWidth = 180

        let expectedHeight = ceil(textView.sizeThatFits(
            CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude)
        ).height + 4)
        XCTAssertEqual(textView.intrinsicContentSize.height, expectedHeight)
        XCTAssertGreaterThan(expectedHeight, textView.font?.lineHeight ?? 0)
    }

    private func configure(
        _ cell: PostNativeCell,
        post: DiscourseTopicDetail.Post,
        sharedIssue: PostNativeCell.SharedIssueState? = nil
    ) {
        cell.configure(
            with: post,
            annotatedBlocks: [],
            config: .default(contentWidth: 354, baseURL: "https://linux.do"),
            delegate: nil,
            floorNumber: post.postNumber,
            postLink: nil,
            baseURL: "https://linux.do",
            hasUnsupportedBlocks: false,
            cookedHTML: post.cooked,
            validReactions: [],
            sharedIssue: sharedIssue
        )
    }

    private func decodePost(
        includesActionMetadata: Bool,
        replyCount: Int = 0
    ) throws -> DiscourseTopicDetail.Post {
        var object: [String: Any] = [
            "id": 8,
            "username": "sam",
            "created_at": "2026-07-19T00:00:00.000Z",
            "cooked": "<p>Hello</p>",
            "post_number": 8,
            "reply_count": replyCount,
        ]
        if includesActionMetadata {
            object["can_boost"] = true
            object["reactions"] = [[
                "id": "heart",
                "type": "emoji",
                "count": 3,
            ]]
            object["reaction_users_count"] = 3
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DiscourseTopicDetail.Post.self, from: data)
    }

    private func actionStack(in root: UIView) -> UIStackView? {
        if let stack = root as? UIStackView,
           stack.arrangedSubviews.contains(where: { ($0 as? UIButton)?.accessibilityLabel == "收藏" }) {
            return stack
        }
        for subview in root.subviews {
            if let stack = actionStack(in: subview) {
                return stack
            }
        }
        return nil
    }

    private func view(in root: UIView, accessibilityIdentifier: String) -> UIView? {
        if root.accessibilityIdentifier == accessibilityIdentifier {
            return root
        }
        for subview in root.subviews {
            if let match = view(in: subview, accessibilityIdentifier: accessibilityIdentifier) {
                return match
            }
        }
        return nil
    }

    private func descendants(in root: UIView) -> [UIView] {
        root.subviews + root.subviews.flatMap(descendants(in:))
    }
}

private extension UIColor {
    var relativeLuminanceForTesting: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }
}
