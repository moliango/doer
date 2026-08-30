import PhotosUI
import UIKit
import UniformTypeIdentifiers

struct NewTopicSubmission: Equatable {
    let title: String
    let raw: String
    let categoryId: Int?
    let tags: [String]

    static func make(title: String, raw: String, categoryId: Int?, tags: [String]) -> NewTopicSubmission? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !raw.isEmpty else { return nil }

        var seen = Set<String>()
        let tags = tags.compactMap { value -> String? in
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { return nil }
            let key = tag.lowercased()
            return seen.insert(key).inserted ? tag : nil
        }
        return NewTopicSubmission(title: title, raw: raw, categoryId: categoryId, tags: tags)
    }
}

final class NewTopicComposerViewController: UIViewController {
    // Panel state shared via ComposerPanelKind

    private let api: DiscourseAPI
    private let categories: [DiscourseCategory]
    private let categoriesById: [Int: DiscourseCategory]
    private var selectedCategoryId: Int?
    private var selectedTags: [String]
    private let initialTitle: String
    private let initialRaw: String
    private let draftKey: String

    private var currentPanel: ComposerPanelKind = .none
    private var editingMode = ComposerEditingMode.stored
    private let modeToggleButton = ComposerToolbarFactory.makeModeButton()
    private var hasLoadedForumEmojis = false
    private var isPreviewingMarkdown = false
    private var isUploading = false
    private var isSubmitting = false
    private var draftSaveTask: Task<Void, Never>?
    private var serverDraftSaveTask: Task<Void, Never>?
    private var panelHeightConstraint: NSLayoutConstraint?
    private let markdownCoordinator = ComposerMarkdownCoordinator()
    
    var onTopicCreated: ((Int) -> Void)?
    var onDraftDeleted: (() -> Void)?
    private var isDiscardingDraft = false
    private var isSavingDraft = false


    private let titleField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = String(localized: "new_topic.title.placeholder")
        field.font = ComposerTypography.titleFont
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.borderStyle = .none
        field.returnKeyType = .next
        field.clearButtonMode = .whileEditing
        return field
    }()

    private let metadataStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }()

    private let categoryButton: UIButton = {
        let button = UIButton(configuration: .plain())
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    private let tagsScrollView: UIScrollView = {
        let view = UIScrollView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.showsHorizontalScrollIndicator = false
        return view
    }()

    private let tagsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        return stack
    }()

    private let metadataSeparator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .separator.withAlphaComponent(0.55)
        return view
    }()

    private let characterCountLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        return label
    }()

    private let textView: ComposerBodyTextView = {
        let view = ComposerBodyTextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        ComposerTypography.applyBody(to: view)
        return view
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "new_topic.body.placeholder")
        ComposerTypography.applyBody(to: label)
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
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.isHidden = true
        return label
    }()

    private lazy var emojiPickerView: EmojiStickerPanelView = {
        let picker = EmojiStickerPanelView()
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.onEmojiSelected = { [weak self] emoji in
            self?.composerInsertRaw(emoji)
        }
        picker.onStickerMarkdownSelected = { [weak self] markdown in
            self?.composerInsertRaw(markdown + "\n")
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

    private lazy var closeButton: UIButton = {
        let button = ComposerToolbarFactory.makeCloseIconButton()
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        button.menu = UIMenu(children: [
            UIAction(
                title: String(localized: "reply.discard"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self] _ in
                self?.discardTapped()
            }
        ])
        button.showsMenuAsPrimaryAction = false
        return button
    }()

    private lazy var saveDraftButton: UIButton = {
        let button = ComposerToolbarFactory.makeSaveDraftIconButton()
        button.addTarget(self, action: #selector(saveDraftTapped), for: .touchUpInside)
        return button
    }()

    private lazy var publishButton: UIButton = {
        let button = ComposerToolbarFactory.makeSendIconButton(
            accessibilityLabel: String(localized: "new_topic.publish", defaultValue: "发布")
        )
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        return button
    }()

    init(
        api: DiscourseAPI,
        categories: [DiscourseCategory],
        initialCategoryId: Int?,
        initialTitle: String = "",
        initialRaw: String = "",
        initialTags: [String] = [],
        draftKey: String = "new_topic"
    ) {
        self.api = api
        self.categories = categories
        self.categoriesById = DiscourseCategory.indexedById(from: categories)
        self.selectedCategoryId = initialCategoryId
        self.selectedTags = Self.normalizedTags(initialTags)
        self.initialTitle = initialTitle
        self.initialRaw = initialRaw
        self.draftKey = draftKey
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "new_topic.title")
        ComposerTypography.applyChrome(to: view)
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(customView: publishButton),
            UIBarButtonItem(customView: saveDraftButton),
            UIBarButtonItem(customView: closeButton),
        ]

        setupHierarchy()
        setupConstraints()
        setupToolbar()
        setupCustomPanel()
        emojiPickerView.presentingViewController = self

        titleField.text = initialTitle
        applyBodyMarkdown(initialRaw)
        titleField.delegate = self
        titleField.addTarget(self, action: #selector(textInputsChanged), for: .editingChanged)
        textView.delegate = self
        markdownCoordinator.surface = self
        textView.pasteCoordinator = markdownCoordinator
        categoryButton.addTarget(self, action: #selector(categoryButtonPressed), for: .touchDown)
        emojiToggleButton.addTarget(self, action: #selector(toggleEmojiPicker), for: .touchUpInside)
        encryptToolbarButton.addTarget(self, action: #selector(encryptToolbarTapped), for: .touchUpInside)
        previewToggleButton.addTarget(self, action: #selector(toggleMarkdownPreview), for: .touchUpInside)
        modeToggleButton.addTarget(self, action: #selector(toggleEditingMode), for: .touchUpInside)
        toolsToggleButton.addTarget(self, action: #selector(toggleToolsPanel), for: .touchUpInside)

        updateCategoryButton()
        rebuildTags()
        updateEditorState()

        Task { await hydrateServerDraftIfNeeded() }
    }

    /// Pull the server draft without overwriting an explicitly opened draft.
    private func hydrateServerDraftIfNeeded() async {
        do {
            guard let server = try await api.fetchDraft(key: draftKey) else { return }
            ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draftKey, sequence: server.sequence)
            let serverTitle = server.data.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let serverRaw = server.data.reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selectedCategoryId == nil,
                  selectedTags.isEmpty,
                  !serverTitle.isEmpty || !serverRaw.isEmpty || server.data.categoryId != nil || !server.data.tags.isEmpty else { return }
            titleField.text = server.data.title ?? ""
            applyBodyMarkdown(server.data.reply ?? "")
            selectedCategoryId = server.data.categoryId
            selectedTags = Self.normalizedTags(server.data.tags)
            updateCategoryButton()
            rebuildTags()
            updateEditorState()
        } catch {
            // Offline / CF: keep the current composer unchanged.
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if titleField.text?.isEmpty != false {
            titleField.becomeFirstResponder()
        } else {
            textView.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        draftSaveTask?.cancel()
        serverDraftSaveTask?.cancel()
    }

    private func scheduleDraftSave() {}


    private func setupHierarchy() {
        view.addSubview(titleField)
        view.addSubview(metadataStack)
        metadataStack.addArrangedSubview(categoryButton)
        metadataStack.addArrangedSubview(tagsScrollView)
        tagsScrollView.addSubview(tagsStack)
        view.addSubview(metadataSeparator)
        view.addSubview(characterCountLabel)
        view.addSubview(textView)
        view.addSubview(previewView)
        view.addSubview(placeholderLabel)
        view.addSubview(bottomStackView)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            titleField.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),

            metadataStack.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 14),
            metadataStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            metadataStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            tagsScrollView.widthAnchor.constraint(equalTo: metadataStack.widthAnchor),
            tagsScrollView.heightAnchor.constraint(equalToConstant: 42),
            tagsStack.topAnchor.constraint(equalTo: tagsScrollView.contentLayoutGuide.topAnchor),
            tagsStack.leadingAnchor.constraint(equalTo: tagsScrollView.contentLayoutGuide.leadingAnchor),
            tagsStack.trailingAnchor.constraint(equalTo: tagsScrollView.contentLayoutGuide.trailingAnchor),
            tagsStack.bottomAnchor.constraint(equalTo: tagsScrollView.contentLayoutGuide.bottomAnchor),
            tagsStack.heightAnchor.constraint(equalTo: tagsScrollView.frameLayoutGuide.heightAnchor),

            metadataSeparator.topAnchor.constraint(equalTo: metadataStack.bottomAnchor, constant: 16),
            metadataSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            metadataSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            metadataSeparator.heightAnchor.constraint(equalToConstant: 0.5),

            characterCountLabel.topAnchor.constraint(equalTo: metadataSeparator.bottomAnchor, constant: 8),
            characterCountLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            textView.topAnchor.constraint(equalTo: characterCountLabel.bottomAnchor, constant: 2),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomStackView.topAnchor),

            previewView.topAnchor.constraint(equalTo: textView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: textView.bottomAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 14),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 24),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -20),

            bottomStackView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomStackView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomStackView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
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

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { value in
            let tag = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return tag
        }
    }

    private func parentCategory(for category: DiscourseCategory) -> DiscourseCategory? {
        category.parentCategoryId.flatMap { categoriesById[$0] }
    }

    private func updateCategoryButton() {
        let selected = selectedCategoryId.flatMap { categoriesById[$0] }
        var configuration = UIButton.Configuration.plain()
        configuration.title = selected.map { $0.displayName(parent: parentCategory(for: $0)) }
            ?? String(localized: "new_topic.category.none")
        configuration.image = UIImage(systemName: "square.grid.2x2")
        configuration.imagePadding = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 13, bottom: 10, trailing: 13)
        configuration.background.backgroundColor = .secondarySystemGroupedBackground
        configuration.background.cornerRadius = 11
        configuration.baseForegroundColor = selected == nil ? .secondaryLabel : .label
        categoryButton.configuration = configuration
        categoryButton.menu = UIMenu(children: categoryMenuElements())
    }

    private func categoryMenuElements() -> [UIMenuElement] {
        var items: [UIMenuElement] = [
            UIAction(
                title: String(localized: "new_topic.category.none"),
                state: selectedCategoryId == nil ? .on : .off
            ) { [weak self] _ in
                self?.selectedCategoryId = nil
                self?.updateCategoryButton()
            },
        ]
        for category in categories {
            items.append(categoryAction(category))
            category.subcategoryList?.forEach { items.append(categoryAction($0, prefix: "  ")) }
        }
        return items
    }

    private func categoryAction(_ category: DiscourseCategory, prefix: String = "") -> UIAction {
        UIAction(
            title: prefix + category.displayName(parent: parentCategory(for: category)),
            state: selectedCategoryId == category.id ? .on : .off
        ) { [weak self] _ in
            self?.selectedCategoryId = category.id
            self?.updateCategoryButton()
            self?.updateEditorState()
            self?.scheduleDraftSave()
        }
    }

    private func rebuildTags() {
        tagsStack.arrangedSubviews.forEach { view in
            tagsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        selectedTags.forEach { tag in
            var configuration = UIButton.Configuration.tinted()
            configuration.title = "#\(tag)"
            configuration.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 6
            configuration.cornerStyle = .capsule
            configuration.baseForegroundColor = AppSettings.shared.themeStyle.accentColor
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = String(format: String(localized: "new_topic.tags.remove_format", defaultValue: "移除标签 %@"), tag)
            button.addAction(UIAction { [weak self] _ in
                self?.selectedTags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
                self?.rebuildTags()
                self?.updateEditorState()
                self?.scheduleDraftSave()
            }, for: .touchUpInside)
            tagsStack.addArrangedSubview(button)
        }

        var addConfiguration = UIButton.Configuration.plain()
        addConfiguration.title = String(localized: "new_topic.tags.add", defaultValue: "添加标签")
        addConfiguration.image = UIImage(systemName: "plus")
        addConfiguration.imagePadding = 6
        addConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        addConfiguration.background.strokeColor = .separator
        addConfiguration.background.strokeWidth = 1
        addConfiguration.background.cornerRadius = 10
        let addButton = UIButton(configuration: addConfiguration)
        addButton.addTarget(self, action: #selector(addTagTapped), for: .touchUpInside)
        tagsStack.addArrangedSubview(addButton)
    }

    @objc private func categoryButtonPressed() {
        closePanel(returnToKeyboard: false)
    }

    @objc private func addTagTapped() {
        closePanel(returnToKeyboard: false)
        let picker = TagPickerViewController(api: api, categoryId: selectedCategoryId, selectedTag: nil)
        picker.onTagSelected = { [weak self] tag in
            guard let self, let tag else { return }
            guard !selectedTags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
            selectedTags.append(tag)
            rebuildTags()
            updateEditorState()
            scheduleDraftSave()
        }
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    @objc private func textInputsChanged() {
        updateEditorState()
        scheduleDraftSave()
    }

    private func updateEditorState() {
        placeholderLabel.isHidden = isPreviewingMarkdown || !bodyRaw.isEmpty
        characterCountLabel.text = String(
            format: String(localized: "new_topic.character_count_format", defaultValue: "%lld 字符"),
            Int64(bodyRaw.count)
        )
        let submission = NewTopicSubmission.make(
            title: titleField.text ?? "",
            raw: bodyRaw,
            categoryId: selectedCategoryId,
            tags: selectedTags
        )
        publishButton.isEnabled = submission != nil && !isUploading && !isSubmitting
        publishButton.alpha = 1
        if isPreviewingMarkdown {
            previewView.update(markdown: ComposerPangu.applyToOutgoing(bodyRaw))
        }
    }

    @objc private func encryptToolbarTapped() {
        markdownCoordinator.handleTool(.encrypt)
    }

    @objc private func toggleEmojiPicker() {
        setPanel(currentPanel == .emoji ? .none : .emoji)
    }

    @objc private func toggleToolsPanel() {
        setPanel(currentPanel == .tools ? .none : .tools)
    }

    @objc private func toggleMarkdownPreview() {
        isPreviewingMarkdown.toggle()
        if isPreviewingMarkdown {
            closePanel(returnToKeyboard: false)
            textView.resignFirstResponder()
            previewView.update(markdown: ComposerPangu.applyToOutgoing(bodyRaw))
        } else {
            textView.becomeFirstResponder()
        }
        let showPreview = isPreviewingMarkdown
        if view.window != nil {
            let shown = showPreview ? previewView : textView
            let hidden = showPreview ? textView : previewView
            shown.alpha = 0
            shown.isHidden = false
            AnimationOptimizer.animateAlpha(shown, to: 1, duration: 0.18)
            AnimationOptimizer.animateAlpha(hidden, to: 0, duration: 0.18) {
                hidden.isHidden = true
                hidden.alpha = 1
            }
        } else {
            textView.isHidden = showPreview
            previewView.isHidden = !showPreview
        }
        updateToolbarState()
        updateEditorState()
    }

    private func setPanel(_ panel: ComposerPanelKind) {
        if isPreviewingMarkdown {
            isPreviewingMarkdown = false
            textView.isHidden = false
            previewView.isHidden = true
        }
        currentPanel = panel
        switch panel {
        case .none:
            emojiPickerView.isHidden = true
            toolsPanelView.isHidden = true
            panelHeightConstraint?.constant = 0
            textView.becomeFirstResponder()
        case .emoji:
            textView.resignFirstResponder()
            emojiPickerView.isHidden = false
            toolsPanelView.isHidden = true
            panelHeightConstraint?.constant = ComposerToolbarFactory.customPanelHeight
            loadForumEmojis()
        case .tools:
            textView.resignFirstResponder()
            emojiPickerView.isHidden = true
            toolsPanelView.isHidden = false
            panelHeightConstraint?.constant = ComposerToolbarFactory.customPanelHeight
        }
        updateToolbarState()
        DoerMotion.animate(duration: DoerMotion.short) { self.view.layoutIfNeeded() }
    }

    private func closePanel(returnToKeyboard: Bool) {
        guard currentPanel != .none else { return }
        currentPanel = .none
        emojiPickerView.isHidden = true
        toolsPanelView.isHidden = true
        panelHeightConstraint?.constant = 0
        updateToolbarState()
        if returnToKeyboard { textView.becomeFirstResponder() }
        DoerMotion.animate(duration: DoerMotion.quick) { self.view.layoutIfNeeded() }
    }

    private func updateToolbarState() {
        ComposerToolbarFactory.updateToolbarTints(
            emojiButton: emojiToggleButton,
            previewButton: previewToggleButton,
            modeButton: modeToggleButton,
            toolsButton: toolsToggleButton,
            panel: currentPanel,
            isPreviewing: isPreviewingMarkdown,
            editingMode: editingMode
        )
    }

    @objc private func toggleEditingMode() {
        let raw = bodyRaw
        editingMode = editingMode.toggled
        ComposerEditingMode.stored = editingMode
        applyBodyMarkdown(raw)
        if isPreviewingMarkdown {
            isPreviewingMarkdown = false
            textView.isHidden = false
            previewView.isHidden = true
        }
        updateToolbarState()
        updateEditorState()
        textView.becomeFirstResponder()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var bodyRaw: String {
        guard let attributed = textView.attributedText, attributed.length > 0 else {
            return textView.text ?? ""
        }
        if editingMode == .rich {
            return ComposerMarkdownCodec.markdown(from: attributed)
        }
        return attributed.string
    }

    private func applyBodyMarkdown(_ raw: String) {
        if editingMode == .rich {
            textView.attributedText = ComposerMarkdownCodec.richAttributedString(from: raw)
        } else {
            textView.attributedText = ComposerMarkdownRenderer.styleSource(
                raw,
                baseAttributes: ComposerTypography.typingAttributes
            )
        }
        textView.typingAttributes = ComposerTypography.typingAttributes
    }

    private func insertRichSnippet(_ markdown: String) {
        let snippet = NSMutableAttributedString(
            attributedString: ComposerMarkdownCodec.richAttributedString(from: markdown)
        )
        if snippet.string.hasSuffix("\n"), snippet.length > 0 {
            snippet.deleteCharacters(in: NSRange(location: snippet.length - 1, length: 1))
        }
        let current = NSMutableAttributedString(
            attributedString: textView.attributedText ?? NSAttributedString(string: "", attributes: ComposerTypography.typingAttributes)
        )
        let selection = textView.selectedRange
        let location = min(max(selection.location, 0), current.length)
        let length = min(max(selection.length, 0), current.length - location)
        current.replaceCharacters(in: NSRange(location: location, length: length), with: snippet)
        textView.attributedText = current
        textView.selectedRange = NSRange(location: location + snippet.length, length: 0)
        textView.typingAttributes = ComposerTypography.typingAttributes
    }


    private func loadForumEmojis() {
        guard !hasLoadedForumEmojis else { return }
        hasLoadedForumEmojis = true
        emojiPickerView.showLoading()
        Task {
            do {
                let groups = try await api.fetchEmojiGroups()
                emojiPickerView.setEmojiGroups(groups, baseURL: api.baseURL)
            } catch {
                emojiPickerView.showError()
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func discardTapped() {
        let hasContent = !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedTags.isEmpty
        guard hasContent else {
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
            guard let self else { return }
            self.isDiscardingDraft = true
            self.draftSaveTask?.cancel()
            self.serverDraftSaveTask?.cancel()
            Task {
                await ComposerServerDraftSync.clearServerDraft(api: self.api, draftKey: self.draftKey)
                await MainActor.run {
                    self.onDraftDeleted?()
                    self.dismiss(animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    @objc private func saveDraftTapped() {
        guard !isSubmitting, !isSavingDraft else { return }
        isSavingDraft = true
        saveDraftButton.isEnabled = false
        draftSaveTask?.cancel()
        serverDraftSaveTask?.cancel()
        let api = self.api
        let title = titleField.text ?? ""
        let raw = bodyRaw
        let categoryId = selectedCategoryId
        let tags = selectedTags
        Task {
            let saved = await ComposerServerDraftSync.syncNewTopic(
                api: api,
                title: title,
                raw: raw,
                categoryId: categoryId,
                tags: tags,
                draftKey: self.draftKey
            )
            await MainActor.run {
                guard saved else {
                    self.isSavingDraft = false
                    self.saveDraftButton.isEnabled = true
                    let alert = UIAlertController(
                        title: String(localized: "common.save.failed", defaultValue: "保存草稿失败"),
                        message: String(localized: "common.retry_later", defaultValue: "请检查网络后重试。"),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
                    self.present(alert, animated: true)
                    return
                }
                self.dismiss(animated: true) { self.isSavingDraft = false }
            }
        }
    }

    @objc private func sendTapped() {
        guard !isSubmitting,
              let submission = NewTopicSubmission.make(
                  title: titleField.text ?? "",
                  raw: bodyRaw,
                  categoryId: selectedCategoryId,
                  tags: selectedTags
              )
        else { return }

        isSubmitting = true
        draftSaveTask?.cancel()
        serverDraftSaveTask?.cancel()
        closePanel(returnToKeyboard: false)
        setSubmissionControlsEnabled(false)
        Task {
            do {
                let response = try await api.createTopic(
                    title: submission.title,
                    raw: ComposerPangu.applyToOutgoing(submission.raw),
                    categoryId: submission.categoryId,
                    tags: submission.tags
                )
                let api = self.api
                await ComposerServerDraftSync.clearServerDraft(api: api, draftKey: self.draftKey)
                if response.isEnqueued {
                    presentQueuedAlert()
                    return
                }
                guard let topicId = response.topicId else {
                    throw NSError(
                        domain: "NewTopicComposer",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "new_topic.create.missing_topic")]
                    )
                }
                dismiss(animated: true) { [weak self] in self?.onTopicCreated?(topicId) }
            } catch {
                isSubmitting = false
                setSubmissionControlsEnabled(true)
                let alert = UIAlertController(
                    title: String(localized: "new_topic.create.failed"),
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

    private func setSubmissionControlsEnabled(_ enabled: Bool) {
        titleField.isEnabled = enabled
        textView.isEditable = enabled
        categoryButton.isEnabled = enabled
        tagsStack.isUserInteractionEnabled = enabled
        updateEditorState()
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
}

extension NewTopicComposerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textView.becomeFirstResponder()
        return true
    }
}

extension NewTopicComposerViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateEditorState()
        scheduleDraftSave()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        if currentPanel != .none { closePanel(returnToKeyboard: false) }
    }
}


// MARK: - ComposerTextSurface

extension NewTopicComposerViewController: ComposerTextSurface {
    var composerHostViewController: UIViewController { self }
    var composerAPI: DiscourseAPI { api }
    var composerTextView: UITextView { textView }
    var composerToolsAnchorView: UIView { toolsToggleButton }
    var composerIsUploading: Bool { isUploading }
    var composerRawText: String { bodyRaw }

    func composerSelectedRawText() -> String {
        let selection = textView.selectedRange
        guard selection.length > 0, let attributed = textView.attributedText else { return "" }
        if editingMode == .rich {
            return ComposerMarkdownCodec.markdown(from: attributed.attributedSubstring(from: selection))
        }
        return ComposerPlainTextEditing.selectedText(in: textView)
    }

    func composerInsertRaw(_ text: String) {
        if editingMode == .rich {
            insertRichSnippet(text)
        } else {
            ComposerPlainTextEditing.replaceSelection(in: textView, with: text)
        }
        updateEditorState()
        scheduleDraftSave()
    }

    func composerWrapSelection(start: String, end: String, placeholder: String) {
        if editingMode == .rich {
            let selected = composerSelectedRawText()
            let body = selected.isEmpty ? placeholder : selected
            insertRichSnippet("\(start)\(body)\(end)")
        } else {
            ComposerPlainTextEditing.wrapSelection(in: textView, start: start, end: end, placeholder: placeholder)
        }
        updateEditorState()
        scheduleDraftSave()
    }

    func composerApplyLinePrefix(_ prefix: String) {
        if editingMode == .rich {
            insertRichSnippet(prefix)
        } else {
            ComposerPlainTextEditing.applyLinePrefix(in: textView, prefix: prefix)
        }
        updateEditorState()
        scheduleDraftSave()
    }

    func composerReplaceFullRaw(_ raw: String) {
        applyBodyMarkdown(raw)
        updateEditorState()
        scheduleDraftSave()
    }

    func composerDidEditContent() {
        updateEditorState()
        scheduleDraftSave()
    }

    func composerSetUploading(_ uploading: Bool, statusText: String?) {
        isUploading = uploading
        uploadStatusLabel.text = statusText
        uploadStatusLabel.isHidden = !uploading
        textView.isEditable = !uploading
        titleField.isEnabled = !uploading
        categoryButton.isEnabled = !uploading
        toolsPanelView.isUploading = uploading
        updateEditorState()
    }

    func composerCloseToolPanel(returnToKeyboard: Bool) {
        closePanel(returnToKeyboard: returnToKeyboard)
    }

    func composerExitMarkdownPreviewIfNeeded() {
        guard isPreviewingMarkdown else { return }
        isPreviewingMarkdown = false
        textView.isHidden = false
        previewView.isHidden = true
        updateToolbarState()
        updateEditorState()
    }
}
