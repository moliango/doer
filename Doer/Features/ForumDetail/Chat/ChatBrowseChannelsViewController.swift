import UIKit

/// Browse open public chat channels and join ones that are not yet followed.
final class ChatBrowseChannelsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    var onOpenChannel: ((DiscourseChatChannel) -> Void)?

    private let api: DiscourseAPI
    private let joinedIds: Set<Int>
    private var channels: [DiscourseChatChannel] = []
    private var joining = Set<Int>()
    private var locallyJoined = Set<Int>()
    private var searchTask: Task<Void, Never>?
    private var isLoading = false

    private let searchBar: UISearchBar = {
        let bar = UISearchBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.placeholder = String(localized: "chat.browse.search", defaultValue: "搜索频道")
        bar.searchBarStyle = .minimal
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        return bar
    }()

    private let tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.keyboardDismissMode = .onDrag
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

    init(api: DiscourseAPI, joinedChannelIds: [Int] = []) {
        self.api = api
        self.joinedIds = Set(joinedChannelIds)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "chat.browse.title", defaultValue: "浏览频道")
        view.backgroundColor = .systemGroupedBackground
        searchBar.delegate = self
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(searchBar)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        Task { await load(filter: nil) }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled, let self else { return }
            let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            await self.load(filter: term.isEmpty ? nil : term)
        }
    }

    private func load(filter: String?) async {
        isLoading = true
        emptyLabel.isHidden = true
        do {
            channels = try await api.browseChatChannels(filter: filter)
        } catch {
            channels = []
            emptyLabel.isHidden = false
            emptyLabel.text = error.localizedDescription
        }
        isLoading = false
        tableView.reloadData()
        if channels.isEmpty, emptyLabel.isHidden {
            emptyLabel.isHidden = false
            emptyLabel.text = String(localized: "chat.browse.empty", defaultValue: "没有可加入的频道")
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        channels.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let channel = channels[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = channel.displayTitle
        content.secondaryText = channel.chatable?.name
        cell.contentConfiguration = content
        if isFollowing(channel) {
            cell.accessoryType = .disclosureIndicator
            cell.accessoryView = nil
        } else {
            let button = UIButton(type: .system)
            button.setTitle(String(localized: "chat.browse.join", defaultValue: "加入"), for: .normal)
            button.sizeToFit()
            button.tag = channel.id
            button.addTarget(self, action: #selector(joinTapped(_:)), for: .touchUpInside)
            button.isEnabled = !joining.contains(channel.id)
            cell.accessoryView = button
            cell.accessoryType = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let channel = channels[indexPath.row]
        if isFollowing(channel) {
            onOpenChannel?(channel)
        } else {
            Task { await join(channel) }
        }
    }

    @objc private func joinTapped(_ sender: UIButton) {
        guard let channel = channels.first(where: { $0.id == sender.tag }) else { return }
        Task { await join(channel) }
    }

    private func isFollowing(_ channel: DiscourseChatChannel) -> Bool {
        locallyJoined.contains(channel.id) || joinedIds.contains(channel.id) || channel.isFollowing
    }

    private func join(_ channel: DiscourseChatChannel) async {
        guard !joining.contains(channel.id) else { return }
        joining.insert(channel.id)
        tableView.reloadData()
        do {
            try await api.joinChatChannel(channelId: channel.id)
            locallyJoined.insert(channel.id)
            joining.remove(channel.id)
            tableView.reloadData()
            onOpenChannel?(channel)
        } catch {
            joining.remove(channel.id)
            tableView.reloadData()
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }
}
