import UIKit

/// FluxDo 风格标签选择页：分组、搜索、图标和热度条与首页左滑标签抽屉保持一致。
final class TagPickerViewController: UIViewController {
    private let api: DiscourseAPI
    private let categoryId: Int?
    private let currentTag: String?
    var onTagSelected: ((String?) -> Void)?

    /// 多选模式（FluxDo 式高级筛选）：非 nil 时行为变为勾选 + 完成。
    private var multiSelection: Set<String>?
    var onTagsSelected: (([String]) -> Void)?

    private var tagGroups: [DiscourseSiteTagGroup] = []
    private var tagQuery = ""
    private var activeTagGroupIndex = 0
    private var searchTask: Task<Void, Never>?

    private let searchContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 18
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let searchIconView: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        view.tintColor = .tertiaryLabel
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let searchField: UITextField = {
        let field = UITextField()
        field.placeholder = String(localized: "home.drawer.tags.search", defaultValue: "搜索标签…")
        field.font = .systemFont(ofSize: 15)
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private let tagGroupScrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }()

    private let tagGroupStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 55
        table.keyboardDismissMode = .onDrag
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self
        table.register(FluxDoTagCell.self, forCellReuseIdentifier: FluxDoTagCell.reuseID)
        return table
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.translatesAutoresizingMaskIntoConstraints = false
        return indicator
    }()

    private var tagGroupHeightConstraint: NSLayoutConstraint?
    private var tableTopToSearchConstraint: NSLayoutConstraint?
    private var tableTopToTagGroupConstraint: NSLayoutConstraint?

    init(api: DiscourseAPI, categoryId: Int?, selectedTag: String?) {
        self.api = api
        self.categoryId = categoryId
        self.currentTag = selectedTag
        super.init(nibName: nil, bundle: nil)
    }

    /// 多选模式入口。
    convenience init(api: DiscourseAPI, categoryId: Int?, selectedTags: [String]) {
        self.init(api: api, categoryId: categoryId, selectedTag: nil)
        multiSelection = Set(selectedTags)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "search.tag_picker.title")
        view.backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
        view.tintColor = AppSettings.shared.themeStyle.accentColor

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )
        if multiSelection != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(doneTapped)
            )
        }

        view.addSubview(searchContainer)
        searchContainer.addSubview(searchIconView)
        searchContainer.addSubview(searchField)
        view.addSubview(tagGroupScrollView)
        tagGroupScrollView.addSubview(tagGroupStack)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(activityIndicator)

        let groupHeight = tagGroupScrollView.heightAnchor.constraint(equalToConstant: 0)
        tagGroupHeightConstraint = groupHeight
        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            searchContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            searchContainer.heightAnchor.constraint(equalToConstant: 36),

            searchIconView.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 12),
            searchIconView.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 16),
            searchIconView.heightAnchor.constraint(equalToConstant: 16),
            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),

            tagGroupScrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 8),
            tagGroupScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tagGroupScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            groupHeight,
            tagGroupStack.topAnchor.constraint(equalTo: tagGroupScrollView.topAnchor),
            tagGroupStack.bottomAnchor.constraint(equalTo: tagGroupScrollView.bottomAnchor),
            tagGroupStack.leadingAnchor.constraint(equalTo: tagGroupScrollView.leadingAnchor, constant: 12),
            tagGroupStack.trailingAnchor.constraint(equalTo: tagGroupScrollView.trailingAnchor, constant: -12),
            tagGroupStack.heightAnchor.constraint(equalTo: tagGroupScrollView.heightAnchor),

            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

            activityIndicator.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
        ])

        tableTopToSearchConstraint = tableView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 12)
        tableTopToTagGroupConstraint = tableView.topAnchor.constraint(equalTo: tagGroupScrollView.bottomAnchor, constant: 8)
        tableTopToSearchConstraint?.isActive = true

        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        fetchTags(query: "")
    }

    deinit {
        searchTask?.cancel()
    }

    private var filteredTagGroups: [DiscourseSiteTagGroup] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tagGroups.compactMap { group in
            let tags = query.isEmpty
                ? group.tags
                : group.tags.filter { $0.name.lowercased().contains(query) || $0.text.lowercased().contains(query) }
            guard !tags.isEmpty else { return nil }
            return DiscourseSiteTagGroup(name: group.name, tags: tags)
        }
    }

    private var showsClearRow: Bool {
        multiSelection.map { !$0.isEmpty } ?? (currentTag != nil)
    }

    private var groupSectionOffset: Int { showsClearRow ? 1 : 0 }

    private func shouldShowGroupLabels(_ groups: [DiscourseSiteTagGroup]) -> Bool {
        groups.count > 1 || (groups.count == 1 && groups[0].name != nil)
    }

    private func fetchTags(query: String) {
        searchTask?.cancel()
        activityIndicator.startAnimating()
        emptyLabel.isHidden = true

        searchTask = Task { [weak self] in
            guard let self else { return }
            if !query.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
            }
            do {
                let groups: [DiscourseSiteTagGroup]
                if let categoryId {
                    let results = try await api.searchTags(query: query, categoryId: categoryId)
                    groups = results.isEmpty ? [] : [DiscourseSiteTagGroup(name: nil, tags: results)]
                } else {
                    groups = try await api.fetchSiteTagGroups()
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.tagGroups = groups
                    self.activeTagGroupIndex = 0
                    self.updateTagGroupChrome()
                    self.tableView.reloadData()
                    self.updateEmptyState()
                    self.activityIndicator.stopAnimating()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.tagGroups = []
                    self.updateTagGroupChrome()
                    self.tableView.reloadData()
                    self.updateEmptyState()
                    self.activityIndicator.stopAnimating()
                }
            }
        }
    }

    private func updateEmptyState() {
        let isEmpty = filteredTagGroups.isEmpty
        emptyLabel.isHidden = !isEmpty
        emptyLabel.text = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "home.drawer.tags.empty", defaultValue: "暂无标签")
            : String(localized: "home.drawer.tags.not_found", defaultValue: "未找到标签")
    }

    private func updateTagGroupChrome() {
        tagGroupStack.arrangedSubviews.forEach {
            tagGroupStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let groups = filteredTagGroups
        let showChips = shouldShowGroupLabels(groups)
        tagGroupScrollView.isHidden = !showChips
        tagGroupHeightConstraint?.constant = showChips ? 34 : 0
        tableTopToSearchConstraint?.isActive = !showChips
        tableTopToTagGroupConstraint?.isActive = showChips

        guard showChips else { return }
        for (index, group) in groups.enumerated() {
            var config = UIButton.Configuration.filled()
            config.title = group.name ?? String(localized: "home.drawer.tags.other", defaultValue: "其他标签")
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 11)
            config.baseForegroundColor = index == activeTagGroupIndex ? .label : .secondaryLabel
            config.baseBackgroundColor = index == activeTagGroupIndex
                ? AppSettings.shared.themeStyle.accentColor.withAlphaComponent(0.16)
                : UIColor.secondarySystemBackground
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attributes = incoming
                attributes.font = .systemFont(ofSize: 12, weight: index == self.activeTagGroupIndex ? .semibold : .regular)
                return attributes
            }
            let button = UIButton(configuration: config)
            button.tag = index
            button.addTarget(self, action: #selector(tagGroupTapped(_:)), for: .touchUpInside)
            tagGroupStack.addArrangedSubview(button)
        }
    }

    @objc private func searchChanged() {
        tagQuery = searchField.text ?? ""
        activeTagGroupIndex = 0
        fetchTags(query: tagQuery)
    }

    @objc private func tagGroupTapped(_ sender: UIButton) {
        let groups = filteredTagGroups
        guard groups.indices.contains(sender.tag) else { return }
        activeTagGroupIndex = sender.tag
        updateTagGroupChrome()
        let section = sender.tag + groupSectionOffset
        guard tableView.numberOfSections > section else { return }
        if tableView.doer_numberOfRows(inSection: section) > 0 {
            tableView.scrollToRow(at: IndexPath(row: 0, section: section), at: .top, animated: true)
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func doneTapped() {
        onTagsSelected?(Array(multiSelection ?? []).sorted())
        dismiss(animated: true)
    }
}

extension TagPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        filteredTagGroups.count + groupSectionOffset
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if showsClearRow && section == 0 { return 1 }
        let groupIndex = section - groupSectionOffset
        guard filteredTagGroups.indices.contains(groupIndex) else { return 0 }
        return filteredTagGroups[groupIndex].tags.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if showsClearRow && section == 0 { return nil }
        let groups = filteredTagGroups
        let groupIndex = section - groupSectionOffset
        guard shouldShowGroupLabels(groups), groups.indices.contains(groupIndex) else { return nil }
        return groups[groupIndex].name ?? String(localized: "home.drawer.tags.other", defaultValue: "其他标签")
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textLabel?.textColor = .secondaryLabel
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if showsClearRow && indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "search.tag_picker.clear")
            content.image = UIImage(systemName: "xmark.circle")
            content.imageProperties.tintColor = .systemRed
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            return cell
        }

        let groupIndex = indexPath.section - groupSectionOffset
        let groups = filteredTagGroups
        let group = groups[groupIndex]
        let maxCount = group.tags.map(\.count).max() ?? 0
        let tag = group.tags[indexPath.row]
        let selected = multiSelection?.contains(tag.name) ?? (tag.name == currentTag)
        let cell = tableView.dequeueReusableCell(withIdentifier: FluxDoTagCell.reuseID, for: indexPath) as! FluxDoTagCell
        cell.configure(
            tag: tag,
            heat: maxCount > 0 ? CGFloat(tag.count) / CGFloat(maxCount) : 0,
            countText: formatCount(tag.count),
            selected: selected
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if showsClearRow && indexPath.section == 0 {
            if multiSelection != nil {
                multiSelection?.removeAll()
                tableView.reloadData()
            } else {
                onTagSelected?(nil)
                dismiss(animated: true)
            }
            return
        }

        let groupIndex = indexPath.section - groupSectionOffset
        let tag = filteredTagGroups[groupIndex].tags[indexPath.row]
        if var multiSelection {
            if multiSelection.contains(tag.name) {
                multiSelection.remove(tag.name)
            } else {
                multiSelection.insert(tag.name)
            }
            self.multiSelection = multiSelection
            updateTagGroupChrome()
            tableView.reloadData()
            return
        }

        onTagSelected?(tag.name)
        dismiss(animated: true)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 100_000 {
            return String(format: "%.1fw", Double(count) / 10_000).replacingOccurrences(of: ".0w", with: "w")
        }
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        }
        return "\(count)"
    }
}
