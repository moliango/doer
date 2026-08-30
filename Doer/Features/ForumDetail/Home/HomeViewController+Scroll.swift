import Combine
import Network
import UIKit

extension HomeViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === createMenuDismissTapGesture, isCreateMenuVisible else { return true }
        let location = touch.location(in: view)
        return !createMenuContainer.frame.contains(location)
            && !floatingActionButton.frame.contains(location)
    }
}

extension HomeViewController: UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        if isCreateMenuVisible, scrollView.isDragging || scrollView.isDecelerating {
            setCreateMenuVisible(false, animated: true)
        }
        hideHomeScrollIndicators()
        updateIncomingTopicsPlacement(animated: false)
        let y = scrollView.contentOffset.y + scrollView.contentInset.top
        let previousY = lastHomeScrollY ?? y
        var deltaY = y - previousY
        lastHomeScrollY = y

        // load-more 插入行会让 contentSize 突然变大，UITableView 常伴随 offset 回弹，
        // 产生假的 deltaY < 0，被误判成「下滑」从而弹出 tab bar。
        let contentHeight = scrollView.contentSize.height
        let contentGrew = contentHeight > lastTopicListContentHeight + 1
        if contentGrew {
            lastTopicListContentHeight = contentHeight
            // 重置基线，吞掉这一帧的假 delta；并短暂禁止 show（后续几帧回弹也不出 tab bar）。
            lastHomeScrollY = y
            deltaY = max(0, deltaY)
            tabBarShowSuppressedUntil = CACurrentMediaTime() + 0.55
        } else {
            lastTopicListContentHeight = contentHeight
        }

        let velocityY = scrollView.panGestureRecognizer.velocity(in: scrollView).y
        if velocityY > 80, y > 24 {
            setFABMode(.refresh, animated: true)
        } else if velocityY < -80 || y <= 2 {
            setFABMode(.create, animated: true)
        }

        // Only hide/show from real user interaction, never from programmatic offset jumps
        // (first load, banner insert, contentSize changes, inset adjustments).
        let userDriven = scrollView.isDragging
            || scrollView.isDecelerating
            || scrollView.panGestureRecognizer.state == .began
            || scrollView.panGestureRecognizer.state == .changed
        // 显示 tab bar 必须手指仍在拖；纯惯性/回弹的负 delta 不算「下滑」。
        let activelyDragging = scrollView.isDragging
            || scrollView.panGestureRecognizer.state == .began
            || scrollView.panGestureRecognizer.state == .changed
        let suppressShow = CACurrentMediaTime() < tabBarShowSuppressedUntil
        let nearBottomPagination = isNearTopicListBottomForPagination
            && (viewModel.canLoadMore || viewModel.isLoadingMore || isTabBarScrollFrozenForLoadMore)

        // Drive search morph while scrolling.
        // - Hysteresis (8 / 24) avoids flicker at the threshold.
        // - Skip while a morph animator is running so inset changes mid-animation
        //   cannot immediately bounce expand↔collapse and eat the search icon.
        // - Also react while decelerating (inertia after 上滑).
        if !isTopRefreshGeometryLocked, searchRowMorphAnimator == nil {
            let allowSearchMorph = userDriven
                || scrollView.isDecelerating
                || scrollView.isDragging
            if allowSearchMorph {
                if isSearchRowCollapsed {
                    if y < 8 {
                        setSearchRowCollapsed(false, animated: true)
                    }
                } else if y > 24 {
                    setSearchRowCollapsed(true, animated: true)
                }
            }
        }

        // 刷新 / 加载下一页 / 触底窗口：只允许「上滑隐藏」，禁止「下滑显示」。
        // 分页 contentSize 抖动的假 deltaY 绝不能把 tab bar 弹出来。
        if shouldFreezeTabBarScrollControl {
            if !AppSettings.shared.bottomBarAutoHideEnabled {
                setHomeTabBarHidden(false, animated: true)
            } else if y <= 8 {
                setHomeTabBarHidden(false, animated: true)
            } else if HomeTabBarScrollPolicy.shouldHideFromScroll(
                contentY: y, userDriven: userDriven, deltaY: deltaY
            ) {
                setHomeTabBarHidden(true, animated: true)
            }
            // 注意：此处故意没有 deltaY < 0 → show 的分支。
            return
        }
        if !AppSettings.shared.bottomBarAutoHideEnabled {
            setHomeTabBarHidden(false, animated: true)
            return
        }
        // Near top always show.
        if y <= 8 {
            setHomeTabBarHidden(false, animated: true)
            return
        }
        // 显示：仅主动手指下滑；上滑翻页 / contentSize 回弹 / 触底分页窗口一律不出。
        if HomeTabBarScrollPolicy.shouldRevealFromScroll(
            contentY: y,
            isDragging: activelyDragging,
            deltaY: deltaY,
            contentGrew: contentGrew,
            suppressShow: suppressShow,
            nearBottomPagination: nearBottomPagination
        ) {
            setHomeTabBarHidden(false, animated: true)
            return
        }
        if HomeTabBarScrollPolicy.shouldHideFromScroll(
            contentY: y, userDriven: userDriven, deltaY: deltaY
        ) {
            setHomeTabBarHidden(true, animated: true)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === tableView else { return }
        if triggerShortPullRefreshIfNeeded(scrollView) { return }
        guard !decelerate else { return }
        settleSearchRowCollapse(animated: true)
        healTabBarVisibilityAfterScrollSettles()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        settleSearchRowCollapse(animated: true)
        healTabBarVisibilityAfterScrollSettles()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        settleSearchRowCollapse(animated: true)
    }

    func settleSearchRowCollapse(animated: Bool) {
        guard !isTopRefreshGeometryLocked else {
            normalizeTopRefreshGeometry(animated: false)
            return
        }
        // Let an in-flight morph finish; its completion applies final chrome.
        guard searchRowMorphAnimator == nil else { return }

        let y = tableView.contentOffset.y + tableView.contentInset.top
        let shouldCollapse: Bool
        if isSearchRowCollapsed {
            shouldCollapse = y >= 8
        } else {
            shouldCollapse = y > 24
        }
        setSearchRowCollapsed(shouldCollapse, animated: animated)
        if searchRowMorphAnimator == nil, searchChromeNeedsHeal() {
            applySearchRowChromeFinalState()
        }
        lastHomeScrollY = tableView.contentOffset.y + tableView.contentInset.top
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath),
              Self.xiaohongshuRowIndex(from: topicId) == nil
        else { return }
        openTopic(topicId)
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let itemId = dataSource.itemIdentifier(for: indexPath),
              let resolved = resolveTopicPreview(at: indexPath, itemId: itemId, point: point)
        else { return nil }
        let topic = resolved.topic
        let topicId = topic.id
        let category = viewModel.category(for: topic)
        let username = AuthManager.shared.username(for: api.baseURL)
        let inQueue = TopicReadLaterStore.shared.contains(
            topicId: topicId,
            baseURL: api.baseURL,
            username: username
        )
        let open = UIAction(
            title: String(localized: "topic.preview.open", defaultValue: "打开话题"),
            image: UIImage(systemName: "arrow.up.right.square")
        ) { [weak self] _ in
            self?.openTopic(topicId)
        }
        let bookmark = UIAction(
            title: String(localized: "topic.bookmark.add", defaultValue: "书签"),
            image: UIImage(systemName: "bookmark")
        ) { [weak self] _ in
            self?.bookmarkTopicFromList(topicId: topicId, title: topic.title)
        }
        let later = UIAction(
            title: inQueue
                ? String(localized: "topic.read_later.remove", defaultValue: "移出稍后")
                : String(localized: "topic.read_later.add", defaultValue: "稍后阅读"),
            image: UIImage(systemName: "clock")
        ) { [weak self] _ in
            TopicReadLaterStore.shared.toggle(
                topicId: topicId,
                baseURL: self?.api.baseURL ?? "",
                username: username,
                title: topic.title,
                lastReadPostNumber: topic.lastReadPostNumber
            )
        }
        return TopicPreviewMenu.configuration(
            topic: topic,
            api: api,
            categoryName: viewModel.categoryDisplayName(for: category),
            actions: [open, bookmark, later],
            previewTargetView: resolved.targetView
        )
    }

    func tableView(
        _ tableView: UITableView,
        previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        TopicPreviewMenu.targetedPreview(for: configuration)
    }

    func tableView(
        _ tableView: UITableView,
        previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        TopicPreviewMenu.targetedPreview(for: configuration)
    }

    func tableView(
        _ tableView: UITableView,
        willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
        animator: UIContextMenuInteractionCommitAnimating
    ) {
        TopicPreviewMenu.applyCommitPopIfAllowed(to: animator)
        guard let number = configuration.identifier as? NSNumber else { return }
        animator.addCompletion { [weak self] in
            self?.openTopic(number.intValue)
        }
    }

    private func resolveTopicPreview(
        at indexPath: IndexPath,
        itemId: Int,
        point: CGPoint
    ) -> (topic: DiscourseTopicList.Topic, targetView: UIView?)? {
        if Self.xiaohongshuRowIndex(from: itemId) != nil {
            guard let cell = tableView.cellForRow(at: indexPath) as? XiaohongshuTopicGridCell else {
                return nil
            }
            let local = tableView.convert(point, to: cell)
            guard let hit = cell.topicPreviewHit(at: local),
                  let topic = viewModel.topic(id: hit.topicId)
            else { return nil }
            return (topic, hit.targetView)
        }
        guard let topic = viewModel.topic(id: itemId) else { return nil }
        let target = tableView.cellForRow(at: indexPath).map { TopicPreviewMenu.targetView(in: $0) }
        return (topic, target)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let topicId = dataSource.itemIdentifier(for: indexPath),
              Self.xiaohongshuRowIndex(from: topicId) == nil,
              let topic = viewModel.topic(id: topicId)
        else { return nil }

        let username = AuthManager.shared.username(for: api.baseURL)

        // Rightmost first: 已读 / 书签 / 稍后
        let markRead = UIContextualAction(
            style: .normal,
            title: String(localized: "topic.mark_read", defaultValue: "已读")
        ) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.markTopicReadFromList(topic)
            completion(true)
        }
        markRead.image = UIImage(systemName: "checkmark.circle")
        markRead.backgroundColor = .systemGray

        let bookmark = UIContextualAction(
            style: .normal,
            title: String(localized: "topic.bookmark.add", defaultValue: "书签")
        ) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.bookmarkTopicFromList(topicId: topicId, title: topic.title)
            completion(true)
        }
        bookmark.image = UIImage(systemName: "bookmark")
        bookmark.backgroundColor = .systemOrange

        let inQueue = TopicReadLaterStore.shared.contains(
            topicId: topicId,
            baseURL: api.baseURL,
            username: username
        )
        let laterTitle = inQueue
            ? String(localized: "topic.read_later.remove", defaultValue: "移出稍后")
            : String(localized: "topic.read_later.add", defaultValue: "稍后阅读")
        let readLater = UIContextualAction(style: .normal, title: laterTitle) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            TopicReadLaterStore.shared.toggle(
                topicId: topicId,
                baseURL: self.api.baseURL,
                username: username,
                title: topic.title,
                lastReadPostNumber: topic.lastReadPostNumber
            )
            completion(true)
        }
        readLater.image = UIImage(systemName: inQueue ? "square.stack.3d.up.slash" : "square.stack.3d.up.fill")
        readLater.backgroundColor = .systemIndigo

        let config = UISwipeActionsConfiguration(actions: [readLater, bookmark, markRead])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let topicId = dataSource.itemIdentifier(for: indexPath),
              Self.xiaohongshuRowIndex(from: topicId) == nil,
              let topic = viewModel.topic(id: topicId)
        else { return nil }

        let notify = UIContextualAction(
            style: .normal,
            title: String(localized: "topic.notifications", defaultValue: "通知")
        ) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.presentTopicNotificationLevelPicker(topicId: topicId, title: topic.title)
            completion(true)
        }
        notify.image = UIImage(systemName: "bell")
        notify.backgroundColor = .systemTeal

        let remind = UIContextualAction(
            style: .normal,
            title: String(localized: "reminder.action", defaultValue: "提醒")
        ) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.presentReminderPicker(
                kind: .readLater,
                topicId: topicId,
                title: topic.title
            )
            completion(true)
        }
        remind.image = UIImage(systemName: "alarm")
        remind.backgroundColor = .systemPurple

        return UISwipeActionsConfiguration(actions: [notify, remind])
    }

    private func markTopicReadFromList(_ topic: DiscourseTopicList.Topic) {
        let highest = max(topic.highestPostNumber ?? 0, topic.postsCount, topic.lastReadPostNumber ?? 0)
        guard highest > 0 else { return }
        _ = viewModel.updateTopicReadProgress(topicId: topic.id, highestSeen: highest, notify: true)
        // Best-effort server timing so web unread clears too.
        let topicId = topic.id
        let api = self.api
        Task {
            _ = await api.sendTopicTimings(
                topicId: topicId,
                topicTime: 1_000,
                timings: [highest: 1_000]
            )
        }
        // Single-row reconfigure
        if let indexPath = dataSource.indexPath(for: topic.id),
           tableView.indexPathsForVisibleRows?.contains(indexPath) == true {
            tableView.reloadRows(at: [indexPath], with: .none)
        }
    }

    private func bookmarkTopicFromList(topicId: Int, title: String) {
        let work = { [weak self] in
            guard let self else { return }
            Task {
                do {
                    _ = try await self.api.createBookmark(topicId: topicId)
                    await MainActor.run {
                        let ban = UIAlertController(
                            title: String(localized: "topic.bookmark.added", defaultValue: "已添加书签"),
                            message: title,
                            preferredStyle: .alert
                        )
                        ban.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
                        // Avoid interrupting swipe animation heavily — brief toast-style alert.
                        self.present(ban, animated: true)
                        Task { @MainActor [weak ban] in
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            ban?.dismiss(animated: true)
                        }
                    }
                } catch {
                    await MainActor.run {
                        let alert = UIAlertController(
                            title: String(localized: "common.error", defaultValue: "失败"),
                            message: error.localizedDescription,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
                        self.present(alert, animated: true)
                    }
                }
            }
        }
        if let authGate {
            authGate.requireAuth(then: work)
        } else {
            work()
        }
    }

    private func presentTopicNotificationLevelPicker(topicId: Int, title: String) {
        let work = { [weak self] in
            guard let self else { return }
            let sheet = UIAlertController(
                title: String(localized: "topic.notifications", defaultValue: "通知级别"),
                message: title,
                preferredStyle: .actionSheet
            )
            let levels: [(DiscourseTopicDetail.NotificationLevel, String)] = [
                (.watching, String(localized: "topic.notifications.watching", defaultValue: "关注")),
                (.tracking, String(localized: "topic.notifications.tracking", defaultValue: "跟踪")),
                (.regular, String(localized: "topic.notifications.regular", defaultValue: "常规")),
                (.muted, String(localized: "topic.notifications.muted", defaultValue: "静音")),
            ]
            for (level, label) in levels {
                sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    guard let self else { return }
                    Task {
                        do {
                            try await self.api.updateTopicNotificationLevel(topicId: topicId, level: level)
                        } catch {
                            await MainActor.run {
                                let alert = UIAlertController(
                                    title: String(localized: "common.error", defaultValue: "失败"),
                                    message: error.localizedDescription,
                                    preferredStyle: .alert
                                )
                                alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
                                self.present(alert, animated: true)
                            }
                        }
                    }
                })
            }
            sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = self.tableView
                pop.sourceRect = self.tableView.bounds
            }
            self.present(sheet, animated: true)
        }
        if let authGate {
            authGate.requireAuth(then: work)
        } else {
            work()
        }
    }

    func presentReminderPicker(kind: LocalReminderScheduler.Kind, topicId: Int, title: String) {
        let sheet = UIAlertController(
            title: String(localized: "reminder.pick", defaultValue: "设置提醒"),
            message: title,
            preferredStyle: .actionSheet
        )
        for preset in LocalReminderScheduler.presetDates() {
            sheet.addAction(UIAlertAction(title: preset.title, style: .default) { [weak self] _ in
                guard let self else { return }
                Task {
                    let ok = await LocalReminderScheduler.schedule(
                        .init(
                            kind: kind,
                            topicId: topicId,
                            baseURL: self.api.baseURL,
                            title: title,
                            fireAt: preset.date
                        )
                    )
                    await MainActor.run {
                        let message = ok
                            ? String(localized: "reminder.scheduled", defaultValue: "已设置本地提醒")
                            : String(localized: "reminder.denied", defaultValue: "未获得通知权限")
                        let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
                        self.present(alert, animated: true)
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(
            title: String(localized: "reminder.cancel_existing", defaultValue: "取消已有提醒"),
            style: .destructive
        ) { [weak self] _ in
            guard let self else { return }
            LocalReminderScheduler.cancel(kind: kind, topicId: topicId, baseURL: self.api.baseURL)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = tableView
            pop.sourceRect = tableView.bounds
        }
        present(sheet, animated: true)
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        heightForHomeRow(at: indexPath, allowAutomatic: false)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        heightForHomeRow(at: indexPath, allowAutomatic: true)
    }

    /// Pinned compact rows must not inherit `TopicCell`'s ~96pt estimate. That
    /// estimate stretches the card, and pull-to-refresh caches the stretched height.
    private func heightForHomeRow(at indexPath: IndexPath, allowAutomatic: Bool) -> CGFloat {
        if isCompactPinnedHomeRow(at: indexPath) {
            return CompactPinnedTopicCell.currentRowHeight
        }
        if allowAutomatic {
            return UITableView.automaticDimension
        }
        return topicListLayout.estimatedRowHeight
    }

    private func isCompactPinnedHomeRow(at indexPath: IndexPath) -> Bool {
        guard let topicId = dataSource.itemIdentifier(for: indexPath),
              Self.xiaohongshuRowIndex(from: topicId) == nil,
              let topic = viewModel.topic(id: topicId)
        else {
            return false
        }
        return HomeTopicListOrdering.isPinned(topic, pinnedIds: viewModel.pinnedTopicIds)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        // Follow-scroll avatar warm-up (not only the first page of the list).
        prefetchAvatarsAroundVisibleRows(around: indexPath)

        let totalRows = tableView.numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 5,
           viewModel.canLoadMore,
           viewModel.loadMoreErrorMessage == nil,
           !viewModel.isLoadingMore,
           !viewModel.isLoading,
           topicLoadMoreTask == nil {
            beginTabBarScrollFreezeForLoadMore()
            topicLoadMoreTask = Task { [weak self] in
                guard let self else { return }
                await self.viewModel.loadMoreTopics()
                await MainActor.run {
                    self.topicLoadMoreTask = nil
                    // Keep freeze until snapshot settles; updateUI ends freeze via syncTabBarFreezeWithLoadMoreState.
                    self.updateUI()
                }
            }
        }
    }

    @objc func loadMoreRetryTapped() {
        guard topicLoadMoreTask == nil, !viewModel.isLoadingMore, !viewModel.isLoading else { return }
        viewModel.loadMoreErrorMessage = nil
        beginTabBarScrollFreezeForLoadMore()
        topicLoadMoreTask = Task { [weak self] in
            guard let self else { return }
            await self.viewModel.loadMoreTopics()
            await MainActor.run {
                self.topicLoadMoreTask = nil
                self.updateUI()
            }
        }
    }
}
