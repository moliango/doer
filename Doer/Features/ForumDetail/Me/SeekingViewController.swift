import UIKit

/// Aggregated follow-stream for monitored users. Own navigation stack (pushed from Me).
final class SeekingViewController: ObservableViewController {
    private let api: DiscourseAPI
    private var usernames: [String]
    private var rows: [DiscourseUserAction] = []
    private var isLoading = false
    private var errorMessage: String?

    private let tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        return table
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    init(api: DiscourseAPI) {
        self.api = api
        self.usernames = SeekingStore.usernames(for: api.baseURL)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "seeking.title", defaultValue: "追觅")
        view.backgroundColor = AppSettings.shared.themeStyle.contentBackgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "seeking.row")
        tableView.refreshControl = UIRefreshControl()
        tableView.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addUser)
        )
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        Task { await load() }
    }

    override func updateUI() {
        tableView.reloadData()
        tableView.refreshControl?.endRefreshing()
        let empty = !isLoading && rows.isEmpty
        emptyLabel.isHidden = !empty
        if usernames.isEmpty {
            emptyLabel.text = String(localized: "seeking.empty.users", defaultValue: "添加要关注的用户，查看他们的发帖和回复")
        } else {
            emptyLabel.text = errorMessage ?? String(localized: "seeking.empty.feed", defaultValue: "暂无动态")
        }
    }

    @objc private func refresh() {
        Task { await load() }
    }

    @objc private func addUser() {
        let alert = UIAlertController(
            title: String(localized: "seeking.add", defaultValue: "添加用户"),
            message: String(localized: "seeking.add.hint", defaultValue: "输入用户名"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "username"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.add", defaultValue: "添加"), style: .default) { [weak self] _ in
            guard let self else { return }
            let name = alert.textFields?.first?.text ?? ""
            self.usernames = SeekingStore.add(name, for: self.api.baseURL)
            Task { await self.load() }
        })
        present(alert, animated: true)
    }

    private func load() async {
        guard !isLoading else { return }
        usernames = SeekingStore.usernames(for: api.baseURL)
        isLoading = true
        errorMessage = nil
        updateUI()
        guard !usernames.isEmpty else {
            rows = []
            isLoading = false
            updateUI()
            return
        }
        do {
            var combined: [DiscourseUserAction] = []
            for name in usernames {
                let page = try await api.fetchUserActions(username: name, filter: "4,5", offset: 0)
                combined.append(contentsOf: page)
            }
            combined.sort { lhs, rhs in
                (lhs.actingAt ?? lhs.createdAt ?? "") > (rhs.actingAt ?? rhs.createdAt ?? "")
            }
            rows = combined
        } catch {
            errorMessage = error.localizedDescription
            rows = []
        }
        isLoading = false
        updateUI()
    }
}

extension SeekingViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "seeking.row", for: indexPath)
        let action = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        let title = action.title.trimmingCharacters(in: .whitespacesAndNewlines)
        content.text = title.isEmpty ? (action.excerpt ?? "#\(action.topicId)") : title
        content.secondaryText = [
            action.username.map { "@\($0)" },
            (action.actingAt ?? action.createdAt).map(UserProfileFormatting.relativeDate),
        ].compactMap { $0 }.joined(separator: " · ")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let action = rows[indexPath.row]
        guard action.topicId > 0 else { return }
        let detail = TopicDetailFactory.make(
            api: api,
            topicId: action.topicId,
            initialFloor: action.postNumber,
            preferNested: AppSettings.shared.nestedReplyViewEnabled
        )
        navigationController?.pushViewController(detail, animated: true)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let username = rows[indexPath.row].username else { return nil }
        let forget = UIContextualAction(
            style: .destructive,
            title: String(localized: "seeking.remove", defaultValue: "取消监控")
        ) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.usernames = SeekingStore.remove(username, for: self.api.baseURL)
            Task { await self.load() }
            completion(true)
        }
        return UISwipeActionsConfiguration(actions: [forget])
    }
}
