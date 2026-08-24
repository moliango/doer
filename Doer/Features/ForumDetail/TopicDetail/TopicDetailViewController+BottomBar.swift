import CookedHTML
import UIKit

// MARK: - TopicDetailBottomBarDelegate

extension TopicDetailViewController: TopicDetailBottomBarDelegate {
    func bottomBarDidTapTimeline() {
        showTimelineSheet()
    }

    func bottomBarDidSelectProgressAction(_ action: ProgressGestureAction) {
        performProgressGestureAction(action)
    }

    func performProgressGestureAction(_ action: ProgressGestureAction) {
        switch action {
        case .none:
            break
        case .openTimeline:
            showTimelineSheet()
        case .scrollToTop:
            scrollToTop()
        case .jumpToUnread:
            jumpToUnreadOrFirst()
        case .nextPost:
            jumpRelativeFloor(+1)
        case .previousPost:
            jumpRelativeFloor(-1)
        case .reply:
            replyButtonTapped()
        case .share:
            shareTopicLink(sourceView: bottomBar)
        case .shareImage:
            shareTopicImage()
        case .exportArticle:
            presentExportMenuFromProgressBar()
        case .openInBrowser:
            openTopicInBrowser()
        case .bookmark:
            bookmarkTopic()
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
        case .notification:
            presentNotificationLevelPicker()
        case .filter:
            viewModel.setFilteringByOP(!viewModel.isFilteringByOP)
            configureTopicActions()
        case .toggleNestedView:
            let enabled = !viewModel.isNestedViewEnabled
            AppSettings.shared.nestedReplyViewEnabled = enabled
            viewModel.setNestedViewEnabled(enabled)
        case .aiAssistant:
            aiAssistantTapped()
        case .readingSettings:
            navigationController?.pushViewController(ReadingSettingsViewController(), animated: true)
        case .search:
            showTimelineSheet()
        case .refresh:
            Task { await viewModel.loadTopic(id: topicId, containerWidth: view.bounds.width) }
        case .goBack:
            if canNavigateBack {
                navigationController?.popViewController(animated: true)
            } else {
                dismiss(animated: true)
            }
        }
    }

    func scrollToTop() {
        guard tableView.numberOfRows(inSection: 0) > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
    }

    func jumpRelativeFloor(_ delta: Int) {
        let total = viewModel.totalFloors
        guard total > 0 else { return }
        let target = min(max(currentVisibleFloor() + delta, 1), total)
        jumpToFloor(target)
    }

    func jumpToUnreadOrFirst() {
        let total = viewModel.totalFloors
        guard total > 0 else { return }
        // Real unread: last_read + 1 (from list or detail). Fallback: next floor / top.
        if let unread = resumeUnreadFloor() {
            jumpToFloor(unread)
            return
        }
        let current = currentVisibleFloor()
        if current < total {
            jumpToFloor(current + 1)
        } else {
            jumpToFloor(1)
        }
    }

    /// First unread floor from `lastReadPostNumber`, clamped to total floors.
    func resumeUnreadFloor() -> Int? {
        let total = viewModel.totalFloors
        guard total > 0 else { return nil }
        let lastRead = lastReadPostNumber ?? viewModel.topic?.lastReadPostNumber ?? 0
        guard lastRead > 0, lastRead < total else { return nil }
        return min(lastRead + 1, total)
    }

    func openTopicInBrowser() {
        guard let url = URL(string: "\(baseURL)/t/\(topicId)") else { return }
        let browser = InAppBrowserViewController(
            api: api,
            username: AuthManager.shared.username(for: api.baseURL),
            initialURL: url
        )
        navigationController?.pushViewController(browser, animated: true)
    }

    func presentExportMenuFromProgressBar() {
        let sheet = UIAlertController(
            title: String(localized: "topic.export", defaultValue: "导出话题"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for range in TopicExportRange.allCases {
            sheet.addAction(UIAlertAction(title: range.title, style: .default) { [weak self] _ in
                self?.exportTopic(format: .markdown, range: range)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = bottomBar
        sheet.popoverPresentationController?.sourceRect = bottomBar.bounds
        present(sheet, animated: true)
    }

    func presentNotificationLevelPicker() {
        let sheet = UIAlertController(
            title: String(localized: "topic.notifications", defaultValue: "通知级别"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for level in DiscourseTopicDetail.NotificationLevel.allCases.reversed() {
            sheet.addAction(UIAlertAction(title: title(for: level), style: .default) { [weak self] _ in
                self?.setNotificationLevel(level)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = bottomBar
        sheet.popoverPresentationController?.sourceRect = bottomBar.bounds
        present(sheet, animated: true)
    }

    func showTimelineSheet() {
        let stream = viewModel.allPostIds
        guard !stream.isEmpty else { return }

        let timeline = TopicTimelineSheetViewController(
            currentIndex: currentVisibleFloor(),
            stream: stream,
            title: TitleEmojiRenderer.plainTitle(fancyTitle: viewModel.topic?.fancyTitle, title: viewModel.topic?.title ?? "")
        )
        timeline.onJumpToPostId = { [weak self] postId in
            self?.jumpToPostId(postId)
        }
        timeline.onDismiss = { [weak self] in
            guard let self else { return }
            // Restore topic chrome after the sheet closes (including after app switch).
            self.bottomBar.isHidden = !self.viewModel.isReady
            self.floatingReplyButton.isHidden = !self.viewModel.isReady
            self.bottomBar.alpha = self.viewModel.isReady ? 1 : 0
            self.bottomBar.transform = .identity
            self.view.bringSubviewToFront(self.floatingReplyButton)
            self.view.bringSubviewToFront(self.tocFabButton)
            self.view.bringSubviewToFront(self.bottomBar)
            self.updateTocChrome()
            self.syncOwningTabBarVisibility()
        }
        timeline.modalPresentationStyle = .pageSheet
        timeline.isModalInPresentation = true
        if let sheet = timeline.sheetPresentationController {
            // Custom height keeps cancel/jump on-screen. A single compact detent avoids
            // the system expanding the container on foreground and sinking the action row.
            if #available(iOS 16.0, *) {
                let timelineDetent = UISheetPresentationController.Detent.custom(
                    identifier: .init("topic.timeline")
                ) { context in
                    // Content height + home-indicator reserve only — avoid a tall empty band
                    // under cancel/jump (the green strip users reported).
                    let homeIndicator: CGFloat = 34
                    let fitted = TopicTimelineSheetViewController.preferredSheetHeight + homeIndicator
                    return min(fitted, context.maximumDetentValue)
                }
                sheet.detents = [timelineDetent]
                sheet.selectedDetentIdentifier = timelineDetent.identifier
                sheet.largestUndimmedDetentIdentifier = nil
            } else {
                sheet.detents = [.medium()]
            }
            // Help UIKit size the sheet to the compact content chain.
            timeline.preferredContentSize = CGSize(
                width: UIScreen.main.bounds.width,
                height: TopicTimelineSheetViewController.preferredSheetHeight + 34
            )
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        present(timeline, animated: true)
    }

    func showFloorJumpPrompt() {
        let total = viewModel.totalFloors
        guard total > 0 else { return }

        let alert = UIAlertController(
            title: String(localized: "topic_detail.bar.jump_to_floor"),
            message: String(localized: "topic_detail.jump.message \(total)"),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "1-\(total)"
            textField.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "topic_detail.jump.confirm"), style: .default) { [weak self] _ in
            guard let self,
                  let text = alert.textFields?.first?.text,
                  let floor = Int(text),
                  floor >= 1, floor <= total
            else { return }

            self.jumpToFloor(floor)
        })
        present(alert, animated: true)
    }

    func jumpToPostId(_ postId: Int) {
        if scrollToPostIdIfVisible(postId, animated: true) {
            return
        }
        guard let targetIndex = viewModel.allPostIds.firstIndex(of: postId) else { return }
        jumpToFloor(targetIndex + 1)
    }

    /// Jump using Discourse `post_number` (as in `/t/:id/:post_number` and notifications).
    /// Resolves to stream position so deleted-post gaps do not land on the wrong reply.
    func jumpToPostNumber(_ postNumber: Int) async {
        guard postNumber > 0 else { return }

        if let post = viewModel.posts.first(where: { $0.postNumber == postNumber }) {
            jumpToPostId(post.id)
            return
        }

        do {
            let post = try await api.fetchPostByNumber(topicId: topicId, postNumber: postNumber)
            if viewModel.allPostIds.contains(post.id) {
                jumpToPostId(post.id)
                return
            }
        } catch {
            #if DEBUG
            print("[TopicDetail] resolve post_number=\(postNumber) failed: \(error)")
            #endif
        }

        // Last resort: historical behavior treated post_number ≈ stream floor.
        jumpToFloor(postNumber)
    }

    /// Stream floor is 1-based index into `allPostIds` (not Discourse `post_number`).
    func jumpToFloor(_ floor: Int) {
        let total = viewModel.totalFloors
        guard floor >= 1, floor <= total else { return }

        let postId = viewModel.allPostIds[floor - 1]
        if scrollToPostIdIfVisible(postId, animated: true) {
            return
        }

        // Loaded posts may still be parsing — only the Diffable snapshot is safe to scroll.
        // Defer until the target id appears in the table rather than using visiblePosts indices
        // (those can exceed table row count when some cells lack parsed blocks).
        if viewModel.isFloorLoaded(floor) {
            pendingScrollToFloor = floor
            view.setNeedsLayout()
            return
        }

        // Scroll is finalized in viewDidLayoutSubviews after the target batch has cells.
        showJumpOverlay()
        hasTitleHeader = false
        suppressLoadEarlier = true
        Task {
            await viewModel.jumpToFloor(floor, containerWidth: view.bounds.width)
            hideJumpOverlay()
        }
    }

    /// Scroll using Diffable item identity + live table row count.
    /// Never trust `visiblePosts` indices — the snapshot only lists parsed-ready posts
    /// (and may reorder under nested-reply mode), so raw indices can be out of bounds.
    @discardableResult
    func scrollToPostIdIfVisible(_ postId: Int, animated: Bool) -> Bool {
        // scrollToRow during Diffable apply / self-sizing beginUpdates desyncs
        // _visibleRows vs _visibleCells.
        guard !isApplyingPostSnapshot, !tableView.doer_isMutatingData else { return false }
        guard tableView.numberOfSections > 0,
              let indexPath = dataSource.indexPath(for: postId)
        else { return false }
        let rowCount = tableView.numberOfRows(inSection: indexPath.section)
        guard rowCount > 0, indexPath.row >= 0, indexPath.row < rowCount else { return false }
        tableView.scrollToRow(at: indexPath, at: .top, animated: animated)
        return true
    }

    func showJumpOverlay() {
        if jumpOverlay.superview == nil {
            view.addSubview(jumpOverlay)
            NSLayoutConstraint.activate([
                jumpOverlay.topAnchor.constraint(equalTo: tableView.topAnchor),
                jumpOverlay.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
                jumpOverlay.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
                jumpOverlay.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
            ])
        }
        jumpOverlay.isHidden = false
        // Keep progress capsule interactive above the jump dimming layer.
        view.bringSubviewToFront(floatingReplyButton)
        view.bringSubviewToFront(tocFabButton)
        view.bringSubviewToFront(bottomBar)
    }

    func hideJumpOverlay() {
        jumpOverlay.isHidden = true
    }

    var canNavigateBack: Bool {
        guard let navigationController else { return false }
        return navigationController.viewControllers.count > 1
            && navigationController.viewControllers.first !== self
    }
}
