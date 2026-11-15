import SDWebImage
import UIKit

extension PostNativeCell {
    // MARK: - Footer Actions
    func configureRepliesButton(count: Int) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "bubble.left",
            withConfiguration: Self.actionSymbolConfig(pointSize: 14)
        )
        config.title = "\(count)"
        config.imagePadding = 5
        config.contentInsets = .zero
        config.baseForegroundColor = .secondaryLabel
        config.background.backgroundColor = Self.actionBackgroundColor
        var title = AttributedString("\(count)")
        title.font = BoostChipLayout.countFont()
        config.attributedTitle = title
        showRepliesButton.configuration = config
        showRepliesButton.clipsToBounds = true
        showRepliesButton.accessibilityLabel = String(
            format: String(localized: "topic.nested.replies_count", defaultValue: "%d 条回复"),
            count
        )
    }

    /// FluxDo expand control under a nested node: ⊕ N 条回复 / ⊖ 收起.
    func configureNestedExpandButton(row: NestedDisplayRow) {
        let count = max(row.directReplyCount, row.loadedChildCount)
        let accent = AppSettings.shared.themeStyle.accentColor
        var config = UIButton.Configuration.plain()
        if row.isExpanded {
            config.image = UIImage(
                systemName: "minus.circle.fill",
                withConfiguration: Self.actionSymbolConfig(pointSize: 13, weight: .medium)
            )
            config.title = String(localized: "topic.nested.collapse", defaultValue: "收起")
        } else {
            config.image = UIImage(
                systemName: "plus.circle.fill",
                withConfiguration: Self.actionSymbolConfig(pointSize: 13, weight: .medium)
            )
            // Use format + StaticString key — interpolating into `localized:defaultValue:`
            // yields a runtime String and fails to compile (expects StaticString).
            config.title = String(
                format: String(localized: "topic.nested.replies_count", defaultValue: "%d 条回复"),
                count
            )
        }
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8)
        config.baseForegroundColor = accent
        config.background.backgroundColor = .clear
        var title = AttributedString(config.title ?? "")
        title.font = TopicDetailTypography.interfaceFont(ofSize: 12, weight: .medium)
        config.attributedTitle = title
        showRepliesButton.configuration = config
        showRepliesButton.clipsToBounds = true
        showRepliesButton.accessibilityLabel = config.title
    }

    func configureSharedIssueButton(_ state: SharedIssueState?) {
        guard let state else {
            currentSharedIssueTopicId = nil
            sharedIssueButton.isHidden = true
            sharedIssueButton.isEnabled = false
            sharedIssueButton.alpha = 1
            sharedIssueButton.configuration = nil
            sharedIssueButton.layer.borderWidth = 0
            sharedIssueButton.layer.borderColor = nil
            sharedIssueButton.layer.shadowOpacity = 0
            sharedIssueCountLabel.isHidden = true
            sharedIssueCountLabel.text = nil
            sharedIssueButton.accessibilityLabel = nil
            return
        }

        let theme = AppSettings.shared.themeStyle
        let fluxBlue = UIColor(red: 0.10, green: 0.54, blue: 0.98, alpha: 1)
        let title = state.userCreated
            ? String(localized: "shared_issue.marked_label")
            : String(localized: "shared_issue.compact_label")
        let foregroundColor: UIColor = state.userCreated ? fluxBlue : theme.accentColor
        let backgroundColor: UIColor = state.userCreated
            ? fluxBlue.withAlphaComponent(0.13)
            : theme.accentColor.withAlphaComponent(0.08)
        let borderColor: UIColor = state.userCreated
            ? fluxBlue.withAlphaComponent(0.26)
            : theme.accentColor.withAlphaComponent(0.16)

        let titleFont = TopicDetailTypography.interfaceFont(
            ofSize: 12.5,
            weight: .semibold
        )
        var attributes = AttributeContainer()
        attributes.font = titleFont

        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: state.userCreated ? "hand.raised.fill" : "hand.raised",
            withConfiguration: Self.actionSymbolConfig(weight: .semibold)
        )
        config.titleLineBreakMode = .byClipping
        config.imagePadding = 6
        config.attributedTitle = AttributedString(title, attributes: attributes)
        let trailingInset: CGFloat = state.count > 0 ? 32 : 11
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: 11,
            bottom: 0,
            trailing: trailingInset
        )
        config.baseForegroundColor = foregroundColor
        config.cornerStyle = .capsule
        config.background.backgroundColor = backgroundColor
        config.background.cornerRadius = Metrics.sharedIssueButtonHeight / 2
        sharedIssueButton.configuration = config
        sharedIssueButton.tintColor = foregroundColor
        sharedIssueButton.titleLabel?.font = titleFont
        sharedIssueButton.titleLabel?.numberOfLines = 1
        sharedIssueButton.titleLabel?.lineBreakMode = .byClipping
        sharedIssueButton.layer.cornerRadius = Metrics.sharedIssueButtonHeight / 2
        sharedIssueButton.layer.cornerCurve = .continuous
        sharedIssueButton.layer.borderWidth = 1.0 / UIScreen.main.scale
        sharedIssueButton.layer.borderColor = borderColor.cgColor
        sharedIssueButton.layer.shadowColor = fluxBlue.cgColor
        sharedIssueButton.layer.shadowOpacity = state.userCreated ? 0.10 : 0
        sharedIssueButton.layer.shadowRadius = 8
        sharedIssueButton.layer.shadowOffset = CGSize(width: 0, height: 3)
        sharedIssueButton.clipsToBounds = true
        sharedIssueButton.isEnabled = state.canCreate
        sharedIssueButton.alpha = state.canCreate ? 1 : 0.68
        sharedIssueButton.isHidden = false
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: titleFont]).width)
        let countWidth: CGFloat = state.count > 0
            ? max(18, ceil(("\(state.count)" as NSString).size(withAttributes: [
                .font: TopicDetailTypography.interfaceFont(ofSize: 11, weight: .semibold),
            ]).width) + 10)
            : 0
        sharedIssueButtonMinWidthConstraint?.constant = 11 + Self.actionIconPointSize + 6 + titleWidth
            + (state.count > 0 ? max(28, countWidth + 7) : 11)
        sharedIssueCountLabel.text = state.count > 0 ? "\(state.count)" : nil
        sharedIssueCountLabel.textColor = state.userCreated ? .white : fluxBlue
        sharedIssueCountLabel.backgroundColor = state.userCreated
            ? fluxBlue.withAlphaComponent(0.92)
            : fluxBlue.withAlphaComponent(0.14)
        sharedIssueCountLabel.layer.borderWidth = state.userCreated ? 1.0 / UIScreen.main.scale : 0
        sharedIssueCountLabel.layer.borderColor = UIColor.white.withAlphaComponent(0.75).cgColor
        sharedIssueCountLabel.isHidden = state.count <= 0
        sharedIssueButton.accessibilityLabel = state.canCreate
            ? String(localized: "shared_issue.title")
            : String(localized: "shared_issue.author_title")
    }

    func configureReactions(_ reactions: [DiscourseTopicDetail.Reaction], count: Int, baseURL: String) {
        guard !reactions.isEmpty else {
            reactionStackView.isHidden = true
            reactionCountLabel.isHidden = true
            return
        }

        let visible = reactions.prefix(3)
        for (i, iv) in reactionImageViews.enumerated() {
            if i < visible.count {
                let reaction = visible[visible.index(visible.startIndex, offsetBy: i)]
                if let url = URL(string: EmojiStore.lookup(for: reaction.id) ?? "") {
                    ForumImageLoader.setImage(on: iv, url: url)
                } else {
                    iv.sd_cancelCurrentImageLoad()
                    iv.image = nil
                }
                iv.isHidden = false
            } else {
                iv.isHidden = true
                iv.sd_cancelCurrentImageLoad()
                iv.image = nil
            }
        }

        if count > 0 {
            reactionCountLabel.text = "\(count)"
            reactionCountLabel.isHidden = false
        } else {
            reactionCountLabel.isHidden = true
        }

        reactionStackView.isHidden = false
    }

    func updateFooterLayout() {
        // FluxDo: shared-issue on its own row above actions; replies lead the action rail.
        let showsSharedIssue = !sharedIssueButton.isHidden
        sharedIssueButtonHeightConstraint?.constant = showsSharedIssue
            ? Metrics.sharedIssueButtonHeight
            : 0
        if showsSharedIssue {
            actionStackTopToContentConstraint?.isActive = false
            actionStackTopToSharedIssueConstraint?.isActive = true
        } else {
            actionStackTopToSharedIssueConstraint?.isActive = false
            actionStackTopToContentConstraint?.isActive = true
        }

        // When like/boost slots are gone, collapse their width so remaining icons sit flush right.
        let showsReact = !reactionPillControl.isHidden
        let showsBoost = !boostButton.isHidden && boostButton.alpha > 0.01
        if !showsReact {
            reactionPillWidthConstraint?.constant = 0
        }
        if !showsBoost {
            boostButton.isHidden = true
        }
    }

    func configureReactionButton(for post: DiscourseTopicDetail.Post) {
        let symbol = post.currentUserReaction == nil ? "heart" : "heart.fill"
        let isActive = post.currentUserReaction != nil
        configureActionButton(
            reactButton,
            symbolName: symbol,
            tintColor: isActive ? .systemPink : .secondaryLabel,
            backgroundColor: .clear,
            accessibilityLabel: "喜欢"
        )
        reactionPillControl.backgroundColor = .clear
        reactionPillControl.layer.borderWidth = 0
        reactionPillControl.layer.borderColor = nil

        // Own posts cannot be liked by the author — hide the reaction pill entirely.
        if post.yours {
            reactionPillControl.isHidden = true
            reactionPillWidthConstraint?.constant = 0
            reactButton.isUserInteractionEnabled = false
            reactButton.isEnabled = false
        } else {
            reactionPillControl.isHidden = false
            reactionPillWidthConstraint?.constant = Metrics.reactionSlotWidth
            reactButton.isUserInteractionEnabled = true
            reactButton.isEnabled = true
        }
    }

    func configureBoostButton(for post: DiscourseTopicDetail.Post) {
        configureActionButton(
            boostButton,
            image: Self.boostIconImage,
            tintColor: .secondaryLabel,
            backgroundColor: .clear,
            accessibilityLabel: String(localized: "post.boost")
        )
        // Own posts never show boost. Others keep a faded slot only when canBoost is false
        // so pagination that omits can_boost does not jump the footer layout.
        if post.yours {
            boostButton.isHidden = true
            boostButton.alpha = 0
            boostButton.isUserInteractionEnabled = false
            boostButton.isEnabled = false
            boostButton.isAccessibilityElement = false
            boostButton.accessibilityElementsHidden = true
        } else {
            boostButton.isHidden = false
            boostButton.alpha = post.canBoost ? 1 : 0
            boostButton.isUserInteractionEnabled = post.canBoost
            boostButton.isEnabled = post.canBoost
            boostButton.isAccessibilityElement = post.canBoost
            boostButton.accessibilityElementsHidden = !post.canBoost
        }
    }

    func configureBookmarkButton(isBookmarked: Bool) {
        configureActionButton(
            bookmarkButton,
            symbolName: isBookmarked ? "bookmark.fill" : "bookmark",
            tintColor: isBookmarked ? .systemYellow : .secondaryLabel,
            backgroundColor: .clear,
            accessibilityLabel: isBookmarked ? "取消收藏" : "收藏"
        )
    }

    func configureReplyButton() {
        configureActionButton(
            replyButton,
            symbolName: "arrowshape.turn.up.left",
            tintColor: .secondaryLabel,
            backgroundColor: .clear,
            accessibilityLabel: "回复"
        )
    }

    func configureMoreMenu(isBookmarked: Bool) {
        configureActionButton(
            moreButton,
            symbolName: "ellipsis",
            tintColor: .secondaryLabel,
            backgroundColor: .clear,
            accessibilityLabel: "更多"
        )
        let copyAction = UIAction(title: "复制链接", image: UIImage(systemName: "link")) { [weak self] _ in
            self?.copyLinkTapped()
        }
        let copyHTMLAction = UIAction(
            title: String(localized: "post.copy_html", defaultValue: "复制原始HTML"),
            image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")
        ) { [weak self] _ in
            guard let cooked = self?.currentPost?.cooked, !cooked.isEmpty else { return }
            UIPasteboard.general.string = cooked
        }
        let bookmarkAction = UIAction(
            title: isBookmarked ? "取消收藏" : "收藏",
            image: UIImage(systemName: isBookmarked ? "bookmark.slash" : "bookmark")
        ) { [weak self] _ in
            self?.bookmarkButtonTapped()
        }
        var actions: [UIMenuElement] = []
        if let post = currentPost, PostEditingPolicy.canShowEditAction(for: post) {
            actions.append(UIAction(
                title: String(localized: "post.edit.action", defaultValue: "编辑"),
                image: UIImage(systemName: "pencil")
            ) { [weak self] _ in
                guard let self, let post = self.currentPost else { return }
                self.delegate?.postCell(didTapEditPost: post)
            })
        }
        let shareImageAction = UIAction(
            title: String(localized: "topic.share_image", defaultValue: "生成分享图片"),
            image: UIImage(systemName: "photo")
        ) { [weak self] _ in
            guard let self, let post = self.currentPost else { return }
            self.delegate?.postCell(didTapShareImageForPost: post)
        }
        if currentPost?.showEditsIndicator == true {
            actions.append(UIAction(
                title: String(localized: "revision.title", defaultValue: "编辑历史"),
                image: UIImage(systemName: "clock.arrow.circlepath")
            ) { [weak self] _ in
                guard let self, let post = self.currentPost else { return }
                self.delegate?.postCell(didTapShowRevisionForPost: post)
            })
        }
        actions.append(contentsOf: [bookmarkAction, copyAction, copyHTMLAction, shareImageAction])
        moreButton.menu = UIMenu(title: "", children: actions)
    }

    func configureActionButton(
        _ button: PostActionButton,
        symbolName: String,
        tintColor: UIColor,
        backgroundColor: UIColor,
        accessibilityLabel: String?
    ) {
        configureActionButton(
            button,
            image: UIImage(systemName: symbolName, withConfiguration: Self.actionSymbolConfig()),
            tintColor: tintColor,
            backgroundColor: backgroundColor,
            accessibilityLabel: accessibilityLabel
        )
    }

    func configureActionButton(
        _ button: PostActionButton,
        image: UIImage?,
        tintColor: UIColor,
        backgroundColor: UIColor,
        accessibilityLabel: String?
    ) {
        button.configuration = nil
        button.setImage(nil, for: .normal)
        button.setFixedIcon(image.map(Self.normalizedActionIcon), tintColor: tintColor)
        button.tintColor = tintColor
        button.backgroundColor = backgroundColor
        button.layer.cornerRadius = Self.bottomBarHeight / 2
        button.layer.cornerCurve = .continuous
        button.accessibilityLabel = accessibilityLabel
        button.clipsToBounds = true
    }

    static func actionSymbolConfig(
        pointSize: CGFloat = actionIconPointSize,
        weight: UIImage.SymbolWeight = .regular
    ) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    }

    nonisolated static func normalizedActionIcon(_ image: UIImage) -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else {
            return image.withRenderingMode(.alwaysTemplate)
        }

        let scale = min(
            actionIconCanvasSize.width / image.size.width,
            actionIconCanvasSize.height / image.size.height
        )
        let drawSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let drawRect = CGRect(
            x: (actionIconCanvasSize.width - drawSize.width) / 2,
            y: (actionIconCanvasSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let renderer = UIGraphicsImageRenderer(size: actionIconCanvasSize)
        let rendered = renderer.image { _ in
            image.withRenderingMode(.alwaysOriginal).draw(in: drawRect)
        }
        return rendered.withRenderingMode(.alwaysTemplate)
    }

    static var actionBackgroundColor: UIColor {
        .clear
    }

}
