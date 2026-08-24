import CookedHTML
import UIKit

extension TopicDetailViewController {
    func updateTocChrome() {
        tocController.update(from: viewModel)
        let onFirstPost = currentVisiblePostNumber() == 1 || tocController.isJumping
        let shouldShow = viewModel.isReady && tocController.hasToc && onFirstPost
        let wasHidden = tocFabButton.isHidden
        tocFabButton.isHidden = !shouldShow
        if shouldShow {
            view.bringSubviewToFront(tocFabButton)
        }
        let targetAlpha: CGFloat = shouldShow ? 1 : 0
        if wasHidden != tocFabButton.isHidden {
            tocFabButton.alpha = targetAlpha
        } else if abs(tocFabButton.alpha - targetAlpha) > 0.01 {
            UIView.animate(withDuration: 0.18) {
                self.tocFabButton.alpha = targetAlpha
            }
        }
        updateTocSpy()
    }

    func presentTopicToc() {
        guard let data = tocController.tocData, !data.isEmpty else { return }
        let panel = TopicTocPanelViewController(
            data: data,
            activeHeadingId: tocController.activeHeadingId,
            activeAncestorIds: tocController.activeAncestorIds
        )
        panel.onSelect = { [weak self] entry in
            self?.jumpToTocEntry(entry)
        }
        present(panel, animated: true)
    }

    func jumpToTocEntry(_ entry: TocEntry) {
        guard let postId = viewModel.posts.first(where: { $0.postNumber == 1 })?.id else { return }
        tocController.beginJump(to: entry.id)
        updateTocChrome()

        let finish = { [weak self] in
            self?.alignTable(to: entry, openingPostId: postId)
            self?.tocController.endJump()
            self?.updateTocChrome()
        }

        if let indexPath = dataSource.indexPath(for: postId),
           let cell = tableView.cellForRow(at: indexPath) as? PostNativeCell {
            cell.completeProgressiveContentIfNeeded(force: true)
            tableView.layoutIfNeeded()
            finish()
            return
        }

        jumpToPostId(postId)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let indexPath = self.dataSource.indexPath(for: postId),
               let cell = self.tableView.cellForRow(at: indexPath) as? PostNativeCell {
                cell.completeProgressiveContentIfNeeded(force: true)
                self.tableView.layoutIfNeeded()
            }
            DispatchQueue.main.async(execute: finish)
        }
    }

    func updateTocSpy() {
        guard tocController.hasToc,
              let postId = viewModel.posts.first(where: { $0.postNumber == 1 })?.id,
              let indexPath = dataSource.indexPath(for: postId),
              let cell = tableView.cellForRow(at: indexPath)
        else { return }

        let headings = TopicHeadingAnchor.collect(from: cell)
        let frames: [(id: String, minY: CGFloat)] = headings.compactMap { view in
            guard let id = view.tocAnchorId else { return nil }
            return (id, view.convert(view.bounds, to: tableView).minY)
        }
        let threshold = tableView.contentOffset.y
            + tableView.adjustedContentInset.top
            + TopicTocController.topBuffer
            + TopicTocController.spyBuffer
        tocController.applySpy(frames: frames, threshold: threshold)
    }

    func currentVisiblePostNumber() -> Int? {
        let paths = tableView.indexPathsForVisibleRows?.sorted { $0.row < $1.row } ?? []
        for path in paths {
            guard let postId = dataSource.itemIdentifier(for: path),
                  postId != TopicDetailListItem.nestedSortBarID,
                  let post = viewModel.post(byId: postId)
            else { continue }
            return post.postNumber
        }
        return nil
    }

    private func alignTable(to entry: TocEntry, openingPostId: Int) {
        guard let indexPath = dataSource.indexPath(for: openingPostId),
              let cell = tableView.cellForRow(at: indexPath)
        else { return }

        (cell as? PostNativeCell)?.completeProgressiveContentIfNeeded(force: true)
        tableView.layoutIfNeeded()

        let headings = TopicHeadingAnchor.collect(from: cell)
        guard let heading = headings.first(where: { $0.tocAnchorId == entry.id }) else { return }
        let rect = heading.convert(heading.bounds, to: tableView)
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
            tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom,
            minY
        )
        let target = rect.minY - tableView.adjustedContentInset.top - TopicTocController.topBuffer
        tableView.setContentOffset(
            CGPoint(x: 0, y: min(max(target, minY), maxY)),
            animated: true
        )
    }
}
