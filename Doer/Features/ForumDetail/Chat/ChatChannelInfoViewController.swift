import SDWebImage
import UIKit

/// Channel settings + members, matching Discourse Chat's info sheet.
final class ChatChannelInfoViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onChannelUpdated: ((DiscourseChatChannel) -> Void)?
    var onLeftChannel: (() -> Void)?

    private let api: DiscourseAPI
    private var channel: DiscourseChatChannel
    private var members: [DiscourseChatChannelMember] = []
    private var selectedPane: Pane = .settings
    private var isBusy = false

    private enum Pane: Int {
        case settings
        case members
    }

    private let segmented: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "chat.info.settings", defaultValue: "设置"),
            String(localized: "chat.info.members", defaultValue: "成员"),
        ])
        control.selectedSegmentIndex = 0
        control.translatesAutoresizingMaskIntoConstraints = false
        return control
    }()

    private let tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.register(ChatChannelMemberCell.self, forCellReuseIdentifier: ChatChannelMemberCell.reuseID)
        return table
    }()

    init(api: DiscourseAPI, channel: DiscourseChatChannel) {
        self.api = api
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "chat.info.title", defaultValue: "频道信息")
        view.backgroundColor = .systemGroupedBackground
        segmented.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(segmented)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        Task { await reload() }
    }

    @objc private func tabChanged() {
        selectedPane = Pane(rawValue: segmented.selectedSegmentIndex) ?? .settings
        tableView.reloadData()
    }

    private func reload() async {
        do {
            channel = try await api.fetchChatChannel(channelId: channel.id)
            onChannelUpdated?(channel)
            members = try await api.fetchChatChannelMembers(channelId: channel.id)
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
        tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        selectedPane == .settings ? 3 : 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch selectedPane {
        case .settings:
            switch section {
            case 0: return 1
            case 1: return 3
            default: return 1
            }
        case .members:
            return members.count + (channel.isGroupDm || channel.isDirectMessage ? 1 : 0)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard selectedPane == .settings else { return nil }
        switch section {
        case 0: return String(localized: "chat.info.title_section", defaultValue: "标题")
        case 1: return String(localized: "chat.info.settings", defaultValue: "设置")
        default: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch selectedPane {
        case .settings:
            return settingsCell(at: indexPath)
        case .members:
            return memberCell(at: indexPath)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch selectedPane {
        case .settings:
            if indexPath.section == 0 { editTitle() }
            if indexPath.section == 1, indexPath.row == 1 { pickNotificationLevel() }
            if indexPath.section == 2 { leaveChannel() }
        case .members:
            if indexPath.row == 0, channel.isGroupDm || channel.isDirectMessage {
                addMembers()
                return
            }
            let member = members[memberIndex(for: indexPath)]
            if let username = member.user?.username, !username.isEmpty {
                navigationController?.pushViewController(
                    UserProfileViewController(api: api, username: username),
                    animated: true
                )
            }
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard selectedPane == .members, channel.canRemoveMembers else { return nil }
        let offset = (channel.isGroupDm || channel.isDirectMessage) ? 1 : 0
        guard indexPath.row >= offset else { return nil }
        let member = members[indexPath.row - offset]
        guard let userId = member.user?.id else { return nil }
        let me = AuthManager.shared.username(for: api.baseURL)?.lowercased()
        if member.username.lowercased() == me { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "pm.remove", defaultValue: "移除")) { [weak self] _, _, done in
            Task { await self?.removeMember(userId: userId); done(true) }
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func settingsCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        if indexPath.section == 0 {
            content.text = channel.displayTitle
            if channel.isGroupDm {
                cell.accessoryType = .disclosureIndicator
                let edit = UILabel()
                edit.text = String(localized: "chat.info.edit", defaultValue: "编辑")
                edit.textColor = .secondaryLabel
                edit.font = .preferredFont(forTextStyle: .body)
                cell.accessoryView = edit
            } else {
                cell.selectionStyle = .none
            }
        } else if indexPath.section == 1 {
            switch indexPath.row {
            case 0:
                content.text = String(localized: "chat.info.mute", defaultValue: "将频道设为免打扰")
                let toggle = UISwitch()
                toggle.isOn = channel.isMuted
                toggle.addAction(UIAction { [weak self] _ in
                    Task { await self?.setMuted(toggle.isOn) }
                }, for: .valueChanged)
                cell.accessoryView = toggle
                cell.selectionStyle = .none
            case 1:
                content.text = String(localized: "chat.info.notify", defaultValue: "发送推送通知")
                content.secondaryText = ChatNotificationLevel.resolved(channel.notificationLevel).title
                cell.accessoryType = .disclosureIndicator
            default:
                content.text = String(localized: "chat.info.threading", defaultValue: "消息串")
                content.secondaryText = String(
                    localized: "chat.info.threading.subtitle",
                    defaultValue: "启用后，回复会进入独立对话"
                )
                let toggle = UISwitch()
                toggle.isOn = channel.threadingEnabled
                toggle.addAction(UIAction { [weak self] _ in
                    Task { await self?.setThreading(toggle.isOn) }
                }, for: .valueChanged)
                cell.accessoryView = toggle
                cell.selectionStyle = .none
            }
        } else {
            content.text = String(localized: "chat.info.leave", defaultValue: "退出频道")
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    private func memberCell(at indexPath: IndexPath) -> UITableViewCell {
        if (channel.isGroupDm || channel.isDirectMessage), indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "chat.members.add", defaultValue: "添加成员")
            content.image = UIImage(systemName: "person.badge.plus")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatChannelMemberCell.reuseID,
            for: indexPath
        ) as? ChatChannelMemberCell ?? ChatChannelMemberCell()
        cell.configure(member: members[memberIndex(for: indexPath)], baseURL: api.baseURL)
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func memberIndex(for indexPath: IndexPath) -> Int {
        let offset = (channel.isGroupDm || channel.isDirectMessage) ? 1 : 0
        return indexPath.row - offset
    }

    private func editTitle() {
        guard channel.isGroupDm else { return }
        let alert = UIAlertController(
            title: String(localized: "chat.info.rename", defaultValue: "编辑标题"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.text = self?.channel.title ?? self?.channel.displayTitle
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.done", defaultValue: "完成"), style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else { return }
            Task { await self?.rename(name) }
        })
        present(alert, animated: true)
    }

    private func pickNotificationLevel() {
        let sheet = UIAlertController(
            title: String(localized: "chat.info.notify", defaultValue: "发送推送通知"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for level in ChatNotificationLevel.allCases {
            let mark = channel.notificationLevel == level.rawValue ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: mark + level.title, style: .default) { [weak self] _ in
                Task { await self?.setNotificationLevel(level) }
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    private func addMembers() {
        let picker = ChatNewConversationViewController(api: api)
        picker.onPickedUsers = { [weak self] users in
            Task { await self?.invite(users.map(\.username)) }
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    private func leaveChannel() {
        let alert = UIAlertController(
            title: String(localized: "chat.info.leave", defaultValue: "退出频道"),
            message: String(localized: "chat.info.leave.confirm", defaultValue: "退出后，有新消息时会话会再次出现。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "chat.info.leave", defaultValue: "退出频道"), style: .destructive) { [weak self] _ in
            Task { await self?.performLeave() }
        })
        present(alert, animated: true)
    }

    private func rename(_ name: String) async {
        guard !isBusy else { return }
        isBusy = true
        do {
            try await api.updateChatChannel(channelId: channel.id, name: name)
            channel.title = name
            onChannelUpdated?(channel)
            tableView.reloadData()
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
        isBusy = false
    }

    private func setMuted(_ muted: Bool) async {
        do {
            try await api.updateChatChannelNotifications(channelId: channel.id, muted: muted)
            channel.currentUserMembership?.muted = muted
            onChannelUpdated?(channel)
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
            tableView.reloadData()
        }
    }

    private func setNotificationLevel(_ level: ChatNotificationLevel) async {
        do {
            try await api.updateChatChannelNotifications(
                channelId: channel.id,
                notificationLevel: level.rawValue
            )
            channel.currentUserMembership?.notificationLevel = level.rawValue
            onChannelUpdated?(channel)
            tableView.reloadData()
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }

    private func setThreading(_ enabled: Bool) async {
        do {
            try await api.updateChatChannel(channelId: channel.id, threadingEnabled: enabled)
            channel.threadingEnabled = enabled
            onChannelUpdated?(channel)
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
            tableView.reloadData()
        }
    }

    private func invite(_ usernames: [String]) async {
        do {
            try await api.addChatChannelMembers(channelId: channel.id, usernames: usernames)
            await reload()
            DoerFeedback.presentToast(
                String(localized: "chat.members.added", defaultValue: "已添加成员"),
                on: self
            )
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }

    private func removeMember(userId: Int) async {
        do {
            try await api.removeChatChannelMember(channelId: channel.id, userId: userId)
            members.removeAll { $0.user?.id == userId }
            tableView.reloadData()
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }

    private func performLeave() async {
        do {
            try await api.leaveChatChannel(channelId: channel.id)
            onLeftChannel?()
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }
}

private final class ChatChannelMemberCell: UITableViewCell {
    static let reuseID = "ChatChannelMemberCell"

    private let avatarView: UIImageView = {
        let view = UIImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 16
        view.backgroundColor = .tertiarySystemFill
        return view
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .medium)
        return label
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(usernameLabel)
        NSLayoutConstraint.activate([
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 32),
            avatarView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            usernameLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            usernameLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            usernameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
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
    }

    func configure(member: DiscourseChatChannelMember, baseURL: String) {
        nameLabel.text = member.displayName
        usernameLabel.text = member.username.isEmpty ? nil : "@\(member.username)"
        AvatarImageLoader.setImage(
            on: avatarView,
            template: member.user?.avatarTemplate,
            baseURL: baseURL,
            userId: member.user?.id,
            size: AvatarImageLoader.primaryAvatarPixelSize,
            placeholder: AvatarImageLoader.defaultPlaceholder
        )
    }
}
