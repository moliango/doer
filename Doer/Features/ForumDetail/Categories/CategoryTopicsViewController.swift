import UIKit

private final class CategoryTopicsViewModel: DoerObservableObject {
    var topics: [DiscourseTopicList.Topic] = []
    var isLoading = false
    var isLoadingMore = false
    var canLoadMore = false

    private let api: DiscourseAPI
    private let category: DiscourseCategory
    private let slug: String
    private let categoryId: Int
    private var currentPage = 0
    private var usersById: [Int: DiscourseTopicList.User] = [:]
    private var categoryIndex = DiscourseCategoryIndex()
    private var hasLoadedFullCategoryIndex = false

    init(api: DiscourseAPI, category: DiscourseCategory) {
        self.api = api
        self.category = category
        self.slug = category.slug
        self.categoryId = category.id
        self.categoryIndex = DiscourseCategoryIndex(categories: [category], source: .categoryList)
    }

    private var canBrowseTopics: Bool {
        AuthManager.shared.isAuthenticated(for: api.baseURL)
    }

    func avatarTemplate(for topic: DiscourseTopicList.Topic) -> String? {
        guard let firstPoster = topic.posters?.first else { return nil }
        return usersById[firstPoster.userId]?.avatarTemplate
    }

    func category(for topic: DiscourseTopicList.Topic) -> DiscourseCategory? {
        guard let id = topic.categoryId else { return category }
        return categoryIndex[id] ?? category
    }

    func categoryDisplayName(for category: DiscourseCategory?) -> String? {
        guard let category else { return nil }
        let resolved = categoryIndex[category.id] ?? category
        return resolved.displayName(parent: parentCategory(for: resolved))
    }

    func loadTopics() async {
        isLoading = true
        currentPage = 0
        notifyChanged()
        defer {
            isLoading = false
            notifyChanged()
        }
        guard await validateTopicAccess() else { return }

        do {
            async let categoriesResult: Void = loadCategoriesIfNeeded()
            let result = try await api.fetchCategoryTopics(slug: slug, id: categoryId, page: 0)
            _ = await categoriesResult
            topics = result.topicList.topics
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
            indexCategories(result.categories, source: .topicList)
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                clearProtectedContent(invalidateSession: true)
                return
            }
            // Error silently handled for now
        }
    }

    func loadMoreTopics() async {
        guard canLoadMore, !isLoadingMore else { return }
        guard await validateTopicAccess() else { return }
        isLoadingMore = true
        notifyChanged()
        defer {
            isLoadingMore = false
            notifyChanged()
        }

        let nextPage = currentPage + 1
        do {
            async let categoriesResult: Void = loadCategoriesIfNeeded()
            let result = try await api.fetchCategoryTopics(slug: slug, id: categoryId, page: nextPage)
            _ = await categoriesResult
            currentPage = nextPage
            let existingIds = Set(topics.map(\.id))
            let newTopics = result.topicList.topics.filter { !existingIds.contains($0.id) }
            topics.append(contentsOf: newTopics)
            canLoadMore = result.topicList.moreTopicsUrl != nil
            indexUsers(result.users)
            indexCategories(result.categories, source: .topicList)
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                clearProtectedContent(invalidateSession: true)
                return
            }
            // Silently fail on load-more
        }
    }

    private func indexUsers(_ users: [DiscourseTopicList.User]?) {
        guard let users else { return }
        for user in users {
            usersById[user.id] = user
        }
    }

    private func loadCategoriesIfNeeded() async {
        guard canBrowseTopics else { return }
        guard !hasLoadedFullCategoryIndex else { return }
        do {
            let siteCategories = (try? await api.fetchSiteCategories()) ?? []
            if !siteCategories.isEmpty {
                indexCategories(siteCategories.filter { $0.id != 1 }, source: .site)
            } else {
                let list = try await api.fetchCategories()
                indexCategories(
                    DiscourseCategory.normalizedTree(fromNested: list.categoryList.categories),
                    source: .categoryList
                )
            }
            hasLoadedFullCategoryIndex = true
        } catch {
            // Category metadata is only used for badge labels.
        }
    }

    private func indexCategories(_ categories: [DiscourseCategory]?, source: DiscourseCategoryIndexSource) {
        categoryIndex.merge(categories, source: source)
    }

    private func indexCategories(_ categories: [DiscourseCategory], source: DiscourseCategoryIndexSource) {
        categoryIndex.merge(categories, source: source)
    }

    private func parentCategory(for category: DiscourseCategory) -> DiscourseCategory? {
        guard let parentId = category.parentCategoryId else { return nil }
        return categoryIndex[parentId]
    }

    private func validateTopicAccess() async -> Bool {
        guard canBrowseTopics else {
            clearProtectedContent(invalidateSession: true)
            return false
        }
        do {
            _ = try await api.fetchCurrentUser()
            return true
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: api.baseURL) {
                clearProtectedContent(invalidateSession: true)
            }
            return false
        }
    }

    private func clearProtectedContent(invalidateSession: Bool = false) {
        topics = []
        isLoading = false
        isLoadingMore = false
        canLoadMore = false
        currentPage = 0
        usersById.removeAll()
        if invalidateSession {
            AuthManager.shared.invalidateWebSession(for: api.baseURL)
        }
        notifyChanged()
    }
}

final class CategoryTopicsViewController: ObservableViewController {
    private let api: DiscourseAPI
    private let category: DiscourseCategory
    private let viewModel: CategoryTopicsViewModel

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        tv.register(CompactPinnedTopicCell.self, forCellReuseIdentifier: CompactPinnedTopicCell.reuseIdentifier)
        tv.delegate = self
        tv.separatorStyle = .none
        tv.backgroundColor = .systemGroupedBackground
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = TopicCell.estimatedHeight
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = {
        UITableViewDiffableDataSource<Int, Int>(tableView: tableView) { [weak self] tableView, indexPath, topicId in
            guard let self,
                  let topic = self.viewModel.topics.first(where: { $0.id == topicId }) else {
                return UITableViewCell()
            }
            let displayCategory = self.viewModel.category(for: topic) ?? self.category
            let categoryColor = Self.color(fromHex: displayCategory.color)
            if topic.pinned == true,
               let cell = tableView.dequeueReusableCell(
                withIdentifier: CompactPinnedTopicCell.reuseIdentifier,
                for: indexPath
               ) as? CompactPinnedTopicCell {
                cell.configure(
                    with: topic,
                    categoryColor: categoryColor,
                    categoryPresentation: nil,
                    categoryBaseURL: self.api.baseURL
                )
                return cell
            }
            guard let cell = tableView.dequeueReusableCell(withIdentifier: TopicCell.reuseIdentifier, for: indexPath) as? TopicCell else {
                return UITableViewCell()
            }
            let avatarURL = AvatarImageLoader.url(
                from: self.viewModel.avatarTemplate(for: topic),
                baseURL: self.api.baseURL,
                size: 96
            )
            cell.configure(
                with: topic,
                avatarURL: avatarURL,
                categoryName: self.viewModel.categoryDisplayName(for: displayCategory),
                categoryColor: categoryColor,
                tags: topic.tags ?? []
            )
            return cell
        }
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let footerSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
        return spinner
    }()

    private let emptyFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))

    private lazy var refreshControl: UIRefreshControl = {
        let rc = UIRefreshControl()
        rc.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        return rc
    }()

    init(api: DiscourseAPI, category: DiscourseCategory) {
        self.api = api
        self.category = category
        self.viewModel = CategoryTopicsViewModel(api: api, category: category)
        super.init(nibName: nil, bundle: nil)
        title = viewModel.categoryDisplayName(for: category) ?? category.displayName(parent: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        view.backgroundColor = .systemGroupedBackground

        tableView.tableFooterView = emptyFooterView
        tableView.refreshControl = refreshControl

        view.addSubview(tableView)
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task {
            await viewModel.loadTopics()
        }
    }

    override func updateUI() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        var seen = Set<Int>()
        let uniqueIds = viewModel.topics.compactMap { topic -> Int? in
            guard seen.insert(topic.id).inserted else { return nil }
            return topic.id
        }
        snapshot.appendItems(uniqueIds, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: true)

        if viewModel.isLoading {
            activityIndicator.startAnimating()
            tableView.isHidden = true
        } else {
            activityIndicator.stopAnimating()
            tableView.isHidden = false
        }

        if viewModel.isLoadingMore {
            tableView.tableFooterView = footerSpinner
            footerSpinner.startAnimating()
        } else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = emptyFooterView
        }
    }

    @objc private func pullToRefresh() {
        Task {
            await viewModel.loadTopics()
            refreshControl.endRefreshing()
        }
    }

    private static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension CategoryTopicsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let topicId = dataSource.itemIdentifier(for: indexPath) else { return }
        let detailVC = TopicDetailFactory.make(api: api, topicId: topicId)
        navigationController?.pushViewController(detailVC, animated: true)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let totalRows = tableView.doer_numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 5 {
            Task {
                await viewModel.loadMoreTopics()
            }
        }
    }
}
