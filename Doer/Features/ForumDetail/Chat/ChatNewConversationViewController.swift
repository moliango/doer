import SDWebImage
import UIKit

/// Search users and open / upsert a Discourse Chat DM (1:1 or group).
final class ChatNewConversationViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    var onCreated: ((DiscourseChatChannel) -> Void)?
    /// When set, confirm returns selected users instead of creating a channel.
    var onPickedUsers: (([DiscourseMentionUser]) -> Void)?

    private let api: DiscourseAPI
    private var results: [DiscourseMentionUser] = []
    private var selected: [DiscourseMentionUser] = []
    private var searchTask: Task<Void, Never>?
    private var isCreating = false

    private let searchBar: UISearchBar = {
        let bar = UISearchBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.placeholder = String(localized: "chat.new.search", defaultValue: "搜索用户")
        bar.searchBarStyle = .minimal
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        return bar
    }()

    private let selectedScroll: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        return scroll
    }()

    private let selectedStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        return stack
    }()

    private let tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(ChatNewConversationUserCell.self, forCellReuseIdentifier: ChatNewConversationUserCell.reuseID)
        table.keyboardDismissMode = .onDrag
        table.rowHeight = 56
        table.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        return table
    }()

    private var confirmItem: UIBarButtonItem?
    private var selectedHeight: NSLayoutConstraint?

    init(api: DiscourseAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = onPickedUsers == nil
            ? String(localized: "chat.new.title", defaultValue: "新建聊天")
            : String(localized: "chat.members.add", defaultValue: "添加成员")
        view.backgroundColor = .systemBackground
        searchBar.delegate = self
        tableView.dataSource = self
        tableView.delegate = self

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.cancel", defaultValue: "取消"),
            style: .plain,
            target: self,
            action: #selector(cancelTapped)
        )
        let confirm = UIBarButtonItem(
            title: confirmTitle,
            style: .done,
            target: self,
            action: #selector(confirmTapped)
        )
        confirm.isEnabled = false
        confirmItem = confirm
        navigationItem.rightBarButtonItem = confirm

        view.addSubview(searchBar)
        view.addSubview(selectedScroll)
        selectedScroll.addSubview(selectedStack)
        view.addSubview(tableView)
        let height = selectedScroll.heightAnchor.constraint(equalToConstant: 0)
        selectedHeight = height
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            selectedScroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            selectedScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectedScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,

            selectedStack.topAnchor.constraint(equalTo: selectedScroll.contentLayoutGuide.topAnchor, constant: 4),
            selectedStack.bottomAnchor.constraint(equalTo: selectedScroll.contentLayoutGuide.bottomAnchor, constant: -8),
            selectedStack.leadingAnchor.constraint(equalTo: selectedScroll.contentLayoutGuide.leadingAnchor, constant: 16),
            selectedStack.trailingAnchor.constraint(equalTo: selectedScroll.contentLayoutGuide.trailingAnchor, constant: -16),
            selectedStack.heightAnchor.constraint(equalTo: selectedScroll.frameLayoutGuide.heightAnchor, constant: -12),

            tableView.topAnchor.constraint(equalTo: selectedScroll.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        rebuildSelectedChips()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchBar.becomeFirstResponder()
    }

    private var confirmTitle: String {
        let count = selected.count
        if onPickedUsers != nil {
            return count > 0
                ? String(format: String(localized: "chat.members.add_count %lld", defaultValue: "添加（%lld）"), count)
                : String(localized: "chat.members.add", defaultValue: "添加成员")
        }
        if count > 1 {
            return String(format: String(localized: "chat.new.group %lld", defaultValue: "创建群聊（%lld）"), count)
        }
        return String(localized: "chat.new.start", defaultValue: "开始聊天")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchTask?.cancel()
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            results = []
            tableView.reloadData()
            return
        }
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                self.results = try await self.api.searchUsersForMention(term: term)
                self.tableView.reloadData()
            } catch {
                self.results = []
                self.tableView.reloadData()
            }
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        results.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatNewConversationUserCell.reuseID,
            for: indexPath
        ) as? ChatNewConversationUserCell ?? ChatNewConversationUserCell()
        let user = results[indexPath.row]
        cell.configure(user: user, baseURL: api.baseURL)
        cell.accessoryType = isSelected(user) ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        toggle(results[indexPath.row])
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    private func isSelected(_ user: DiscourseMentionUser) -> Bool {
        selected.contains { $0.username.compare(user.username, options: .caseInsensitive) == .orderedSame }
    }

    private func toggle(_ user: DiscourseMentionUser) {
        if let index = selected.firstIndex(where: {
            $0.username.compare(user.username, options: .caseInsensitive) == .orderedSame
        }) {
            selected.remove(at: index)
        } else {
            selected.append(user)
        }
        confirmItem?.title = confirmTitle
        confirmItem?.isEnabled = ChatDirectMessageCreatePolicy.canCreate(usernames: selected.map(\.username))
        rebuildSelectedChips()
    }

    private func rebuildSelectedChips() {
        selectedStack.arrangedSubviews.forEach {
            selectedStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        selectedHeight?.constant = selected.isEmpty ? 0 : 44
        for user in selected {
            selectedStack.addArrangedSubview(makeSelectedChip(user))
        }
    }

    private func makeSelectedChip(_ user: DiscourseMentionUser) -> UIView {
        let chip = UIControl()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.backgroundColor = .tertiarySystemFill
        chip.layer.cornerRadius = 16
        chip.layer.cornerCurve = .continuous
        chip.addAction(UIAction { [weak self] _ in
            self?.toggle(user)
            self?.tableView.reloadData()
        }, for: .touchUpInside)

        let avatar = UIImageView()
        avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.layer.cornerRadius = 12
        avatar.clipsToBounds = true
        avatar.contentMode = .scaleAspectFill
        avatar.backgroundColor = .secondarySystemFill
        AvatarImageLoader.setImage(
            on: avatar,
            template: user.avatarTemplate,
            baseURL: api.baseURL,
            size: AvatarImageLoader.primaryAvatarPixelSize,
            placeholder: AvatarImageLoader.defaultPlaceholder
        )

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.text = user.username

        let remove = UIImageView(image: UIImage(systemName: "xmark.circle.fill"))
        remove.translatesAutoresizingMaskIntoConstraints = false
        remove.tintColor = .secondaryLabel
        remove.setContentHuggingPriority(.required, for: .horizontal)

        chip.addSubview(avatar)
        chip.addSubview(label)
        chip.addSubview(remove)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 2),
            avatar.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 24),
            avatar.heightAnchor.constraint(equalToConstant: 24),
            chip.heightAnchor.constraint(equalToConstant: 32),

            label.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            remove.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4),
            remove.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
            remove.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 14),
            remove.heightAnchor.constraint(equalToConstant: 14),
        ])
        return chip
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func confirmTapped() {
        let names = selected.map(\.username)
        guard ChatDirectMessageCreatePolicy.canCreate(usernames: names), !isCreating else { return }
        if let onPickedUsers {
            let picked = selected
            dismiss(animated: true) {
                onPickedUsers(picked)
            }
            return
        }
        isCreating = true
        confirmItem?.isEnabled = false
        Task { @MainActor in
            do {
                let channel = try await api.createDirectMessageChannel(usernames: names, upsert: true)
                dismiss(animated: true) { [onCreated] in
                    onCreated?(channel)
                }
            } catch {
                isCreating = false
                confirmItem?.isEnabled = true
                DoerFeedback.presentToast(error.localizedDescription, on: self)
            }
        }
    }
}

private final class ChatNewConversationUserCell: UITableViewCell {
    static let reuseID = "ChatNewConversationUserCell"

    private let avatarView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 18
        view.backgroundColor = .tertiarySystemFill
        return view
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(avatarView)
        contentView.addSubview(usernameLabel)
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            usernameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            usernameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            usernameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            nameLabel.leadingAnchor.constraint(equalTo: usernameLabel.leadingAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: usernameLabel.bottomAnchor, constant: 2),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
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
        usernameLabel.text = nil
        nameLabel.text = nil
        nameLabel.isHidden = false
        accessoryType = .none
    }

    func configure(user: DiscourseMentionUser, baseURL: String) {
        usernameLabel.text = user.username
        let trimmedName = user.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedName.isEmpty || trimmedName.caseInsensitiveCompare(user.username) == .orderedSame {
            nameLabel.isHidden = true
            nameLabel.text = nil
        } else {
            nameLabel.isHidden = false
            nameLabel.text = trimmedName
        }
        AvatarImageLoader.setImage(
            on: avatarView,
            template: user.avatarTemplate,
            baseURL: baseURL,
            size: AvatarImageLoader.primaryAvatarPixelSize,
            placeholder: AvatarImageLoader.defaultPlaceholder
        )
    }
}
