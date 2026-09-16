import UIKit

final class DoerListRefreshPolicy: NSObject {
    private weak var tableView: UITableView?
    private let viewModel: DoerObservableObject
    private var isRefreshing = false
    private var isLoadingMore = false
    private var refreshTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private let onRefresh: () async -> Void
    private let onLoadMore: () async -> Void

    init(
        tableView: UITableView,
        viewModel: DoerObservableObject,
        onRefresh: @escaping () async -> Void,
        onLoadMore: @escaping () async -> Void
    ) {
        self.tableView = tableView
        self.viewModel = viewModel
        self.onRefresh = onRefresh
        self.onLoadMore = onLoadMore
    }

    /// Convenience for call sites that still pass fire-and-forget closures.
    convenience init(
        tableView: UITableView,
        viewModel: DoerObservableObject,
        onRefresh: @escaping () -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        let refresh = onRefresh
        let loadMore = onLoadMore
        self.init(
            tableView: tableView,
            viewModel: viewModel,
            onRefresh: { () async in refresh() },
            onLoadMore: { () async in loadMore() }
        )
    }

    func startPullToRefresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        // Cancel an in-flight load-more so page 0 refresh does not race with appends.
        cancelLoadMore()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshing = false
                self.refreshTask = nil
            }
            await self.onRefresh()
            self.scrollToTopSafely(animated: false)
        }
    }

    func handleWillDisplay(at indexPath: IndexPath) {
        guard let tableView else { return }
        let totalRows = tableView.doer_numberOfRows(inSection: 0)
        guard totalRows > 0, indexPath.row >= totalRows - 6 else { return }
        guard !isRefreshing, !isLoadingMore else { return }
        isLoadingMore = true
        loadMoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isLoadingMore = false
                self.loadMoreTask = nil
            }
            await self.onLoadMore()
        }
    }

    func cancelLoadMore() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        isLoadingMore = false
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        cancelLoadMore()
    }

    /// Safe top scroll: never calls `scrollToRow` on an empty table.
    func forceScrollToTop(animated: Bool) {
        scrollToTopSafely(animated: animated)
    }

    private func scrollToTopSafely(animated: Bool) {
        guard let tableView else { return }
        let top = -tableView.adjustedContentInset.top
        let offset = CGPoint(x: tableView.contentOffset.x, y: top)
        if animated {
            tableView.setContentOffset(offset, animated: true)
        } else {
            tableView.contentOffset = offset
        }
    }
}
