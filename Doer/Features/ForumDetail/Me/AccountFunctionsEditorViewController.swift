import UIKit

final class AccountFunctionsEditorViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate {
    private enum Section: Int, CaseIterable {
        case visible
        case hidden
    }

    private let preferences = MeAccountFunctionPreferences()
    private var visibleFunctions: [MeAccountFunction] = []
    private var hiddenFunctions: [MeAccountFunction] = []
    private let tableView = UITableView(frame: .zero, style: .plain)

    init() {
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "me.account_functions.customize", defaultValue: "自定义账号功能")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "settings.bottom_bar.restore_default", defaultValue: "恢复默认"),
            style: .plain,
            target: self,
            action: #selector(restoreDefaultTapped)
        )
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.register(MeCustomizeHostCell.self, forCellReuseIdentifier: MeCustomizeHostCell.reuseIdentifier)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reloadFromPreferences()
        applyTheme()
        reloadHeader()
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableInteractiveBackSwipe()
        applyTheme()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reloadHeaderIfNeeded()
    }

    private func applyTheme() {
        view.backgroundColor = MeCustomizeEditorChrome.screenBackground
        view.tintColor = MeCustomizeEditorChrome.accentColor
        MeCustomizeEditorChrome.applyListStyle(to: tableView)
    }

    private func reloadFromPreferences() {
        visibleFunctions = preferences.visibleFunctions
        hiddenFunctions = preferences.hiddenFunctions
    }

    private func reloadHeader() {
        let chips = visibleFunctions.map {
            MeCustomizeEditorChrome.makeChip(title: $0.title, symbolName: $0.symbolName, tintColor: $0.tintColor)
        }
        let preview: UIView
        if chips.isEmpty {
            preview = MeCustomizeEditorChrome.makeInfoCard(
                text: String(localized: "me.account_functions.all_hidden", defaultValue: "已隐藏全部账号功能，「我的」页不会显示账号功能列表。")
            )
        } else {
            preview = MeCustomizeEditorChrome.makeChipScroller(chips)
        }
        let hero = MeCustomizeEditorChrome.makeHeroCard(
            eyebrow: String(localized: "me.actions.title"),
            title: String(
                format: String(localized: "me.customize.shown_count_format", defaultValue: "已显示 %d 项"),
                visibleFunctions.count
            ),
            subtitle: String(localized: "me.account_functions.hero.help", defaultValue: "隐藏的入口不会出现在「我的」页；长按拖动调整显示顺序。"),
            preview: preview
        )
        hero.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            hero.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            hero.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            hero.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        tableView.tableHeaderView = MeCustomizeEditorChrome.sizedHeader(container, width: tableView.bounds.width)
    }

    private func reloadHeaderIfNeeded() {
        guard let header = tableView.tableHeaderView else { return }
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let sized = MeCustomizeEditorChrome.sizedHeader(header, width: width)
        if abs(sized.frame.height - header.frame.height) > 0.5 {
            tableView.tableHeaderView = sized
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .visible: return max(visibleFunctions.count, 1)
        case .hidden: return max(hiddenFunctions.count, 1)
        case .none: return 0
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch Section(rawValue: section) {
        case .visible:
            return MeCustomizeEditorChrome.makeTableSectionHeader(
                title: String(localized: "me.account_functions.visible", defaultValue: "显示"),
                symbolName: "rectangle.stack.fill"
            )
        case .hidden:
            return MeCustomizeEditorChrome.makeTableSectionHeader(
                title: String(localized: "me.account_functions.hidden", defaultValue: "已隐藏"),
                symbolName: "eye.slash.fill"
            )
        case .none:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MeCustomizeHostCell.reuseIdentifier, for: indexPath)
        guard let host = cell as? MeCustomizeHostCell else { return cell }
        switch Section(rawValue: indexPath.section) {
        case .visible:
            if visibleFunctions.isEmpty {
                host.display(
                    MeCustomizeEditorChrome.makeInfoCard(
                        text: String(localized: "me.account_functions.all_hidden", defaultValue: "已隐藏全部账号功能，「我的」页不会显示账号功能列表。")
                    )
                )
            } else if visibleFunctions.indices.contains(indexPath.row) {
                let function = visibleFunctions[indexPath.row]
                host.display(
                    MeCustomizeEditorChrome.makeItemRow(
                        title: function.title,
                        subtitle: function.subtitle,
                        symbolName: function.symbolName,
                        tintColor: function.tintColor,
                        accessory: MeCustomizeEditorChrome.makeVisibleAccessory(
                            onHide: { [weak self] in self?.hideFunction(function) }
                        )
                    )
                )
                host.accessibilityCustomActions = moveActions(at: indexPath.row)
            }
        case .hidden:
            if hiddenFunctions.isEmpty {
                host.display(
                    MeCustomizeEditorChrome.makeInfoCard(
                        text: String(localized: "me.account_functions.hidden_empty", defaultValue: "没有隐藏的账号功能。")
                    )
                )
            } else if hiddenFunctions.indices.contains(indexPath.row) {
                let function = hiddenFunctions[indexPath.row]
                host.display(
                    MeCustomizeEditorChrome.makeItemRow(
                        title: function.title,
                        subtitle: String(localized: "me.account_functions.item_hidden", defaultValue: "已隐藏"),
                        symbolName: function.symbolName,
                        tintColor: function.tintColor,
                        accessory: MeCustomizeEditorChrome.makeRestoreAccessory { [weak self] in
                            self?.restoreFunction(function)
                        },
                        dimmed: true
                    )
                )
            }
        case .none:
            break
        }
        return host
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .visible && visibleFunctions.count > 1
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        moveVisible(from: sourceIndexPath, to: destinationIndexPath)
    }

    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        proposedDestinationIndexPath.section == Section.visible.rawValue ? proposedDestinationIndexPath : sourceIndexPath
    }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard canMoveRowAt(tableView, indexPath: indexPath),
              visibleFunctions.indices.contains(indexPath.row)
        else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = visibleFunctions[indexPath.row]
        return [item]
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard session.localDragSession != nil,
              destinationIndexPath?.section == Section.visible.rawValue,
              !visibleFunctions.isEmpty
        else {
            return UITableViewDropProposal(operation: .cancel)
        }
        return UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let destination = coordinator.destinationIndexPath,
              destination.section == Section.visible.rawValue,
              let item = coordinator.items.first,
              let source = item.sourceIndexPath
        else { return }
        tableView.performBatchUpdates {
            moveVisible(from: source, to: destination)
            tableView.moveRow(at: source, to: destination)
        }
        coordinator.drop(item.dragItem, toRowAt: destination)
    }

    private func moveActions(at index: Int) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "me.customize.move_up", defaultValue: "上移")
            ) { [weak self] _ in
                self?.moveFunction(at: index, by: -1)
                return true
            })
        }
        if index < visibleFunctions.count - 1 {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "me.customize.move_down", defaultValue: "下移")
            ) { [weak self] _ in
                self?.moveFunction(at: index, by: 1)
                return true
            })
        }
        return actions
    }

    private func moveFunction(at index: Int, by delta: Int) {
        let target = index + delta
        guard visibleFunctions.indices.contains(index),
              visibleFunctions.indices.contains(target) else { return }
        let function = visibleFunctions.remove(at: index)
        visibleFunctions.insert(function, at: target)
        persistAndReload()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func moveVisible(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.section == Section.visible.rawValue,
              destinationIndexPath.section == Section.visible.rawValue,
              visibleFunctions.indices.contains(sourceIndexPath.row)
        else {
            tableView.reloadData()
            return
        }
        let function = visibleFunctions.remove(at: sourceIndexPath.row)
        let destination = min(destinationIndexPath.row, visibleFunctions.count)
        visibleFunctions.insert(function, at: destination)
        persist()
        reloadHeader()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func hideFunction(_ function: MeAccountFunction) {
        guard let index = visibleFunctions.firstIndex(of: function) else { return }
        hiddenFunctions.append(visibleFunctions.remove(at: index))
        persistAndReload()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func restoreFunction(_ function: MeAccountFunction) {
        guard let index = hiddenFunctions.firstIndex(of: function) else { return }
        visibleFunctions.append(hiddenFunctions.remove(at: index))
        persistAndReload()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func restoreDefaultTapped() {
        preferences.reset()
        reloadFromPreferences()
        reloadHeader()
        tableView.reloadData()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func persist() {
        preferences.setVisibleFunctions(visibleFunctions)
        reloadFromPreferences()
    }

    private func persistAndReload() {
        persist()
        reloadHeader()
        tableView.reloadData()
    }

    private func canMoveRowAt(_ tableView: UITableView, indexPath: IndexPath) -> Bool {
        self.tableView(tableView, canMoveRowAt: indexPath)
    }
}
