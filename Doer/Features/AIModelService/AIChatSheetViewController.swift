import UIKit

/// 话题 AI 助手（FluxDo ai_chat_page 的原生对应物）。
/// 以 sheet 形式挂在话题详情上；也可从「聊天记录」直接打开历史会话。
@MainActor
final class AIChatSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let api: DiscourseAPI
    private let topicId: Int
    private var topicTitle: String?

    private var session: AIChatSession?
    private var messages: [AIChatMessage] = []
    private var contextScope = AIChatSettings.defaultContextScope
    private var contextPosts: [(Int, String, String)]?
    private var streamTask: Task<Void, Never>?
    private var isStreaming = false
    private var streamingText = ""
    private var presets: [AIPromptPreset] = []

    private var accentColor: UIColor {
        AppSettings.shared.themeStyle.accentColor
    }

    // MARK: - Views

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "ai.chat.title", defaultValue: "AI 助手")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }()

    private lazy var contextButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "doc.plaintext",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        )
        config.imagePadding = 4
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildContextMenu() ?? [])
            },
        ])
        return button
    }()

    private lazy var moreButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "ellipsis",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        config.baseForegroundColor = .label
        let button = UIButton(configuration: config)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.buildMoreMenu() ?? [])
            },
        ])
        return button
    }()

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.separatorStyle = .none
        tv.backgroundColor = .clear
        tv.keyboardDismissMode = .interactive
        tv.dataSource = self
        tv.delegate = self
        tv.register(AIChatBubbleCell.self, forCellReuseIdentifier: AIChatBubbleCell.reuseIdentifier)
        tv.translatesAutoresizingMaskIntoConstraints = false
        return tv
    }()

    private let inputField: UITextField = {
        let field = UITextField()
        field.placeholder = String(localized: "ai.chat.input.placeholder", defaultValue: "输入消息...")
        field.font = .systemFont(ofSize: 15)
        field.returnKeyType = .send
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    private let inputContainer: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var sendButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.image = UIImage(
            systemName: "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        )
        config.cornerStyle = .capsule
        config.baseBackgroundColor = accentColor
        config.baseForegroundColor = .white
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addAction(UIAction { [weak self] _ in self?.sendOrStopTapped() }, for: .touchUpInside)
        return button
    }()

    init(api: DiscourseAPI, topicId: Int, topicTitle: String?, session: AIChatSession? = nil) {
        self.api = api
        self.topicId = topicId
        self.topicTitle = topicTitle ?? session?.topicTitle
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLayout()
        inputField.delegate = self

        if let session {
            messages = session.messages
        }
        refreshEmptyState()
        Task {
            presets = await AIChatStore.shared.presets()
            if session == nil {
                session = await AIChatStore.shared.latestSession(baseURL: api.baseURL, topicId: topicId)
                if let session {
                    messages = session.messages
                    tableView.reloadData()
                    scrollToBottom(animated: false)
                }
            }
            refreshEmptyState()
        }
    }

    private func setupLayout() {
        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), contextButton, moreButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        separator.translatesAutoresizingMaskIntoConstraints = false

        inputContainer.addSubview(inputField)
        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(tableView)
        view.addSubview(inputContainer)
        view.addSubview(sendButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            tableView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor, constant: -8),

            inputContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            inputContainer.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -10),
            inputContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10),
            inputContainer.heightAnchor.constraint(equalToConstant: 40),

            inputField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 14),
            inputField.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -14),
            inputField.topAnchor.constraint(equalTo: inputContainer.topAnchor),
            inputField.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor),

            sendButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            sendButton.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 40),
            sendButton.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - Menus

    private func buildContextMenu() -> [UIMenuElement] {
        AIContextScope.allCases.map { scope in
            UIAction(title: scope.label, state: scope == contextScope ? .on : .off) { [weak self] _ in
                guard let self else { return }
                contextScope = scope
                contextPosts = nil
                updateContextButton()
            }
        }
    }

    private func buildMoreMenu() -> [UIMenuElement] {
        var actions: [UIMenuElement] = [
            UIAction(
                title: String(localized: "ai.chat.new_session", defaultValue: "新对话"),
                image: UIImage(systemName: "plus.bubble")
            ) { [weak self] _ in
                self?.startNewSession()
            },
            UIAction(
                title: String(localized: "ai.chat.pick_model", defaultValue: "选择模型"),
                image: UIImage(systemName: "cpu")
            ) { [weak self] _ in
                self?.presentModelSettings()
            },
        ]
        if let model = AIModelServiceStore.defaultModelRef()?.modelID {
            actions.append(UIAction(title: model, attributes: .disabled) { _ in })
        }
        return actions
    }

    private func updateContextButton() {
        contextButton.configuration?.title = contextScope.label
        contextButton.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            return out
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateContextButton()
    }

    private func startNewSession() {
        streamTask?.cancel()
        isStreaming = false
        streamingText = ""
        session = nil
        messages = []
        tableView.reloadData()
        refreshEmptyState()
        updateSendButton()
    }

    private func presentModelSettings() {
        let controller = AIModelServiceViewController(api: api)
        let nav = UINavigationController(rootViewController: controller)
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissPresented)
        )
        present(nav, animated: true)
    }

    @objc private func dismissPresented() {
        presentedViewController?.dismiss(animated: true)
    }

    // MARK: - Empty state

    private func refreshEmptyState() {
        guard messages.isEmpty, !isStreaming else {
            tableView.backgroundView = nil
            return
        }
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hint = UILabel()
        hint.text = String(localized: "ai.chat.ask_hint", defaultValue: "向 AI 助手提问")
        hint.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.textColor = accentColor

        let headline = UILabel()
        headline.text = String(localized: "ai.chat.ask_headline", defaultValue: "AI 会基于话题内容为你解答")
        headline.font = .systemFont(ofSize: 19, weight: .semibold)
        headline.numberOfLines = 0

        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(headline)
        stack.setCustomSpacing(18, after: headline)

        let symbols = ["doc.text", "character.book.closed", "text.bubble", "lightbulb"]
        for (index, preset) in presets.prefix(4).enumerated() {
            stack.addArrangedSubview(makePromptChip(
                title: preset.title,
                symbolName: symbols[index % symbols.count]
            ) { [weak self] in
                self?.send(text: preset.prompt, displayText: preset.title)
            })
        }
        stack.addArrangedSubview(makePromptChip(
            title: String(localized: "ai.chat.more_prompts", defaultValue: "更多"),
            symbolName: "ellipsis"
        ) { [weak self] in
            self?.presentAllPresets()
        })

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])
        tableView.backgroundView = container
    }

    private func makePromptChip(title: String, symbolName: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(
            systemName: symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        )
        config.imagePadding = 8
        config.baseForegroundColor = .label
        config.background.strokeColor = UIColor.separator.withAlphaComponent(0.6)
        config.background.strokeWidth = 1
        config.background.cornerRadius = 12
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = UIFont.systemFont(ofSize: 14, weight: .medium)
            return out
        }
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func presentAllPresets() {
        let sheet = UIAlertController(
            title: String(localized: "ai.presets.title", defaultValue: "快捷词"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for preset in presets {
            sheet.addAction(UIAlertAction(title: preset.title, style: .default) { [weak self] _ in
                self?.send(text: preset.prompt, displayText: preset.title)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    // MARK: - Sending

    private func sendOrStopTapped() {
        if isStreaming {
            streamTask?.cancel()
            return
        }
        let text = inputField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return }
        inputField.text = nil
        send(text: text, displayText: text)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendOrStopTapped()
        return true
    }

    /// text = 实际发给模型的内容；displayText = 气泡里展示的内容（快捷词展示标题）。
    private func send(text: String, displayText: String) {
        guard !isStreaming else { return }
        guard resolveModel() != nil else {
            presentNoModelAlert()
            return
        }

        messages.append(AIChatMessage(role: .user, content: displayText == text ? text : displayText))
        let outgoingPrompt = text
        isStreaming = true
        streamingText = ""
        refreshEmptyState()
        tableView.reloadData()
        scrollToBottom(animated: true)
        updateSendButton()

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let resolved = await loadResolvedModel() else {
                    throw AIChatServiceError.noDefaultModel
                }
                let context = try await loadContextIfNeeded()

                var outgoing = AIChatService.contextMessagePair(
                    contextText: AIChatService.contextText(posts: context, scope: contextScope)
                )
                for message in messages.dropLast() where !message.content.isEmpty {
                    outgoing.append(message)
                }
                outgoing.append(AIChatMessage(role: .user, content: outgoingPrompt))

                let stream = AIChatService.streamChat(
                    providerType: resolved.provider.type,
                    baseURL: resolved.provider.baseURL,
                    apiKey: resolved.apiKey,
                    model: resolved.model.id,
                    systemPrompt: AIChatService.systemPrompt(topicTitle: topicTitle),
                    messages: outgoing
                )
                for try await chunk in stream {
                    streamingText += chunk
                    updateStreamingRow()
                }
                finishStreaming(error: nil)
            } catch is CancellationError {
                finishStreaming(error: nil)
            } catch {
                finishStreaming(error: error)
            }
        }
    }

    private func finishStreaming(error: Error?) {
        guard isStreaming else { return }
        isStreaming = false
        if !streamingText.isEmpty {
            messages.append(AIChatMessage(role: .assistant, content: streamingText))
        }
        streamingText = ""
        if let error {
            messages.append(AIChatMessage(
                role: .assistant,
                content: String(
                    format: String(localized: "ai.chat.error", defaultValue: "请求失败：%@"),
                    error.localizedDescription
                )
            ))
        }
        tableView.reloadData()
        scrollToBottom(animated: true)
        updateSendButton()
        persistSession()
    }

    private func persistSession() {
        var session = self.session ?? AIChatSession(
            baseURL: api.baseURL,
            topicId: topicId,
            topicTitle: topicTitle ?? "#\(topicId)"
        )
        session.messages = messages
        session.modelName = AIModelServiceStore.defaultModelRef()?.modelID
        self.session = session
        Task {
            try? await AIChatStore.shared.save(session)
        }
    }

    private func updateSendButton() {
        sendButton.configuration?.image = UIImage(
            systemName: isStreaming ? "stop.fill" : "arrow.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        )
    }

    private func presentNoModelAlert() {
        let alert = UIAlertController(
            title: nil,
            message: String(localized: "ai.chat.no_model", defaultValue: "请先在 AI 模型服务中配置并选择默认模型"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "ai.chat.go_configure", defaultValue: "去配置"),
            style: .default
        ) { [weak self] _ in
            self?.presentModelSettings()
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Model / context resolution

    private struct ResolvedModel {
        let provider: AIProvider
        let model: AIModel
        let apiKey: String
    }

    private func resolveModel() -> AIDefaultModelRef? {
        AIModelServiceStore.defaultModelRef()
    }

    private func loadResolvedModel() async -> ResolvedModel? {
        guard let ref = AIModelServiceStore.defaultModelRef(),
              let provider = await AIModelServiceStore.shared.provider(id: ref.providerID),
              let model = provider.models.first(where: { $0.id == ref.modelID }),
              let apiKey = await AIModelServiceStore.shared.apiKey(for: provider.id)
        else { return nil }
        return ResolvedModel(provider: provider, model: model, apiKey: apiKey)
    }

    private func loadContextIfNeeded() async throws -> [(Int, String, String)] {
        if let contextPosts { return contextPosts }
        let detail = try await api.fetchTopic(id: topicId)
        if topicTitle == nil {
            topicTitle = detail.title
        }
        var posts = detail.postStream.posts.map { ($0.postNumber, $0.username, $0.cooked) }
        // 「全部楼层」补拉首页之外的帖子；ponytail: 上限 100 楼，防 token 爆炸。
        if contextScope == .all,
           let stream = detail.postStream.stream,
           stream.count > posts.count {
            let loadedCount = posts.count
            let remaining = Array(stream.dropFirst(loadedCount).prefix(100 - min(loadedCount, 100)))
            if !remaining.isEmpty {
                let extra = try await api.fetchTopicPosts(topicId: topicId, postIds: remaining)
                posts += extra.postStream.posts.map { ($0.postNumber, $0.username, $0.cooked) }
            }
        }
        posts.sort { $0.0 < $1.0 }
        contextPosts = posts
        return posts
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count + (isStreaming ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: AIChatBubbleCell.reuseIdentifier,
            for: indexPath
        ) as? AIChatBubbleCell else {
            return UITableViewCell()
        }
        if indexPath.row < messages.count {
            let message = messages[indexPath.row]
            cell.configure(text: message.content, isUser: message.role == .user, accentColor: accentColor)
        } else {
            let placeholder = String(localized: "ai.chat.thinking", defaultValue: "思考中…")
            cell.configure(
                text: streamingText.isEmpty ? placeholder : streamingText,
                isUser: false,
                accentColor: accentColor
            )
        }
        return cell
    }

    private func updateStreamingRow() {
        let streamingIndex = IndexPath(row: messages.count, section: 0)
        guard tableView.doer_numberOfRows(inSection: 0) > streamingIndex.row else {
            tableView.reloadData()
            return
        }
        if let cell = tableView.cellForRow(at: streamingIndex) as? AIChatBubbleCell {
            cell.updateText(streamingText)
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
            scrollToBottom(animated: false)
        }
    }

    private func scrollToBottom(animated: Bool) {
        let rows = tableView.doer_numberOfRows(inSection: 0)
        guard rows > 0 else { return }
        tableView.scrollToRow(at: IndexPath(row: rows - 1, section: 0), at: .bottom, animated: animated)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row < messages.count else { return nil }
        let content = messages[indexPath.row].content
        return UIContextMenuConfiguration(actionProvider: { _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "invites.copy"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = content
                },
            ])
        })
    }
}

// MARK: - Bubble cell

private final class AIChatBubbleCell: UITableViewCell {
    static let reuseIdentifier = "AIChatBubbleCell"

    private let bubbleView: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private var leadingConstraint: NSLayoutConstraint?
    private var trailingConstraint: NSLayoutConstraint?
    private var isUserMessage = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        contentView.addSubview(bubbleView)
        bubbleView.addSubview(messageLabel)

        let leading = bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        let trailing = bubbleView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        leadingConstraint = leading
        trailingConstraint = trailing

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            bubbleView.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),

            messageLabel.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 10),
            messageLabel.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -10),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 14),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, isUser: Bool, accentColor: UIColor) {
        isUserMessage = isUser
        applyRenderedText(text)
        if isUser {
            bubbleView.backgroundColor = accentColor
            leadingConstraint?.isActive = false
            trailingConstraint?.isActive = true
        } else {
            bubbleView.backgroundColor = .secondarySystemBackground
            trailingConstraint?.isActive = false
            leadingConstraint?.isActive = true
        }
    }

    func updateText(_ text: String) {
        applyRenderedText(text)
    }

    private func applyRenderedText(_ text: String) {
        let color: UIColor = isUserMessage ? .white : .label
        messageLabel.attributedText = Self.renderMarkdown(text, textColor: color)
        messageLabel.textColor = color
    }

    /// 将 AI 回复中的 Markdown 渲染成可读富文本；流式半截语法解析失败时回退纯文本。
    private static func renderMarkdown(_ text: String, textColor: UIColor) -> NSAttributedString {
        let baseFont = UIFont.systemFont(ofSize: 15)
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: textColor,
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        guard let markdown = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) else {
            return NSAttributedString(string: text, attributes: baseAttributes)
        }

        let result = NSMutableAttributedString(markdown)
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttribute(.foregroundColor, value: textColor, range: fullRange)

        // 统一正文字号，同时保留 markdown 带来的粗体/斜体/等宽字重。
        result.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let current = (value as? UIFont) ?? baseFont
            let traits = current.fontDescriptor.symbolicTraits
            var descriptor = baseFont.fontDescriptor
            if let withTraits = descriptor.withSymbolicTraits(traits) {
                descriptor = withTraits
            }
            result.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 15), range: range)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        result.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        return result
    }
}
