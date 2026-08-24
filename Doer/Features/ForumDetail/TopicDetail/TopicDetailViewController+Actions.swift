import UIKit

extension TopicDetailViewController {
    // MARK: - Auth / error helpers (used by Coordinator + cells)

    func performAuthenticated(_ action: @escaping () -> Void) {
        if let authGate = findAuthGating() {
            authGate.requireAuth(then: action)
        } else {
            action()
        }
    }

    func findAuthGating() -> AuthGating? {
        nearestAuthGating()
    }

    func showPostActionError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "post.action.failed"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Diffable / bottom bar helpers (stay on VC)

    func reloadPostCell(postId: Int) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(postId) != nil else { return }
        // Gate self-sizing beginUpdates while Diffable reloads cells.
        tableView.doer_beginDataMutation()
        snapshot.reloadItems([postId])
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.tableView.doer_endDataMutation()
        }
    }

    func reconfigureVisiblePostCells(reloadAllIfNoneVisible: Bool = false) {
        // Never reloadItems while a full snapshot replace is in flight.
        guard !isApplyingPostSnapshot else { return }
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }

        let visibleIds = (tableView.indexPathsForVisibleRows ?? []).compactMap {
            dataSource.itemIdentifier(for: $0)
        }.filter { snapshot.indexOfItem($0) != nil }

        let ids: [Int]
        if !visibleIds.isEmpty {
            ids = visibleIds
        } else if reloadAllIfNoneVisible {
            ids = snapshot.itemIdentifiers
        } else {
            return
        }

        tableView.doer_beginDataMutation()
        snapshot.reloadItems(ids)
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            self?.tableView.doer_endDataMutation()
        }
    }

    func updateBottomBarProgress() {
        let current = currentVisibleFloor()
        let total = viewModel.totalFloors
        if let lastBottomBarProgressState,
           lastBottomBarProgressState.current == current,
           lastBottomBarProgressState.total == total {
            bottomBar.refreshGestureRecognizers()
            return
        }
        lastBottomBarProgressState = (current: current, total: total)
        bottomBar.configure(
            currentFloor: current,
            totalFloors: total
        )
    }

    func currentVisibleFloor() -> Int {
        guard viewModel.totalFloors > 0 else { return 0 }
        let visibleIndexPath = tableView.indexPathsForVisibleRows?
            .sorted { $0.row < $1.row }
            .first
        guard let visibleIndexPath,
              let postId = dataSource.itemIdentifier(for: visibleIndexPath),
              let streamIndex = viewModel.allPostIds.firstIndex(of: postId)
        else {
            return max(1, min(viewModel.loadedRangeStart + 1, viewModel.totalFloors))
        }
        return streamIndex + 1
    }

    // MARK: - Nav chrome (stays on VC; actions go through Coordinator)

    func makeExportMenu() -> UIMenu {
        let formatMenus = TopicExportFormat.allCases.map { format in
            UIMenu(
                title: format.title,
                image: UIImage(systemName: format == .markdown ? "doc.plaintext" : "chevron.left.forwardslash.chevron.right"),
                children: TopicExportRange.allCases.map { range in
                    UIAction(title: range.title) { [weak self] _ in
                        self?.coordinator.exportTopic(format: format, range: range)
                    }
                }
            )
        }
        let notionMenus = NotionSyncScope.allCases.map { scope in
            UIAction(title: scope.title) { [weak self] _ in
                self?.coordinator.syncTopicToNotion(scope: scope)
            }
        }
        let notionMenu = UIMenu(
            title: String(localized: "notion.sync", defaultValue: "同步到 Notion"),
            image: UIImage(systemName: "tray.and.arrow.up"),
            children: notionMenus
        )
        return UIMenu(
            title: String(localized: "topic.export", defaultValue: "导出话题"),
            image: UIImage(systemName: "square.and.arrow.up"),
            children: formatMenus + [notionMenu]
        )
    }

    func configureTopicActions() {
        let searchButton = UIBarButtonItem(
            image: UIImage(systemName: "magnifyingglass"),
            style: .plain,
            target: self,
            action: #selector(searchTopicTapped)
        )
        searchButton.accessibilityLabel = String(localized: "topic.search", defaultValue: "搜索话题")

        let moreButton = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            style: .plain,
            target: self,
            action: #selector(presentTopicMoreMenu)
        )
        moreButton.accessibilityLabel = String(localized: "topic.more", defaultValue: "更多操作")

        // FluxDo chrome: search + more only; quick actions live inside more popup.
        navigationItem.rightBarButtonItems = [moreButton, searchButton]
    }

    @objc func presentTopicMoreMenu() {
        let topic = viewModel.topic
        let username = AuthManager.shared.username(for: api.baseURL)
        let isReadLater = TopicReadLaterStore.shared.contains(
            topicId: topicId,
            baseURL: api.baseURL,
            username: username
        )
        let model = TopicMoreMenuViewController.Model(
            isBookmarked: topic?.bookmarked == true,
            isInReadLater: isReadLater,
            notificationLevel: topic?.notificationLevel,
            hasActiveFilter: viewModel.isFilteringByOP || viewModel.isFilteringTopLevel || viewModel.isNestedViewEnabled,
            isFilteringByOP: viewModel.isFilteringByOP,
            isFilteringTopLevel: viewModel.isFilteringTopLevel,
            isNestedViewEnabled: viewModel.isNestedViewEnabled,
            canEdit: topic?.canEdit == true,
            showExport: DoerPluginRuntime.shared.registry.isPluginEnabled(
                BuiltInPluginID.topicExport,
                for: pluginScope
            ),
            canAssign: topic?.canAssign == true || topic?.assignedToUsername != nil,
            assignedToUsername: topic?.assignedToUsername,
            currentFloor: currentVisibleFloor(),
            totalFloors: max(viewModel.totalFloors, 1),
            hasTableOfContents: tocController.hasToc
        )
        let barItem = navigationItem.rightBarButtonItems?.first
        TopicMoreMenuPresenter.present(from: self, barButtonItem: barItem, model: model) { [weak self] action in
            self?.handleTopicMoreMenuAction(action)
        }
    }

    func handleTopicMoreMenuAction(_ action: TopicMoreMenuViewController.Action) {
        switch action {
        case .bookmark:
            coordinator.bookmarkTopic()
        case .readLater:
            let title = viewModel.topic?.title
                ?? viewModel.topic?.fancyTitle
                ?? "#\(topicId)"
            TopicReadLaterStore.shared.toggle(
                topicId: topicId,
                baseURL: api.baseURL,
                username: AuthManager.shared.username(for: api.baseURL),
                title: title,
                lastReadPostNumber: lastReadPostNumber ?? viewModel.topic?.lastReadPostNumber
            )
            configureTopicActions()
        case .shareLink:
            coordinator.shareTopicLink(sourceView: nil)
        case .editTopic:
            coordinator.editTopic()
        case .shareImage:
            coordinator.shareTopicImage()
        case .export(let format, let range):
            coordinator.exportTopic(format: format, range: range)
        case .openBrowser:
            guard let url = URL(string: "\(baseURL)/t/\(topicId)") else { return }
            let browser = InAppBrowserViewController(
                api: api,
                username: AuthManager.shared.username(for: api.baseURL),
                initialURL: url
            )
            navigationController?.pushViewController(browser, animated: true)
        case .openTimeline:
            showTimelineSheet()
        case .jumpToFloor(let floor):
            jumpToFloor(floor)
        case .readingSettings:
            navigationController?.pushViewController(ReadingSettingsViewController(), animated: true)
        case .tableOfContents:
            presentTopicToc()
        case .markUnreadStepBack:
            markTopicUnread(mode: .stepBack)
        case .markUnreadClear:
            markTopicUnread(mode: .clear)
        case .assignToMe:
            performAssign(mode: .toMe)
        case .assignPickUser:
            performAssign(mode: .pickUser)
        case .unassign:
            performAssign(mode: .clear)
        case .filterOP:
            viewModel.setFilteringByOP(!viewModel.isFilteringByOP)
            configureTopicActions()
        case .filterTopLevel:
            viewModel.setFilteringTopLevel(!viewModel.isFilteringTopLevel)
            configureTopicActions()
        case .filterNested:
            let enabled = !viewModel.isNestedViewEnabled
            AppSettings.shared.nestedReplyViewEnabled = enabled
            viewModel.setNestedViewEnabled(enabled)
            configureTopicActions()
        case .filterClear:
            AppSettings.shared.nestedReplyViewEnabled = false
            viewModel.clearTopicFilters()
            configureTopicActions()
        case .notification(let level):
            Task { @MainActor in
                do {
                    try await api.updateTopicNotificationLevel(topicId: topicId, level: level)
                    await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width)
                    configureTopicActions()
                } catch {
                    DoerFeedback.presentToast(error.localizedDescription, on: self)
                }
            }
        }
    }

    enum AssignMode {
        case toMe
        case pickUser
        case clear
    }

    func performAssign(mode: AssignMode) {
        switch mode {
        case .clear:
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.api.unassignTopic(topicId: self.topicId)
                    DoerFeedback.presentToast(
                        String(localized: "topic.assign.clear.done", defaultValue: "已取消指定"),
                        on: self
                    )
                    await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
                } catch {
                    DoerFeedback.presentToast(error.localizedDescription, on: self)
                }
            }
        case .toMe:
            let me = AuthManager.shared.username(for: api.baseURL)
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.api.assignTopic(topicId: self.topicId, username: me)
                    DoerFeedback.presentToast(
                        String(localized: "topic.assign.to_me.done", defaultValue: "已指定给你"),
                        on: self
                    )
                    await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
                } catch {
                    DoerFeedback.presentToast(error.localizedDescription, on: self)
                }
            }
        case .pickUser:
            // Center card form — never a bottom action sheet.
            let me = AuthManager.shared.username(for: api.baseURL)
            let alert = UIAlertController(
                title: String(localized: "topic.assign.pick_user", defaultValue: "指定给"),
                message: String(localized: "topic.assign.pick_user.message", defaultValue: "输入用户名"),
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = String(localized: "messages.compose.recipient_placeholder", defaultValue: "用户名")
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.text = me
            }
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default) { [weak self] _ in
                let name = alert.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                guard let self, let name, !name.isEmpty else { return }
                Task { @MainActor in
                    do {
                        try await self.api.assignTopic(topicId: self.topicId, username: name)
                        DoerFeedback.presentToast(
                            String(localized: "topic.assign.to_me.done", defaultValue: "已指定"),
                            on: self
                        )
                        await self.viewModel.loadTopic(id: self.topicId, containerWidth: self.view.bounds.width)
                    } catch {
                        DoerFeedback.presentToast(error.localizedDescription, on: self)
                    }
                }
            })
            present(alert, animated: true)
        }
    }

    enum MarkUnreadMode {
        case stepBack
        case clear
    }

    func markTopicUnread(mode: MarkUnreadMode) {
        let username = AuthManager.shared.username(for: api.baseURL)
        let server = lastReadPostNumber ?? viewModel.topic?.lastReadPostNumber
        switch mode {
        case .stepBack:
            let next = TopicReadProgressStore.shared.stepBack(
                topicId: topicId,
                baseURL: api.baseURL,
                username: username,
                serverLastRead: server
            )
            lastReadPostNumber = next > 0 ? next : nil
            DoerFeedback.presentToast(
                String(localized: "topic.mark_unread.step_back.done", defaultValue: "已回退一层阅读进度"),
                on: self
            )
        case .clear:
            TopicReadProgressStore.shared.clear(
                topicId: topicId,
                baseURL: api.baseURL,
                username: username
            )
            lastReadPostNumber = nil
            DoerFeedback.presentToast(
                String(localized: "topic.mark_unread.clear.done", defaultValue: "已清空阅读进度"),
                on: self
            )
        }
        // Best-effort server signal via timings on the target floor (server is often monotonic).
        let target = lastReadPostNumber ?? 1
        Task {
            _ = await api.sendTopicTimings(topicId: topicId, topicTime: 1, timings: [target: 1])
        }
    }

    func presentTopicFilterSheet() {
        let sheet = UIAlertController(
            title: String(localized: "topic.filter", defaultValue: "筛选"),
            message: nil,
            preferredStyle: .actionSheet
        )
        func add(_ title: String, on: Bool, handler: @escaping () -> Void) {
            let label = on ? "✓ \(title)" : title
            sheet.addAction(UIAlertAction(title: label, style: .default) { _ in handler() })
        }
        add(String(localized: "topic.filter_op", defaultValue: "只看题主"), on: viewModel.isFilteringByOP) { [weak self] in
            guard let self else { return }
            self.viewModel.setFilteringByOP(!self.viewModel.isFilteringByOP)
            self.configureTopicActions()
        }
        add(String(localized: "topic.filter_top_level", defaultValue: "只看顶层"), on: viewModel.isFilteringTopLevel) { [weak self] in
            guard let self else { return }
            self.viewModel.setFilteringTopLevel(!self.viewModel.isFilteringTopLevel)
            self.configureTopicActions()
        }
        add(String(localized: "topic.filter_nested", defaultValue: "树形视图"), on: viewModel.isNestedViewEnabled) { [weak self] in
            guard let self else { return }
            let enabled = !self.viewModel.isNestedViewEnabled
            AppSettings.shared.nestedReplyViewEnabled = enabled
            self.viewModel.setNestedViewEnabled(enabled)
            self.configureTopicActions()
        }
        if viewModel.hasActiveTopicFilter {
            sheet.addAction(UIAlertAction(
                title: String(localized: "topic.filter_clear", defaultValue: "取消筛选"),
                style: .destructive
            ) { [weak self] _ in
                AppSettings.shared.nestedReplyViewEnabled = false
                self?.viewModel.clearTopicFilters()
                self?.configureTopicActions()
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(sheet, animated: true)
    }


    func title(for level: DiscourseTopicDetail.NotificationLevel) -> String {
        switch level {
        case .watching: return String(localized: "topic.notifications.watching", defaultValue: "关注")
        case .tracking: return String(localized: "topic.notifications.tracking", defaultValue: "跟踪")
        case .regular: return String(localized: "topic.notifications.regular", defaultValue: "常规")
        case .muted: return String(localized: "topic.notifications.muted", defaultValue: "静音")
        }
    }

    // MARK: - Action entry points → Coordinator

    func replyButtonTapped() {
        coordinator.replyButtonTapped()
    }

    func shareTopicLink(sourceView: UIView?) {
        coordinator.shareTopicLink(sourceView: sourceView)
    }

    func bookmarkTopic() {
        coordinator.bookmarkTopic()
    }

    func exportTopic(format: TopicExportFormat, range: TopicExportRange) {
        coordinator.exportTopic(format: format, range: range)
    }

    func notionSync() {
        coordinator.notionSync()
    }

    @objc func aiAssistantTapped() {
        coordinator.aiAssistantTapped()
    }

    @objc func searchTopicTapped() {
        coordinator.searchTopicTapped()
    }

    @objc func pluginStateDidChange() {
        // Coordinator also observes; keep for any direct NotificationCenter.addObserver(self) call sites.
        configureTopicActions()
    }

    func editTopic() {
        coordinator.editTopic()
    }

    func handleLink(_ url: URL) {
        coordinator.handleLink(url)
    }

    func openInternalDestination(_ destination: ForumInternalLinkDestination) {
        coordinator.openInternalDestination(destination)
    }

    func shareTopicImage(postId: Int? = nil) {
        coordinator.shareTopicImage(postId: postId)
    }

    func maybeAutoSyncNotionAfterBookmark() {
        coordinator.maybeAutoSyncNotionAfterBookmark()
    }

    func presentSafari(_ url: URL) {
        coordinator.presentSafari(url)
    }

    func openInternalViewController(_ viewController: UIViewController) {
        coordinator.openInternalViewController(viewController)
    }

    func setNotificationLevel(_ level: DiscourseTopicDetail.NotificationLevel) {
        coordinator.setNotificationLevel(level)
    }

    func syncTopicToNotion(scope: NotionSyncScope, duplicate: NotionDuplicateAction = .skip) {
        coordinator.syncTopicToNotion(scope: scope, duplicate: duplicate)
    }

    // MARK: - Live topic stream sync

    func startLiveTopicSync() {
        stopLiveTopicSync()
        let timer = Timer(timeInterval: TopicDetailPaginationPolicy.liveSyncInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performLiveTopicSync(reason: "timer")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveSyncTimer = timer

        if appForegroundObserver == nil {
            appForegroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.performLiveTopicSync(reason: "foreground")
                }
            }
        }

        Task { await performLiveTopicSync(reason: "start") }
    }

    func stopLiveTopicSync() {
        liveSyncTimer?.invalidate()
        liveSyncTimer = nil
        if let appForegroundObserver {
            NotificationCenter.default.removeObserver(appForegroundObserver)
            self.appForegroundObserver = nil
        }
    }

    func isReadingNearBottomForLiveSync() -> Bool {
        let total = tableView.numberOfRows(inSection: 0)
        guard total > 0 else { return true }
        let threshold = TopicDetailPaginationPolicy.liveSyncNearBottomRows
        let maxVisible = tableView.indexPathsForVisibleRows?.map(\.row).max() ?? 0
        return maxVisible >= total - threshold
    }

    @MainActor
    func performLiveTopicSync(reason: String) async {
        guard viewModel.isReady, !viewModel.isJumping else { return }
        let autoAppend = isReadingNearBottomForLiveSync()
        let pending = await viewModel.syncLiveTopicStream(
            autoAppend: autoAppend,
            containerWidth: view.bounds.width
        )
        updateNewRepliesBanner(forcePending: pending)
        #if DEBUG
        if pending > 0 {
            print("[TopicDetail] live sync reason=\(reason) pending=\(pending) autoAppend=\(autoAppend)")
        }
        #endif
    }

    func updateNewRepliesBanner(forcePending: Int? = nil) {
        let count = forcePending ?? viewModel.pendingNewReplyCount
        let shouldShow = viewModel.isReady && count > 0
        let title: String
        if count <= 0 {
            title = ""
        } else if count == 1 {
            title = String(localized: "topic_detail.new_replies.one", defaultValue: "1 条新回复")
        } else {
            title = String(
                format: String(localized: "topic_detail.new_replies.many", defaultValue: "%lld 条新回复"),
                locale: .current,
                count
            )
        }

        var config = newRepliesBanner.configuration ?? .filled()
        config.title = title
        config.baseBackgroundColor = AppSettings.shared.themeStyle.accentColor
        newRepliesBanner.configuration = config

        let currentlyVisible = !newRepliesBanner.isHidden && newRepliesBanner.alpha > 0.01
        guard shouldShow != currentlyVisible else {
            if shouldShow {
                newRepliesBanner.isHidden = false
                newRepliesBanner.alpha = 1
            }
            return
        }

        if shouldShow {
            newRepliesBanner.isHidden = false
            view.bringSubviewToFront(newRepliesBanner)
            AnimationOptimizer.animateAlphaAndTransform(
                newRepliesBanner,
                alpha: 1,
                transform: .identity,
                duration: 0.22
            )
        } else {
            AnimationOptimizer.animateAlphaAndTransform(
                newRepliesBanner,
                alpha: 0,
                transform: CGAffineTransform(translationX: 0, y: 8),
                duration: 0.18
            ) {
                self.newRepliesBanner.isHidden = true
                self.newRepliesBanner.transform = .identity
            }
        }
    }

    func handleNewRepliesBannerTapped() {
        Task { @MainActor in
            let floor = await viewModel.consumePendingNewReplies(containerWidth: view.bounds.width)
            updateNewRepliesBanner()
            if let floor {
                jumpToFloor(floor)
            } else if viewModel.totalFloors > 0 {
                jumpToFloor(viewModel.totalFloors)
            }
        }
    }
}
