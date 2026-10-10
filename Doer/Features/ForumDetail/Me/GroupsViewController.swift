import SDWebImage
import UIKit

/// Discourse group directory, matching the official directory filters.
final class GroupsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum GroupScope: String, CaseIterable {
        case all
        case mine
        case owned
        case `public`
        case closed

        var title: String {
            switch self {
            case .all:
                return String(localized: "groups.filter.all_groups", defaultValue: "全部群组")
            case .mine:
                return String(localized: "groups.filter.mine", defaultValue: "我的群组")
            case .owned:
                return String(localized: "groups.filter.owned", defaultValue: "我拥有的群组")
            case .public:
                return String(localized: "groups.filter.public", defaultValue: "公开群组")
            case .closed:
                return String(localized: "groups.filter.closed", defaultValue: "已关闭的群组")
            }
        }

        /// Discourse `type` query. Nil lists every visible group.
        var requestType: String? {
            switch self {
            case .all: return nil
            case .mine: return "my"
            case .owned: return "owner"
            case .public: return "public"
            case .closed: return "close"
            }
        }

        /// All and public groups open the member page. Joined and owned groups open topics.
        var opensTopics: Bool {
            self == .mine || self == .owned
        }
    }

    private let api: DiscourseAPI
    private var groups: [DiscourseGroup] = []
    private var selectedScope: GroupScope = .all
    private var filterText = ""
    private var page = 0
    private var canLoadMore = false
    private var isLoading = false
    private var errorMessage: String?
    private var filterTask: Task<Void, Never>?
    private var loadGeneration = 0

    private let filterButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.contentHorizontalAlignment = .leading
        return button
    }()

    private let searchBar: UISearchBar = {
        let bar = UISearchBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.searchBarStyle = .minimal
        bar.placeholder = String(localized: "groups.search", defaultValue: "搜索群组名称")
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        return bar
    }()

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let stateLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let refreshControl = UIRefreshControl()

    init(api: DiscourseAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "groups.title", defaultValue: "群组")
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor
        searchBar.delegate = self
        rebuildFilterMenu()

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = refreshControl
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.register(GroupCell.self, forCellReuseIdentifier: GroupCell.reuseIdentifier)
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textAlignment = .center
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 0
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true

        view.addSubview(filterButton)
        view.addSubview(searchBar)
        view.addSubview(tableView)
        view.addSubview(stateLabel)
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            filterButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            filterButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            filterButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterButton.heightAnchor.constraint(equalToConstant: 36),
            searchBar.topAnchor.constraint(equalTo: filterButton.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            loadingIndicator.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
        ])
        reload(reset: true)
    }

    private func rebuildFilterMenu() {
        var config = UIButton.Configuration.plain()
        config.title = selectedScope.title
        config.image = UIImage(systemName: "chevron.up.chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 16, weight: .semibold)
            return out
        }
        filterButton.configuration = config
        filterButton.menu = UIMenu(children: GroupScope.allCases.map { scope in
            UIAction(
                title: scope.title,
                state: scope == selectedScope ? .on : .off
            ) { [weak self] _ in
                guard let self, self.selectedScope != scope else { return }
                self.selectedScope = scope
                self.rebuildFilterMenu()
                self.reload(reset: true)
            }
        })
    }

    @objc private func refreshPulled() {
        reload(reset: true)
    }

    private func reload(reset: Bool) {
        guard !isLoading || reset else { return }
        if reset {
            page = 0
            canLoadMore = false
            loadGeneration += 1
        }
        isLoading = true
        errorMessage = nil
        updateState()
        let type = selectedScope.requestType
        let filter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedPage = page
        let generation = loadGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if generation == loadGeneration { isLoading = false } }
            guard generation == loadGeneration else { return }
            do {
                let loaded = try await api.fetchGroups(
                    type: type,
                    filter: filter.isEmpty ? nil : filter,
                    page: requestedPage
                )
                if reset {
                    groups = loaded
                } else {
                    let known = Set(groups.map(\.id))
                    groups.append(contentsOf: loaded.filter { !known.contains($0.id) })
                }
                canLoadMore = loaded.count >= 36
                page = requestedPage + 1
            } catch {
                errorMessage = error.localizedDescription
            }
            guard generation == loadGeneration else { return }
            tableView.reloadData()
            refreshControl.endRefreshing()
            updateState()
        }
    }

    private func updateState() {
        let showSpinner = isLoading && groups.isEmpty && !refreshControl.isRefreshing
        showSpinner ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
        stateLabel.isHidden = !groups.isEmpty || showSpinner
        if let errorMessage, groups.isEmpty {
            stateLabel.text = errorMessage
        } else if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            stateLabel.text = String(localized: "groups.empty", defaultValue: "暂无符合条件的群组")
        } else {
            stateLabel.text = String(localized: "groups.empty.search", defaultValue: "没有找到这个群组")
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: GroupCell.reuseIdentifier, for: indexPath)
        guard let groupCell = cell as? GroupCell, groups.indices.contains(indexPath.row) else {
            return cell
        }
        groupCell.configure(group: groups[indexPath.row], baseURL: api.baseURL)
        return groupCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard groups.indices.contains(indexPath.row) else { return }
        let group = groups[indexPath.row]
        if selectedScope.opensTopics {
            navigationController?.pushViewController(
                GroupTopicsViewController(api: api, group: group),
                animated: true
            )
        } else {
            navigationController?.pushViewController(
                GroupDetailViewController(api: api, group: group),
                animated: true
            )
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard canLoadMore, !isLoading, indexPath.row >= groups.count - 4 else { return }
        reload(reset: false)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        filterText = searchText
        filterTask?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.reload(reset: true)
        }
        filterTask = task
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        filterText = searchBar.text ?? ""
        reload(reset: true)
    }

}

private final class GroupCell: UITableViewCell {
    static let reuseIdentifier = "GroupCell"

    private let flairView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.layer.cornerRadius = 8
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        return label
    }()

    private let detailLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        return label
    }()

    private let joinedIcon: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = .systemGreen
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }()

    private let joinedLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .systemGreen
        label.text = String(localized: "groups.joined", defaultValue: "已加入")
        return label
    }()

    private let joinedRow = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        joinedRow.translatesAutoresizingMaskIntoConstraints = false
        joinedRow.axis = .horizontal
        joinedRow.spacing = 4
        joinedRow.alignment = .center
        joinedRow.addArrangedSubview(joinedIcon)
        joinedRow.addArrangedSubview(joinedLabel)
        joinedRow.isHidden = true
        let textStack = UIStackView(arrangedSubviews: [nameLabel, joinedRow, detailLabel])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.axis = .vertical
        textStack.spacing = 2
        contentView.addSubview(flairView)
        contentView.addSubview(textStack)
        NSLayoutConstraint.activate([
            flairView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            flairView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            flairView.widthAnchor.constraint(equalToConstant: 36),
            flairView.heightAnchor.constraint(equalToConstant: 36),
            joinedIcon.widthAnchor.constraint(equalToConstant: 14),
            joinedIcon.heightAnchor.constraint(equalToConstant: 14),
            flairView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: flairView.bottomAnchor, constant: 12),
            textStack.leadingAnchor.constraint(equalTo: flairView.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        flairView.sd_cancelCurrentImageLoad()
        flairView.image = nil
        nameLabel.text = nil
        detailLabel.text = nil
        joinedRow.isHidden = true
    }

    func configure(group: DiscourseGroup, baseURL: String) {
        nameLabel.text = group.displayName
        joinedRow.isHidden = !(group.isGroupUser || group.isGroupOwner)
        let members = String(
            format: String(localized: "groups.member_count", defaultValue: "%@ 名成员"),
            GroupCountFormat.compact(group.userCount)
        )
        let excerpt = group.bioExcerpt?
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        detailLabel.text = excerpt.isEmpty ? members : "\(members) · \(excerpt)"
        flairView.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        flairView.image = UIImage(systemName: "person.3.fill")
        flairView.tintColor = .secondaryLabel
        flairView.contentMode = .center
        if let url = group.flairAbsoluteURL(baseURL: baseURL) {
            flairView.contentMode = .scaleAspectFit
            flairView.sd_setImage(with: url)
        }
    }
}

/// Topics that mention a group, via Discourse search `group:{name}`.
final class GroupTopicsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let api: DiscourseAPI
    private let group: DiscourseGroup
    private var topics: [DiscourseSearchResult.SearchTopic] = []
    private var page = 1
    private var canLoadMore = false
    private var isLoading = false
    private var errorMessage: String?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let stateLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let refreshControl = UIRefreshControl()

    init(api: DiscourseAPI, group: DiscourseGroup) {
        self.api = api
        self.group = group
        super.init(nibName: nil, bundle: nil)
        title = group.displayName
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.refreshControl = refreshControl
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "group.topic")
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textAlignment = .center
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 0
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true
        view.addSubview(tableView)
        view.addSubview(stateLabel)
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        reload(reset: true)
    }

    @objc private func refreshPulled() {
        reload(reset: true)
    }

    private func reload(reset: Bool) {
        guard !isLoading else { return }
        if reset { page = 1 }
        isLoading = true
        errorMessage = nil
        updateState()
        let query = "group:\(group.name) order:latest"
        let requestedPage = page
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await api.search(term: query, page: requestedPage, typeFilter: "topic")
                let loaded = result.topics ?? []
                if reset {
                    topics = loaded
                } else {
                    let known = Set(topics.map(\.id))
                    topics.append(contentsOf: loaded.filter { !known.contains($0.id) })
                }
                canLoadMore = result.groupedSearchResult?.moreFullPageResults == true && !loaded.isEmpty
                page = requestedPage + 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            tableView.reloadData()
            refreshControl.endRefreshing()
            updateState()
        }
    }

    private func updateState() {
        let showSpinner = isLoading && topics.isEmpty && !refreshControl.isRefreshing
        showSpinner ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
        tableView.isHidden = topics.isEmpty && showSpinner
        stateLabel.isHidden = !topics.isEmpty || showSpinner
        stateLabel.text = errorMessage ?? String(localized: "groups.topics.empty", defaultValue: "这个群组还没有话题")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        topics.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "group.topic", for: indexPath)
        guard topics.indices.contains(indexPath.row) else { return cell }
        var content = cell.defaultContentConfiguration()
        let topic = topics[indexPath.row]
        content.text = topic.fancyTitle?.isEmpty == false ? topic.fancyTitle : topic.title
        content.secondaryText = String(
            format: String(localized: "groups.topics.posts", defaultValue: "%d 帖"),
            topic.postsCount
        )
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard topics.indices.contains(indexPath.row) else { return }
        navigationController?.pushViewController(
            TopicDetailFactory.make(api: api, topicId: topics[indexPath.row].id),
            animated: true
        )
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard canLoadMore, !isLoading, indexPath.row >= topics.count - 4 else { return }
        reload(reset: false)
    }
}

/// Compact member counts: 6100 → 6.1k, matching the official group directory.
enum GroupCountFormat {
    static func compact(_ count: Int) -> String {
        let value = Double(max(count, 0))
        if value >= 1_000_000 {
            return trim(value / 1_000_000) + "m"
        }
        if value >= 1_000 {
            return trim(value / 1_000) + "k"
        }
        return "\(count)"
    }

    private static func trim(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }
}

/// Group page for the directory: bio, join, then members.
final class GroupDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let api: DiscourseAPI
    private var group: DiscourseGroup
    private var members: [DiscourseGroupMember] = []
    private var totalMembers = 0
    private var offset = 0
    private var canLoadMore = false
    private var isLoading = false
    private var isJoining = false
    private var errorMessage: String?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let refreshControl = UIRefreshControl()
    private let joinButton = UIButton(type: .system)
    private let stateLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)

    init(api: DiscourseAPI, group: DiscourseGroup) {
        self.api = api
        self.group = group
        super.init(nibName: nil, bundle: nil)
        title = group.displayName
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 72, bottom: 0, right: 0)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 64
        tableView.refreshControl = refreshControl
        tableView.register(GroupMemberCell.self, forCellReuseIdentifier: GroupMemberCell.reuseIdentifier)
        tableView.tableHeaderView = makeHeader()
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)

        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.textAlignment = .center
        stateLabel.textColor = .secondaryLabel
        stateLabel.numberOfLines = 0
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.hidesWhenStopped = true

        view.addSubview(tableView)
        view.addSubview(stateLabel)
        view.addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 280),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            loadingIndicator.centerXAnchor.constraint(equalTo: stateLabel.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: stateLabel.centerYAnchor),
        ])
        reload(reset: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs(header.frame.height - height) > 0.5 || abs(header.frame.width - width) > 0.5 {
            header.frame.size = CGSize(width: width, height: height)
            tableView.tableHeaderView = header
        }
    }

    @objc private func refreshPulled() {
        reload(reset: true)
    }

    private func reload(reset: Bool) {
        guard !isLoading else { return }
        if reset { offset = 0 }
        isLoading = true
        errorMessage = nil
        updateState()
        let name = group.name
        let requestedOffset = offset
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if reset, let fresh = try? await api.fetchGroup(name: name) {
                    group = fresh
                    tableView.tableHeaderView = makeHeader()
                    view.setNeedsLayout()
                }
                let page = try await api.fetchGroupMembers(name: name, offset: requestedOffset)
                if reset {
                    members = page.members
                } else {
                    let known = Set(members.map(\.id))
                    members.append(contentsOf: page.members.filter { !known.contains($0.id) })
                }
                totalMembers = page.total
                offset = members.count
                canLoadMore = members.count < page.total && !page.members.isEmpty
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
            tableView.reloadData()
            refreshControl.endRefreshing()
            updateState()
        }
    }

    private func updateState() {
        let showSpinner = isLoading && members.isEmpty && !refreshControl.isRefreshing
        showSpinner ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
        stateLabel.isHidden = !members.isEmpty || showSpinner
        stateLabel.text = errorMessage ?? String(localized: "groups.members.empty", defaultValue: "还没有成员")
    }

    private func makeHeader() -> UIView {
        let theme = AppSettings.shared.themeStyle
        let header = UIView()
        header.backgroundColor = .clear

        let flair = UIImageView()
        flair.translatesAutoresizingMaskIntoConstraints = false
        flair.contentMode = .scaleAspectFit
        flair.clipsToBounds = true
        flair.layer.cornerRadius = 24
        flair.layer.cornerCurve = .continuous
        flair.backgroundColor = theme.topicChipBackgroundColor
        flair.tintColor = .secondaryLabel
        flair.image = UIImage(systemName: "person.2.fill")
        if let url = group.flairAbsoluteURL(baseURL: api.baseURL) {
            flair.sd_setImage(with: url)
        }

        let name = UILabel()
        name.translatesAutoresizingMaskIntoConstraints = false
        name.text = group.displayName
        name.font = .systemFont(ofSize: 20, weight: .bold)
        name.textColor = .label

        let handle = UILabel()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.text = "@\(group.name)"
        handle.font = .systemFont(ofSize: 14)
        handle.textColor = .secondaryLabel

        let bio = UILabel()
        bio.translatesAutoresizingMaskIntoConstraints = false
        bio.text = group.bioText
        bio.font = .systemFont(ofSize: 16)
        bio.textColor = .label
        bio.numberOfLines = 0
        bio.isHidden = group.bioText.isEmpty

        let countIcon = UIImageView(image: UIImage(systemName: "person.2"))
        countIcon.translatesAutoresizingMaskIntoConstraints = false
        countIcon.tintColor = .tertiaryLabel
        countIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let count = UILabel()
        count.translatesAutoresizingMaskIntoConstraints = false
        count.text = String(
            format: String(localized: "groups.member_count", defaultValue: "%@ 名成员"),
            GroupCountFormat.compact(group.userCount)
        )
        count.font = .systemFont(ofSize: 14)
        count.textColor = .secondaryLabel
        let countRow = UIStackView(arrangedSubviews: [countIcon, count])
        countRow.translatesAutoresizingMaskIntoConstraints = false
        countRow.axis = .horizontal
        countRow.spacing = 6
        countRow.alignment = .center

        configureJoinButton()
        let section = UILabel()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.text = String(
            format: String(localized: "groups.members.section", defaultValue: "成员 (%@)"),
            GroupCountFormat.compact(totalMembers > 0 ? totalMembers : group.userCount)
        )
        section.font = .systemFont(ofSize: 15, weight: .semibold)
        section.textColor = .secondaryLabel

        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = UIColor.separator

        header.addSubview(flair)
        header.addSubview(name)
        header.addSubview(handle)
        header.addSubview(bio)
        header.addSubview(countRow)
        header.addSubview(joinButton)
        header.addSubview(hairline)
        header.addSubview(section)
        NSLayoutConstraint.activate([
            flair.topAnchor.constraint(equalTo: header.topAnchor, constant: 16),
            flair.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            flair.widthAnchor.constraint(equalToConstant: 48),
            flair.heightAnchor.constraint(equalToConstant: 48),
            name.leadingAnchor.constraint(equalTo: flair.trailingAnchor, constant: 12),
            name.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            name.topAnchor.constraint(equalTo: flair.topAnchor, constant: 2),
            handle.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            handle.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            handle.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            bio.topAnchor.constraint(equalTo: flair.bottomAnchor, constant: 16),
            bio.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            bio.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            countRow.topAnchor.constraint(equalTo: bio.bottomAnchor, constant: bio.isHidden ? 0 : 12),
            countRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            countIcon.widthAnchor.constraint(equalToConstant: 16),
            countIcon.heightAnchor.constraint(equalToConstant: 16),
            joinButton.topAnchor.constraint(equalTo: countRow.bottomAnchor, constant: 16),
            joinButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            joinButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            joinButton.heightAnchor.constraint(equalToConstant: 48),
            hairline.topAnchor.constraint(equalTo: joinButton.bottomAnchor, constant: 16),
            hairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            section.topAnchor.constraint(equalTo: hairline.bottomAnchor, constant: 14),
            section.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            section.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            section.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8),
        ])
        return header
    }

    private func configureJoinButton() {
        joinButton.translatesAutoresizingMaskIntoConstraints = false
        joinButton.layer.cornerRadius = 24
        joinButton.layer.cornerCurve = .continuous
        joinButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        let joined = group.isGroupUser || group.isGroupOwner
        if joined {
            joinButton.setTitle(String(localized: "groups.joined", defaultValue: "已加入"), for: .normal)
            joinButton.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
            joinButton.setTitleColor(.secondaryLabel, for: .normal)
            joinButton.isEnabled = group.isGroupUser && !group.isGroupOwner
        } else if group.publicAdmission {
            joinButton.setTitle(String(localized: "groups.join", defaultValue: "加入群组"), for: .normal)
            joinButton.backgroundColor = AppSettings.shared.themeStyle.accentColor
            joinButton.setTitleColor(.white, for: .normal)
            joinButton.isEnabled = true
        } else {
            joinButton.setTitle(String(localized: "groups.closed", defaultValue: "群组已关闭"), for: .normal)
            joinButton.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
            joinButton.setTitleColor(.tertiaryLabel, for: .normal)
            joinButton.isEnabled = false
        }
        joinButton.removeTarget(nil, action: nil, for: .allEvents)
        joinButton.addTarget(self, action: #selector(joinTapped), for: .touchUpInside)
    }

    @objc private func joinTapped() {
        guard !isJoining else { return }
        isJoining = true
        joinButton.isEnabled = false
        let name = group.name
        let leaving = group.isGroupUser
        let username = AuthManager.shared.username(for: api.baseURL) ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard !username.isEmpty else {
                    throw DiscourseAPIError(
                        messages: [String(localized: "groups.join.need_login", defaultValue: "请先登录后再加入群组")],
                        errorType: "not_logged_in"
                    )
                }
                if leaving {
                    try await api.leaveGroup(name: name, username: username)
                } else {
                    try await api.joinGroup(name: name, username: username)
                }
                if let fresh = try? await api.fetchGroup(name: name) {
                    group = fresh
                }
                tableView.tableHeaderView = makeHeader()
                view.setNeedsLayout()
            } catch {
                errorMessage = error.localizedDescription
                configureJoinButton()
            }
            isJoining = false
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        members.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: GroupMemberCell.reuseIdentifier, for: indexPath)
        guard let memberCell = cell as? GroupMemberCell, members.indices.contains(indexPath.row) else {
            return cell
        }
        memberCell.configure(member: members[indexPath.row], baseURL: api.baseURL)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard members.indices.contains(indexPath.row) else { return }
        navigationController?.pushViewController(
            UserProfileViewController(api: api, username: members[indexPath.row].username),
            animated: true
        )
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard canLoadMore, !isLoading, indexPath.row >= members.count - 6 else { return }
        reload(reset: false)
    }
}

private final class GroupMemberCell: UITableViewCell {
    static let reuseIdentifier = "GroupMemberCell"

    private let avatarView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 20
        view.backgroundColor = ImagePaintPolicy.waitingFillColor
        return view
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        return label
    }()

    private let handleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .tertiaryLabel
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let names = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        names.translatesAutoresizingMaskIntoConstraints = false
        names.axis = .vertical
        names.spacing = 1
        contentView.addSubview(avatarView)
        contentView.addSubview(names)
        contentView.addSubview(timeLabel)
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 40),
            avatarView.heightAnchor.constraint(equalToConstant: 40),
            names.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            names.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            names.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            timeLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            timeLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.sd_cancelCurrentImageLoad()
        avatarView.image = nil
        nameLabel.text = nil
        handleLabel.text = nil
        timeLabel.text = nil
    }

    func configure(member: DiscourseGroupMember, baseURL: String) {
        let sameName = member.displayName.caseInsensitiveCompare(member.username) == .orderedSame
        nameLabel.text = sameName ? nil : member.displayName
        nameLabel.isHidden = sameName
        handleLabel.text = "@\(member.username)"
        timeLabel.text = UserProfileFormatting.relativeDate(member.lastPostedAt ?? member.lastSeenAt)
        if timeLabel.text == "--" { timeLabel.text = nil }
        AvatarImageLoader.setImage(
            on: avatarView,
            template: member.avatarTemplate,
            baseURL: baseURL,
            userId: member.id
        )
    }
}
