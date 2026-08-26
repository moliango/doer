import Combine
import Network
import UIKit

// MARK: - IncomingTopics
extension HomeViewController {
    /// Host height used for floating inset + inline table header.
    var incomingTopicsBannerHostHeight: CGFloat {
        Self.incomingTopicsBannerHeightChat
    }

    func installIncomingTopicsBannerLayoutConstraints() {
        let headerHeight = incomingTopicsHeaderView.heightAnchor.constraint(
            equalToConstant: incomingTopicsBannerHostHeight
        )
        let buttonHeight = incomingTopicsButton.heightAnchor.constraint(
            equalToConstant: incomingTopicsBannerHostHeight
        )
        let buttonLeading = incomingTopicsButton.leadingAnchor.constraint(
            equalTo: incomingTopicsHeaderView.leadingAnchor,
            constant: 18
        )
        let buttonTrailing = incomingTopicsButton.trailingAnchor.constraint(
            equalTo: incomingTopicsHeaderView.trailingAnchor,
            constant: -18
        )
        let buttonCenterX = incomingTopicsButton.centerXAnchor.constraint(
            equalTo: incomingTopicsHeaderView.centerXAnchor
        )
        let buttonMaxWidth = incomingTopicsButton.widthAnchor.constraint(
            lessThanOrEqualTo: incomingTopicsHeaderView.widthAnchor,
            constant: -48
        )
        buttonCenterX.isActive = false
        buttonMaxWidth.isActive = false

        let inlineHeight = incomingTopicsInlineButton.heightAnchor.constraint(
            equalToConstant: incomingTopicsBannerHostHeight
        )
        let inlineLeading = incomingTopicsInlineButton.leadingAnchor.constraint(
            equalTo: incomingTopicsInlineHeaderView.leadingAnchor,
            constant: 18
        )
        let inlineTrailing = incomingTopicsInlineButton.trailingAnchor.constraint(
            equalTo: incomingTopicsInlineHeaderView.trailingAnchor,
            constant: -18
        )
        let inlineCenterX = incomingTopicsInlineButton.centerXAnchor.constraint(
            equalTo: incomingTopicsInlineHeaderView.centerXAnchor
        )
        let inlineMaxWidth = incomingTopicsInlineButton.widthAnchor.constraint(
            lessThanOrEqualTo: incomingTopicsInlineHeaderView.widthAnchor,
            constant: -48
        )
        inlineCenterX.isActive = false
        inlineMaxWidth.isActive = false

        incomingTopicsHeaderHeightConstraint = headerHeight
        incomingTopicsButtonHeightConstraint = buttonHeight
        incomingTopicsButtonLeadingConstraint = buttonLeading
        incomingTopicsButtonTrailingConstraint = buttonTrailing
        incomingTopicsButtonCenterXConstraint = buttonCenterX
        incomingTopicsButtonMaxWidthConstraint = buttonMaxWidth
        incomingTopicsInlineButtonHeightConstraint = inlineHeight
        incomingTopicsInlineButtonLeadingConstraint = inlineLeading
        incomingTopicsInlineButtonTrailingConstraint = inlineTrailing
        incomingTopicsInlineButtonCenterXConstraint = inlineCenterX
        incomingTopicsInlineButtonMaxWidthConstraint = inlineMaxWidth

        NSLayoutConstraint.activate([
            headerHeight,
            buttonHeight, buttonLeading, buttonTrailing,
            inlineHeight, inlineLeading, inlineTrailing,
        ])
    }

    /// Telegram: centered blue pill. WeChat: list-edge flat bar. Default: wide card.
    func applyIncomingTopicsBannerLayout() {
        let theme = AppSettings.shared.themeStyle
        let hostHeight = incomingTopicsBannerHostHeight

        incomingTopicsHeaderHeightConstraint?.constant = hostHeight
        incomingTopicsInlineHeaderView.frame.size.height = isIncomingTopicsInlineBannerVisible
            ? hostHeight
            : incomingTopicsInlineHeaderView.frame.height

        switch theme {
        case .weChat:
            // Match WeChat list side inset (16) — flat tip bar.
            incomingTopicsButtonHeightConstraint?.constant = 44
            incomingTopicsInlineButtonHeightConstraint?.constant = 44
            tearDownTelegramBannerWidthConstraints()
            incomingTopicsButtonCenterXConstraint?.isActive = false
            incomingTopicsButtonMaxWidthConstraint?.isActive = false
            incomingTopicsButtonLeadingConstraint?.constant = 16
            incomingTopicsButtonTrailingConstraint?.constant = -16
            incomingTopicsButtonLeadingConstraint?.isActive = true
            incomingTopicsButtonTrailingConstraint?.isActive = true

            incomingTopicsInlineButtonCenterXConstraint?.isActive = false
            incomingTopicsInlineButtonMaxWidthConstraint?.isActive = false
            incomingTopicsInlineButtonLeadingConstraint?.constant = 16
            incomingTopicsInlineButtonTrailingConstraint?.constant = -16
            incomingTopicsInlineButtonLeadingConstraint?.isActive = true
            incomingTopicsInlineButtonTrailingConstraint?.isActive = true

        default:
            incomingTopicsButtonHeightConstraint?.constant = 40
            incomingTopicsInlineButtonHeightConstraint?.constant = 40
            incomingTopicsButtonLeadingConstraint?.isActive = false
            incomingTopicsButtonTrailingConstraint?.isActive = false
            incomingTopicsButtonCenterXConstraint?.isActive = true
            incomingTopicsButtonMaxWidthConstraint?.constant = -64
            incomingTopicsButtonMaxWidthConstraint?.isActive = true
            ensureTelegramBannerWidthConstraints()

            incomingTopicsInlineButtonLeadingConstraint?.isActive = false
            incomingTopicsInlineButtonTrailingConstraint?.isActive = false
            incomingTopicsInlineButtonCenterXConstraint?.isActive = true
            incomingTopicsInlineButtonMaxWidthConstraint?.constant = -64
            incomingTopicsInlineButtonMaxWidthConstraint?.isActive = true
            ensureTelegramInlineBannerWidthConstraints()
        }

        incomingTopicsButton.applyThemeStyle()
        incomingTopicsInlineButton.applyThemeStyle()
        updateIncomingTopicsInlineHeaderFrame()
        if isIncomingTopicsBannerVisible, incomingTopicsUsesTopSpace {
            updateTableInsets()
        }
    }

    private func ensureTelegramBannerWidthConstraints() {
        if incomingTopicsButton.constraints.contains(where: { $0.identifier == "tgBannerMinWidth" }) {
            return
        }
        let minW = incomingTopicsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        minW.identifier = "tgBannerMinWidth"
        minW.priority = .defaultHigh
        minW.isActive = true
        // Hug content: lower horizontal compression so title defines width under max.
        incomingTopicsButton.setContentHuggingPriority(.required, for: .horizontal)
        incomingTopicsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func ensureTelegramInlineBannerWidthConstraints() {
        if incomingTopicsInlineButton.constraints.contains(where: { $0.identifier == "tgInlineBannerMinWidth" }) {
            return
        }
        let minW = incomingTopicsInlineButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        minW.identifier = "tgInlineBannerMinWidth"
        minW.priority = .defaultHigh
        minW.isActive = true
        incomingTopicsInlineButton.setContentHuggingPriority(.required, for: .horizontal)
        incomingTopicsInlineButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func tearDownTelegramBannerWidthConstraints() {
        for button in [incomingTopicsButton, incomingTopicsInlineButton] {
            button.constraints
                .filter { $0.identifier == "tgBannerMinWidth" || $0.identifier == "tgInlineBannerMinWidth" }
                .forEach { $0.isActive = false }
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }
    }

    func updateCategoryButton() {
        let selected = viewModel.selectedCategory()
        let title = viewModel.categoryDisplayName(for: selected) ?? String(localized: "home.filter.categories")
        applyDropdownStyle(to: categoryButton, title: title, selected: selected != nil)
        categoryButton.sizeToFit()
    }

    func updateFilterButton() {
        filterButton.menu = UIMenu(title: "", children: buildFilterMenuElements())
        applyDropdownStyle(to: filterButton, title: title(for: viewModel.listMode), selected: true)

        let showsNewSubset = viewModel.listMode == .newTopics
        if showsNewSubset {
            if newSubsetButton.superview == nil {
                let categoryIndex = filterStackView.arrangedSubviews.firstIndex(of: categoryButton) ?? filterStackView.arrangedSubviews.count
                filterStackView.insertArrangedSubview(newSubsetButton, at: categoryIndex)
            }
            newSubsetButton.isHidden = false
            newSubsetButton.menu = UIMenu(title: "", children: buildNewSubsetMenuElements())
            applyDropdownStyle(
                to: newSubsetButton,
                title: viewModel.newSubset.title,
                selected: viewModel.newSubset != .all
            )
        } else {
            newSubsetButton.isHidden = true
            filterStackView.removeArrangedSubview(newSubsetButton)
            newSubsetButton.removeFromSuperview()
        }
    }

    func prefetchAvatarImages(for topics: [DiscourseTopicList.Topic]) {
        let prefetchLimit = AppSettings.shared.avatarLoadingProfile.homeAvatarPrefetchLimit
        let urls = topics
            .prefix(prefetchLimit)
            .compactMap { topic in
                AvatarImageLoader.url(
                    from: viewModel.avatarTemplate(for: topic),
                    baseURL: api.baseURL,
                    size: AvatarImageLoader.primaryAvatarPixelSize
                )
            }
        AvatarImageLoader.prefetch(urls: urls, cloudflareBaseURL: api.baseURL)
    }

    /// Prefetch avatars for the visible window + a few rows ahead (FluxDo-style scroll following).
    /// Called from `willDisplay` so deep lists don't only warm the first N topics.
    func prefetchAvatarsAroundVisibleRows(around indexPath: IndexPath) {
        let topics = viewModel.topics
        guard !topics.isEmpty else { return }
        let lookAhead = max(AppSettings.shared.avatarLoadingProfile.homeAvatarPrefetchLimit, 8)
        let start = max(0, indexPath.row - 2)
        let end = min(topics.count, indexPath.row + lookAhead)
        guard start < end else { return }
        let window = Array(topics[start..<end])
        let urls = window.compactMap { topic in
            AvatarImageLoader.url(
                from: viewModel.avatarTemplate(for: topic),
                baseURL: api.baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
        }
        guard !urls.isEmpty else { return }
        AvatarImageLoader.prefetch(urls: urls, cloudflareBaseURL: api.baseURL)
    }

    func updateIncomingTopicsHeader() {
        let count = viewModel.incomingTopicIds.count
        guard viewModel.listMode == .latest,
              viewModel.selectedCategoryId == nil,
              count > 0
        else {
            setIncomingTopicsBannerVisible(false, animated: view.window != nil)
            setIncomingTopicsInlineBannerVisible(false)
            updateIncomingTopicsPlacement(animated: false)
            return
        }

        let title = String.localizedStringWithFormat(String(localized: "home.incoming_topics %lld"), Int64(count))
        incomingTopicsButton.configure(title: title, isLoading: viewModel.isLoadingIncomingTopics)
        incomingTopicsInlineButton.configure(title: title, isLoading: viewModel.isLoadingIncomingTopics)
        incomingTopicsButton.isEnabled = !viewModel.isLoadingIncomingTopics
        incomingTopicsInlineButton.isEnabled = !viewModel.isLoadingIncomingTopics
        let usesFloatingBanner = AppSettings.shared.homeIncomingTopicsBannerFloatingEnabled
        setIncomingTopicsBannerVisible(usesFloatingBanner, animated: view.window != nil)
        setIncomingTopicsInlineBannerVisible(!usesFloatingBanner)
        updateIncomingTopicsPlacement(animated: view.window != nil)
    }

    func setIncomingTopicsBannerVisible(_ visible: Bool, animated: Bool) {
        if !visible {
            setIncomingTopicsUsesTopSpace(false)
        }
        guard isIncomingTopicsBannerVisible != visible else {
            if visible {
                incomingTopicsHeaderView.isHidden = false
                incomingTopicsHeaderView.accessibilityElementsHidden = false
                incomingTopicsHeaderView.alpha = 1
                incomingTopicsHeaderView.transform = .identity
            }
            return
        }

        isIncomingTopicsBannerVisible = visible
        incomingTopicsHeaderView.accessibilityElementsHidden = !visible

        let hiddenTransform = CGAffineTransform(translationX: 0, y: -6)
        let updates = {
            self.incomingTopicsHeaderView.alpha = visible ? 1 : 0
            self.incomingTopicsHeaderView.transform = visible ? .identity : hiddenTransform
        }
        let completion: (Bool) -> Void = { _ in
            self.incomingTopicsHeaderView.isHidden = !self.isIncomingTopicsBannerVisible
            if !self.isIncomingTopicsBannerVisible {
                self.incomingTopicsHeaderView.transform = hiddenTransform
            }
        }

        if visible {
            incomingTopicsHeaderView.isHidden = false
            incomingTopicsHeaderView.transform = hiddenTransform
        }

        guard animated else {
            updates()
            completion(true)
            return
        }

        DoerMotion.animate(
            duration: DoerMotion.quick,
            animations: updates
        ) { _ in
            completion(true)
        }
    }

    func updateIncomingTopicsPlacement(animated: Bool) {
        let shouldUseTopSpace = isIncomingTopicsBannerVisible && AppSettings.shared.homeIncomingTopicsBannerFloatingEnabled
        setIncomingTopicsUsesTopSpace(shouldUseTopSpace)
        incomingTopicsButton.setFloating(AppSettings.shared.homeIncomingTopicsBannerFloatingEnabled)
        incomingTopicsInlineButton.setFloating(false)

        guard animated else { return }
        DoerMotion.animate(duration: DoerMotion.quick) {
            self.view.layoutIfNeeded()
        }
    }

    func setIncomingTopicsInlineBannerVisible(_ visible: Bool) {
        guard isIncomingTopicsInlineBannerVisible != visible else {
            updateIncomingTopicsInlineHeaderFrame()
            return
        }
        isIncomingTopicsInlineBannerVisible = visible
        updateIncomingTopicsInlineHeaderFrame()
    }

    func updateIncomingTopicsInlineHeaderFrame() {
        let headerView = isIncomingTopicsInlineBannerVisible ? incomingTopicsInlineHeaderView : emptyTableHeaderView
        let height = isIncomingTopicsInlineBannerVisible
            ? incomingTopicsBannerHostHeight
            : CGFloat.leastNormalMagnitude
        let nextFrame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
        let needsFrameUpdate = headerView.frame.size != nextFrame.size
        if needsFrameUpdate {
            headerView.frame = nextFrame
        }
        if tableView.tableHeaderView !== headerView || needsFrameUpdate {
            tableView.tableHeaderView = headerView
        }
    }

    func setIncomingTopicsUsesTopSpace(_ usesTopSpace: Bool) {
        guard incomingTopicsUsesTopSpace != usesTopSpace else { return }
        incomingTopicsUsesTopSpace = usesTopSpace
        updateTableInsets()
    }

    func updateTableInsets() {
        let incomingTopicsTopSpace = isIncomingTopicsBannerVisible && incomingTopicsUsesTopSpace
            ? incomingTopicsBannerHostHeight
            : 0
        // Offline strip sits under the header; include its laid-out height.
        let offlineHeight = offlineIndicatorView.isHidden ? 0 : offlineIndicatorView.bounds.height
        let topInset = headerContainer.frame.maxY + offlineHeight + tableTopSpacing + incomingTopicsTopSpace
        let bottomInset = currentBottomChromeHeight + tableBottomSpacing

        var insets = tableView.contentInset
        let oldTopInset = insets.top
        let oldBottomInset = insets.bottom
        guard abs(oldTopInset - topInset) > 0.5 || abs(oldBottomInset - bottomInset) > 0.5 else { return }

        insets.top = topInset
        insets.bottom = bottomInset
        tableView.contentInset = insets
        tableView.verticalScrollIndicatorInsets = insets

        let shouldPreserveVisibleTopContent = !isTopRefreshGeometryLocked

        // Keep the visible content stable for normal header/banner changes. During
        // an intentional top refresh, the final offset is owned by the geometry lock.
        if shouldPreserveVisibleTopContent, oldTopInset > 0, abs(oldTopInset - topInset) > 0.5 {
            tableView.contentOffset.y += oldTopInset - topInset
        }
        if bottomInset < oldBottomInset {
            let minimumOffsetY = -insets.top
            let maximumOffsetY = max(
                minimumOffsetY,
                tableView.contentSize.height + insets.bottom - tableView.bounds.height
            )
            if tableView.contentOffset.y > maximumOffsetY {
                tableView.contentOffset.y = maximumOffsetY
            }
        }
    }

    var currentBottomChromeHeight: CGFloat {
        if let forumTabBarController = tabBarController as? ForumTabBarController {
            return forumTabBarController.visibleTabBarHeight
        }
        guard let tabBar = tabBarController?.tabBar, !tabBar.isHidden else { return 0 }
        return tabBar.frame.height
    }

    var tableTopSpacing: CGFloat {
        usesXiaohongshuCardLayout ? Self.xiaohongshuTableTopSpacing : Self.baseTableTopSpacing
    }

    var tableBottomSpacing: CGFloat {
        usesXiaohongshuCardLayout ? Self.xiaohongshuTableBottomSpacing : Self.baseTableBottomSpacing
    }
}
