import UIKit

/// FluxDo 风格分类/标签侧栏：左缘右滑打开，分类树 + 标签分组/搜索/热度条。
final class HomeCategoryDrawerView: UIView {
    enum Mode: Int {
        case categories
        case tags
    }

    var onSelectCategory: ((Int?) -> Void)?
    var onSelectTag: ((String) -> Void)?
    var onEditPinned: (() -> Void)?
    var onOpenChanged: ((Bool) -> Void)?

    private let panelWidth: CGFloat = 304
    private var progress: CGFloat = 0
    private var expandedCategoryIDs = Set<Int>()
    private var mode: Mode = .categories
    private var categories: [DiscourseCategory] = []
    private var tagGroups: [DiscourseSiteTagGroup] = []
    private var selectedCategoryId: Int?
    private var baseURL: String = ""
    private var displayNameProvider: ((DiscourseCategory) -> String)?
    private var isLoadingTags = false
    private var tagQuery = ""
    private var activeTagGroupIndex = 0

    private let dimmingView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        view.alpha = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let panelView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let segmentControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "home.drawer.categories", defaultValue: "分类"),
            String(localized: "home.drawer.tags", defaultValue: "标签"),
        ])
        control.selectedSegmentIndex = 0
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private let editButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "home.drawer.edit_pins", defaultValue: "编辑")
        config.baseForegroundColor = .systemBlue
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let searchContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 18
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
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
        scroll.isHidden = true
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

    private let tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.translatesAutoresizingMaskIntoConstraints = false
        table.keyboardDismissMode = .onDrag
        table.sectionHeaderTopPadding = 8
        return table
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 0
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var panelLeadingConstraint: NSLayoutConstraint?
    private var searchHeightConstraint: NSLayoutConstraint?
    private var tagGroupHeightConstraint: NSLayoutConstraint?
    private var tableTopToSearchConstraint: NSLayoutConstraint?
    private var tableTopToTagGroupConstraint: NSLayoutConstraint?
    private var isOpen: Bool { progress > 0.001 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        applyClosedInteractionState()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, progress > 0.001 else { return nil }
        return super.hitTest(point, with: event)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        categories: [DiscourseCategory],
        selectedCategoryId: Int?,
        baseURL: String,
        displayNameProvider: @escaping (DiscourseCategory) -> String
    ) {
        self.categories = categories.filter { $0.id != 1 }
        self.selectedCategoryId = selectedCategoryId
        self.baseURL = baseURL
        self.displayNameProvider = displayNameProvider
        reloadVisibleContent()
    }

    func setTagGroups(_ groups: [DiscourseSiteTagGroup], isLoading: Bool) {
        tagGroups = groups
        isLoadingTags = isLoading
        if activeTagGroupIndex >= filteredTagGroups().count {
            activeTagGroupIndex = 0
        }
        if mode == .tags {
            rebuildTagGroupChips()
            reloadVisibleContent()
        }
    }

    func open(animated: Bool) {
        setProgress(1, animated: animated)
    }

    func close(animated: Bool) {
        searchField.resignFirstResponder()
        setProgress(0, animated: animated)
    }

    func toggle(animated: Bool) {
        setProgress(isOpen ? 0 : 1, animated: animated)
    }

    func dragBy(_ dx: CGFloat) {
        setProgress((progress + dx / panelWidth).clamped(to: 0...1), animated: false)
    }

    func settle(velocityDx: CGFloat) {
        let target: CGFloat
        if abs(velocityDx) >= 650 {
            target = velocityDx > 0 ? 1 : 0
        } else {
            target = progress >= 0.5 ? 1 : 0
        }
        setProgress(target, animated: true)
    }

    func prepareForInteractiveOpen() {
        accessibilityElementsHidden = false
        isUserInteractionEnabled = true
        setProgress(max(progress, 0.001), animated: false)
    }

    func setInteractiveProgress(_ value: CGFloat) {
        setProgress(value, animated: false)
    }

    private func setupUI() {
        addSubview(dimmingView)
        addSubview(panelView)
        panelView.addSubview(segmentControl)
        panelView.addSubview(editButton)
        panelView.addSubview(searchContainer)
        searchContainer.addSubview(searchIconView)
        searchContainer.addSubview(searchField)
        panelView.addSubview(tagGroupScrollView)
        tagGroupScrollView.addSubview(tagGroupStack)
        panelView.addSubview(tableView)
        panelView.addSubview(emptyLabel)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(DrawerCategoryCell.self, forCellReuseIdentifier: DrawerCategoryCell.reuseID)
        tableView.register(FluxDoTagCell.self, forCellReuseIdentifier: FluxDoTagCell.reuseID)

        let leading = panelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -panelWidth)
        panelLeadingConstraint = leading
        searchHeightConstraint = searchContainer.heightAnchor.constraint(equalToConstant: 0)
        tagGroupHeightConstraint = tagGroupScrollView.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: bottomAnchor),

            leading,
            panelView.topAnchor.constraint(equalTo: topAnchor),
            panelView.bottomAnchor.constraint(equalTo: bottomAnchor),
            panelView.widthAnchor.constraint(equalToConstant: panelWidth),

            segmentControl.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            segmentControl.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 16),
            segmentControl.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -8),
            segmentControl.heightAnchor.constraint(equalToConstant: 32),

            editButton.centerYAnchor.constraint(equalTo: segmentControl.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -8),

            searchContainer.topAnchor.constraint(equalTo: segmentControl.bottomAnchor, constant: 10),
            searchContainer.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 16),
            searchContainer.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -16),
            searchHeightConstraint!,

            searchIconView.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 12),
            searchIconView.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 16),
            searchIconView.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),

            tagGroupScrollView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 8),
            tagGroupScrollView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            tagGroupScrollView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            tagGroupHeightConstraint!,

            tagGroupStack.topAnchor.constraint(equalTo: tagGroupScrollView.topAnchor),
            tagGroupStack.bottomAnchor.constraint(equalTo: tagGroupScrollView.bottomAnchor),
            tagGroupStack.leadingAnchor.constraint(equalTo: tagGroupScrollView.leadingAnchor, constant: 12),
            tagGroupStack.trailingAnchor.constraint(equalTo: tagGroupScrollView.trailingAnchor, constant: -12),
            tagGroupStack.heightAnchor.constraint(equalTo: tagGroupScrollView.heightAnchor),

            tableView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: panelView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: panelView.trailingAnchor, constant: -24),
        ])

        tableTopToSearchConstraint = tableView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 4)
        tableTopToTagGroupConstraint = tableView.topAnchor.constraint(equalTo: tagGroupScrollView.bottomAnchor, constant: 4)
        tableTopToSearchConstraint?.isActive = true
        tableTopToTagGroupConstraint?.isActive = false

        segmentControl.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimmingTapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panelPanned(_:)))
        panelView.addGestureRecognizer(pan)
        updateModeChrome()
    }

    @objc private func segmentChanged() {
        mode = segmentControl.selectedSegmentIndex == 0 ? .categories : .tags
        searchField.resignFirstResponder()
        updateModeChrome()
        if mode == .tags {
            rebuildTagGroupChips()
        }
        reloadVisibleContent()
    }

    @objc private func editTapped() {
        onEditPinned?()
    }

    @objc private func dimmingTapped() {
        close(animated: true)
    }

    @objc private func searchChanged() {
        tagQuery = searchField.text ?? ""
        activeTagGroupIndex = 0
        rebuildTagGroupChips()
        reloadVisibleContent()
    }

    @objc private func panelPanned(_ gesture: UIPanGestureRecognizer) {
        let dx = gesture.translation(in: self).x
        gesture.setTranslation(.zero, in: self)
        switch gesture.state {
        case .changed:
            dragBy(dx)
        case .ended, .cancelled:
            settle(velocityDx: gesture.velocity(in: self).x)
        default:
            break
        }
    }

    private func updateModeChrome() {
        let showTags = mode == .tags
        editButton.isHidden = showTags
        searchContainer.isHidden = !showTags
        let groups = filteredTagGroups()
        let showChips = showTags && shouldShowGroupLabels(groups)
        tagGroupScrollView.isHidden = !showChips
        searchHeightConstraint?.constant = showTags ? 36 : 0
        tagGroupHeightConstraint?.constant = showChips ? 34 : 0

        tableTopToSearchConstraint?.isActive = !showTags
        tableTopToTagGroupConstraint?.isActive = showTags
    }

    private func setProgress(_ value: CGFloat, animated: Bool) {
        let clamped = value.clamped(to: 0...1)
        let wasOpen = isOpen
        progress = clamped
        isUserInteractionEnabled = clamped > 0.001
        if clamped > 0.001 {
            accessibilityElementsHidden = false
        }

        let updates = {
            self.panelLeadingConstraint?.constant = -self.panelWidth * (1 - clamped)
            self.dimmingView.alpha = clamped
            self.layoutIfNeeded()
        }

        if animated {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.92,
                initialSpringVelocity: 0.2,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: updates
            ) { _ in
                if self.progress <= 0.001 {
                    self.applyClosedInteractionState()
                }
            }
        } else {
            updates()
            if progress <= 0.001 {
                applyClosedInteractionState()
            }
        }

        if wasOpen != isOpen {
            onOpenChanged?(isOpen)
        }
    }

    private func applyClosedInteractionState() {
        // Never toggle `isHidden` on the root overlay: UIKit may inject a temporary
        // height == 0 constraint and break the panel's vertical chain (Home white screen).
        isHidden = false
        isUserInteractionEnabled = false
        dimmingView.alpha = 0
        accessibilityElementsHidden = true
    }

    private func filteredTagGroups() -> [DiscourseSiteTagGroup] {
        let query = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [DiscourseSiteTagGroup] = []
        for group in tagGroups {
            let tags: [DiscourseTag]
            if query.isEmpty {
                tags = group.tags
            } else {
                tags = group.tags.filter {
                    $0.name.lowercased().contains(query) || $0.text.lowercased().contains(query)
                }
            }
            if !tags.isEmpty {
                result.append(DiscourseSiteTagGroup(name: group.name, tags: tags))
            }
        }
        return result
    }

    private func shouldShowGroupLabels(_ groups: [DiscourseSiteTagGroup]) -> Bool {
        groups.count > 1 || (groups.count == 1 && groups[0].name != nil)
    }

    private func rebuildTagGroupChips() {
        tagGroupStack.arrangedSubviews.forEach {
            tagGroupStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let groups = filteredTagGroups()
        guard shouldShowGroupLabels(groups) else {
            updateModeChrome()
            return
        }
        for (index, group) in groups.enumerated() {
            let title = group.name
                ?? String(localized: "home.drawer.tags.other", defaultValue: "其他标签")
            let button = makeTagGroupChip(title: title, selected: index == activeTagGroupIndex)
            button.tag = index
            button.addTarget(self, action: #selector(tagGroupChipTapped(_:)), for: .touchUpInside)
            tagGroupStack.addArrangedSubview(button)
        }
        updateModeChrome()
    }

    private func makeTagGroupChip(title: String, selected: Bool) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 11, bottom: 5, trailing: 11)
        config.baseForegroundColor = selected ? .label : .secondaryLabel
        config.baseBackgroundColor = selected
            ? AppSettings.shared.themeStyle.accentColor.withAlphaComponent(0.16)
            : UIColor.secondarySystemBackground
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attrs = incoming
            attrs.font = UIFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            return attrs
        }
        let button = UIButton(configuration: config)
        return button
    }

    @objc private func tagGroupChipTapped(_ sender: UIButton) {
        let groups = filteredTagGroups()
        guard groups.indices.contains(sender.tag) else { return }
        activeTagGroupIndex = sender.tag
        rebuildTagGroupChips()
        let section = sender.tag
        if tableView.doer_numberOfRows(inSection: section) > 0 {
            tableView.scrollToRow(at: IndexPath(row: 0, section: section), at: .top, animated: true)
        } else if tableView.numberOfSections > section {
            // header only
            let rect = tableView.rectForHeader(inSection: section)
            tableView.scrollRectToVisible(rect, animated: true)
        }
    }

    private func reloadVisibleContent() {
        guard window != nil else { return }
        tableView.reloadData()
        switch mode {
        case .categories:
            emptyLabel.isHidden = !categories.isEmpty
            emptyLabel.text = String(localized: "home.drawer.categories.empty", defaultValue: "暂无分类")
        case .tags:
            if isLoadingTags {
                emptyLabel.isHidden = false
                emptyLabel.text = String(localized: "home.drawer.tags.loading", defaultValue: "加载标签…")
            } else {
                let empty = filteredTagGroups().isEmpty
                emptyLabel.isHidden = !empty
                emptyLabel.text = tagQuery.isEmpty
                    ? String(localized: "home.drawer.tags.empty", defaultValue: "暂无标签")
                    : String(localized: "home.drawer.tags.not_found", defaultValue: "未找到标签")
            }
        }
    }

    // MARK: - Category rows

    private struct CategoryRow {
        let category: DiscourseCategory?
        let depth: Int
        let isExpandable: Bool
        let isExpanded: Bool
        let isAllTopicsEntry: Bool
        let title: String
    }

    private func categoryRows() -> [CategoryRow] {
        var rows: [CategoryRow] = [
            CategoryRow(
                category: nil,
                depth: 0,
                isExpandable: false,
                isExpanded: false,
                isAllTopicsEntry: false,
                title: String(localized: "home.filter.all_categories", defaultValue: "全部分类")
            )
        ]
        for category in categories {
            appendCategoryRows(category, depth: 0, into: &rows)
        }
        return rows
    }

    private func appendCategoryRows(_ category: DiscourseCategory, depth: Int, into rows: inout [CategoryRow]) {
        let children = category.subcategoryList ?? []
        let expandable = !children.isEmpty
        let expanded = expandedCategoryIDs.contains(category.id)
        let title = displayNameProvider?(category) ?? category.name
        rows.append(
            CategoryRow(
                category: category,
                depth: depth,
                isExpandable: expandable,
                isExpanded: expanded,
                isAllTopicsEntry: false,
                title: title
            )
        )
        guard expandable, expanded else { return }
        rows.append(
            CategoryRow(
                category: category,
                depth: depth + 1,
                isExpandable: false,
                isExpanded: false,
                isAllTopicsEntry: true,
                title: String(localized: "home.drawer.all_topics", defaultValue: "全部话题")
            )
        )
        for child in children {
            appendCategoryRows(child, depth: depth + 1, into: &rows)
        }
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 100_000 {
            let value = Double(count) / 10_000.0
            return String(format: "%.1fw", value).replacingOccurrences(of: ".0w", with: "w")
        }
        if count >= 10_000 {
            let value = Double(count) / 1000.0
            return String(format: "%.1fk", value).replacingOccurrences(of: ".0k", with: "k")
        }
        if count >= 1000 {
            let value = Double(count) / 1000.0
            return String(format: "%.1fk", value).replacingOccurrences(of: ".0k", with: "k")
        }
        return "\(count)"
    }
}

// MARK: - Table

extension HomeCategoryDrawerView: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        switch mode {
        case .categories: return 1
        case .tags:
            let groups = filteredTagGroups()
            return shouldShowGroupLabels(groups) ? groups.count : max(groups.count, 0)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .categories:
            return categoryRows().count
        case .tags:
            let groups = filteredTagGroups()
            guard groups.indices.contains(section) else { return 0 }
            return groups[section].tags.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard mode == .tags else { return nil }
        let groups = filteredTagGroups()
        guard shouldShowGroupLabels(groups), groups.indices.contains(section) else { return nil }
        return groups[section].name
            ?? String(localized: "home.drawer.tags.other", defaultValue: "其他标签")
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textLabel?.textColor = .secondaryLabel
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch mode {
        case .categories:
            let row = categoryRows()[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: DrawerCategoryCell.reuseID, for: indexPath) as! DrawerCategoryCell
            let selected: Bool
            if row.isAllTopicsEntry {
                selected = row.category?.id == selectedCategoryId
            } else if let category = row.category {
                selected = category.id == selectedCategoryId
            } else {
                selected = selectedCategoryId == nil
            }
            cell.configure(
                title: row.title,
                depth: row.depth,
                isExpandable: row.isExpandable,
                isExpanded: row.isExpanded,
                isSelected: selected,
                readRestricted: row.category?.readRestricted == true && !row.isAllTopicsEntry,
                category: row.isAllTopicsEntry ? nil : row.category,
                baseURL: baseURL
            )
            return cell
        case .tags:
            let groups = filteredTagGroups()
            let tag = groups[indexPath.section].tags[indexPath.row]
            let maxCount = groups[indexPath.section].tags.map(\.count).max() ?? 0
            let heat = maxCount > 0 ? CGFloat(tag.count) / CGFloat(maxCount) : 0
            let cell = tableView.dequeueReusableCell(withIdentifier: FluxDoTagCell.reuseID, for: indexPath) as! FluxDoTagCell
            cell.configure(tag: tag, heat: heat, countText: formatCount(tag.count))
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch mode {
        case .categories:
            let row = categoryRows()[indexPath.row]
            if row.isExpandable, let category = row.category, !row.isAllTopicsEntry {
                if expandedCategoryIDs.contains(category.id) {
                    expandedCategoryIDs.remove(category.id)
                } else {
                    expandedCategoryIDs.insert(category.id)
                }
                tableView.reloadData()
                return
            }
            selectedCategoryId = row.category?.id
            onSelectCategory?(row.category?.id)
            close(animated: true)
        case .tags:
            let tag = filteredTagGroups()[indexPath.section].tags[indexPath.row]
            onSelectTag?(tag.name)
            close(animated: true)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard mode == .tags, scrollView === tableView else { return }
        let groups = filteredTagGroups()
        guard shouldShowGroupLabels(groups), !groups.isEmpty else { return }
        // 根据当前可见顶部 section 高亮 chip
        if let paths = tableView.indexPathsForVisibleRows, let first = paths.first {
            if activeTagGroupIndex != first.section {
                activeTagGroupIndex = first.section
                rebuildTagGroupChips()
            }
        }
    }
}

// MARK: - Cells

private final class DrawerCategoryCell: UITableViewCell {
    static let reuseID = "DrawerCategoryCell"

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let lockView = UIImageView()
    private var leadingConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 10
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.tintColor = .tertiaryLabel
        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.image = UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        lockView.tintColor = .secondaryLabel
        lockView.isHidden = true

        contentView.addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(chevronView)
        contentView.addSubview(lockView)

        let leading = iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        leadingConstraint = leading
        NSLayoutConstraint.activate([
            leading,
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 32),
            iconContainer.heightAnchor.constraint(equalToConstant: 32),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),
            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
            lockView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 2),
            lockView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 2),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        depth: Int,
        isExpandable: Bool,
        isExpanded: Bool,
        isSelected: Bool,
        readRestricted: Bool,
        category: DiscourseCategory?,
        baseURL: String
    ) {
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15.5, weight: isSelected ? .semibold : .medium)
        titleLabel.textColor = isSelected ? AppSettings.shared.themeStyle.accentColor : .label
        leadingConstraint?.constant = 16 + CGFloat(depth) * 18
        lockView.isHidden = !readRestricted
        if isExpandable {
            chevronView.isHidden = false
            chevronView.image = UIImage(
                systemName: isExpanded ? "chevron.up" : "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            )
        } else {
            chevronView.isHidden = true
            chevronView.image = nil
        }

        if let category,
           let presentation = TopicCategoryBadgePresentation.resolve(
               category: category,
               parent: nil,
               displayName: title,
               baseURL: baseURL
           ) {
            let color = TopicTaxonomyColor.resolve(hex: presentation.colorHex) ?? .secondaryLabel
            iconContainer.backgroundColor = color.withAlphaComponent(0.14)
            iconView.tintColor = color
            switch presentation.iconSource {
            case .fontAwesome(let name):
                iconView.image = DiscourseFontAwesomeIcon.image(for: name, color: color, size: 14)
                    ?? UIImage(systemName: "folder.fill")
            case .lock:
                iconView.image = UIImage(systemName: "lock.fill")
            case .logo, .dot:
                iconView.image = UIImage(systemName: "square.grid.2x2.fill")
            }
        } else {
            iconContainer.backgroundColor = AppSettings.shared.themeStyle.accentColor.withAlphaComponent(0.14)
            iconView.tintColor = AppSettings.shared.themeStyle.accentColor
            iconView.image = UIImage(systemName: "square.grid.2x2.fill")
        }
    }
}

final class FluxDoTagCell: UITableViewCell {
    static let reuseID = "FluxDoTagCell"

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let heatTrack = UIView()
    private let heatFill = UIView()
    private var heatWidthConstraint: NSLayoutConstraint?
    private var heatRatio: CGFloat = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 9
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.clipsToBounds = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14.5, weight: .medium)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 13, weight: .regular)
        countLabel.textColor = .tertiaryLabel
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        heatTrack.translatesAutoresizingMaskIntoConstraints = false
        heatTrack.backgroundColor = UIColor.separator.withAlphaComponent(0.25)
        heatTrack.layer.cornerRadius = 1.5
        heatTrack.clipsToBounds = true
        heatFill.translatesAutoresizingMaskIntoConstraints = false
        heatFill.layer.cornerRadius = 1.5

        contentView.addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(heatTrack)
        heatTrack.addSubview(heatFill)

        let heatWidth = heatFill.widthAnchor.constraint(equalToConstant: 0)
        heatWidthConstraint = heatWidth

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 32),
            iconContainer.heightAnchor.constraint(equalToConstant: 32),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -8),

            countLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            heatTrack.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            heatTrack.trailingAnchor.constraint(equalTo: countLabel.trailingAnchor),
            heatTrack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            heatTrack.heightAnchor.constraint(equalToConstant: 3),
            heatTrack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            heatFill.leadingAnchor.constraint(equalTo: heatTrack.leadingAnchor),
            heatFill.topAnchor.constraint(equalTo: heatTrack.topAnchor),
            heatFill.bottomAnchor.constraint(equalTo: heatTrack.bottomAnchor),
            heatWidth,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(tag: DiscourseTag, heat: CGFloat, countText: String, selected: Bool = false) {
        let presentation = TopicTagIconCatalog.presentation(for: tag.name)
        let color = presentation.flatMap { TopicTaxonomyColor.resolve(hex: $0.colorHex) }
            ?? AppSettings.shared.themeStyle.accentColor
        titleLabel.text = tag.text.isEmpty ? tag.name : tag.text
        countLabel.text = countText
        iconContainer.backgroundColor = color.withAlphaComponent(0.14)
        iconView.tintColor = color
        if let iconName = presentation?.iconName,
           let image = DiscourseFontAwesomeIcon.image(for: iconName, color: color, size: 14) {
            iconView.image = image
        } else {
            iconView.image = UIImage(systemName: "number")
        }
        heatFill.backgroundColor = color
        heatRatio = max(0.02, min(1, heat))
        accessoryType = selected ? .checkmark : .none
        tintColor = color
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        heatWidthConstraint?.constant = heatTrack.bounds.width * heatRatio
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
