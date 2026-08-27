import Combine
import Network
import UIKit

// MARK: - Data
extension HomeViewController {
    func applyTopicSnapshot(animatingDifferences: Bool? = nil) {
        let itemIdentifiers = topicSnapshotItemIdentifiers()
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(itemIdentifiers, toSection: 0)

        prefetchAvatarImages(for: viewModel.topics)
        let currentSnapshot = dataSource.snapshot()
        let currentIds = currentSnapshot.itemIdentifiers
        let needsInitialSnapshot = currentSnapshot.sectionIdentifiers.isEmpty
        let visibleExistingIds = Set(
            tableView.indexPathsForVisibleRows?.compactMap { dataSource.itemIdentifier(for: $0) } ?? []
        )
        let idsNeedingReconfigure = itemIdentifiers.filter { visibleExistingIds.contains($0) }
        // load more / contentSize 突变窗口禁止 diffable 动画，否则 offset 会抖并带动 tab bar。
        // Also disable while user is near bottom with pending pagination (pre-freeze window).
        let shouldAnimateSnapshot: Bool
        if let animatingDifferences {
            shouldAnimateSnapshot = animatingDifferences
        } else if shouldFreezeTabBarScrollControl
            || viewModel.isLoadingMore
            || isTabBarScrollFrozenForLoadMore
            || topicLoadMoreTask != nil {
            shouldAnimateSnapshot = false
        } else {
            shouldAnimateSnapshot = view.window != nil
                && !tableView.isDragging
                && !tableView.isDecelerating
        }

        let layoutKind = homeListLayoutKind
        let layoutChanged = lastAppliedHomeListLayoutKind != layoutKind
        lastAppliedHomeListLayoutKind = layoutKind

        if !needsInitialSnapshot, currentIds == itemIdentifiers, !layoutChanged {
            if !idsNeedingReconfigure.isEmpty {
                var updatedSnapshot = currentSnapshot
                // A topic can switch between pinned and regular cells without changing its id.
                // Reload allows the data source to dequeue the new reuse identifier.
                updatedSnapshot.reloadItems(idsNeedingReconfigure)
                dataSource.apply(updatedSnapshot, animatingDifferences: false)
            }
        } else {
            if layoutChanged, !itemIdentifiers.isEmpty, currentIds == itemIdentifiers {
                // Same topic ids but different cell class (TopicCell ↔ chat session list).
                snapshot.reloadItems(itemIdentifiers)
            } else if !idsNeedingReconfigure.isEmpty {
                snapshot.reloadItems(idsNeedingReconfigure)
            }
            dataSource.apply(snapshot, animatingDifferences: layoutChanged ? false : shouldAnimateSnapshot)
        }
    }

    func topicSnapshotItemIdentifiers() -> [Int] {
        topicListLayout.snapshotItemIdentifiers(
            topics: viewModel.topics,
            pinnedIds: viewModel.pinnedTopicIds
        )
    }

    func reloadTopics(resetCategoryMetadata: Bool = false, detectIncoming: Bool = true) {
        topicReloadTask?.cancel()
        topicLoadMoreTask?.cancel()
        topicLoadMoreTask = nil
        reloadTimeoutTask?.cancel()
        incomingTopicsRetryTask?.cancel()
        incomingTopicsRetryTask = nil
        reloadSequence += 1
        let sequence = reloadSequence
        if viewModel.topics.isEmpty, ConnectivityService.shared.isConnected {
            isInitialTopicLoadPending = true
            updateUI()
        }

        if resetCategoryMetadata {
            viewModel.resetCategoryMetadata(clearSelection: true)
        }

        reloadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.reloadTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.handleReloadTimeout(sequence: sequence)
            }
        }

        topicReloadTask = Task { [weak self] in
            guard let self else { return }
            await self.viewModel.loadTopics()
            guard !Task.isCancelled else { return }
            if detectIncoming {
                await self.viewModel.detectIncomingTopics()
            }
            await MainActor.run {
                self.finishReload(sequence: sequence)
            }
        }
    }

    func handleReloadTimeout(sequence: Int) {
        guard sequence == reloadSequence else { return }
        topicReloadTask?.cancel()
        topicReloadTask = nil
        reloadTimeoutTask = nil
        isInitialTopicLoadPending = false
        postInitialContentReadyIfNeeded()
        viewModel.finishLoadingAfterTimeout(message: String(localized: "error.network_timeout"))
        if refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
        // 只收 geometry lock；tab bar 等 lock 释放后再 restore，避开 endRefreshing 回弹窗口。
        finishTopRefreshGeometryLockIfNeeded()
    }

    func finishReload(sequence: Int) {
        guard sequence == reloadSequence else { return }
        reloadTimeoutTask?.cancel()
        reloadTimeoutTask = nil
        topicReloadTask = nil
        isInitialTopicLoadPending = false
        postInitialContentReadyIfNeeded()
        if refreshControl.isRefreshing {
            refreshControl.endRefreshing()
        }
        // 先 updateUI 再收 lock；restore 只在 lock 真正 release 时做一次。
        updateUI()
        finishTopRefreshGeometryLockIfNeeded()
    }

    func postInitialContentReadyIfNeeded() {
        guard !didPostInitialContentReady else { return }
        didPostInitialContentReady = true
        // First paint/bind can thrash contentOffset; re-assert tab bar after first content.
        setHomeTabBarHidden(false, animated: false)
        (tabBarController as? ForumTabBarController)?.syncTabBarVisibilityForCurrentContent()
        NotificationCenter.default.post(
            name: Self.initialContentReadyNotification,
            object: self,
            userInfo: [DiscourseAPI.cloudflareBaseURLUserInfoKey: api.baseURL]
        )
    }

    func selectListMode(_ mode: HomeListMode) {
        guard viewModel.listMode != mode else { return }
        viewModel.listMode = mode
        if !HomeTopicListOrdering.showsCompactPins(for: mode) {
            viewModel.pinnedTopicIds = []
        }
        updateFilterButton()
        reloadTopics()
    }

    func selectNewSubset(_ subset: HomeNewSubset) {
        guard viewModel.listMode == .newTopics, viewModel.newSubset != subset else { return }
        viewModel.newSubset = subset
        updateFilterButton()
        reloadTopics()
    }

    @objc func searchTapped() {
        let searchVC = SearchViewController(api: api)
        navigationController?.pushViewController(searchVC, animated: true)
    }

    @objc func notificationsTapped() {
        let notificationsVC = NotificationsViewController(
            api: api,
            authGate: authGate,
            notificationCoordinator: notificationCoordinator
        )
        notificationsVC.onTopicSelected = { [weak self] topicId, postNumber, postId in
            guard let self else { return }
            let detailVC = self.makeHomeTopicDetail(
                topicId: topicId,
                initialFloor: postNumber,
                initialPostId: postId
            )
            self.navigationController?.pushViewController(detailVC, animated: true)
        }
        let nav = UINavigationController(rootViewController: notificationsVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
        present(nav, animated: true)
    }

    func updateNotificationBadge() {
        let unreadCount = notificationCoordinator.unreadCount
        notificationBadgeView.isHidden = unreadCount == 0
        notificationBadgeView.layer.borderColor = headerContainer.backgroundColor?.cgColor
        notificationButton.accessibilityValue = unreadCount > 0 ? String(unreadCount) : nil
    }

    @objc func categoryManagerTapped() {
        if AppSettings.shared.homeCategoryDrawerSwipeEnabled {
            refreshCategoryDrawerContent()
            view.bringSubviewToFront(categoryDrawer)
            categoryDrawer.open(animated: true)
            return
        }
        presentCategoryPinManager()
    }

    @objc func miniProgramButtonTapped() {
        guard AppSettings.shared.miniProgramsEnabled else { return }
        presentMiniProgramDrawer()
    }
}
