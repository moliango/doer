import SDWebImage
import UIKit

final class SearchViewController: ObservableViewController, UITextFieldDelegate {
    private let api: DiscourseAPI
    private let viewModel: SearchViewModel
    private let initialQuery: String?
    private let fixedQueryQualifier: String?

    private var searchTask: Task<Void, Never>?
    private var selectedScope: SearchResultScope = .topics
    private var scopeButtons: [SearchResultScope: UIButton] = [:]

    private var currentScopeIsEmpty: Bool {
        switch selectedScope {
        case .topics: return viewModel.searchResults.isEmpty
        case .users: return viewModel.userResults.isEmpty
        case .tags: return viewModel.tagResults.isEmpty
        }
    }
    

    // MARK: - FluxDO capsule header

    private let headerContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var backButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let img = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        button.setImage(img, for: .normal)
        button.addAction(UIAction { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }, for: .touchUpInside)
        return button
    }()

    private let searchCapsule: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .secondarySystemFill
        v.layer.cornerRadius = 20
        v.layer.cornerCurve = .continuous
        return v
    }()

    private lazy var searchField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.placeholder = String(localized: "search.placeholder", defaultValue: "搜索")
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.addTarget(self, action: #selector(searchFieldEditingChanged), for: .editingChanged)
        return field
    }()

    private lazy var searchActionButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.triggerSearch() }, for: .touchUpInside)
        return button
    }()

    private lazy var filterIconButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "slider.horizontal.3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        button.addAction(UIAction { [weak self] _ in self?.presentFilterPanel() }, for: .touchUpInside)
        return button
    }()

    // MARK: - Filter Bar

    private let filterBar: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var categoryButton: UIButton = {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildCategoryMenuElements() ?? [])
            },
        ])
        return button
    }()

    private lazy var sortButton: UIButton = {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildSortMenuElements() ?? [])
            },
        ])
        return button
    }()

    private lazy var sortTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = .secondaryLabel
        label.text = String(localized: "search.sort.prefix", defaultValue: "排序：")
        return label
    }()

    private lazy var aiSearchSwitch: UISwitch = {
        let control = UISwitch()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addTarget(self, action: #selector(aiSearchToggled(_:)), for: .valueChanged)
        return control
    }()

    private lazy var aiSparkleView: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "sparkles"))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = .systemPurple
        view.contentMode = .scaleAspectFit
        return view
    }()

    private lazy var resultCountLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private lazy var advancedFilterButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in
            self?.presentFilterPanel()
        }, for: .touchUpInside)
        return button
    }()

    private let filterSeparator: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // MARK: - Active filter chips (FluxDo ActiveSearchFiltersBar)


    private let scopeScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let scopeStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let chipsScrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let chipsStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var chipsHeightConstraint: NSLayoutConstraint?

    // MARK: - Table

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(SearchResultCell.self, forCellReuseIdentifier: SearchResultCell.reuseIdentifier)
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "SearchUserCell")
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "SearchTagCell")
        tv.delegate = self
        tv.separatorStyle = .none
        tv.backgroundColor = .systemGroupedBackground
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 168
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, String> = .init(tableView: tableView) { [weak self] tableView, indexPath, itemId in
        guard let self else { return UITableViewCell() }

        if itemId.hasPrefix("post:"),
           let postId = Int(itemId.dropFirst(5)),
           let cell = tableView.dequeueReusableCell(withIdentifier: SearchResultCell.reuseIdentifier, for: indexPath) as? SearchResultCell,
           let post = self.viewModel.searchResults.first(where: { $0.id == postId }) {
            let topic = self.viewModel.topic(for: post.topicId)
            let category = topic?.categoryId.flatMap { self.viewModel.categoriesById[$0] }
            cell.configure(
                with: post,
                topic: topic,
                baseURL: self.api.baseURL,
                categoryName: self.viewModel.categoryDisplayName(for: category),
                categoryColor: category.flatMap { Self.color(fromHex: $0.color) },
                isAIResult: self.viewModel.aiTopicIds.contains(post.topicId)
            )
            return cell
        }

        if itemId.hasPrefix("user:"),
           let userId = Int(itemId.dropFirst(5)),
           let user = self.viewModel.userResults.first(where: { $0.id == userId }) {
            let cell = tableView.dequeueReusableCell(withIdentifier: "SearchUserCell")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "SearchUserCell")
            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: "person.crop.circle.fill")
            content.imageProperties.tintColor = AppSettings.shared.themeStyle.accentColor
            content.text = user.name?.isEmpty == false ? "\(user.name!) (@\(user.username))" : "@\(user.username)"
            content.secondaryText = "@\(user.username)"
            content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.backgroundColor = .clear
            return cell
        }

        if itemId.hasPrefix("tag:") {
            let name = String(itemId.dropFirst(4))
            let tag = self.viewModel.tagResults.first(where: { $0.name == name || $0.text == name })
                ?? self.viewModel.hotTags.first(where: { $0.name == name || $0.text == name })
            let cell = tableView.dequeueReusableCell(withIdentifier: "SearchTagCell")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "SearchTagCell")
            var content = cell.defaultContentConfiguration()
            content.image = UIImage(systemName: "tag.fill")
            content.imageProperties.tintColor = .systemOrange
            content.text = "#\(tag?.text ?? name)"
            if let count = tag?.count, count > 0 {
                content.secondaryText = "\(count)"
            }
            content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.backgroundColor = .clear
            return cell
        }

        return UITableViewCell()
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    private let listStateView: ListStateView = {
        let v = ListStateView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "search.no_results")
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    init(api: DiscourseAPI, initialQuery: String? = nil, fixedQueryQualifier: String? = nil) {
        self.api = api
        self.viewModel = SearchViewModel(api: api)
        self.initialQuery = initialQuery
        self.fixedQueryQualifier = fixedQueryQualifier
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        syncOwningTabBarVisibility()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
        syncOwningTabBarVisibility()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        title = nil
        navigationItem.title = String(localized: "search.title", defaultValue: "搜索")
        navigationController?.setNavigationBarHidden(true, animated: false)
        view.backgroundColor = .systemGroupedBackground
        filterBar.backgroundColor = .systemGroupedBackground
        tableView.backgroundColor = .systemGroupedBackground
        headerContainer.backgroundColor = .systemGroupedBackground
        // Search should not show topic-detail skeleton "进度条" placeholders.
        tableView.showsVerticalScrollIndicator = false
        tableView.showsHorizontalScrollIndicator = false

        setupHeader()
        setupFilterBar()
        setupScopeBar()
        aiSearchSwitch.transform = CGAffineTransform(scaleX: 0.80, y: 0.80)
        updateFilterButtons()

        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(emptyLabel)
        view.addSubview(listStateView)

        NSLayoutConstraint.activate([
            scopeScrollView.topAnchor.constraint(equalTo: chipsScrollView.bottomAnchor),
            scopeScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scopeScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scopeScrollView.heightAnchor.constraint(equalToConstant: 44),

            scopeStack.topAnchor.constraint(equalTo: scopeScrollView.contentLayoutGuide.topAnchor, constant: 6),
            scopeStack.bottomAnchor.constraint(equalTo: scopeScrollView.contentLayoutGuide.bottomAnchor, constant: -6),
            scopeStack.leadingAnchor.constraint(equalTo: scopeScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            scopeStack.trailingAnchor.constraint(equalTo: scopeScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            scopeStack.heightAnchor.constraint(equalTo: scopeScrollView.frameLayoutGuide.heightAnchor, constant: -12),

            tableView.topAnchor.constraint(equalTo: scopeScrollView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            listStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            listStateView.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            listStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            listStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        Task {
            await viewModel.loadCategories()
        }
        Task {
            await viewModel.loadRecentSearches()
        }
        Task {
            await viewModel.loadHotTags()
        }
        if let initialQuery, !initialQuery.isEmpty {
            searchField.text = initialQuery
            triggerSearch()
        }
    }

    private func syncOwningTabBarVisibility() {
        (tabBarController as? ForumTabBarController)?.syncTabBarVisibilityForCurrentContent()
    }


    private func setupHeader() {
        view.addSubview(headerContainer)
        headerContainer.addSubview(backButton)
        headerContainer.addSubview(searchCapsule)
        searchCapsule.addSubview(searchField)
        headerContainer.addSubview(searchActionButton)
        headerContainer.addSubview(filterIconButton)

        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 52),

            backButton.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 36),
            backButton.heightAnchor.constraint(equalToConstant: 36),

            filterIconButton.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -10),
            filterIconButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            filterIconButton.widthAnchor.constraint(equalToConstant: 36),
            filterIconButton.heightAnchor.constraint(equalToConstant: 36),

            searchActionButton.trailingAnchor.constraint(equalTo: filterIconButton.leadingAnchor, constant: -2),
            searchActionButton.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            searchActionButton.widthAnchor.constraint(equalToConstant: 36),
            searchActionButton.heightAnchor.constraint(equalToConstant: 36),

            searchCapsule.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            searchCapsule.trailingAnchor.constraint(equalTo: searchActionButton.leadingAnchor, constant: -6),
            searchCapsule.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),
            searchCapsule.heightAnchor.constraint(equalToConstant: 40),

            searchField.leadingAnchor.constraint(equalTo: searchCapsule.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: searchCapsule.trailingAnchor, constant: -10),
            searchField.topAnchor.constraint(equalTo: searchCapsule.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchCapsule.bottomAnchor),
        ])
    }

    // MARK: - Filter Bar Setup

    private func setupFilterBar() {
        view.addSubview(filterBar)
        filterBar.addSubview(sortTitleLabel)
        filterBar.addSubview(sortButton)
        filterBar.addSubview(aiSparkleView)
        filterBar.addSubview(aiSearchSwitch)
        filterBar.addSubview(resultCountLabel)
        view.addSubview(chipsScrollView)
        chipsScrollView.addSubview(chipsStack)
        view.addSubview(scopeScrollView)
        scopeScrollView.addSubview(scopeStack)

        let chipsHeightConstraint = chipsScrollView.heightAnchor.constraint(equalToConstant: 0)
        self.chipsHeightConstraint = chipsHeightConstraint

        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: 40),

            sortTitleLabel.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor, constant: 16),
            sortTitleLabel.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            sortButton.leadingAnchor.constraint(equalTo: sortTitleLabel.trailingAnchor, constant: 2),
            sortButton.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            resultCountLabel.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor, constant: -16),
            resultCountLabel.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            aiSearchSwitch.trailingAnchor.constraint(equalTo: resultCountLabel.leadingAnchor, constant: -8),
            aiSearchSwitch.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),

            aiSparkleView.trailingAnchor.constraint(equalTo: aiSearchSwitch.leadingAnchor, constant: -4),
            aiSparkleView.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),
            aiSparkleView.widthAnchor.constraint(equalToConstant: 15),
            aiSparkleView.heightAnchor.constraint(equalToConstant: 15),

            chipsScrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            chipsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipsHeightConstraint,

            chipsStack.topAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.topAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.bottomAnchor),
            chipsStack.leadingAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            chipsStack.trailingAnchor.constraint(equalTo: chipsScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            chipsStack.heightAnchor.constraint(equalTo: chipsScrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    // MARK: - Filter Button Appearance


    private func setupScopeBar() {
        scopeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scopeButtons.removeAll()
        for scope in SearchResultScope.allCases {
            var config = UIButton.Configuration.plain()
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 13, weight: .semibold)
                return out
            }
            let button = UIButton(configuration: config)
            button.tag = scope.rawValue
            button.addTarget(self, action: #selector(scopeChipTapped(_:)), for: .touchUpInside)
            scopeButtons[scope] = button
            scopeStack.addArrangedSubview(button)
        }
        refreshScopeChipStyles()
        scopeScrollView.isHidden = true
    }

    private func refreshScopeChipStyles() {
        let accent = AppSettings.shared.themeStyle.accentColor
        for scope in SearchResultScope.allCases {
            guard let button = scopeButtons[scope] else { continue }
            let count: Int = {
                switch scope {
                case .topics: return viewModel.searchResults.count
                case .users: return viewModel.userResults.count
                case .tags: return viewModel.tagResults.count
                }
            }()
            var config = button.configuration ?? .plain()
            config.title = count > 0 ? "\(scope.title) \(count)" : scope.title
            let selected = scope == selectedScope
            config.baseForegroundColor = selected ? .white : .secondaryLabel
            config.background.backgroundColor = selected ? accent : UIColor.secondarySystemFill
            button.configuration = config
        }
    }

    @objc private func scopeChipTapped(_ sender: UIButton) {
        guard let scope = SearchResultScope(rawValue: sender.tag) else { return }
        guard scope != selectedScope else { return }
        selectedScope = scope
        viewModel.selectedScope = scope
        refreshScopeChipStyles()
        applyResultSnapshot()
    }

    private func updateFilterButtons() {
        aiSearchSwitch.isOn = viewModel.aiSearchEnabled
        aiSearchSwitch.isEnabled = viewModel.selectedSortOrder == .relevance
        aiSparkleView.alpha = aiSearchSwitch.isEnabled ? 1 : 0.35
        resultCountLabel.text = viewModel.hasSearched ? viewModel.resultCountText : nil
        resultCountLabel.isHidden = !viewModel.hasSearched

        // Category button
        if let cat = viewModel.selectedCategory() {
            applyButtonConfig(
                categoryButton,
                title: viewModel.categoryDisplayName(for: cat) ?? cat.name,
                systemImage: "folder.fill",
                isActive: true,
                dotColor: Self.color(fromHex: cat.color)
            )
        } else {
            applyButtonConfig(
                categoryButton,
                title: String(localized: "search.filter.all_categories"),
                systemImage: "folder",
                isActive: false
            )
        }

        // Sort button — FluxDO "相关性 ▾" style next to "排序："
        var sortConfig = UIButton.Configuration.plain()
        sortConfig.title = viewModel.selectedSortOrder.displayName
        sortConfig.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        sortConfig.imagePlacement = .trailing
        sortConfig.imagePadding = 4
        sortConfig.baseForegroundColor = .label
        sortConfig.contentInsets = .zero
        sortConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 14, weight: .medium)
            return outgoing
        }
        sortButton.configuration = sortConfig

        // Advanced filter button (FluxDo tune icon + active count)
        let activeCount = viewModel.advancedFilter.activeCount
        applyButtonConfig(
            advancedFilterButton,
            title: activeCount > 0
                ? String(
                    format: String(localized: "search.filter.advanced_count", defaultValue: "筛选 · %d"),
                    activeCount
                )
                : String(localized: "search.filter.advanced", defaultValue: "筛选"),
            systemImage: activeCount > 0 ? "slider.horizontal.3" : "slider.horizontal.3",
            isActive: activeCount > 0
        )

        rebuildActiveFilterChips()
    }

    private func applyButtonConfig(
        _ button: UIButton,
        title: String,
        systemImage: String,
        isActive: Bool,
        dotColor: UIColor? = nil
    ) {
        var config: UIButton.Configuration
        if isActive {
            config = .tinted()
            config.baseBackgroundColor = .systemBlue
            config.baseForegroundColor = .systemBlue
        } else {
            config = .gray()
            config.baseForegroundColor = .secondaryLabel
        }
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)

        config.title = title
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 13, weight: .medium)
            return out
        }

        if let dotColor {
            config.image = UIImage(systemName: "circle.fill")?
                .withTintColor(dotColor, renderingMode: .alwaysOriginal)
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 8))
        } else {
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            config.image = UIImage(systemName: systemImage, withConfiguration: symbolConfig)
        }
        config.imagePlacement = .leading
        config.imagePadding = 4

        button.configuration = config
    }

    // MARK: - Active filter chips

    private func rebuildActiveFilterChips() {
        chipsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let filter = viewModel.advancedFilter
        guard !filter.isEmpty else {
            chipsHeightConstraint?.constant = 0
            chipsScrollView.isHidden = true
            return
        }
        chipsScrollView.isHidden = false
        chipsHeightConstraint?.constant = 40

        for tag in filter.tags {
            chipsStack.addArrangedSubview(makeChip(title: "#\(tag)") { [weak self] in
                guard let self else { return }
                viewModel.advancedFilter.tags.removeAll { $0 == tag }
                filterDidChange()
            })
        }
        if let status = filter.status {
            chipsStack.addArrangedSubview(makeChip(title: status.label) { [weak self] in
                self?.viewModel.advancedFilter.status = nil
                self?.filterDidChange()
            })
        }
        if filter.afterDate != nil || filter.beforeDate != nil {
            var parts: [String] = []
            if let after = filter.afterDate {
                parts.append(SearchAdvancedFilter.dateFormatter.string(from: after) + " 起")
            }
            if let before = filter.beforeDate {
                parts.append(SearchAdvancedFilter.dateFormatter.string(from: before) + " 止")
            }
            chipsStack.addArrangedSubview(makeChip(title: parts.joined(separator: " ")) { [weak self] in
                self?.viewModel.advancedFilter.afterDate = nil
                self?.viewModel.advancedFilter.beforeDate = nil
                self?.filterDidChange()
            })
        }

        var clearConfig = UIButton.Configuration.plain()
        clearConfig.title = String(localized: "search.filter.clear_all", defaultValue: "清除全部筛选")
        clearConfig.baseForegroundColor = .systemRed
        clearConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        clearConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 12, weight: .medium)
            return out
        }
        let clearButton = UIButton(configuration: clearConfig)
        clearButton.addAction(UIAction { [weak self] _ in
            self?.viewModel.advancedFilter = SearchAdvancedFilter()
            self?.filterDidChange()
        }, for: .touchUpInside)
        chipsStack.addArrangedSubview(clearButton)
    }

    private func makeChip(title: String, onRemove: @escaping () -> Void) -> UIView {
        var config = UIButton.Configuration.tinted()
        config.title = title
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .systemBlue
        config.cornerStyle = .capsule
        config.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        )
        config.imagePlacement = .trailing
        config.imagePadding = 5
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 8)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 12, weight: .medium)
            return out
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in onRemove() }, for: .touchUpInside)
        return button
    }

    private func filterDidChange() {
        updateFilterButtons()
        triggerSearch()
    }

    // MARK: - Category Menu

    private func buildCategoryMenuElements() -> [UIMenuElement] {
        if viewModel.categories.isEmpty {
            return [UIAction(title: String(localized: "search.filter.loading"), attributes: .disabled) { _ in }]
        }

        var elements: [UIMenuElement] = []

        // "All Categories"
        let allAction = UIAction(
            title: String(localized: "search.filter.all_categories"),
            image: UIImage(systemName: "square.grid.2x2"),
            state: viewModel.selectedCategoryId == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectCategory(nil)
        }
        elements.append(allAction)

        for cat in viewModel.categories {
            let catAction = UIAction(
                title: viewModel.categoryDisplayName(for: cat) ?? cat.name,
                image: colorDotImage(hex: cat.color),
                state: viewModel.selectedCategoryId == cat.id ? .on : .off
            ) { [weak self] _ in
                self?.selectCategory(cat.id)
            }

            if let subs = cat.subcategoryList, !subs.isEmpty {
                var groupChildren: [UIAction] = [catAction]
                for sub in subs {
                    let subAction = UIAction(
                        title: viewModel.categoryDisplayName(for: sub) ?? sub.name,
                        image: colorDotImage(hex: sub.color),
                        state: viewModel.selectedCategoryId == sub.id ? .on : .off
                    ) { [weak self] _ in
                        self?.selectCategory(sub.id)
                    }
                    groupChildren.append(subAction)
                }
                let inlineMenu = UIMenu(title: "", options: .displayInline, children: groupChildren)
                elements.append(inlineMenu)
            } else {
                elements.append(catAction)
            }
        }

        return elements
    }

    // MARK: - Advanced filter panel

    private func presentFilterPanel() {
        let panel = SearchFilterPanelViewController(
            api: api,
            categories: viewModel.categories,
            selectedCategoryId: viewModel.selectedCategoryId,
            filter: viewModel.advancedFilter
        ) { [weak self] categoryId, filter in
            guard let self else { return }
            viewModel.selectedCategoryId = categoryId
            viewModel.advancedFilter = filter
            filterDidChange()
        }
        if let sheet = panel.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(panel, animated: true)
    }

    // MARK: - Filter Selection

    private func selectCategory(_ categoryId: Int?) {
        viewModel.selectedCategoryId = categoryId
        updateFilterButtons()
        triggerSearch()
    }

    private func selectSortOrder(_ order: SearchSortOrder) {
        viewModel.selectedSortOrder = order
        updateFilterButtons()
        triggerSearch()
    }

    // MARK: - Sort Menu

    private func buildSortMenuElements() -> [UIMenuElement] {
        SearchSortOrder.allCases.map { order in
            UIAction(
                title: order.displayName,
                state: viewModel.selectedSortOrder == order ? .on : .off
            ) { [weak self] _ in
                self?.selectSortOrder(order)
            }
        }
    }

    // MARK: - Recent searches (empty state)

    private func makeIdleDiscoveryView() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = String(localized: "search.recent.title", defaultValue: "最近搜索")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel

        var clearConfig = UIButton.Configuration.plain()
        clearConfig.title = String(localized: "search.recent.clear", defaultValue: "清空")
        clearConfig.baseForegroundColor = .secondaryLabel
        clearConfig.contentInsets = .zero
        clearConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 12)
            return out
        }
        let clearButton = UIButton(configuration: clearConfig)
        clearButton.addAction(UIAction { [weak self] _ in
            Task { await self?.viewModel.clearRecentSearches() }
        }, for: .touchUpInside)

        let headerRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), clearButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        stack.addArrangedSubview(headerRow)
        stack.setCustomSpacing(8, after: headerRow)

        for term in viewModel.recentSearches.prefix(10) {
            let display = viewModel.displayTerm(forRecent: term)
            guard !display.isEmpty else { continue }
            var config = UIButton.Configuration.plain()
            config.title = display
            config.image = UIImage(
                systemName: "clock.arrow.circlepath",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            )
            config.imagePadding = 10
            config.baseForegroundColor = .label
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 2, bottom: 10, trailing: 2)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 15)
                return out
            }
            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if let order = self.viewModel.sortOrder(embeddedIn: term) {
                    self.viewModel.selectedSortOrder = order
                    self.updateFilterButtons()
                }
                self.searchField.text = display
                self.triggerSearch()
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        if !viewModel.hotTags.isEmpty {
            let hotTitle = UILabel()
            hotTitle.text = String(localized: "search.hot.title", defaultValue: "热门标签")
            hotTitle.font = .systemFont(ofSize: 13, weight: .semibold)
            hotTitle.textColor = .secondaryLabel
            stack.setCustomSpacing(20, after: stack.arrangedSubviews.last!)
            stack.addArrangedSubview(hotTitle)
            stack.setCustomSpacing(8, after: hotTitle)

            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            var x: CGFloat = 0
            var y: CGFloat = 0
            let maxW = UIScreen.main.bounds.width - 40
            let hPad: CGFloat = 8
            let vPad: CGFloat = 8
            for tag in viewModel.hotTags.prefix(16) {
                var config = UIButton.Configuration.gray()
                config.title = "#\(tag.text)"
                config.cornerStyle = .capsule
                config.buttonSize = .small
                config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
                let button = UIButton(configuration: config)
                button.sizeToFit()
                let w = max(button.bounds.width, 44)
                let h: CGFloat = 32
                if x + w > maxW, x > 0 {
                    x = 0
                    y += h + vPad
                }
                button.frame = CGRect(x: x, y: y, width: w + 8, height: h)
                let term = tag.text
                button.addAction(UIAction { [weak self] _ in
                    self?.searchField.text = term
                    self?.selectedScope = .topics
                    self?.triggerSearch()
                }, for: .touchUpInside)
                wrap.addSubview(button)
                x += w + 8 + hPad
            }
            wrap.heightAnchor.constraint(equalToConstant: y + 32).isActive = true
            stack.addArrangedSubview(wrap)
        }

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: - User results header

    private func makeUsersHeaderView() -> UIView? {
        guard !viewModel.userResults.isEmpty else { return nil }
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 64))
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        for user in viewModel.userResults.prefix(10) {
            var config = UIButton.Configuration.gray()
            config.title = user.username
            config.cornerStyle = .capsule
            config.buttonSize = .small
            config.image = UIImage(systemName: "person.crop.circle")
            config.imagePadding = 5
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 12)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming
                out.font = .systemFont(ofSize: 13, weight: .medium)
                return out
            }
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                let profile = UserProfileViewController(api: api, username: user.username)
                navigationController?.pushViewController(profile, animated: true)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        header.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: header.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return header
    }

    // MARK: - Search

    override func updateUI() {
        let showsInitialLoading = viewModel.isSearching
            && viewModel.searchResults.isEmpty
            && viewModel.errorMessage == nil
        // Only a centered spinner — no skeleton progress bars on the search page.
        if showsInitialLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        emptyLabel.isHidden = true
        if let error = viewModel.errorMessage {
            listStateView.isHidden = false
            listStateView.configure(.error(error)) { [weak self] in
                self?.triggerSearch()
            }
        } else if viewModel.hasSearched, currentScopeIsEmpty, !viewModel.isSearching {
            listStateView.isHidden = false
            listStateView.configure(.empty) { [weak self] in
                self?.triggerSearch()
            }
        } else {
            listStateView.isHidden = true
        }

        updateFilterButtons()
        refreshScopeChipStyles()
        scopeScrollView.isHidden = !viewModel.hasSearched

        // Idle: recent history + hot tags. After search: result list by scope.
        if !viewModel.hasSearched {
            tableView.backgroundView = makeIdleDiscoveryView()
            tableView.tableHeaderView = nil
        } else {
            tableView.backgroundView = nil
            tableView.tableHeaderView = nil
        }

        applyResultSnapshot()
    }

    private func applyResultSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        guard viewModel.hasSearched else {
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }

        let items: [String]
        switch selectedScope {
        case .topics:
            var seen = Set<Int>()
            items = viewModel.searchResults.compactMap { post -> String? in
                guard seen.insert(post.id).inserted else { return nil }
                return "post:\(post.id)"
            }
        case .users:
            items = viewModel.userResults.map { "user:\($0.id)" }
        case .tags:
            items = viewModel.tagResults.map { "tag:\($0.name)" }
        }
        snapshot.appendItems(items, toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)

        // Empty state for current scope
        let emptyForScope = items.isEmpty && !viewModel.isSearching && viewModel.errorMessage == nil
        if emptyForScope {
            listStateView.isHidden = false
            listStateView.configure(.empty) { [weak self] in
                self?.triggerSearch()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        triggerSearch()
        textField.resignFirstResponder()
        return true
    }

    @objc private func searchFieldEditingChanged() {
        // Keep clear button / empty recent state reactive.
        if (searchField.text ?? "").isEmpty, viewModel.hasSearched == false {
            updateUI()
        }
    }

    @objc private func aiSearchToggled(_ sender: UISwitch) {
        viewModel.aiSearchEnabled = sender.isOn
        if viewModel.hasSearched {
            triggerSearch()
        } else {
            updateUI()
        }
    }

    private func triggerSearch() {
        let term = searchField.text ?? ""
        guard !term.isEmpty else { return }
        let effectiveTerm: String
        if let fixedQueryQualifier, !fixedQueryQualifier.isEmpty {
            effectiveTerm = "\(term.trimmingCharacters(in: .whitespacesAndNewlines)) \(fixedQueryQualifier)"
        } else {
            effectiveTerm = term
        }
        searchTask?.cancel()
        searchTask = Task {
            await viewModel.search(term: effectiveTerm)
        }
    }

    func refreshAfterCloudflareVerification() {
        triggerSearch()
    }

    // MARK: - Helpers

    private func colorDotImage(hex: String) -> UIImage? {
        guard let color = Self.color(fromHex: hex) else { return nil }
        return UIImage(systemName: "circle.fill")?
            .withTintColor(color, renderingMode: .alwaysOriginal)
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 10))
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

// MARK: - UITableViewDelegate

extension SearchViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemId = dataSource.itemIdentifier(for: indexPath) else { return }

        if itemId.hasPrefix("post:"),
           let postId = Int(itemId.dropFirst(5)),
           let post = viewModel.searchResults.first(where: { $0.id == postId }) {
            // Jump to the matched floor / post — the whole point of search hit navigation.
            let detailVC = TopicDetailFactory.make(
                api: api,
                topicId: post.topicId,
                initialFloor: post.postNumber,
                initialPostId: post.id
            )
            navigationController?.pushViewController(detailVC, animated: true)
            return
        }

        if itemId.hasPrefix("user:"),
           let userId = Int(itemId.dropFirst(5)),
           let user = viewModel.userResults.first(where: { $0.id == userId }) {
            let profile = UserProfileViewController(api: api, username: user.username)
            navigationController?.pushViewController(profile, animated: true)
            return
        }

        if itemId.hasPrefix("tag:") {
            let name = String(itemId.dropFirst(4))
            let tagName = viewModel.tagResults.first(where: { $0.name == name })?.text
                ?? viewModel.hotTags.first(where: { $0.name == name })?.text
                ?? name
            let tagsVC = TagTopicsViewController(api: api, tagName: tagName)
            navigationController?.pushViewController(tagsVC, animated: true)
        }
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard selectedScope == .topics,
              let itemId = dataSource.itemIdentifier(for: indexPath),
              itemId.hasPrefix("post:"),
              let postId = Int(itemId.dropFirst(5)),
              let post = viewModel.searchResults.first(where: { $0.id == postId })
        else { return nil }
        let topic = viewModel.topic(for: post.topicId)
        let previewTopic = post.makePreviewTopic(topic: topic, baseURL: api.baseURL)
        let category = topic?.categoryId.flatMap { viewModel.categoriesById[$0] }
        let cell = tableView.cellForRow(at: indexPath)
        let open = UIAction(
            title: String(localized: "topic.preview.open", defaultValue: "打开"),
            image: UIImage(systemName: "arrow.up.right")
        ) { [weak self] _ in
            self?.openSearchPost(post)
        }
        return TopicPreviewMenu.configuration(
            topic: previewTopic,
            api: api,
            categoryName: viewModel.categoryDisplayName(for: category),
            actions: [open],
            previewTargetView: cell.map { TopicPreviewMenu.targetView(in: $0) }
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
            self?.openSearchTopic(id: number.intValue)
        }
    }

    private func openSearchPost(_ post: DiscourseSearchResult.SearchPost) {
        let detailVC = TopicDetailFactory.make(
            api: api,
            topicId: post.topicId,
            initialFloor: post.postNumber,
            initialPostId: post.id
        )
        navigationController?.pushViewController(detailVC, animated: true)
    }

    private func openSearchTopic(id topicId: Int) {
        if let post = viewModel.searchResults.first(where: { $0.topicId == topicId }) {
            openSearchPost(post)
            return
        }
        navigationController?.pushViewController(
            TopicDetailFactory.make(api: api, topicId: topicId),
            animated: true
        )
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard selectedScope == .topics else { return }
        let totalRows = tableView.numberOfRows(inSection: 0)
        if indexPath.row >= totalRows - 5 {
            Task {
                await viewModel.loadMoreResults()
            }
        }
    }
}

extension DiscourseSearchResult.SearchPost {
    func makePreviewTopic(
        topic: DiscourseSearchResult.SearchTopic?,
        baseURL: String
    ) -> DiscourseTopicList.Topic {
        let rawTitle = topicTitleHeadline?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleSource: String = {
            if !rawTitle.isEmpty {
                return CookedContentPipeline.plainTextPreview(fromCooked: rawTitle, baseURL: baseURL)
            }
            if let fancy = topic?.fancyTitle, !fancy.isEmpty { return fancy }
            if let title = topic?.title, !title.isEmpty { return title }
            return String(localized: "search.untitled", defaultValue: "无标题")
        }()
        let excerpt = CookedContentPipeline.plainTextPreview(fromCooked: blurb ?? "", baseURL: baseURL)
        return .makeRecommendation(
            id: topicId,
            title: titleSource,
            fancyTitle: topic?.fancyTitle,
            postsCount: topic?.postsCount ?? max(postNumber, 1),
            replyCount: max((topic?.postsCount ?? 1) - 1, 0),
            categoryId: topic?.categoryId,
            createdAt: createdAt ?? "",
            lastPostedAt: nil,
            tags: topic?.tags ?? [],
            excerpt: excerpt.isEmpty ? nil : excerpt
        )
    }
}
