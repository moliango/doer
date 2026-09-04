import PhotosUI
import UIKit
import UniformTypeIdentifiers

final class ReplyComposerViewController: UIViewController {
    private static let emojiShortcodeRegex = try! NSRegularExpression(pattern: ":([^\\s:]+(?::t\\d)?):")

    private let api: DiscourseAPI
    private let topicId: Int
    private let replyToPost: DiscourseTopicDetail.Post?
    private let baseURL: String
    private let initialText: String?
    private let submissionMode: ReplyComposerSubmissionMode
    private let serverDraftKey: String?
    /// Local @ candidates (topic posters) shown instantly while the API search runs — FluxDo parity.
    private let mentionSeedUsers: [DiscourseMentionUser]
    var onPostCreated: (() -> Void)?
    var onDraftDeleted: (() -> Void)?
    var onPostUpdated: ((Int) -> Void)?

    private var editingMode = ComposerEditingMode.stored
    private let modeToggleButton = ComposerToolbarFactory.makeModeButton()

    private var currentPanel: ComposerPanelKind = .none
    private var hasLoadedForumEmojis = false
    private var isPreviewingMarkdown = false
    private var isUploading = false
    private var isSubmitting = false
    private var isDiscardingDraft = false
    private var isApplyingAttributedText = false
    private var draftSaveTask: Task<Void, Never>?
    private var serverDraftSaveTask: Task<Void, Never>?
    private var sourceRestyleTask: Task<Void, Never>?
    private var panelHeightConstraint: NSLayoutConstraint?
    private let markdownCoordinator = ComposerMarkdownCoordinator()
    /// UTF-16 range of the active `@term` token in the display string (includes `@`).
    private var activeMentionRange: NSRange?
    private var mentionSearchTask: Task<Void, Never>?
    private var mentionSearchGeneration = 0
    private var mentionPickerBottomConstraint: NSLayoutConstraint?
    private var mentionPickerLeadingConstraint: NSLayoutConstraint?

    private let grabberView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiaryLabel.withAlphaComponent(0.35)
        view.layer.cornerRadius = 2
        return view
    }()

    private let headerContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private let closeButton = ComposerToolbarFactory.makeCloseIconButton()

    private let headerTitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppSettings.shared.appInterfaceFont(
            matching: .systemFont(ofSize: 17, weight: .semibold)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let headerSubtitleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = AppSettings.shared.appInterfaceFont(
            matching: .systemFont(ofSize: 13, weight: .regular)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private lazy var headerTitleStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [headerTitleLabel, headerSubtitleLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }()

    private lazy var headerActionsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [closeButton, sendButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let sendButton: UIButton = {
        let button = ComposerToolbarFactory.makeSendIconButton()
        button.isEnabled = false
        return button
    }()

    private let separatorView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator
        return view
    }()

    private let textView: ComposerBodyTextView = {
        let tv = ComposerBodyTextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        ComposerTypography.applyBody(to: tv)
        tv.returnKeyType = .default
        return tv
    }()

    /// Present only when the experimental WYSIWYG setting is on at load. Nil keeps the existing Aa/MD `textView`.
    private var experimentalComposerView: ExperimentalComposerView?

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "reply.markdown_placeholder")
        ComposerTypography.applyBody(to: label)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let previewView: ComposerMarkdownPreviewView = {
        let view = ComposerMarkdownPreviewView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()

    private let bottomStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        return stack
    }()

    private let toolbarContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private let customPanelContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        return view
    }()

    private let emojiToggleButton = ComposerToolbarFactory.makeCircleButton(
        systemName: "face.smiling",
        accessibilityLabel: String(localized: "reply.toolbar.emoji")
    )

    private let encryptToolbarButton = ComposerToolbarFactory.makeCircleButton(
        systemName: "key.fill",
        accessibilityLabel: String(localized: "crypto.encrypt.action", defaultValue: "加密")
    )

    private let previewToggleButton = ComposerToolbarFactory.makePlainButton(
        systemName: "eye",
        accessibilityLabel: String(localized: "reply.toolbar.preview")
    )

    private let toolsToggleButton = ComposerToolbarFactory.makePlainButton(
        systemName: "plus.circle.fill",
        accessibilityLabel: String(localized: "reply.toolbar.more_tools")
    )

    private let rightToolbarPill: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = ComposerTypography.mutedFill
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let uploadStatusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    private lazy var emojiPickerView: EmojiStickerPanelView = {
        let picker = EmojiStickerPanelView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onEmojiSelected = { [weak self] emoji in
            self?.insertText(emoji)
        }
        picker.onStickerMarkdownSelected = { [weak self] markdown in
            self?.insertText(markdown + "\n")
        }
        return picker
    }()

    private lazy var toolsPanelView: ComposerToolPanelView = {
        let panel = ComposerToolPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onToolSelected = { [weak self] tool in
            self?.markdownCoordinator.handleTool(tool)
        }
        return panel
    }()

    private lazy var mentionPickerView: ComposerMentionPickerView = {
        let picker = ComposerMentionPickerView()
        picker.onSelect = { [weak self] user in
            self?.insertMention(user)
        }
        return picker
    }()

    init(
        api: DiscourseAPI,
        topicId: Int,
        replyToPost: DiscourseTopicDetail.Post?,
        baseURL: String,
        initialText: String? = nil,
        submissionMode: ReplyComposerSubmissionMode = .reply,
        mentionSeedUsers: [DiscourseMentionUser] = [],
        draftKey: String? = nil
    ) {
        self.api = api
        self.topicId = topicId
        self.replyToPost = replyToPost
        self.baseURL = baseURL
        self.initialText = initialText
        self.submissionMode = submissionMode
        self.mentionSeedUsers = mentionSeedUsers
        if case .reply = submissionMode {
            self.serverDraftKey = draftKey ?? ComposerLocalDraftStore.discourseReplyDraftKey(topicId: topicId, replyToPostNumber: replyToPost?.postNumber)
        } else {
            self.serverDraftKey = nil
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ComposerTypography.applyChrome(to: view)
        headerContainer.backgroundColor = ComposerTypography.backgroundColor
        toolbarContainer.backgroundColor = ComposerTypography.backgroundColor
        customPanelContainer.backgroundColor = ComposerTypography.backgroundColor

        configureHeaderCopy()
        configureCloseMenu()

        view.addSubview(grabberView)
        view.addSubview(headerContainer)
        headerContainer.addSubview(headerTitleStack)
        headerContainer.addSubview(headerActionsStack)
        headerContainer.addSubview(separatorView)
        view.addSubview(textView)
        if let experimental = ExperimentalComposerHosting.makeViewIfEnabled(
            pasteCoordinator: markdownCoordinator,
            imageBaseURL: baseURL,
            placeholderText: String(localized: "reply.markdown_placeholder"),
            onDocumentChanged: { [weak self] in
                guard let self else { return }
                self.updatePlaceholder()
                self.updateSendButton()
                self.scheduleDraftSave()
            },
            onEditingBegan: { [weak self] in
                guard let self, self.currentPanel != .none else { return }
                self.closePanel(returnToKeyboard: false)
            },
            onSelectionChanged: { [weak self] in
                self?.refreshMentionSuggestions()
                self?.refreshExperimentalTools()
            },
            onScroll: { [weak self] in
                self?.repositionMentionPicker()
            }
        ) {
            view.addSubview(experimental)
            experimentalComposerView = experimental
            textView.isHidden = true
            placeholderLabel.isHidden = true
            modeToggleButton.isHidden = false
        }
        view.addSubview(previewView)
        view.addSubview(placeholderLabel)
        if let experimental = experimentalComposerView {
            view.insertSubview(experimental, belowSubview: previewView)
        }
        view.addSubview(bottomStackView)
        // Above text, below chrome — so @ list is tappable over the editor.
        view.addSubview(mentionPickerView)

        setupToolbar()
        setupCustomPanel()
        emojiPickerView.presentingViewController = self
        mentionPickerView.configure(baseURL: baseURL)
        PresenceService.shared.attach(api: api)

        let mentionLeading = mentionPickerView.leadingAnchor.constraint(
            equalTo: textView.leadingAnchor,
            constant: 22
        )
        let mentionTop = mentionPickerView.topAnchor.constraint(
            equalTo: textView.topAnchor,
            constant: 56
        )
        mentionPickerLeadingConstraint = mentionLeading
        mentionPickerBottomConstraint = mentionTop

        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: 42),
            grabberView.heightAnchor.constraint(equalToConstant: 5),

            headerContainer.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 8),
            headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerContainer.heightAnchor.constraint(equalToConstant: 56),

            headerActionsStack.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            headerActionsStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            headerTitleStack.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            headerTitleStack.trailingAnchor.constraint(lessThanOrEqualTo: headerActionsStack.leadingAnchor, constant: -12),
            headerTitleStack.centerYAnchor.constraint(equalTo: headerContainer.centerYAnchor),

            separatorView.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor),
            separatorView.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5),

            textView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomStackView.topAnchor),

            previewView.topAnchor.constraint(equalTo: textView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: textView.bottomAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 22),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 27),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -22),

            bottomStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomStackView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),

            mentionLeading,
            mentionTop,
            mentionPickerView.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -22),
        ])

        if let experimental = experimentalComposerView {
            NSLayoutConstraint.activate([
                experimental.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
                experimental.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                experimental.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                experimental.bottomAnchor.constraint(equalTo: bottomStackView.topAnchor),
            ])
        }

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        emojiToggleButton.addTarget(self, action: #selector(toggleEmojiPicker), for: .touchUpInside)
        encryptToolbarButton.addTarget(self, action: #selector(encryptToolbarTapped), for: .touchUpInside)
        previewToggleButton.addTarget(self, action: #selector(toggleMarkdownPreview), for: .touchUpInside)
        modeToggleButton.addTarget(self, action: #selector(toggleEditingMode), for: .touchUpInside)
        toolsToggleButton.addTarget(self, action: #selector(toggleToolsPanel), for: .touchUpInside)

        textView.delegate = self
        markdownCoordinator.surface = self
        textView.pasteCoordinator = markdownCoordinator

        // Prefer explicit initial text from a cloud draft or quote.
        if let initialText, !initialText.isEmpty {
            setRawComposerText(initialText)
        }
        updatePlaceholder()
        updateSendButton()
        updateToolbarState()

        if case .reply = submissionMode {
            Task { await self.hydrateServerDraftIfNeeded() }
        }
    }

    /// FluxDo: merge server draft when local is empty / older sequence is unknown.
    private func hydrateServerDraftIfNeeded() async {
        guard case .reply = submissionMode, let draftKey = serverDraftKey else { return }
        do {
            guard let server = try await api.fetchDraft(key: draftKey) else { return }
            ComposerLocalDraftStore.saveSequence(
                baseURL: baseURL,
                draftKey: draftKey,
                sequence: server.sequence
            )
            let serverRaw = server.data.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !serverRaw.isEmpty else { return }
            let localRaw = composerRawText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only fill when the composer is still empty — never clobber in-progress typing.
            guard localRaw.isEmpty else { return }
            setRawComposerText(server.data.reply ?? "")
            updatePlaceholder()
            updateSendButton()
        } catch {
            // Offline / CF: keep the current composer unchanged.
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PresenceService.shared.enter(topicId: topicId)
        focusComposer()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        PresenceService.shared.leave()
        draftSaveTask?.cancel()
        serverDraftSaveTask?.cancel()
        sourceRestyleTask?.cancel()
    }

    private func scheduleDraftSave() {}

    private var usesExperimentalComposer: Bool { experimentalComposerView != nil }

    private var mentionSourceTextView: UITextView {
        experimentalComposerView?.activeTextView ?? textView
    }

    private var activeEditorView: UIView {
        experimentalComposerView ?? textView
    }

    private func focusComposer() {
        if let experimentalComposerView {
            experimentalComposerView.becomeFirstResponder()
        } else {
            textView.becomeFirstResponder()
        }
    }

    private func blurComposer() {
        if let experimentalComposerView {
            experimentalComposerView.resignFirstResponder()
        } else {
            textView.resignFirstResponder()
        }
    }


    private func setupToolbar() {
        bottomStackView.addArrangedSubview(toolbarContainer)
        bottomStackView.addArrangedSubview(customPanelContainer)
        ComposerToolbarFactory.installToolbarLayout(
            in: toolbarContainer,
            emojiButton: emojiToggleButton,
            uploadStatusLabel: uploadStatusLabel,
            rightPill: rightToolbarPill,
            previewButton: previewToggleButton,
            modeButton: modeToggleButton,
            toolsButton: toolsToggleButton,
            encryptButton: encryptToolbarButton
        )
    }

    private func setupCustomPanel() {
        panelHeightConstraint = ComposerToolbarFactory.installPanelLayout(
            in: customPanelContainer,
            emojiPanel: emojiPickerView,
            toolsPanel: toolsPanelView
        )
    }

    @objc private func encryptToolbarTapped() {
        markdownCoordinator.handleTool(.encrypt)
    }

    @objc private func toggleEmojiPicker() {
        hideMentionPicker()
        setPanel(currentPanel == .emoji ? .none : .emoji)
    }

    @objc private func toggleToolsPanel() {
        hideMentionPicker()
        setPanel(currentPanel == .tools ? .none : .tools)
    }

    private var isExperimentalSourceVisible = false

    @objc private func toggleEditingMode() {
        if let experimental = experimentalComposerView {
            toggleExperimentalSource(experimental)
            return
        }
        hideMentionPicker()
        let raw = composerRawText
        editingMode = editingMode.toggled
        ComposerEditingMode.stored = editingMode
        if isPreviewingMarkdown {
            isPreviewingMarkdown = false
            updatePreviewState()
        }
        applyFullRawText(raw)
        focusComposer()
        updateToolbarState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func toggleExperimentalSource(_ experimental: ExperimentalComposerView) {
        hideMentionPicker()
        if isExperimentalSourceVisible {
            let raw = textView.text ?? composerRawText
            if experimental.tryLoad(raw) {
                isExperimentalSourceVisible = false
                experimental.isHidden = false
                textView.isHidden = true
                experimental.becomeFirstResponder()
            }
        } else {
            let raw = experimental.markdown
            isExperimentalSourceVisible = true
            experimental.resignFirstResponder()
            experimental.isHidden = true
            textView.isHidden = false
            editingMode = .source
            isApplyingAttributedText = true
            textView.attributedText = ComposerMarkdownRenderer.styleSource(
                raw,
                baseAttributes: ComposerTypography.typingAttributes
            )
            isApplyingAttributedText = false
            textView.becomeFirstResponder()
        }
        updateToolbarState()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func refreshExperimentalTools() {
        toolsPanelView.setActiveTools(experimentalComposerView?.activeTools ?? [])
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            experimentalComposerView?.performUndo()
        }
        super.motionEnded(motion, with: event)
    }

    @objc private func toggleMarkdownPreview() {
        hideMentionPicker()
        isPreviewingMarkdown.toggle()
        if isPreviewingMarkdown {
            closePanel(returnToKeyboard: false)
            blurComposer()
            experimentalComposerView?.captureFocus()
            previewView.update(markdown: ComposerPangu.applyToOutgoing(composerRawText))
        } else {
            focusComposer()
            experimentalComposerView?.restoreCapturedFocus()
        }
        updatePreviewState()
    }

    private func setPanel(_ panel: ComposerPanelKind) {
        if isPreviewingMarkdown {
            isPreviewingMarkdown = false
            updatePreviewState()
        }

        currentPanel = panel
        switch panel {
        case .none:
            emojiPickerView.isHidden = true
            toolsPanelView.isHidden = true
            panelHeightConstraint?.constant = 0
            focusComposer()
        case .emoji:
            blurComposer()
            emojiPickerView.isHidden = false
            toolsPanelView.isHidden = true
            panelHeightConstraint?.constant = ComposerToolbarFactory.customPanelHeight
            loadForumEmojis()
        case .tools:
            blurComposer()
            emojiPickerView.isHidden = true
            toolsPanelView.isHidden = false
            panelHeightConstraint?.constant = ComposerToolbarFactory.customPanelHeight
        }
        updateToolbarState()
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }

    private func closePanel(returnToKeyboard: Bool) {
        guard currentPanel != .none else {
            if returnToKeyboard {
                focusComposer()
            }
            return
        }
        hideMentionPicker()
        currentPanel = .none
        emojiPickerView.isHidden = true
        toolsPanelView.isHidden = true
        panelHeightConstraint?.constant = 0
        updateToolbarState()
        if returnToKeyboard {
            focusComposer()
        }
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.view.layoutIfNeeded()
        }
    }

    private func loadForumEmojis() {
        guard !hasLoadedForumEmojis else { return }
        hasLoadedForumEmojis = true
        emojiPickerView.showLoading()
        Task {
            do {
                let groups = try await api.fetchEmojiGroups()
                await MainActor.run {
                    self.emojiPickerView.setEmojiGroups(groups, baseURL: self.baseURL)
                }
            } catch {
                await MainActor.run {
                    self.emojiPickerView.showError()
                }
            }
        }
    }

    /// Raw markdown for the body (ComposerTextSurface uses the same extraction).
    private var bodyRawText: String {
        if let experimentalComposerView, !isExperimentalSourceVisible {
            return experimentalComposerView.markdown
        }
        return rawText(from: textView.attributedText ?? NSAttributedString(string: textView.text ?? ""))
    }

    private var composerDisplayText: String {
        mentionSourceTextView.attributedText?.string ?? mentionSourceTextView.text ?? ""
    }

    private var composerTextAttributes: [NSAttributedString.Key: Any] {
        ComposerTypography.typingAttributes
    }

    private func setRawComposerText(_ raw: String) {
        if let experimentalComposerView, !isExperimentalSourceVisible {
            if experimentalComposerView.tryLoad(raw) {
                updatePlaceholder()
                updateSendButton()
                return
            }
            ExperimentalComposerHosting.abandon(
                experimentalComposerView,
                revealing: textView,
                modeButton: modeToggleButton
            )
            self.experimentalComposerView = nil
        }
        let attributed = makeComposerAttributedString(raw)
        applyComposerAttributedText(attributed, selectedRange: NSRange(location: attributed.length, length: 0))
    }

    private func rawText(inDisplayRange range: NSRange) -> String {
        let attributed = textView.attributedText ?? NSAttributedString(string: textView.text ?? "", attributes: composerTextAttributes)
        let validRange = clampedRange(range, length: attributed.length)
        guard validRange.length > 0 else { return "" }
        return rawText(from: attributed.attributedSubstring(from: validRange))
    }

    private func rawText(from attributed: NSAttributedString) -> String {
        let expanded = expandingEmojiShortcodes(in: attributed)
        if editingMode == .rich {
            return ComposerMarkdownCodec.markdown(from: expanded)
        }
        var result = ""
        expanded.enumerateAttributes(in: NSRange(location: 0, length: expanded.length)) { attributes, range, _ in
            let text = expanded.attributedSubstring(from: range).string
            result += text.replacingOccurrences(of: "\u{fffc}", with: "")
        }
        return result
    }

    private func expandingEmojiShortcodes(in attributed: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        var location = result.length
        while location > 0 {
            location -= 1
            let attrs = result.attributes(at: location, effectiveRange: nil)
            guard let attachment = attrs[.attachment] as? EmojiTextAttachment,
                  let shortcode = attachment.shortcode
            else { continue }
            var range = NSRange(location: location, length: 1)
            result.attributes(at: location, effectiveRange: &range)
            var textAttrs = attrs
            textAttrs[.attachment] = nil
            result.replaceCharacters(in: range, with: NSAttributedString(string: shortcode, attributes: textAttrs))
            location = range.location
        }
        return result
    }

    private func makeComposerAttributedString(_ raw: String) -> NSMutableAttributedString {
        let styled: NSMutableAttributedString
        if editingMode == .rich {
            styled = ComposerMarkdownCodec.richAttributedString(from: raw)
        } else {
            styled = ComposerMarkdownRenderer.styleSource(raw, baseAttributes: composerTextAttributes)
        }
        return attachEmojiShortcodes(in: styled)
    }

    private func makeComposerSnippet(_ raw: String) -> NSMutableAttributedString {
        let styled = makeComposerAttributedString(raw)
        if editingMode == .rich, styled.string.hasSuffix("\n"), styled.length > 0 {
            styled.deleteCharacters(in: NSRange(location: styled.length - 1, length: 1))
        }
        return styled
    }

    private func attachEmojiShortcodes(in styled: NSMutableAttributedString) -> NSMutableAttributedString {
        let font = ComposerTypography.bodyFont
        let matches = Self.emojiShortcodeRegex.matches(in: styled.string, range: NSRange(location: 0, length: styled.length))
        let result = NSMutableAttributedString()
        var cursor = 0
        for match in matches {
            let fullRange = match.range(at: 0)
            let codeRange = match.range(at: 1)
            if fullRange.location > cursor {
                result.append(styled.attributedSubstring(from: NSRange(location: cursor, length: fullRange.location - cursor)))
            }
            let code = (styled.string as NSString).substring(with: codeRange)
            let shortcode = (styled.string as NSString).substring(with: fullRange)
            if let urlString = EmojiStore.url(for: code), let url = URL(string: urlString) {
                let attachment = EmojiTextAttachment()
                attachment.emojiURL = url
                attachment.shortcode = shortcode
                attachment.bounds = CGRect(
                    x: 0,
                    y: font.descender,
                    width: font.lineHeight,
                    height: font.lineHeight
                )
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(styled.attributedSubstring(from: fullRange))
            }
            cursor = fullRange.location + fullRange.length
        }
        if cursor < styled.length {
            result.append(styled.attributedSubstring(from: NSRange(location: cursor, length: styled.length - cursor)))
        }
        return result
    }

    private func scheduleSourceRestyle() {
        guard !isPreviewingMarkdown else { return }
        guard editingMode == .source else { return }
        // Don't fight IME marked text — restyling mid-composition jumps the caret.
        guard textView.markedTextRange == nil else { return }
        sourceRestyleTask?.cancel()
        let delayNs: UInt64 = AppSettings.shared.composerInstantRender ? 40_000_000 : 220_000_000
        sourceRestyleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard let self, !Task.isCancelled, !self.isApplyingAttributedText, !self.isPreviewingMarkdown else { return }
            guard self.textView.markedTextRange == nil else { return }
            self.restyleSourcePreservingSelection()
        }
    }

    private func restyleSourcePreservingSelection() {
        let raw = composerRawText
        let selection = textView.selectedRange
        let rawPrefix = rawText(inDisplayRange: NSRange(location: 0, length: min(selection.location, textView.attributedText?.length ?? 0)))
        let styled = makeComposerAttributedString(raw)
        let caret = makeComposerAttributedString(rawPrefix).length
        let selected = NSRange(location: min(caret, styled.length), length: 0)
        applyComposerAttributedText(styled, selectedRange: selected)
        loadComposerEmojiImages(in: textView.attributedText ?? styled)
    }

    private func replaceDisplayRange(
        _ range: NSRange,
        withRawText raw: String,
        selectedRangeInInsertedText: NSRange? = nil
    ) {
        if let experimentalComposerView {
            experimentalComposerView.replaceActiveDisplayRange(range, withRaw: raw)
            updatePlaceholder()
            updateSendButton()
            return
        }
        let current = NSMutableAttributedString(attributedString: textView.attributedText ?? NSAttributedString(string: textView.text ?? "", attributes: composerTextAttributes))
        let validRange = clampedRange(range, length: current.length)
        let inserted = makeComposerSnippet(raw)
        current.replaceCharacters(in: validRange, with: inserted)

        let relativeSelection = selectedRangeInInsertedText ?? NSRange(location: inserted.length, length: 0)
        let selectedLocation = min(max(relativeSelection.location, 0), inserted.length)
        let selectedLength = min(max(relativeSelection.length, 0), inserted.length - selectedLocation)
        let selectedRange = NSRange(location: validRange.location + selectedLocation, length: selectedLength)
        applyComposerAttributedText(current, selectedRange: selectedRange)
    }

    private func replaceSelection(withRawText raw: String, selectedRangeInInsertedText: NSRange? = nil) {
        if let experimentalComposerView {
            experimentalComposerView.insertRaw(raw)
            updatePlaceholder()
            updateSendButton()
            return
        }
        replaceDisplayRange(textView.selectedRange, withRawText: raw, selectedRangeInInsertedText: selectedRangeInInsertedText)
    }

    private func applyComposerAttributedText(_ attributed: NSMutableAttributedString, selectedRange: NSRange) {
        isApplyingAttributedText = true
        textView.attributedText = attributed
        textView.typingAttributes = composerTextAttributes
        if editingMode == .rich {
            textView.typingAttributes = ComposerMarkdownCodec.typingAttributes(
                at: selectedRange.location,
                in: attributed
            )
        }
        textView.selectedRange = clampedRange(selectedRange, length: attributed.length)
        isApplyingAttributedText = false

        loadComposerEmojiImages(in: attributed)
        updatePlaceholder()
        updateSendButton()
        if isPreviewingMarkdown {
            previewView.update(markdown: ComposerPangu.applyToOutgoing(composerRawText))
        } else {
            refreshMentionSuggestions()
        }
    }

    private func loadComposerEmojiImages(in attributed: NSAttributedString) {
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            guard let attachment = value as? EmojiTextAttachment,
                  attachment.image == nil,
                  let url = attachment.emojiURL
            else { return }

            ForumImageLoader.loadImage(with: url) { [weak self, weak attachment] image in
                guard let self, let attachment, let image else { return }
                Task { @MainActor in
                    attachment.image = image
                    self.textView.layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: self.textView.attributedText.length))
                    self.textView.setNeedsDisplay()
                }
            }
        }
    }

    private func clampedRange(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        let upperBound = min(max(range.location + range.length, location), length)
        return NSRange(location: location, length: upperBound - location)
    }

    private func insertText(_ text: String) {
        replaceSelection(withRawText: text)
        refreshMentionSuggestions()
    }

    // MARK: - @ mention

    private func refreshMentionSuggestions() {
        guard !isPreviewingMarkdown, !isApplyingAttributedText else {
            hideMentionPicker()
            return
        }
        let display = composerDisplayText
        let cursor = mentionSourceTextView.selectedRange.location
        guard let query = Self.activeMentionQuery(in: display, cursor: cursor) else {
            hideMentionPicker()
            return
        }
        activeMentionRange = query.range
        repositionMentionPicker()
        scheduleMentionSearch(term: query.term)
    }

    private func hideMentionPicker() {
        activeMentionRange = nil
        mentionSearchTask?.cancel()
        mentionSearchTask = nil
        mentionPickerView.hide(animated: true)
    }

    private func scheduleMentionSearch(term: String) {
        mentionSearchTask?.cancel()
        mentionSearchGeneration += 1
        let generation = mentionSearchGeneration
        let topicId = self.topicId
        let seed = localMentionSeeds(matching: term)

        // FluxDo shows the overlay as soon as @ is active. Local topic posters
        // fill the list instantly (matches the screenshot of many candidates).
        view.bringSubviewToFront(mentionPickerView)
        if !seed.isEmpty {
            mentionPickerView.update(users: seed, animated: true)
            view.layoutIfNeeded()
            repositionMentionPicker()
        }

        mentionSearchTask = Task { [weak self] in
            // FluxDo default debounce is 300ms; keep empty-term snappy (topic participants).
            let delay: UInt64 = term.isEmpty ? 80_000_000 : 300_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            do {
                let remote = try await self?.api.searchUsersForMention(term: term, topicId: topicId) ?? []
                guard !Task.isCancelled, let self, generation == self.mentionSearchGeneration else { return }
                let merged = Self.mergeMentionUsers(seed: seed, remote: remote)
                await MainActor.run {
                    guard generation == self.mentionSearchGeneration, self.activeMentionRange != nil else { return }
                    self.view.bringSubviewToFront(self.mentionPickerView)
                    self.mentionPickerView.update(users: merged, animated: true)
                    self.view.layoutIfNeeded()
                    self.repositionMentionPicker()
                }
            } catch {
                guard !Task.isCancelled, let self, generation == self.mentionSearchGeneration else { return }
                await MainActor.run {
                    // Keep local seeds on network failure so @ still does something.
                    if seed.isEmpty {
                        self.mentionPickerView.hide(animated: true)
                    }
                }
            }
        }
    }

    private func localMentionSeeds(matching term: String) -> [DiscourseMentionUser] {
        var seeds: [DiscourseMentionUser] = mentionSeedUsers
        if let reply = replyToPost {
            seeds.insert(
                DiscourseMentionUser(
                    username: reply.username,
                    name: reply.name,
                    avatarTemplate: reply.avatarTemplate
                ),
                at: 0
            )
        }
        // Dedupe while preserving order (reply target first).
        var seen = Set<String>()
        seeds = seeds.filter { user in
            let key = user.username.lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(seeds.prefix(8)) }
        return seeds.filter {
            $0.username.lowercased().hasPrefix(needle)
                || ($0.name?.lowercased().contains(needle) ?? false)
        }
    }

    private static func mergeMentionUsers(
        seed: [DiscourseMentionUser],
        remote: [DiscourseMentionUser]
    ) -> [DiscourseMentionUser] {
        var seen = Set<String>()
        var result: [DiscourseMentionUser] = []
        for user in seed + remote {
            let key = user.username.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(user)
            if result.count >= 12 { break }
        }
        return result
    }

    private func insertMention(_ user: DiscourseMentionUser) {
        guard let range = activeMentionRange else { return }
        let insertion = "@\(user.username) "
        replaceDisplayRange(range, withRawText: insertion)
        hideMentionPicker()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func repositionMentionPicker() {
        // Keep the card near the caret so it matches FluxDO-style placement.
        guard let range = activeMentionRange,
              range.location != NSNotFound,
              mentionSourceTextView.bounds.height > 0
        else { return }

        let caretRange = NSRange(location: min(range.location, max((mentionSourceTextView.attributedText?.length ?? 0) - 1, 0)), length: 0)
        var caretRect = mentionSourceTextView.caretRect(for: mentionSourceTextView.position(
            from: mentionSourceTextView.beginningOfDocument,
            offset: caretRange.location
        ) ?? mentionSourceTextView.endOfDocument)

        if caretRect.isNull || caretRect.origin.x.isInfinite || caretRect.origin.y.isInfinite {
            caretRect = CGRect(x: 22, y: 22, width: 2, height: 28)
        }

        let converted = mentionSourceTextView.convert(caretRect, to: activeEditorView)
        let top = max(12, min(converted.maxY + 8, activeEditorView.bounds.height - 80))
        let leading = max(16, min(converted.minX, activeEditorView.bounds.width - 220))
        mentionPickerBottomConstraint?.constant = top
        mentionPickerLeadingConstraint?.constant = leading
    }

    /// Finds `@term` immediately before the cursor — FluxDo parity:
    /// `RegExp(r'@([\w_-]*)$')` with `@` at start or after whitespace/newline.
    static func activeMentionQuery(in displayText: String, cursor: Int) -> (term: String, range: NSRange)? {
        let ns = displayText as NSString
        let length = ns.length
        guard cursor > 0, cursor <= length else { return nil }

        // Use NSString end-to-end so UTF-16 indices match UITextView.selectedRange.
        let before = ns.substring(to: cursor) as NSString
        // Explicit ASCII class (FluxDo `\w` ≈ [A-Za-z0-9_]); hyphen must be at end of class.
        guard let regex = try? NSRegularExpression(pattern: #"@([A-Za-z0-9_-]*)$"#, options: []) else {
            return nil
        }
        let full = NSRange(location: 0, length: before.length)
        guard let match = regex.firstMatch(in: before as String, options: [], range: full),
              match.numberOfRanges >= 2
        else { return nil }

        let atIndex = match.range.location
        // Boundary: start of text, or whitespace / newline before @ (FluxDo).
        if atIndex > 0 {
            let prev = before.character(at: atIndex - 1)
            guard let prevScalar = UnicodeScalar(prev),
                  CharacterSet.whitespacesAndNewlines.contains(prevScalar)
            else { return nil }
        }

        let termRange = match.range(at: 1)
        let term = before.substring(with: termRange)
        return (term, NSRange(location: atIndex, length: match.range.length))
    }

    private func applyFullRawText(_ raw: String) {
        if let experimentalComposerView {
            experimentalComposerView.replaceFullRaw(raw)
            updatePlaceholder()
            updateSendButton()
            if isPreviewingMarkdown {
                previewView.update(markdown: ComposerPangu.applyToOutgoing(raw))
            }
            return
        }
        isApplyingAttributedText = true
        textView.attributedText = makeComposerAttributedString(raw)
        isApplyingAttributedText = false
        updatePlaceholder()
        updateSendButton()
        if isPreviewingMarkdown {
            previewView.update(markdown: ComposerPangu.applyToOutgoing(raw))
        }
    }

    private func updatePlaceholder() {
        if usesExperimentalComposer {
            placeholderLabel.isHidden = true
            return
        }
        placeholderLabel.isHidden = isPreviewingMarkdown || !composerRawText.isEmpty
    }

    private func configureHeaderCopy() {
        switch submissionMode {
        case .reply:
            if let username = replyToPost?.username, !username.isEmpty {
                headerTitleLabel.text = String(localized: "reply.title", defaultValue: "回复")
                headerSubtitleLabel.text = "@\(username)"
                headerSubtitleLabel.isHidden = false
            } else {
                headerTitleLabel.text = String(localized: "reply.title.topic")
                headerSubtitleLabel.text = nil
                headerSubtitleLabel.isHidden = true
            }
        case .edit:
            headerTitleLabel.text = String(localized: "post.edit.title", defaultValue: "编辑评论")
            headerSubtitleLabel.text = nil
            headerSubtitleLabel.isHidden = true
            sendButton.accessibilityLabel = String(localized: "common.save")
        }
    }

    private func configureCloseMenu() {
        guard case .reply = submissionMode else {
            closeButton.menu = nil
            return
        }
        closeButton.menu = UIMenu(children: [
            UIAction(
                title: String(localized: "reply.discard"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.discardTapped()
            }
        ])
        closeButton.showsMenuAsPrimaryAction = false
    }

    private func updateSendButton() {
        let enabled = !composerRawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = enabled && !isUploading
        sendButton.alpha = 1
    }

    private func updatePreviewState() {
        let showPreview = isPreviewingMarkdown
        let editor = activeEditorView
        let needsSwitch = previewView.isHidden == showPreview
        if view.window != nil, needsSwitch {
            let shown = showPreview ? previewView : editor
            let hidden = showPreview ? editor : previewView
            shown.alpha = 0
            shown.isHidden = false
            AnimationOptimizer.animateAlpha(shown, to: 1, duration: 0.18)
            AnimationOptimizer.animateAlpha(hidden, to: 0, duration: 0.18) {
                hidden.isHidden = true
                hidden.alpha = 1
            }
        } else {
            editor.isHidden = showPreview
            previewView.isHidden = !showPreview
            editor.alpha = 1
            previewView.alpha = 1
        }
        if usesExperimentalComposer {
            experimentalComposerView?.isHidden = showPreview || isExperimentalSourceVisible
            textView.isHidden = showPreview || !isExperimentalSourceVisible
            placeholderLabel.isHidden = true
        } else {
            placeholderLabel.isHidden = showPreview || !composerRawText.isEmpty
        }
        updateToolbarState()
    }

    private func updateToolbarState() {
        ComposerToolbarFactory.updateToolbarTints(
            emojiButton: emojiToggleButton,
            previewButton: previewToggleButton,
            modeButton: modeToggleButton,
            toolsButton: toolsToggleButton,
            panel: currentPanel,
            isPreviewing: isPreviewingMarkdown,
            editingMode: isExperimentalSourceVisible ? .source : .rich
        )
    }

    @objc private func closeTapped() {
        hideMentionPicker()
        dismiss(animated: true)
    }

    @objc private func discardTapped() {
        hideMentionPicker()
        guard case .reply = submissionMode, serverDraftKey != nil else {
            dismiss(animated: true)
            return
        }
        let alert = UIAlertController(
            title: String(localized: "reply.discard.confirm.title"),
            message: String(localized: "reply.discard.confirm.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "reply.discard"), style: .destructive) { [weak self] _ in
            guard let self, let draftKey = self.serverDraftKey else { return }
            self.isDiscardingDraft = true
            self.draftSaveTask?.cancel()
            self.serverDraftSaveTask?.cancel()
            Task {
                await ComposerServerDraftSync.clearServerDraft(api: self.api, draftKey: draftKey)
                await MainActor.run {
                    self.onDraftDeleted?()
                    self.dismiss(animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    @objc private func sendTapped() {
        hideMentionPicker()
        let raw = ComposerPangu.applyToOutgoing(
            composerRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !raw.isEmpty, !isSubmitting else { return }

        isSubmitting = true
        // Stop any in-flight autosave so it cannot re-write the draft after we clear it.
        draftSaveTask?.cancel()
        serverDraftSaveTask?.cancel()
        sourceRestyleTask?.cancel()
        sendButton.isEnabled = false
        textView.isEditable = false
        experimentalComposerView?.isEditable = false
        closePanel(returnToKeyboard: false)

        Task {
            do {
                switch submissionMode {
                case .reply:
                    let response = try await api.createReply(
                        topicId: topicId,
                        replyToPostNumber: replyToPost?.postNumber,
                        raw: raw
                    )
                    guard let draftKey = self.serverDraftKey else { return }
                    let api = self.api
                    // Await server draft delete before dismiss so hydrate on next open
                    // cannot race a late autosave / stale server body.
                    await ComposerServerDraftSync.clearServerDraft(api: api, draftKey: draftKey)
                    if response.isEnqueued {
                        presentQueuedAlert()
                        return
                    }
                    dismiss(animated: true) { [weak self] in
                        self?.onPostCreated?()
                    }
                case .edit(let postId):
                    try await api.updatePost(id: postId, raw: raw)
                    dismiss(animated: true) { [weak self] in
                        self?.onPostUpdated?(postId)
                    }
                }
            } catch {
                isSubmitting = false
                sendButton.isEnabled = true
                textView.isEditable = true
                experimentalComposerView?.isEditable = true
                let alert = UIAlertController(
                    title: String(localized: "reply.send.failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(
                    title: String(localized: "common.retry", defaultValue: "重试"),
                    style: .default
                ) { [weak self] _ in
                    self?.sendTapped()
                })
                alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .cancel))
                present(alert, animated: true)
            }
        }
    }

    private func presentQueuedAlert() {
        let alert = UIAlertController(
            title: String(localized: "post.submit.queued.title"),
            message: String(localized: "post.submit.queued.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    private func applyRichLinePrefix(_ prefix: String) {
        if let experimentalComposerView {
            experimentalComposerView.applyLinePrefix(prefix)
            return
        }
        let attributed = textView.attributedText ?? NSAttributedString(string: "", attributes: composerTextAttributes)
        guard attributed.length > 0 else {
            replaceDisplayRange(NSRange(location: 0, length: 0), withRawText: prefix)
            return
        }
        let ns = attributed.string as NSString
        let selection = textView.selectedRange
        let lineRange = ns.lineRange(for: NSRange(location: min(selection.location, ns.length), length: 0))
        let hasNewline = ns.substring(with: lineRange).hasSuffix("\n")
        let contentRange = NSRange(
            location: lineRange.location,
            length: max(lineRange.length - (hasNewline ? 1 : 0), 0)
        )
        guard contentRange.length > 0 else {
            replaceDisplayRange(NSRange(location: lineRange.location, length: 0), withRawText: prefix)
            return
        }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        if prefix.hasPrefix("> ") {
            let depth = (mutable.attribute(.composerQuoteDepth, at: contentRange.location, effectiveRange: nil) as? Int) ?? 0
            let next = depth > 0 ? 0 : 1
            mutable.addAttribute(.composerQuoteDepth, value: next, range: contentRange)
            mutable.addAttribute(.foregroundColor, value: next > 0 ? UIColor.secondaryLabel : UIColor.label, range: contentRange)
            mutable.addAttribute(
                .paragraphStyle,
                value: ComposerTypography.paragraphStyle(headIndent: next > 0 ? 14 : 0),
                range: contentRange
            )
        } else if prefix == "- " || prefix.hasSuffix(". ") {
            let existing = mutable.attribute(.composerListMarker, at: contentRange.location, effectiveRange: nil) as? String
            if existing == prefix {
                mutable.removeAttribute(.composerListMarker, range: contentRange)
            } else {
                mutable.addAttribute(.composerListMarker, value: prefix, range: contentRange)
            }
        } else if prefix.hasPrefix("#") {
            let level = prefix.filter { $0 == "#" }.count
            let existing = mutable.attribute(.composerHeadingLevel, at: contentRange.location, effectiveRange: nil) as? Int
            if existing == level {
                mutable.removeAttribute(.composerHeadingLevel, range: contentRange)
                mutable.addAttribute(.font, value: ComposerTypography.bodyFont, range: contentRange)
            } else {
                mutable.addAttribute(.composerHeadingLevel, value: level, range: contentRange)
                mutable.addAttribute(.font, value: ComposerTypography.headingFont(level: max(level, 1)), range: contentRange)
            }
        } else {
            replaceDisplayRange(NSRange(location: lineRange.location, length: 0), withRawText: prefix)
            return
        }
        applyComposerAttributedText(mutable, selectedRange: selection)
    }
}

// MARK: - ComposerTextSurface

extension ReplyComposerViewController: ComposerTextSurface {
    var composerHostViewController: UIViewController { self }
    var composerAPI: DiscourseAPI { api }
    var composerTextView: UITextView { mentionSourceTextView }
    var composerToolsAnchorView: UIView { toolsToggleButton }
    var composerIsUploading: Bool { isUploading }

    var composerRawText: String { bodyRawText }

    func composerSelectedRawText() -> String {
        if let experimentalComposerView {
            return experimentalComposerView.selectedRawText()
        }
        let selection = textView.selectedRange
        guard selection.length > 0 else { return "" }
        return rawText(inDisplayRange: selection)
    }

    func composerInsertRaw(_ text: String) {
        replaceSelection(withRawText: text)
        updatePlaceholder()
        updateSendButton()
        scheduleDraftSave()
    }

    func composerWrapSelection(start: String, end: String, placeholder: String) {
        if let experimentalComposerView {
            experimentalComposerView.wrapSelection(start: start, end: end, placeholder: placeholder)
            updatePlaceholder()
            updateSendButton()
            scheduleDraftSave()
            return
        }
        let selection = textView.selectedRange
        let selected = selection.length > 0 ? rawText(inDisplayRange: selection) : placeholder
        let replacement = "\(start)\(selected)\(end)"
        if editingMode == .rich {
            let visual = makeComposerSnippet(replacement)
            replaceDisplayRange(
                selection,
                withRawText: replacement,
                selectedRangeInInsertedText: NSRange(location: 0, length: visual.length)
            )
        } else {
            let selectedDisplayLength = makeComposerAttributedString(selected).length
            replaceDisplayRange(
                selection,
                withRawText: replacement,
                selectedRangeInInsertedText: NSRange(location: start.count, length: selectedDisplayLength)
            )
        }
        updatePlaceholder()
        updateSendButton()
        scheduleDraftSave()
    }

    func composerApplyLinePrefix(_ prefix: String) {
        if usesExperimentalComposer {
            applyRichLinePrefix(prefix)
            updatePlaceholder()
            updateSendButton()
            scheduleDraftSave()
            return
        }
        if editingMode == .rich {
            applyRichLinePrefix(prefix)
            updatePlaceholder()
            updateSendButton()
            scheduleDraftSave()
            return
        }
        let text = composerDisplayText
        let nsText = text as NSString
        let selection = textView.selectedRange
        let lineRange = nsText.lineRange(for: NSRange(location: min(selection.location, nsText.length), length: 0))
        let lineText = nsText.substring(with: lineRange)
        if lineText.hasPrefix(prefix) {
            let removalRange = NSRange(location: lineRange.location, length: prefix.count)
            replaceDisplayRange(removalRange, withRawText: "")
            textView.selectedRange = clampedRange(
                NSRange(location: max(selection.location - prefix.count, lineRange.location), length: selection.length),
                length: textView.attributedText.length
            )
        } else {
            replaceDisplayRange(NSRange(location: lineRange.location, length: 0), withRawText: prefix)
            textView.selectedRange = clampedRange(
                NSRange(location: selection.location + prefix.count, length: selection.length),
                length: textView.attributedText.length
            )
        }
        updatePlaceholder()
        updateSendButton()
        scheduleDraftSave()
    }

    func composerFocusedBlockRaw() -> String? {
        experimentalComposerView?.focusedBlockRaw
    }

    func composerReplaceFocusedBlock(with raw: String) {
        if let experimentalComposerView {
            experimentalComposerView.replaceFocusedBlock(with: raw)
            updatePlaceholder()
            updateSendButton()
            scheduleDraftSave()
            return
        }
        composerInsertRaw(raw)
    }

    func composerReplaceFullRaw(_ raw: String) {
        applyFullRawText(raw)
        scheduleDraftSave()
    }

    func composerDidEditContent() {
        updatePlaceholder()
        updateSendButton()
        scheduleDraftSave()
    }

    func composerSetUploading(_ uploading: Bool, statusText: String?) {
        isUploading = uploading
        uploadStatusLabel.text = statusText
        uploadStatusLabel.isHidden = !uploading
        textView.isEditable = !uploading
        experimentalComposerView?.isEditable = !uploading
        updateSendButton()
        toolsPanelView.isUploading = uploading
    }

    func composerCloseToolPanel(returnToKeyboard: Bool) {
        closePanel(returnToKeyboard: returnToKeyboard)
    }

    func composerExitMarkdownPreviewIfNeeded() {
        guard isPreviewingMarkdown else { return }
        isPreviewingMarkdown = false
        updatePreviewState()
    }
}



extension ReplyComposerViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard !isApplyingAttributedText else { return }
        updatePlaceholder()
        updateSendButton()
        scheduleDraftSave()
        if isPreviewingMarkdown {
            previewView.update(markdown: ComposerPangu.applyToOutgoing(composerRawText))
            hideMentionPicker()
        } else {
            scheduleSourceRestyle()
            refreshMentionSuggestions()
        }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isApplyingAttributedText else { return }
        if editingMode == .rich, let attributed = textView.attributedText {
            textView.typingAttributes = ComposerMarkdownCodec.typingAttributes(
                at: textView.selectedRange.location,
                in: attributed
            )
        }
        refreshMentionSuggestions()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if currentPanel != .none {
            closePanel(returnToKeyboard: false)
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        hideMentionPicker()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === textView, activeMentionRange != nil else { return }
        repositionMentionPicker()
    }
}
