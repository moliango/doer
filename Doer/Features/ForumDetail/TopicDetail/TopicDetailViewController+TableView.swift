import UIKit

// MARK: - UITableViewDelegate

extension TopicDetailViewController: UITableViewDelegate {
    private static let scrollChromeMinInterval: TimeInterval = 0.12

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let postId = dataSource.itemIdentifier(for: indexPath) {
            if postId == TopicDetailListItem.nestedSortBarID {
                return 48
            }
            if let cached = postRowHeightCache[postId], cached > 1 {
                return cached
            }
            if let estimated = postRowEstimatedHeightCache[postId], estimated > 1 {
                return estimated
            }
        }
        // Tall first posts (code blocks) need a higher estimate so the table does not
        // park the next floor under unfinished content during the first layout pass.
        if indexPath.row == 0 {
            return 520
        }
        return 220
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        tableView.doer_setScrollBusy(true)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            tableView.doer_setScrollBusy(false)
            flushScrollChrome(force: true)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        tableView.doer_setScrollBusy(false)
        flushScrollChrome(force: true)
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        tableView.doer_setScrollBusy(false)
        flushScrollChrome(force: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        readingTracker.scrolled()
        // Progress / reading visibility: throttle while flinging to keep main thread free.
        flushScrollChrome(force: false)

        guard let header = tableView.tableHeaderView else {
            handleLoadEarlierIfNeeded(scrollView)
            return
        }
        let headerBottom = header.frame.maxY
        let offsetY = scrollView.contentOffset.y + scrollView.safeAreaInsets.top
        let shouldShowCollapsedTitle = offsetY >= headerBottom
        if shouldShowCollapsedTitle != isShowingCollapsedNavigationTitle {
            isShowingCollapsedNavigationTitle = shouldShowCollapsedTitle
            navigationItem.titleView = shouldShowCollapsedTitle ? navTitleLabel : nil
        }

        handleLoadEarlierIfNeeded(scrollView)
    }

    private func flushScrollChrome(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastScrollChromeUpdateUptime < Self.scrollChromeMinInterval {
            return
        }
        lastScrollChromeUpdateUptime = now
        updateVisibleReadingPosts()
        updateBottomBarProgress()
        updateTocChrome()
    }

    private func handleLoadEarlierIfNeeded(_ scrollView: UIScrollView) {
        let currentOffset = scrollView.contentOffset.y
        let isScrollingUp = currentOffset < lastScrollOffset
        lastScrollOffset = currentOffset

        // Clear suppress flag once user scrolls down, meaning they've settled after a jump
        if !isScrollingUp {
            suppressLoadEarlier = false
        }

        // Only trigger load-earlier when user is actively scrolling UP
        // and within 200pt of the top — prevents false triggers after jump
        guard isScrollingUp,
              !suppressLoadEarlier,
              !viewModel.isNestedViewEnabled,
              viewModel.canLoadEarlier,
              !isLoadingEarlierLocally
        else { return }
        let contentTop = -(scrollView.adjustedContentInset.top)
        if scrollView.contentOffset.y <= contentTop + 200 {
            // Capture anchor synchronously before any async work
            guard let anchorIndexPath = tableView.indexPathsForVisibleRows?.first,
                  let anchorId = dataSource.itemIdentifier(for: anchorIndexPath)
            else { return }
            let cellTopOffset = tableView.rectForRow(at: anchorIndexPath).minY - tableView.contentOffset.y
            earlierLoadAnchor = (postId: anchorId, cellTopOffset: cellTopOffset)
            isLoadingEarlierLocally = true
            Task {
                let didStart = await viewModel.loadEarlierPosts(containerWidth: view.bounds.width)
                if !didStart {
                    earlierLoadAnchor = nil
                    isLoadingEarlierLocally = false
                }
                // updateUI (triggered by DoerObservableObject) will handle position restoration
            }
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let scrollBusy = tableView.doer_isScrollBusy
            || tableView.isDragging
            || tableView.isDecelerating

        if let native = cell as? PostNativeCell {
            if scrollBusy {
                // Keep first paint cheap while flinging; finish on settle.
                native.setScrollMediaPaused(true)
            } else {
                native.completeProgressiveContentIfNeeded(force: true)
                native.setScrollMediaPaused(false)
            }
        }

        // Height reconcile only when idle and we lack a solid measured cache.
        // Mid-scroll reconcile → beginUpdates is the main long-thread jank source.
        if let postId = dataSource.itemIdentifier(for: indexPath),
           let cached = postRowHeightCache[postId],
           cached > 1 {
            // Have a measured height — skip unless the cell is wildly off and we're idle.
            if !scrollBusy, abs(cell.frame.height - cached) > 12 {
                (cell as? PostNativeCell)?.requestHeightReconciliation()
            }
        } else if !scrollBusy {
            // First paint without cache: one deferred measure when settled.
            (cell as? PostNativeCell)?.requestHeightReconciliation()
        }

        // Prefetch content images for this row + a few ahead (smoother first paint).
        // Skip aggressive ahead-prefetch while flinging — decode competes with scroll.
        var displayedPostId: Int?
        if let postId = dataSource.itemIdentifier(for: indexPath),
           postId != TopicDetailListItem.nestedSortBarID {
            displayedPostId = postId
            if !scrollBusy {
                var ahead: [Int] = [postId]
                let total = tableView.numberOfRows(inSection: 0)
                for offset in 1...3 {
                    let next = indexPath.row + offset
                    guard next < total,
                          let id = dataSource.itemIdentifier(for: IndexPath(row: next, section: 0)),
                          id != TopicDetailListItem.nestedSortBarID
                    else { break }
                    ahead.append(id)
                }
                prefetchContentImages(forPostIds: ahead)
            }
        }

        // Flat stream pagination only — nested tree uses /n/topic roots + expand children.
        guard !viewModel.isNestedViewEnabled else { return }

        // Next-window readiness: keep ~one page ahead of the visible stream index.
        // Backup: also fire near the end of the current table snapshot.
        let totalRows = tableView.numberOfRows(inSection: 0)
        let nearSnapshotEnd = indexPath.row >= max(0, totalRows - TopicDetailPaginationPolicy.displayPrefetchRowThreshold)
        let streamIndex = displayedPostId.flatMap { id in viewModel.allPostIds.firstIndex(of: id) }
        if let streamIndex {
            let width = view.bounds.width
            viewModel.acknowledgeVisibleTailIfNeeded(visibleStreamIndex: streamIndex)
            Task {
                await viewModel.ensureForwardWindowReady(
                    visibleStreamIndex: streamIndex,
                    containerWidth: width
                )
            }
        } else if nearSnapshotEnd {
            let width = view.bounds.width
            Task {
                await viewModel.loadMorePosts(containerWidth: width)
            }
        }
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let postId = dataSource.itemIdentifier(for: indexPath) {
            let height = cell.frame.height
            if height > 1 {
                postRowHeightCache[postId] = height
                postRowEstimatedHeightCache[postId] = height
            }
        }
        // Cancel off-screen fallback Web renders to cut dual-path jank / CPU.
        if let native = cell as? PostNativeCell {
            native.cancelOffscreenMediaWork()
        }
    }
}
