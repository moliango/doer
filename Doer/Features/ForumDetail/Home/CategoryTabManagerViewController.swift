import UIKit

final class CategoryTabManagerViewController: UITableViewController {
    var onPinnedCategoryIdsChanged: (([Int]) -> Void)?

    private enum Section: Int, CaseIterable {
        case pinned
        case available
    }

    private struct AvailableRow {
        let category: DiscourseCategory
        let depth: Int
        let isExpandable: Bool
        let isExpanded: Bool
    }

    private let allCategories: [DiscourseCategory]
    private let baseURL: String
    private let displayNameProvider: (DiscourseCategory) -> String
    private var pinnedCategoryIds: [Int]
    private var expandedCategoryIDs = Set<Int>()

    private var categoriesById: [Int: DiscourseCategory] {
        Dictionary(uniqueKeysWithValues: allCategories.map { ($0.id, $0) })
    }

    private var childrenByParent: [Int: [DiscourseCategory]] {
        var map: [Int: [DiscourseCategory]] = [:]
        for category in allCategories where category.id != 1 {
            if let parentId = category.parentCategoryId {
                map[parentId, default: []].append(category)
            }
        }
        return map
    }

    private var rootCategories: [DiscourseCategory] {
        allCategories.filter { $0.id != 1 && $0.parentCategoryId == nil }
    }

    private var pinnedCategories: [DiscourseCategory] {
        let lookup = categoriesById
        return pinnedCategoryIds.compactMap { lookup[$0] }
    }

    private var pinnedIDSet: Set<Int> {
        Set(pinnedCategoryIds)
    }

    init(
        categories: [DiscourseCategory],
        pinnedCategoryIds: [Int],
        baseURL: String,
        displayNameProvider: @escaping (DiscourseCategory) -> String
    ) {
        self.allCategories = categories
        self.pinnedCategoryIds = Self.validPinnedIds(pinnedCategoryIds, categories: categories)
        self.baseURL = baseURL
        self.displayNameProvider = displayNameProvider
        super.init(style: .plain)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "home.category_manager.title")
        applyTheme()
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.sectionHeaderTopPadding = 8
        tableView.keyboardDismissMode = .onDrag
        tableView.register(CategoryManagerCell.self, forCellReuseIdentifier: CategoryManagerCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "EmptyCell")
        tableView.dragInteractionEnabled = true
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "home.category_manager.done"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyTheme()
    }

    private func applyTheme() {
        let background = AppSettings.shared.themeStyle.topicListBackgroundColor
        view.backgroundColor = background
        tableView.backgroundColor = background
        tableView.tintColor = AppSettings.shared.themeStyle.accentColor
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .pinned:
            return max(pinnedCategories.count, 1)
        case .available:
            return max(availableRows().count, 1)
        case .none:
            return 0
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let title: String
        switch Section(rawValue: section) {
        case .pinned:
            title = String(localized: "home.category_manager.my_categories")
        case .available:
            title = String(localized: "home.category_manager.all_categories")
        case .none:
            return nil
        }
        return makeSectionHeader(title: title)
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        let text: String
        switch Section(rawValue: section) {
        case .pinned:
            text = String(localized: "home.category_manager.remove_hint")
        case .available:
            text = String(localized: "home.category_manager.add_hint")
        case .none:
            return nil
        }
        return makeSectionFooter(text: text)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .pinned:
            let categories = pinnedCategories
            guard !categories.isEmpty else {
                return emptyCell(text: String(localized: "home.category_manager.empty_pinned"), indexPath: indexPath)
            }
            return categoryCell(
                category: categories[indexPath.row],
                depth: 0,
                isExpandable: false,
                isExpanded: false,
                mode: .remove,
                indexPath: indexPath
            )
        case .available:
            let rows = availableRows()
            guard !rows.isEmpty else {
                return emptyCell(text: String(localized: "home.category_manager.empty_available"), indexPath: indexPath)
            }
            let row = rows[indexPath.row]
            return categoryCell(
                category: row.category,
                depth: row.depth,
                isExpandable: row.isExpandable,
                isExpanded: row.isExpanded,
                mode: .add,
                indexPath: indexPath
            )
        case .none:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .pinned:
            let categories = pinnedCategories
            guard categories.indices.contains(indexPath.row) else { return }
            unpin(categories[indexPath.row].id)
        case .available:
            let rows = availableRows()
            guard rows.indices.contains(indexPath.row) else { return }
            let row = rows[indexPath.row]
            if row.isExpandable {
                toggleExpanded(row.category.id)
            } else {
                pin(row.category.id)
            }
        case .none:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .pinned && pinnedCategories.count > 1
    }

    override func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        movePinned(from: sourceIndexPath, to: destinationIndexPath)
    }

    private func movePinned(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard Section(rawValue: sourceIndexPath.section) == .pinned,
              Section(rawValue: destinationIndexPath.section) == .pinned,
              pinnedCategoryIds.indices.contains(sourceIndexPath.row)
        else {
            tableView.reloadData()
            return
        }
        let id = pinnedCategoryIds.remove(at: sourceIndexPath.row)
        let destination = min(destinationIndexPath.row, pinnedCategoryIds.count)
        pinnedCategoryIds.insert(id, at: destination)
        commitPinnedCategoryChange(reload: false)
    }

    override func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        if proposedDestinationIndexPath.section == Section.pinned.rawValue {
            return proposedDestinationIndexPath
        }
        return sourceIndexPath
    }

    private func categoryCell(
        category: DiscourseCategory,
        depth: Int,
        isExpandable: Bool,
        isExpanded: Bool,
        mode: CategoryManagerCell.Mode,
        indexPath: IndexPath
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: CategoryManagerCell.reuseIdentifier,
            for: indexPath
        ) as? CategoryManagerCell else {
            return UITableViewCell()
        }
        let parent = category.parentCategoryId.flatMap { categoriesById[$0] }
        cell.configure(
            title: displayNameProvider(category),
            depth: depth,
            isExpandable: isExpandable,
            isExpanded: isExpanded,
            readRestricted: category.readRestricted,
            category: category,
            parent: parent,
            baseURL: baseURL,
            mode: mode
        )
        cell.onActionTapped = { [weak self] in
            switch mode {
            case .add:
                self?.pin(category.id)
            case .remove:
                self?.unpin(category.id)
            }
        }
        return cell
    }

    private func emptyCell(text: String, indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "EmptyCell", for: indexPath)
        var config = UIListContentConfiguration.cell()
        config.text = text
        config.textProperties.color = .secondaryLabel
        config.textProperties.font = .systemFont(ofSize: 14, weight: .regular)
        config.textProperties.alignment = .center
        cell.contentConfiguration = config
        cell.selectionStyle = .none
        cell.accessoryType = .none
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        return cell
    }

    private func makeSectionHeader(title: String) -> UIView {
        let container = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])
        return container
    }

    private func makeSectionFooter(text: String) -> UIView {
        let container = UIView()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .tertiaryLabel
        label.numberOfLines = 0
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func availableRows() -> [AvailableRow] {
        var rows: [AvailableRow] = []
        for root in rootCategories {
            appendAvailable(root, depth: 0, into: &rows)
        }
        return rows
    }

    private func appendAvailable(_ category: DiscourseCategory, depth: Int, into rows: inout [AvailableRow]) {
        let pinned = pinnedIDSet
        let children = childrenByParent[category.id] ?? []
        if pinned.contains(category.id) {
            for child in children {
                appendAvailable(child, depth: depth, into: &rows)
            }
            return
        }

        let hasVisibleChildren = children.contains { hasUnpinnedNode($0, pinned: pinned) }
        let expanded = expandedCategoryIDs.contains(category.id)
        rows.append(
            AvailableRow(
                category: category,
                depth: depth,
                isExpandable: hasVisibleChildren,
                isExpanded: expanded
            )
        )
        guard hasVisibleChildren, expanded else { return }
        for child in children {
            appendAvailable(child, depth: depth + 1, into: &rows)
        }
    }

    private func hasUnpinnedNode(_ category: DiscourseCategory, pinned: Set<Int>) -> Bool {
        if !pinned.contains(category.id) { return true }
        return (childrenByParent[category.id] ?? []).contains { hasUnpinnedNode($0, pinned: pinned) }
    }

    private func toggleExpanded(_ categoryId: Int) {
        if expandedCategoryIDs.contains(categoryId) {
            expandedCategoryIDs.remove(categoryId)
        } else {
            expandedCategoryIDs.insert(categoryId)
        }
        tableView.reloadData()
    }

    private func pin(_ categoryId: Int) {
        guard !pinnedIDSet.contains(categoryId) else { return }
        pinnedCategoryIds.append(categoryId)
        commitPinnedCategoryChange()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func unpin(_ categoryId: Int) {
        pinnedCategoryIds.removeAll { $0 == categoryId }
        commitPinnedCategoryChange()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func commitPinnedCategoryChange(reload: Bool = true) {
        pinnedCategoryIds = Self.validPinnedIds(pinnedCategoryIds, categories: allCategories)
        onPinnedCategoryIdsChanged?(pinnedCategoryIds)
        if reload {
            tableView.reloadData()
        }
    }

    @objc private func doneTapped() {
        dismiss(animated: true)
    }

    private static func validPinnedIds(_ ids: [Int], categories: [DiscourseCategory]) -> [Int] {
        let validIds = Set(categories.map(\.id))
        var seen = Set<Int>()
        return ids.filter { validIds.contains($0) && seen.insert($0).inserted }
    }
}

extension CategoryTabManagerViewController: UITableViewDragDelegate, UITableViewDropDelegate {
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard indexPath.section == Section.pinned.rawValue,
              pinnedCategories.count > 1,
              pinnedCategoryIds.indices.contains(indexPath.row)
        else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = pinnedCategoryIds[indexPath.row]
        return [item]
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard session.localDragSession != nil,
              destinationIndexPath?.section == Section.pinned.rawValue
        else {
            return UITableViewDropProposal(operation: .cancel)
        }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let destination = coordinator.destinationIndexPath,
              destination.section == Section.pinned.rawValue,
              let item = coordinator.items.first,
              let source = item.sourceIndexPath
        else { return }
        tableView.performBatchUpdates {
            movePinned(from: source, to: destination)
            tableView.moveRow(at: source, to: destination)
        }
        coordinator.drop(item.dragItem, toRowAt: destination)
    }
}

final class CategoryManagerCell: UITableViewCell {
    enum Mode {
        case add
        case remove
    }

    static let reuseIdentifier = "CategoryManagerCell"

    var onActionTapped: (() -> Void)?

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let chevronView = UIImageView()
    private let lockView = UIImageView()
    private let actionButton = UIButton(type: .system)
    private var leadingConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 10
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.clipsToBounds = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        titleLabel.textColor = .label

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.tintColor = .tertiaryLabel

        lockView.translatesAutoresizingMaskIntoConstraints = false
        lockView.image = UIImage(
            systemName: "lock.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        )
        lockView.tintColor = .secondaryLabel
        lockView.isHidden = true

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)

        contentView.addSubview(iconContainer)
        iconContainer.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(chevronView)
        contentView.addSubview(lockView)
        contentView.addSubview(actionButton)

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

            chevronView.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            actionButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            actionButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 32),
            actionButton.heightAnchor.constraint(equalToConstant: 32),

            lockView.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 2),
            lockView.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor, constant: 2),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActionTapped = nil
        titleLabel.text = nil
        iconView.image = nil
        chevronView.image = nil
    }

    func configure(
        title: String,
        depth: Int,
        isExpandable: Bool,
        isExpanded: Bool,
        readRestricted: Bool,
        category: DiscourseCategory,
        parent: DiscourseCategory?,
        baseURL: String,
        mode: Mode
    ) {
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
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

        applyCategoryIcon(title: title, category: category, parent: parent, baseURL: baseURL)
        applyAction(mode: mode, title: title)
    }

    private func applyCategoryIcon(
        title: String,
        category: DiscourseCategory,
        parent: DiscourseCategory?,
        baseURL: String
    ) {
        if let presentation = TopicCategoryBadgePresentation.resolve(
            category: category,
            parent: parent,
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
            let accent = AppSettings.shared.themeStyle.accentColor
            iconContainer.backgroundColor = accent.withAlphaComponent(0.14)
            iconView.tintColor = accent
            iconView.image = UIImage(systemName: "square.grid.2x2.fill")
        }
    }

    private func applyAction(mode: Mode, title: String) {
        let accent = AppSettings.shared.themeStyle.accentColor
        var config = UIButton.Configuration.plain()
        config.contentInsets = .zero
        switch mode {
        case .add:
            config.image = UIImage(
                systemName: "plus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            )
            actionButton.tintColor = accent
            actionButton.backgroundColor = accent.withAlphaComponent(0.12)
            actionButton.accessibilityLabel = String(localized: "home.category_manager.add_hint")
            actionButton.accessibilityValue = title
        case .remove:
            config.image = UIImage(
                systemName: "minus",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            )
            actionButton.tintColor = .systemRed
            actionButton.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
            actionButton.accessibilityLabel = String(localized: "home.category_manager.remove_hint")
            actionButton.accessibilityValue = title
        }
        actionButton.configuration = config
        actionButton.layer.cornerRadius = 14
        actionButton.layer.cornerCurve = .continuous
    }

    @objc private func actionTapped() {
        onActionTapped?()
    }
}
