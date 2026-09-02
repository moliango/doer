import UIKit

final class ProfileStatsEditorViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate {
    var onChange: ((MeStatsConfiguration) -> Void)?

    private enum Section: Int, CaseIterable {
        case layout
        case visible
        case hidden
    }

    private var configuration: MeStatsConfiguration
    private let previewItems: [MeStatItem]
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(configuration: MeStatsConfiguration, previewItems: [MeStatItem] = []) {
        self.configuration = configuration
        self.previewItems = previewItems
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "me.stats.customize")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "settings.bottom_bar.restore_default", defaultValue: "恢复默认"),
            style: .plain,
            target: self,
            action: #selector(resetTapped)
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

    private func currentPreviewItems() -> [MeStatItem] {
        let values = Dictionary(uniqueKeysWithValues: previewItems.map { ($0.type, $0) })
        return configuration.orderedMetrics.map { type in
            values[type] ?? MeStatItem(type: type, valueText: "—")
        }
    }

    private func reloadHeader() {
        let previewCanvas = MeStatsLayoutCanvas()
        previewCanvas.configure(items: currentPreviewItems(), layout: configuration.layout)
        let hero = MeCustomizeEditorChrome.makeHeroCard(
            eyebrow: String(localized: "me.stats.title"),
            title: String(
                format: String(localized: "me.customize.shown_count_format", defaultValue: "已显示 %d 项"),
                configuration.orderedMetrics.count
            ),
            subtitle: String(localized: "me.stats.hero.help", defaultValue: "长按拖动调整顺序，至少保留两个项目。布局会立刻作用到统计卡片。"),
            preview: previewCanvas
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

    private var visibleMetrics: [MeStatType] { configuration.orderedMetrics }
    private var hiddenMetrics: [MeStatType] { configuration.hiddenMetrics }

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .layout: return 1
        case .visible: return visibleMetrics.count
        case .hidden: return max(hiddenMetrics.count, 1)
        case .none: return 0
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch Section(rawValue: section) {
        case .layout:
            return MeCustomizeEditorChrome.makeTableSectionHeader(
                title: String(localized: "me.stats.layout", defaultValue: "展示布局"),
                symbolName: "rectangle.3.group.fill"
            )
        case .visible:
            return MeCustomizeEditorChrome.makeTableSectionHeader(
                title: String(localized: "me.stats.visible", defaultValue: "显示在卡片"),
                symbolName: "chart.bar.fill"
            )
        case .hidden:
            return MeCustomizeEditorChrome.makeTableSectionHeader(
                title: String(localized: "me.stats.hidden", defaultValue: "未显示"),
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
        case .layout:
            host.display(makeLayoutRow())
        case .visible:
            guard visibleMetrics.indices.contains(indexPath.row) else { return host }
            let metric = visibleMetrics[indexPath.row]
            host.display(
                MeCustomizeEditorChrome.makeItemRow(
                    title: metric.title,
                    subtitle: String(localized: "me.stats.item.visible", defaultValue: "显示在统计卡片"),
                    symbolName: metric.symbolName,
                    tintColor: metric.tintColor,
                    accessory: MeCustomizeEditorChrome.makeVisibleAccessory(
                        canHide: visibleMetrics.count > 2,
                        onHide: { [weak self] in self?.hideMetric(metric) }
                    )
                )
            )
            host.accessibilityCustomActions = moveActions(at: indexPath.row)
        case .hidden:
            if hiddenMetrics.isEmpty {
                host.display(
                    MeCustomizeEditorChrome.makeInfoCard(
                        text: String(localized: "me.stats.hidden_empty", defaultValue: "全部统计项目都已显示。")
                    )
                )
            } else if hiddenMetrics.indices.contains(indexPath.row) {
                let metric = hiddenMetrics[indexPath.row]
                host.display(
                    MeCustomizeEditorChrome.makeItemRow(
                        title: metric.title,
                        subtitle: String(localized: "me.stats.item.hidden", defaultValue: "点加号加回卡片"),
                        symbolName: metric.symbolName,
                        tintColor: metric.tintColor,
                        accessory: MeCustomizeEditorChrome.makeRestoreAccessory { [weak self] in
                            self?.showMetric(metric)
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
        Section(rawValue: indexPath.section) == .visible && visibleMetrics.count > 1
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
              visibleMetrics.indices.contains(indexPath.row)
        else { return [] }
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = visibleMetrics[indexPath.row]
        return [item]
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        guard session.localDragSession != nil,
              destinationIndexPath?.section == Section.visible.rawValue
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

    private func makeLayoutRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually
        for layout in MeStatsLayout.allCases {
            let option = MeStatsLayoutOptionView(layout: layout)
            option.apply(selected: configuration.layout == layout)
            option.addAction(UIAction { [weak self] _ in
                self?.selectLayout(layout)
            }, for: .touchUpInside)
            row.addArrangedSubview(option)
        }
        return row
    }

    private func moveActions(at index: Int) -> [UIAccessibilityCustomAction] {
        var actions: [UIAccessibilityCustomAction] = []
        if index > 0 {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "me.customize.move_up", defaultValue: "上移")
            ) { [weak self] _ in
                self?.moveMetric(at: index, by: -1)
                return true
            })
        }
        if index < visibleMetrics.count - 1 {
            actions.append(UIAccessibilityCustomAction(
                name: String(localized: "me.customize.move_down", defaultValue: "下移")
            ) { [weak self] _ in
                self?.moveMetric(at: index, by: 1)
                return true
            })
        }
        return actions
    }

    private func selectLayout(_ layout: MeStatsLayout) {
        guard configuration.layout != layout else { return }
        configuration.layout = layout
        publish()
        reloadHeader()
        tableView.reloadSections(IndexSet(integer: Section.layout.rawValue), with: .none)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func moveMetric(at index: Int, by delta: Int) {
        configuration.moveMetric(at: index, by: delta)
        publishAndReload()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func moveVisible(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath.section == Section.visible.rawValue,
              destinationIndexPath.section == Section.visible.rawValue
        else {
            tableView.reloadData()
            return
        }
        configuration.moveMetric(from: sourceIndexPath.row, to: destinationIndexPath.row)
        publish()
        reloadHeader()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func hideMetric(_ metric: MeStatType) {
        guard configuration.hideMetric(metric) else {
            let alert = UIAlertController(
                title: nil,
                message: String(localized: "me.stats.minimum_two", defaultValue: "至少保留两个统计项目。"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
            present(alert, animated: true)
            return
        }
        publishAndReload()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func showMetric(_ metric: MeStatType) {
        configuration.showMetric(metric)
        publishAndReload()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @objc private func resetTapped() {
        configuration = MeStatsConfiguration(
            orderedMetrics: [.daysVisited, .postCount, .likesReceived, .topicCount],
            layout: .grid
        )
        publishAndReload()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func publish() {
        onChange?(configuration)
    }

    private func publishAndReload() {
        publish()
        reloadHeader()
        tableView.reloadData()
    }

    private func canMoveRowAt(_ tableView: UITableView, indexPath: IndexPath) -> Bool {
        self.tableView(tableView, canMoveRowAt: indexPath)
    }
}
