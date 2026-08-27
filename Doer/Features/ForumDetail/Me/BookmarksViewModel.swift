import Foundation

final class BookmarksViewModel: DoerObservableObject {
    var bookmarks: [DiscourseBookmark] = []
    var isLoading = false
    var isLoadingMore = false
    var canLoadMore = false
    var errorMessage: String?
    var loadMoreErrorMessage: String?
    var requiresLogin = false

    private let api: DiscourseAPI
    private var username: String?
    private var currentPage = 0

    /// Discourse `/u/:username/bookmarks.json` caps `limit` at 20.
    private static let pageSize = 20

    init(api: DiscourseAPI, username: String?) {
        self.api = api
        self.username = username
    }

    func updateUsername(_ username: String?) {
        self.username = username
    }

    /// Keep the spinner up while `/session/current` catches up after cookie login.
    func markLoadingIfEmpty() {
        guard bookmarks.isEmpty else { return }
        isLoading = true
        errorMessage = nil
        requiresLogin = false
        notifyChanged()
    }

    func loadBookmarks() async {
        guard let username, !username.isEmpty else {
            bookmarks = []
            isLoading = false
            isLoadingMore = false
            canLoadMore = false
            requiresLogin = true
            errorMessage = String(localized: "login.required.message")
            notifyChanged()
            return
        }

        isLoading = true
        errorMessage = nil
        loadMoreErrorMessage = nil
        requiresLogin = false
        notifyChanged()
        do {
            let list = try await api.fetchBookmarks(username: username, page: 0)
            bookmarks = Self.uniqueBookmarks(list.bookmarks)
            currentPage = 0
            canLoadMore = Self.hasMorePages(list)
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                requiresLogin = true
            }
            errorMessage = error.localizedDescription
            if bookmarks.isEmpty {
                canLoadMore = false
            }
        }
        isLoading = false
        notifyChanged()
    }

    func loadMore() async {
        guard canLoadMore, !isLoading, !isLoadingMore else { return }
        guard let username, !username.isEmpty else { return }

        isLoadingMore = true
        loadMoreErrorMessage = nil
        notifyChanged()
        let nextPage = currentPage + 1
        do {
            let list = try await api.fetchBookmarks(username: username, page: nextPage)
            let existingIds = Set(bookmarks.map(\.id))
            bookmarks.append(contentsOf: Self.uniqueBookmarks(list.bookmarks).filter { !existingIds.contains($0.id) })
            currentPage = nextPage
            canLoadMore = Self.hasMorePages(list)
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                requiresLogin = true
            }
            loadMoreErrorMessage = error.localizedDescription
        }
        isLoadingMore = false
        notifyChanged()
    }

    func reload() async {
        errorMessage = nil
        loadMoreErrorMessage = nil
        requiresLogin = false
        canLoadMore = false
        currentPage = 0
        notifyChanged()
        await loadBookmarks()
    }

    private static func uniqueBookmarks(_ bookmarks: [DiscourseBookmark]) -> [DiscourseBookmark] {
        var seen = Set<Int>()
        return bookmarks.filter { seen.insert($0.id).inserted }
    }

    private static func hasMorePages(_ list: DiscourseBookmarkList) -> Bool {
        if let more = list.moreBookmarksUrl, !more.isEmpty {
            return true
        }
        return list.bookmarks.count >= pageSize
    }
}
