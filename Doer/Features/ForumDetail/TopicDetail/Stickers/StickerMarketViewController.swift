import SDWebImage
import UIKit

final class StickerMarketViewController: UIViewController {
    var onSubscriptionsChanged: (() -> Void)?

    private var allGroups: [StickerGroup] = []
    private var topics: [StickerMarketTopic] = []
    private var subscribed = Set(StickerMarketStore.shared.subscribedGroupIds())
    private var selectedCategoryId = StickerMarketFilterPolicy.allCategoryId
    private var searchQuery = ""

    private var visibleGroups: [StickerGroup] {
        StickerMarketFilterPolicy.filtered(
            groups: allGroups,
            categoryId: selectedCategoryId,
            query: searchQuery
        )
    }

    private let searchBar: UISearchBar = {
        let bar = UISearchBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.placeholder = String(localized: "sticker.market.search", defaultValue: "搜索表情包")
        bar.searchBarStyle = .minimal
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        return bar
    }()

    private let categoryScroll: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = true
        return scroll
    }()

    private let categoryStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.dataSource = self
        tv.delegate = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tv.keyboardDismissMode = .onDrag
        return tv
    }()

    private let loading = UIActivityIndicatorView(style: .medium)
    private let errorLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "sticker.market.title", defaultValue: "表情包市场")
        view.backgroundColor = .systemGroupedBackground
        searchBar.delegate = self
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.done", defaultValue: "完成"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "sticker.market.base_url", defaultValue: "市场地址"),
            style: .plain,
            target: self,
            action: #selector(editBaseURL)
        )

        loading.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)
        view.addSubview(categoryScroll)
        categoryScroll.addSubview(categoryStack)
        view.addSubview(tableView)
        view.addSubview(loading)
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            categoryScroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            categoryScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            categoryScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            categoryScroll.heightAnchor.constraint(equalToConstant: 44),

            categoryStack.topAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.topAnchor, constant: 4),
            categoryStack.bottomAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.bottomAnchor, constant: -8),
            categoryStack.leadingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.leadingAnchor, constant: 16),
            categoryStack.trailingAnchor.constraint(equalTo: categoryScroll.contentLayoutGuide.trailingAnchor, constant: -16),
            categoryStack.heightAnchor.constraint(equalTo: categoryScroll.frameLayoutGuide.heightAnchor, constant: -12),

            tableView.topAnchor.constraint(equalTo: categoryScroll.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loading.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loading.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        loadGroups()
    }

    private func loadGroups() {
        loading.startAnimating()
        errorLabel.isHidden = true
        Task {
            do {
                let index = try await StickerMarketStore.shared.fetchIndex()
                let groups = try await StickerMarketStore.shared.fetchAllGroups()
                await MainActor.run {
                    self.loading.stopAnimating()
                    self.topics = index.displayTopics
                    self.allGroups = groups
                    self.rebuildCategoryChips()
                    self.reloadVisible()
                }
            } catch {
                await MainActor.run {
                    self.loading.stopAnimating()
                    self.errorLabel.text = error.localizedDescription
                    self.errorLabel.isHidden = false
                }
            }
        }
    }

    private func reloadVisible() {
        tableView.reloadData()
        let empty = visibleGroups.isEmpty
        if empty {
            if allGroups.isEmpty {
                errorLabel.text = String(localized: "sticker.market.empty", defaultValue: "市场暂无表情包")
            } else {
                errorLabel.text = String(localized: "sticker.market.search.empty", defaultValue: "没有匹配的表情包")
            }
        }
        errorLabel.isHidden = !empty
    }

    private func rebuildCategoryChips() {
        categoryStack.arrangedSubviews.forEach { view in
            categoryStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for topic in topics {
            let button = makeCategoryChip(topic)
            categoryStack.addArrangedSubview(button)
        }
        categoryScroll.isHidden = topics.count < 2
    }

    private func makeCategoryChip(_ topic: StickerMarketTopic) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        config.title = topic.label
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .semibold)
            return outgoing
        }
        let selected = topic.id == selectedCategoryId || (topic.isAll && selectedCategoryId == StickerMarketFilterPolicy.allCategoryId)
        config.baseBackgroundColor = selected
            ? AppSettings.shared.themeStyle.accentColor
            : UIColor.secondarySystemFill
        config.baseForegroundColor = selected ? .white : .label
        let button = UIButton(configuration: config)
        button.tag = topics.firstIndex(where: { $0.id == topic.id }) ?? 0
        button.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
        return button
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard topics.indices.contains(sender.tag) else { return }
        selectedCategoryId = topics[sender.tag].id
        rebuildCategoryChips()
        reloadVisible()
    }

    @objc private func doneTapped() {
        onSubscriptionsChanged?()
        dismiss(animated: true)
    }

    @objc private func editBaseURL() {
        let alert = UIAlertController(
            title: String(localized: "sticker.market.base_url", defaultValue: "市场地址"),
            message: String(localized: "sticker.market.base_url_message", defaultValue: "修改后会清空市场缓存"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = StickerMarketStore.shared.baseURL
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "sticker.market.reset_default", defaultValue: "恢复默认"), style: .destructive) { [weak self] _ in
            StickerMarketStore.shared.resetBaseURL()
            self?.loadGroups()
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.save", defaultValue: "保存"), style: .default) { [weak self] _ in
            let value = alert.textFields?.first?.text ?? ""
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            StickerMarketStore.shared.setBaseURL(value)
            self?.loadGroups()
        })
        present(alert, animated: true)
    }
}

extension StickerMarketViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchQuery = searchText
        reloadVisible()
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}

extension StickerMarketViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleGroups.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let group = visibleGroups[indexPath.row]
        content.text = group.name
        content.secondaryText = "\(group.emojiCount) " + String(localized: "sticker.market.count_suffix", defaultValue: "个表情")
        if let url = URL(string: group.icon) {
            content.image = UIImage(systemName: "face.smiling")
            SDWebImageManager.shared.loadImage(with: url, options: [], progress: nil) { image, _, _, _, _, _ in
                Task { @MainActor in
                    guard tableView.cellForRow(at: indexPath) != nil else { return }
                    var updated = cell.defaultContentConfiguration()
                    updated.text = group.name
                    updated.secondaryText = content.secondaryText
                    updated.image = image ?? UIImage(systemName: "face.smiling")
                    updated.imageProperties.maximumSize = CGSize(width: 36, height: 36)
                    cell.contentConfiguration = updated
                }
            }
        } else {
            content.image = UIImage(systemName: "face.smiling")
        }
        content.imageProperties.maximumSize = CGSize(width: 36, height: 36)
        cell.contentConfiguration = content
        let isOn = subscribed.contains(group.id)
        cell.accessoryType = isOn ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let group = visibleGroups[indexPath.row]
        if subscribed.contains(group.id) {
            subscribed.remove(group.id)
            StickerMarketStore.shared.unsubscribe(group.id)
        } else {
            subscribed.insert(group.id)
            StickerMarketStore.shared.subscribe(group.id)
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}
