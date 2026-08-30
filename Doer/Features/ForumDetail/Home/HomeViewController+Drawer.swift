import Combine
import Network
import UIKit

// MARK: - Drawer
extension HomeViewController {
    func handleSettingsChanged() {
        topicListLayout = HomeTopicListLayoutFactory.make(style: AppSettings.shared.themeStyle)
        setHomeTabBarHidden(false, animated: false)
        updateMiniProgramButtonVisibility()
        updateCategoryDrawerModeUI()
        applyThemeStyle()
        updateFilterButton()
        updateCategoryButton()
        updateCategoryTabs()
        updateFloatingActionButton(animated: false)
        applyIncomingTopicsBannerLayout()
        updateIncomingTopicsHeader()
        updateTableInsets()
        applyTopicSnapshot(animatingDifferences: false)
        if usesXiaohongshuCardLayout || usesChatHomeListLayout {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    func updateMiniProgramButtonVisibility() {
        let enabled = AppSettings.shared.miniProgramsEnabled
        miniProgramButton.isHidden = !enabled
        miniProgramButton.isUserInteractionEnabled = enabled
    }


    func setupCategoryDrawer() {
        categoryDrawer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(categoryDrawer)
        NSLayoutConstraint.activate([
            categoryDrawer.topAnchor.constraint(equalTo: view.topAnchor),
            categoryDrawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            categoryDrawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryDrawer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        categoryDrawer.onSelectCategory = { [weak self] categoryId in
            self?.selectCategory(categoryId)
        }
        categoryDrawer.onSelectTag = { [weak self] (tagName: String) in
            guard let self else { return }
            let tagVC = TagTopicsViewController(api: self.api, tagName: tagName)
            self.navigationController?.pushViewController(tagVC, animated: true)
        }
        categoryDrawer.onEditPinned = { [weak self] in
            self?.categoryDrawer.close(animated: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.presentCategoryPinManager()
            }
        }
        categoryDrawer.onOpenChanged = { [weak self] isOpen in
            self?.tableView.isScrollEnabled = !isOpen
        }

        let edgePan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(categoryDrawerEdgePanned(_:)))
        edgePan.edges = .left
        edgePan.delegate = self
        view.addGestureRecognizer(edgePan)
        categoryDrawerEdgePan = edgePan
        updateCategoryDrawerModeUI()
    }

    func updateCategoryDrawerModeUI() {
        let enabled = isCategoryDrawerMode
        categoryDrawerEdgePan?.isEnabled = enabled

        // Drawer owns category navigation — hide the redundant chip row, 分类
        // filter dropdown, and the header menu button (edge-swipe opens drawer).
        // Pin management moves to the drawer "编辑" action.
        categoryScrollView.isHidden = enabled
        categoryScrollView.isUserInteractionEnabled = !enabled
        categoryManagerButton.isHidden = enabled
        categoryManagerButton.isUserInteractionEnabled = !enabled
        categoryButton.isHidden = enabled
        categoryButton.isUserInteractionEnabled = !enabled
        // Keep the dropdown out of VoiceOver / hit-testing while collapsed in the stack.
        categoryButton.accessibilityElementsHidden = enabled

        categoryScrollHeightConstraint?.constant = enabled ? 0 : Self.categoryRowHeight
        // Drawer: pin「最新」to the top (category chips hidden). Normal: under chips.
        filterTopToCategoryConstraint?.isActive = !enabled
        filterTopToSafeAreaConstraint?.isActive = enabled
        // Chip mode: 搜索/分类/小程序/铃铛 on the top row with category chips.
        // Drawer mode: chips + 三线 hidden → remaining chrome aligns with filter.
        trailingChromeCenterYToCategoryConstraint?.isActive = !enabled
        trailingChromeCenterYToFilterConstraint?.isActive = enabled
        filterTrailingToHeaderConstraint?.isActive = !enabled
        filterTrailingToChromeConstraint?.isActive = enabled

        if enabled {
            refreshCategoryDrawerContent()
        } else {
            var config = categoryManagerButton.configuration ?? .plain()
            config.image = UIImage(
                systemName: "line.3.horizontal",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            )
            categoryManagerButton.accessibilityLabel = String(localized: "home.category_manager.title")
            categoryManagerButton.accessibilityHint = nil
            categoryManagerButton.configuration = config
            categoryDrawer.close(animated: false)
        }

        // Recompute header height so drawer mode does not leave an empty chip-row gap.
        let targetHeaderHeight = isSearchRowCollapsed ? collapsedHeaderHeight : expandedHeaderHeight
        headerHeightConstraint?.constant = targetHeaderHeight
        headerContainer.layoutIfNeeded()
        updateTableInsets()
    }

    func refreshCategoryDrawerContent() {
        categoryDrawer.configure(
            categories: viewModel.categories,
            selectedCategoryId: viewModel.selectedCategoryId,
            baseURL: api.baseURL,
            displayNameProvider: { [weak self] category in
                self?.viewModel.categoryDisplayName(for: category) ?? category.name
            }
        )
        loadCategoryDrawerTagsIfNeeded()
    }

    func loadCategoryDrawerTagsIfNeeded() {
        guard AppSettings.shared.homeCategoryDrawerSwipeEnabled else { return }
        if didLoadCategoryDrawerTags {
            return
        }
        categoryDrawer.setTagGroups([], isLoading: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let groups = try await self.api.fetchSiteTagGroups()
                await MainActor.run {
                    self.didLoadCategoryDrawerTags = true
                    self.categoryDrawer.setTagGroups(groups, isLoading: false)
                }
            } catch {
                await MainActor.run {
                    self.categoryDrawer.setTagGroups([], isLoading: false)
                }
            }
        }
    }


    @objc func categoryDrawerEdgePanned(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard AppSettings.shared.homeCategoryDrawerSwipeEnabled else { return }
        let tx = gesture.translation(in: view).x
        let velocity = gesture.velocity(in: view).x
        switch gesture.state {
        case .began:
            refreshCategoryDrawerContent()
            view.bringSubviewToFront(categoryDrawer)
            categoryDrawer.prepareForInteractiveOpen()
        case .changed:
            categoryDrawer.setInteractiveProgress(max(0, min(1, tx / 304)))
        case .ended, .cancelled:
            categoryDrawer.settle(velocityDx: velocity)
        default:
            break
        }
    }

    func openTopic(_ topicId: Int) {
        let topic = viewModel.topic(id: topicId)
        let username = AuthManager.shared.username(for: api.baseURL)
        let mergedLastRead = TopicReadProgressStore.shared.mergedLastRead(
            serverLastRead: topic?.lastReadPostNumber,
            topicId: topicId,
            baseURL: api.baseURL,
            username: username
        )
        // Resume at first unread floor when we know last_read (server and/or local).
        let resumeFloor = Self.resumeReadingFloor(for: topic, mergedLastRead: mergedLastRead)
        let detailVC = makeHomeTopicDetail(
            topicId: topicId,
            initialFloor: resumeFloor,
            lastReadPostNumber: mergedLastRead > 0 ? mergedLastRead : topic?.lastReadPostNumber
        )
        if usesSplitDetail {
            showTopicInSplit(detailVC)
        } else {
            navigationController?.pushViewController(detailVC, animated: true)
        }
    }

    /// First unread post number, or `nil` to open at the top.
    static func resumeReadingFloor(
        for topic: DiscourseTopicList.Topic?,
        mergedLastRead: Int? = nil
    ) -> Int? {
        guard let topic else { return nil }
        let lastRead = mergedLastRead ?? topic.lastReadPostNumber ?? 0
        let highest = topic.highestPostNumber ?? topic.postsCount
        guard lastRead > 1, highest > lastRead else { return nil }
        return min(lastRead + 1, highest)
    }
}
