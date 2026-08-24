import SDWebImage
/// FluxDo-style site chat: channel list + open room.
/// List chrome follows Home topic rows via `TopicListCellFactory` when WeChat/Telegram is active.
final class ChatChannelsViewController: ObservableViewController {
    private let api: DiscourseAPI
    private var channels: [DiscourseChatChannel] = []
    private var isLoading = false
    private var errorMessage: String?

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        TopicListCellFactory.registerCells(on: table)
        table.register(UITableViewCell.self, forCellReuseIdentifier: "chat.channel.standard")
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        table.refreshControl = UIRefreshControl()
        table.refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        return table
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.numberOfLines = 0
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .body)
        label.isHidden = true
        return label
    }()

    init(api: DiscourseAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(AppSettings.shared)
        title = String(localized: "chat.title", defaultValue: "站内聊天")
        applyTheme()
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        Task { await loadChannels() }
    }

    override func updateUI() {
        applyTheme()
        tableView.reloadData()
        tableView.refreshControl?.endRefreshing()
        if isLoading && channels.isEmpty {
            emptyLabel.isHidden = true
        } else if let errorMessage {
            emptyLabel.isHidden = false
            emptyLabel.text = errorMessage
        } else if channels.isEmpty {
            emptyLabel.isHidden = false
            emptyLabel.text = String(localized: "chat.empty", defaultValue: "暂无聊天频道（站点可能未开启 Chat）")
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func applyTheme() {
        let theme = AppSettings.shared.themeStyle
        view.backgroundColor = theme.topicListBackgroundColor
        tableView.backgroundColor = theme.topicListBackgroundColor
        tableView.estimatedRowHeight = TopicListCellFactory.estimatedRowHeight
        tableView.refreshControl?.tintColor = theme.accentColor
        view.tintColor = theme.accentColor
        emptyLabel.textColor = .secondaryLabel
    }

    @objc private func refresh() {
        Task { await loadChannels() }
    }

    private func loadChannels() async {
        isLoading = true
        errorMessage = nil
        updateUI()
        do {
            let response = try await api.fetchChatChannels()
            channels = response.all.sorted {
                ($0.unreadCount, $0.displayTitle) > ($1.unreadCount, $1.displayTitle)
            }
        } catch {
            errorMessage = error.localizedDescription
            channels = []
        }
        isLoading = false
        updateUI()
    }
}

extension ChatChannelsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        channels.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let channel = channels[indexPath.row]
        let layout = TopicListLayoutKind.current
        let time = channel.lastMessageSentAt.map { TopicCell.formatDate($0) }
        let badge: String? = channel.unreadCount > 0
            ? (channel.unreadCount > 99 ? "99+" : "\(channel.unreadCount)")
            : nil
        let avatarURL = channel.avatarURL(baseURL: api.baseURL)
        let item = TopicListSessionItem(
            title: channel.displayTitle,
            subtitle: badge != nil
                ? String(format: String(localized: "chat.unread_count", defaultValue: "%d 条未读"), channel.unreadCount)
                : (time ?? String(localized: "chat.channel_subtitle", defaultValue: "频道")),
            timeText: time,
            avatarURL: avatarURL,
            avatarTemplate: channel.avatarTemplate,
            isEmphasized: channel.unreadCount > 0,
            badgeText: badge,
            baseURL: api.baseURL,
            monogramText: channel.monogramLetter,
            monogramColor: channel.monogramColor,
            monogramForegroundColor: channel.monogramForegroundColor
        )
        // Always use session row chrome so channel icons load (standard fallback has no avatar).
        let rowLayout: TopicListLayoutKind = layout.usesChatSessionRows ? layout : .weChat
        return TopicListCellFactory.makeSessionCell(
            tableView: tableView,
            indexPath: indexPath,
            item: item,
            layout: rowLayout
        )
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let channel = channels[indexPath.row]
        navigationController?.pushViewController(
            ChatRoomViewController(api: api, channel: channel),
            animated: true
        )
    }
}

// MARK: - Chat room

final class ChatRoomViewController: ObservableViewController, UITableViewDataSource, UITableViewDelegate {
    private let api: DiscourseAPI
    private let channel: DiscourseChatChannel
    private var messages: [DiscourseChatMessage] = []
    private var isLoading = false
    private var isSending = false
    /// Keep the transcript pinned to the latest message (open, send, keyboard).
    private var pinsToLatestMessage = true
    private var currentUsername: String? {
        AuthManager.shared.username(for: api.baseURL)?.lowercased()
    }

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .plain)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.register(ChatBubbleCell.self, forCellReuseIdentifier: ChatBubbleCell.reuseIdentifier)
        table.keyboardDismissMode = .interactive
        table.separatorStyle = .none
        table.allowsSelection = false
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 88
        return table
    }()

    private let chatInputBar: WeChatChatInputBar = WeChatChatInputBar()
    private var chatInputBarBottomConstraint: NSLayoutConstraint?
    private var emojiStoreObserver: NSObjectProtocol?
    private var composerController: ChatRoomComposerController?
    private var pendingAttachments: [(id: Int, filename: String)] = []
    private var isUploadingAttachment = false
    private let attachmentBanner: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.contentHorizontalAlignment = .left
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        config.titleLineBreakMode = .byTruncatingTail
        button.configuration = config
        button.isHidden = true
        return button
    }()
    private var attachmentBannerHeight: NSLayoutConstraint?

    init(api: DiscourseAPI, channel: DiscourseChatChannel) {
        self.api = api
        self.channel = channel
        super.init(nibName: nil, bundle: nil)
        // Must be set before push for UIKit to hide the tab bar.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(AppSettings.shared)
        title = channel.displayTitle
        chatInputBar.onSend = { [weak self] text in
            self?.sendMessage(text)
        }
        let composer = ChatRoomComposerController(host: self, api: api)
        composer.onInsertText = { [weak self] text in
            self?.chatInputBar.insertText(text)
        }
        composer.onUploaded = { [weak self] id, filename in
            self?.appendPendingAttachment(id: id, filename: filename)
        }
        composer.onUploadStateChange = { [weak self] uploading in
            self?.isUploadingAttachment = uploading
            self?.chatInputBar.isComposerEnabled = !(self?.isSending == true || uploading)
        }
        composer.plusAnchor = { [weak self] in
            self?.chatInputBar.plusMenuAnchorView
        }
        composerController = composer
        chatInputBar.onPlus = { [weak self] in
            self?.composerController?.showMenu()
        }
        chatInputBar.onEmoji = { [weak self] in
            self?.presentEmojiPicker()
        }
        chatInputBar.onBeginEditing = { [weak self] in
            guard let self else { return }
            self.pinsToLatestMessage = true
            self.scrollToBottom(animated: false)
        }
        chatInputBar.onHeightChange = { [weak self] in
            guard let self else { return }
            self.view.layoutIfNeeded()
            if self.pinsToLatestMessage {
                self.scrollToBottom(animated: false)
            }
        }
        // Conversation UI owns the bottom chrome — hide host tab bar (WeChat-like).
        hidesBottomBarWhenPushed = true
        setupLayout()
        applyTheme()
        emojiStoreObserver = NotificationCenter.default.addObserver(
            forName: EmojiStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tableView.reloadData()
            }
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleMessageLongPress(_:)))
        tableView.addGestureRecognizer(longPress)
        Task {
            await api.loadOrFetchEmojiMap()
            await loadMessages()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            if let emojiStoreObserver {
                NotificationCenter.default.removeObserver(emojiStoreObserver)
                self.emojiStoreObserver = nil
            }
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if pinsToLatestMessage {
            scrollToBottom(animated: false, layout: false)
        }
    }

    override func updateUI() {
        applyTheme()
        tableView.reloadData()
        chatInputBar.setSending(isSending || isUploadingAttachment)
        chatInputBar.isComposerEnabled = !isSending && !isUploadingAttachment
        pinsToLatestMessage = true
        scrollToBottom(animated: false)
    }

    private func setupLayout() {
        view.addSubview(tableView)
        view.addSubview(attachmentBanner)
        view.addSubview(chatInputBar)
        attachmentBanner.addAction(UIAction { [weak self] _ in
            self?.clearPendingAttachments()
        }, for: .touchUpInside)

        let bottom = chatInputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        chatInputBarBottomConstraint = bottom
        let bannerHeight = attachmentBanner.heightAnchor.constraint(equalToConstant: 0)
        attachmentBannerHeight = bannerHeight
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: attachmentBanner.topAnchor),

            attachmentBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            attachmentBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            attachmentBanner.bottomAnchor.constraint(equalTo: chatInputBar.topAnchor),
            bannerHeight,

            chatInputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatInputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chatKeyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chatKeyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func chatKeyboardWillChangeFrame(_ notification: Notification) {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return }
        let converted = view.convert(frame, from: nil)
        let overlap = max(0, view.bounds.maxY - converted.minY)
        let lift = max(0, overlap - view.safeAreaInsets.bottom)
        chatInputBarBottomConstraint?.constant = -lift
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt)
            ?? UIView.AnimationOptions.curveEaseInOut.rawValue
        if lift > 0 {
            pinsToLatestMessage = true
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        ) {
            self.view.layoutIfNeeded()
            if lift > 0 {
                self.scrollToBottom(animated: false, layout: false)
            }
        } completion: { _ in
            if lift > 0 {
                self.scrollToBottom(animated: false)
            }
        }
    }

    @objc private func chatKeyboardWillHide(_ notification: Notification) {
        chatInputBarBottomConstraint?.constant = 0
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt)
            ?? UIView.AnimationOptions.curveEaseInOut.rawValue
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        ) {
            self.view.layoutIfNeeded()
        }
    }

    private func applyTheme() {
        let theme = AppSettings.shared.themeStyle
        let chatStyle = ChatTopicStyle.current
        let canvas = chatStyle?.chatBackgroundColor ?? theme.topicListBackgroundColor
        view.backgroundColor = canvas
        tableView.backgroundColor = canvas
        chatInputBar.applyChatStyle()
        view.tintColor = theme.accentColor
        attachmentBanner.backgroundColor = theme.topicListBackgroundColor
        attachmentBanner.tintColor = theme.accentColor
        attachmentBanner.setTitleColor(theme.accentColor, for: .normal)
    }

    private func scrollToBottom(animated: Bool, layout: Bool = true) {
        guard !messages.isEmpty else { return }
        if layout {
            tableView.layoutIfNeeded()
        }
        let inset = tableView.adjustedContentInset
        let maxOffset = tableView.contentSize.height - tableView.bounds.height + inset.bottom
        let target = max(-inset.top, maxOffset)
        guard abs(tableView.contentOffset.y - target) > 0.5 else { return }
        if animated {
            tableView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        } else {
            tableView.contentOffset = CGPoint(x: 0, y: target)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pinsToLatestMessage = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { updatePinState(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updatePinState(scrollView)
    }

    private func updatePinState(_ scrollView: UIScrollView) {
        let inset = scrollView.adjustedContentInset
        let distance = scrollView.contentSize.height
            - (scrollView.contentOffset.y + scrollView.bounds.height - inset.bottom)
        pinsToLatestMessage = distance < 80
    }

    private func loadMessages() async {
        isLoading = true
        do {
            messages = try await api.fetchChatMessages(channelId: channel.id)
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
            messages = []
        }
        isLoading = false
        updateUI()
    }

    @objc private func sendMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let uploadIds = pendingAttachments.map(\.id)
        guard (!trimmed.isEmpty || !uploadIds.isEmpty), !isSending, !isUploadingAttachment else { return }
        let replyId = chatInputBar.replyToChatMessageId
        isSending = true
        chatInputBar.setSending(true)
        Task { @MainActor in
            do {
                try await api.sendChatMessage(
                    channelId: channel.id,
                    message: trimmed,
                    inReplyToId: replyId,
                    uploadIds: uploadIds
                )
                chatInputBar.clearAfterSend()
                clearPendingAttachments()
                pinsToLatestMessage = true
                await loadMessages()
                scrollToBottom(animated: true)
            } catch {
                DoerFeedback.presentToast(error.localizedDescription, on: self)
            }
            isSending = false
            chatInputBar.setSending(false)
        }
    }

    private func appendPendingAttachment(id: Int, filename: String) {
        pendingAttachments.append((id: id, filename: filename))
        refreshAttachmentBanner()
    }

    private func clearPendingAttachments() {
        pendingAttachments.removeAll()
        refreshAttachmentBanner()
    }

    private func refreshAttachmentBanner() {
        let count = pendingAttachments.count
        chatInputBar.allowsEmptySend = count > 0
        var config = attachmentBanner.configuration ?? .plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        config.titleLineBreakMode = .byTruncatingTail
        if count == 0 {
            config.title = nil
            attachmentBanner.configuration = config
            attachmentBanner.isHidden = true
            attachmentBannerHeight?.constant = 0
        } else {
            let names = pendingAttachments.map(\.filename).joined(separator: "、")
            config.title = String(
                format: String(localized: "chat.attach.pending", defaultValue: "已附加 %d 个文件（点按清除）"),
                count
            ) + " · " + names
            attachmentBanner.configuration = config
            attachmentBanner.isHidden = false
            attachmentBannerHeight?.constant = 36
        }
        view.layoutIfNeeded()
        if pinsToLatestMessage {
            scrollToBottom(animated: false)
        }
    }

    private func presentEmojiPicker() {
        let picker = EmojiPickerView()
        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        host.title = String(localized: "emoji.picker", defaultValue: "表情")
        picker.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            picker.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        picker.showLoading()
        // Seed from cache immediately so the sheet is never empty on open.
        if let cached = EmojiStore.cachedEntries(for: api.baseURL), !cached.isEmpty {
            picker.setEmojiGroups(
                [DiscourseEmojiGroup(key: "custom", emojis: cached)],
                baseURL: api.baseURL
            )
        }
        picker.onEmojiSelected = { [weak self, weak host] shortcode in
            host?.dismiss(animated: true) {
                self?.chatInputBar.insertText(shortcode)
            }
        }
        let nav = UINavigationController(rootViewController: host)
        host.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak nav] _ in
                nav?.dismiss(animated: true)
            }
        )
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)

        Task { @MainActor in
            do {
                let groups = try await api.fetchEmojiGroups()
                picker.setEmojiGroups(groups, baseURL: api.baseURL)
            } catch {
                if EmojiStore.cachedEntries(for: api.baseURL)?.isEmpty != false {
                    picker.showError()
                }
            }
        }
    }

    @objc private func handleMessageLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let point = gesture.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point),
              messages.indices.contains(indexPath.row)
        else { return }
        let message = messages[indexPath.row]
        presentMessageActions(for: message, at: indexPath)
    }

    private func presentMessageActions(for message: DiscourseChatMessage, at indexPath: IndexPath) {
        let name = message.user?.name?.nilIfEmpty
            ?? message.user?.username
            ?? String(localized: "notifications.someone", defaultValue: "某人")
        let preview = message.displayBody
        let sheet = UIAlertController(title: name, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: String(localized: "chat.action.reply", defaultValue: "回复"),
            style: .default
        ) { [weak self] _ in
            self?.chatInputBar.setChatReplyTarget(
                messageId: message.id,
                name: name,
                preview: preview
            )
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "action.copy", defaultValue: "复制"),
            style: .default
        ) { _ in
            UIPasteboard.general.string = preview
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController,
           let cell = tableView.cellForRow(at: indexPath) {
            pop.sourceView = cell
            pop.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: ChatBubbleCell.reuseIdentifier,
            for: indexPath
        ) as? ChatBubbleCell else {
            return UITableViewCell()
        }
        let msg = messages[indexPath.row]
        let isOutgoing = {
            guard let me = currentUsername,
                  let name = msg.user?.username?.lowercased()
            else { return false }
            return me == name
        }()
        let replyPreview: String? = {
            guard let replyId = msg.inReplyToId,
                  let target = messages.first(where: { $0.id == replyId })
            else { return nil }
            let who = target.user?.name?.nilIfEmpty ?? target.user?.username ?? ""
            let body = target.displayBody
            let clipped = body.count > 40 ? String(body.prefix(40)) + "…" : body
            if who.isEmpty { return clipped }
            return "\(who): \(clipped)"
        }()
        cell.configure(
            message: msg,
            isOutgoing: isOutgoing,
            baseURL: api.baseURL,
            replyPreview: replyPreview
        )
        return cell
    }
}

// MARK: - Bubble cell

private final class ChatBubbleCell: UITableViewCell {
    static let reuseIdentifier = "ChatBubbleCell"

    private let avatarView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .secondarySystemFill
        return iv
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        return label
    }()

    private let bubbleView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let bodyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 0
        return label
    }()

    private let replyPreviewLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        label.isHidden = true
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10)
        label.textColor = .tertiaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.required, for: .vertical)
        return label
    }()

    private var avatarLeading: NSLayoutConstraint?
    private var avatarTrailing: NSLayoutConstraint?
    private var bubbleLeadingFromAvatar: NSLayoutConstraint?
    private var bubbleTrailingFromAvatar: NSLayoutConstraint?
    private var bubbleLeadingMargin: NSLayoutConstraint?
    private var bubbleTrailingMargin: NSLayoutConstraint?
    private var nameAlignLeading: NSLayoutConstraint?
    private var nameAlignTrailing: NSLayoutConstraint?
    private var replyPreviewHeightConstraint: NSLayoutConstraint?
    private var bodyTopToReplyConstraint: NSLayoutConstraint?
    private var bodyTopToBubbleConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(avatarView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(replyPreviewLabel)
        bubbleView.addSubview(bodyLabel)

        let avatarLead = avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12)
        let avatarTrail = avatarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12)
        let bubbleFromAvatarL = bubbleView.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 8)
        let bubbleFromAvatarT = bubbleView.trailingAnchor.constraint(equalTo: avatarView.leadingAnchor, constant: -8)
        let bubbleLead = bubbleView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 56)
        let bubbleTrail = bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -56)
        let nameL = nameLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor)
        let nameT = nameLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor)

        avatarLeading = avatarLead
        avatarTrailing = avatarTrail
        bubbleLeadingFromAvatar = bubbleFromAvatarL
        bubbleTrailingFromAvatar = bubbleFromAvatarT
        bubbleLeadingMargin = bubbleLead
        bubbleTrailingMargin = bubbleTrail
        nameAlignLeading = nameL
        nameAlignTrailing = nameT

        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),

            timeLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 3),
            timeLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            timeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 64),

            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),

            bubbleView.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            bubbleView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.78),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: bubbleView.bottomAnchor, constant: 8),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: timeLabel.bottomAnchor, constant: 8),

            replyPreviewLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            replyPreviewLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            replyPreviewLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),

            bodyLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            bodyLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),
            bodyLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),

            bubbleLead,
            bubbleTrail,
        ])

        let bubbleBottomPin = bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        bubbleBottomPin.priority = UILayoutPriority(250)
        bubbleBottomPin.isActive = true
        let timeBottomPin = timeLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        timeBottomPin.priority = UILayoutPriority(250)
        timeBottomPin.isActive = true

        let replyHeight = replyPreviewLabel.heightAnchor.constraint(equalToConstant: 0)
        replyPreviewHeightConstraint = replyHeight
        replyHeight.isActive = true

        let bodyToReply = bodyLabel.topAnchor.constraint(equalTo: replyPreviewLabel.bottomAnchor, constant: 4)
        let bodyToBubble = bodyLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10)
        bodyTopToReplyConstraint = bodyToReply
        bodyTopToBubbleConstraint = bodyToBubble
        bodyToBubble.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        message: DiscourseChatMessage,
        isOutgoing: Bool,
        baseURL: String,
        replyPreview: String? = nil
    ) {
        let theme = AppSettings.shared.themeStyle
        let chatStyle = ChatTopicStyle.current
        let isDark = traitCollection.userInterfaceStyle == .dark
        let radius = chatStyle?.bubbleCornerRadius ?? theme.chromeCornerRadius

        contentView.backgroundColor = .clear
        backgroundColor = .clear

        let displayName = message.user?.name?.nilIfEmpty
            ?? message.user?.username
            ?? "…"
        nameLabel.text = displayName
        nameLabel.textAlignment = isOutgoing ? .right : .left
        nameLabel.isHidden = isOutgoing && chatStyle == .telegram

        let sendTime = message.formattedSendTime()
        timeLabel.text = sendTime
        timeLabel.isHidden = sendTime.isEmpty

        if let replyPreview, !replyPreview.isEmpty {
            replyPreviewLabel.isHidden = false
            replyPreviewLabel.text = replyPreview
            replyPreviewHeightConstraint?.isActive = false
            bodyTopToBubbleConstraint?.isActive = false
            bodyTopToReplyConstraint?.isActive = true
        } else {
            replyPreviewLabel.isHidden = true
            replyPreviewLabel.text = nil
            bodyTopToReplyConstraint?.isActive = false
            replyPreviewHeightConstraint?.constant = 0
            replyPreviewHeightConstraint?.isActive = true
            bodyTopToBubbleConstraint?.isActive = true
        }

        TitleEmojiRenderer.apply(
            message.displayBody,
            to: bodyLabel,
            font: bodyLabel.font ?? .systemFont(ofSize: 16),
            textColor: bodyLabel.textColor,
            baseURL: baseURL
        )
        bodyLabel.textColor = isOutgoing
            ? (chatStyle == .telegram && isDark ? .white : .label)
            : .label

        bubbleView.layer.cornerRadius = radius
        if isOutgoing {
            bubbleView.backgroundColor = chatStyle?.outgoingBubbleColor(isDark: isDark)
                ?? theme.accentColor.withAlphaComponent(0.22)
        } else {
            bubbleView.backgroundColor = chatStyle?.incomingBubbleColor(isDark: isDark)
                ?? theme.topicCardBackgroundColor
        }

        let avatarSize: CGFloat = chatStyle?.avatarSize ?? 36
        avatarView.layer.cornerRadius = chatStyle?.avatarCornerRadius ?? 6
        // Keep fixed 36 constraints for simplicity; radius still theme-matched.
        _ = avatarSize

        avatarLeading?.isActive = !isOutgoing
        avatarTrailing?.isActive = isOutgoing
        bubbleLeadingFromAvatar?.isActive = !isOutgoing
        bubbleTrailingFromAvatar?.isActive = isOutgoing
        // Keep opposite edge free so bubble can grow toward center.
        if isOutgoing {
            bubbleLeadingMargin?.isActive = true
            bubbleTrailingMargin?.constant = -12
            bubbleTrailingMargin?.isActive = true
            // Pin trailing of bubble to avatar leading via bubbleTrailingFromAvatar
            nameAlignTrailing?.isActive = true
            nameAlignLeading?.isActive = false
        } else {
            bubbleTrailingMargin?.isActive = true
            bubbleLeadingMargin?.constant = 12
            bubbleLeadingMargin?.isActive = true
            nameAlignLeading?.isActive = true
            nameAlignTrailing?.isActive = false
        }

        let template = message.user?.avatarTemplate
        let url = AvatarImageLoader.url(from: template, baseURL: baseURL, size: 72)
        AvatarImageLoader.setImage(
            on: avatarView,
            url: url,
            placeholder: UIImage(systemName: "person.crop.circle.fill"),
            cloudflareBaseURL: baseURL,
            avatarBaseURL: baseURL,
            userId: message.user?.id
        )

        if sendTime.isEmpty {
            accessibilityLabel = displayName
        } else {
            accessibilityLabel = "\(displayName), \(sendTime.replacingOccurrences(of: "\n", with: " "))"
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarView.sd_cancelCurrentImageLoad()
        avatarView.image = nil
        bodyLabel.text = nil
        bodyLabel.attributedText = nil
        replyPreviewLabel.text = nil
        replyPreviewLabel.isHidden = true
        nameLabel.text = nil
        timeLabel.text = nil
        timeLabel.isHidden = false
        accessibilityLabel = nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
