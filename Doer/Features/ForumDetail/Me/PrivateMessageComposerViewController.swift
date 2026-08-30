import UIKit

final class PrivateMessageComposerViewController: UIViewController, UITextViewDelegate, UITextFieldDelegate {
    var onMessageSent: ((DiscourseCreatePostResponse) -> Void)?
    var onDraftDeleted: (() -> Void)?
    private var isDiscardingDraft = false

    private let api: DiscourseAPI
    private let draftKey: String
    /// Empty means user must type/search a recipient (new-PM entry).
    private var recipient: String
    private let allowsEditingRecipient: Bool
    private var draftSaveTask: Task<Void, Never>?
    private var serverDraftSaveTask: Task<Void, Never>?

    private let recipientLabel = UILabel()
    private let recipientField = UITextField()
    private let titleField = UITextField()
    private let textView = ComposerBodyTextView()
    private let placeholderLabel = UILabel()
    private var editingMode = ComposerEditingMode.stored
    private var isSending = false
    private var isUploading = false
    private let initialRaw: String
    private var modeBarItem: UIBarButtonItem?
    private var previewBarItem: UIBarButtonItem?
    private var isPreviewingMarkdown = false
    private let previewView: ComposerMarkdownPreviewView = {
        let view = ComposerMarkdownPreviewView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        return view
    }()
    private let markdownCoordinator = ComposerMarkdownCoordinator()
    private let uploadStatusLabel = ComposerToolbarFactory.makeUploadStatusLabel()

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

    private lazy var sendButton: UIButton = {
        let button = ComposerToolbarFactory.makeSendIconButton()
        button.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        return button
    }()

    init(api: DiscourseAPI, recipient: String = "", initialTitle: String = "", initialRaw: String = "", draftKey: String = "new_private_message") {
        self.api = api
        self.draftKey = draftKey
        self.recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        self.allowsEditingRecipient = self.recipient.isEmpty
        self.initialRaw = initialRaw
        super.init(nibName: nil, bundle: nil)
        titleField.text = initialTitle
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "user.profile.private_message")
        view.backgroundColor = ComposerTypography.backgroundColor
        setupNavigation()
        setupUI()
        markdownCoordinator.surface = self
        applyBodyMarkdown(initialRaw)
        updateSendState()
        Task { await hydrateServerDraftIfNeeded() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        draftSaveTask?.cancel()
        serverDraftSaveTask?.cancel()
    }

    private func setupNavigation() {
        let modeItem = UIBarButtonItem(
            title: editingMode == .rich ? "Aa" : "MD",
            style: .plain,
            target: self,
            action: #selector(toggleEditingMode)
        )
        modeBarItem = modeItem
        let previewItem = UIBarButtonItem(
            image: UIImage(systemName: "eye"),
            style: .plain,
            target: self,
            action: #selector(toggleMarkdownPreview)
        )
        previewBarItem = previewItem
        previewItem.tintColor = ComposerTypography.accentColor
        modeItem.tintColor = ComposerTypography.accentColor
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(customView: sendButton),
            UIBarButtonItem(customView: closeButton),
            previewItem,
            modeItem,
        ]
    }

    private func setupUI() {
        recipientLabel.translatesAutoresizingMaskIntoConstraints = false
        recipientLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 13,
            weight: .semibold,
            fallback: .systemFont(ofSize: 13, weight: .semibold)
        )
        recipientLabel.textColor = .secondaryLabel
        recipientLabel.adjustsFontForContentSizeCategory = true

        recipientField.translatesAutoresizingMaskIntoConstraints = false
        recipientField.borderStyle = .roundedRect
        recipientField.placeholder = String(localized: "messages.compose.recipient_placeholder", defaultValue: "收件人用户名")
        recipientField.autocapitalizationType = .none
        recipientField.autocorrectionType = .no
        recipientField.returnKeyType = .next
        recipientField.delegate = self
        recipientField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        recipientField.font = .preferredFont(forTextStyle: .body)
        recipientField.adjustsFontForContentSizeCategory = true
        recipientField.isHidden = !allowsEditingRecipient

        if allowsEditingRecipient {
            recipientLabel.text = String(localized: "messages.compose.recipient", defaultValue: "收件人")
            recipientField.text = recipient
        } else {
            recipientLabel.text = "@\(recipient)"
            recipientField.isHidden = true
        }

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.borderStyle = .roundedRect
        titleField.placeholder = String(localized: "new_topic.title.placeholder")
        titleField.returnKeyType = .next
        titleField.delegate = self
        titleField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        titleField.font = ComposerTypography.titleFont
        titleField.adjustsFontForContentSizeCategory = true
        titleField.tintColor = ComposerTypography.accentColor

        textView.translatesAutoresizingMaskIntoConstraints = false
        ComposerTypography.applyBody(to: textView)
        textView.layer.cornerRadius = ComposerTypography.chromeRadius
        textView.layer.cornerCurve = .continuous
        textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        textView.delegate = self
        textView.pasteCoordinator = markdownCoordinator

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        ComposerTypography.applyBody(to: placeholderLabel)
        placeholderLabel.text = String(localized: "reply.placeholder")
        placeholderLabel.isHidden = true

        view.addSubview(recipientLabel)
        view.addSubview(recipientField)
        view.addSubview(titleField)
        view.addSubview(textView)
        view.addSubview(previewView)
        textView.addSubview(placeholderLabel)
        textView.addSubview(uploadStatusLabel)

        let titleTop = allowsEditingRecipient
            ? titleField.topAnchor.constraint(equalTo: recipientField.bottomAnchor, constant: 10)
            : titleField.topAnchor.constraint(equalTo: recipientLabel.bottomAnchor, constant: 10)

        NSLayoutConstraint.activate([
            recipientLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            recipientLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            recipientLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            recipientField.topAnchor.constraint(equalTo: recipientLabel.bottomAnchor, constant: 8),
            recipientField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            recipientField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            recipientField.heightAnchor.constraint(equalToConstant: 40),

            titleTop,
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            titleField.heightAnchor.constraint(equalToConstant: 40),

            textView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),

            previewView.topAnchor.constraint(equalTo: textView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: textView.bottomAnchor),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 14),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -16),

            uploadStatusLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 10),
            uploadStatusLabel.centerXAnchor.constraint(equalTo: textView.centerXAnchor),
        ])
    }

    private var resolvedRecipient: String {
        if allowsEditingRecipient {
            return (recipientField.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        }
        return recipient
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
        placeholderLabel.isHidden = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func insertRichSnippet(_ markdown: String) {
        let snippet = NSMutableAttributedString(
            attributedString: ComposerMarkdownCodec.richAttributedString(from: markdown)
        )
        if snippet.string.hasSuffix("\n"), snippet.length > 0 {
            snippet.deleteCharacters(in: NSRange(location: snippet.length - 1, length: 1))
        }
        let current = NSMutableAttributedString(
            attributedString: textView.attributedText ?? NSAttributedString(
                string: "",
                attributes: ComposerTypography.typingAttributes
            )
        )
        let selection = textView.selectedRange
        let location = min(max(selection.location, 0), current.length)
        let length = min(max(selection.length, 0), current.length - location)
        current.replaceCharacters(in: NSRange(location: location, length: length), with: snippet)
        textView.attributedText = current
        textView.selectedRange = NSRange(location: location + snippet.length, length: 0)
        textView.typingAttributes = ComposerTypography.typingAttributes
    }

    @objc private func toggleEditingMode() {
        let raw = bodyRaw
        editingMode = editingMode.toggled
        ComposerEditingMode.stored = editingMode
        applyBodyMarkdown(raw)
        modeBarItem?.title = editingMode == .rich ? "Aa" : "MD"
        textView.becomeFirstResponder()
    }

    @objc private func toggleMarkdownPreview() {
        isPreviewingMarkdown.toggle()
        previewView.isHidden = !isPreviewingMarkdown
        textView.isHidden = isPreviewingMarkdown
        placeholderLabel.isHidden = isPreviewingMarkdown || !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        previewBarItem?.image = UIImage(systemName: isPreviewingMarkdown ? "eye.slash" : "eye")
        if isPreviewingMarkdown {
            textView.resignFirstResponder()
            previewView.update(markdown: ComposerPangu.applyToOutgoing(bodyRaw))
        } else {
            textView.becomeFirstResponder()
        }
    }

    private func hydrateServerDraftIfNeeded() async {
        do {
            guard let server = try await api.fetchDraft(key: draftKey) else { return }
            ComposerLocalDraftStore.saveSequence(
                baseURL: api.baseURL,
                draftKey: draftKey,
                sequence: server.sequence
            )
            // Only fill empty composer; never clobber typing / explicit initial.
            let localTitle = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let localRaw = bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard localTitle.isEmpty, localRaw.isEmpty else { return }
            let serverTitle = server.data.title ?? ""
            let serverRaw = server.data.reply ?? ""
            guard !serverTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !serverRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            // Prefer drafts aimed at this recipient when recipients are present.
            let recipients = server.data.recipients.isEmpty
                ? (server.data.targetRecipients?.split(separator: ",").map(String.init) ?? [])
                : server.data.recipients
            if !recipients.isEmpty, !recipient.isEmpty {
                let normalized = recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let hit = recipients.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }
                guard hit else { return }
            }
            if allowsEditingRecipient, let firstRecipient = recipients.first, recipient.isEmpty {
                recipient = firstRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
                recipientField.text = recipient
            }
            titleField.text = serverTitle
            applyBodyMarkdown(serverRaw)
            updateSendState()
        } catch {
            // Offline / CF — keep local.
        }
    }

    private func scheduleDraftSave() {}

    private func updateSendState() {
        let title = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = resolvedRecipient
        sendButton.isEnabled = !isSending && !isUploading && !title.isEmpty && !raw.isEmpty && !to.isEmpty
        closeButton.isEnabled = !isSending && !isUploading
        modeBarItem?.isEnabled = !isSending && !isUploading
        titleField.isEnabled = !isSending && !isUploading
        recipientField.isEnabled = !isSending && !isUploading
        textView.isEditable = !isSending && !isUploading
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: String(localized: "common.retry", defaultValue: "重试"),
            style: .default
        ) { [weak self] _ in
            self?.sendTapped()
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func discardTapped() {
        let hasContent = !resolvedRecipient.isEmpty
            || !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    @objc private func sendTapped() {
        let messageTitle = titleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = ComposerPangu.applyToOutgoing(bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines))
        let to = resolvedRecipient
        guard !messageTitle.isEmpty, !raw.isEmpty, !to.isEmpty, !isSending, !isUploading else { return }
        recipient = to

        isSending = true
        updateSendState()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await api.sendPrivateMessage(to: to, title: messageTitle, raw: raw)
                await ComposerServerDraftSync.clearServerDraft(api: self.api, draftKey: self.draftKey)
                dismiss(animated: true) { [onMessageSent] in
                    onMessageSent?(response)
                }
            } catch {
                isSending = false
                updateSendState()
                showError(error)
            }
        }
    }

    @objc private func inputChanged() {
        updateSendState()
        scheduleDraftSave()
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSendState()
        scheduleDraftSave()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textView.becomeFirstResponder()
        return false
    }
}

// MARK: - ComposerTextSurface

extension PrivateMessageComposerViewController: ComposerTextSurface {
    var composerHostViewController: UIViewController { self }
    var composerAPI: DiscourseAPI { api }
    var composerTextView: UITextView { textView }
    var composerToolsAnchorView: UIView { sendButton }
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
        placeholderLabel.isHidden = !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSendState()
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
        placeholderLabel.isHidden = !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSendState()
        scheduleDraftSave()
    }

    func composerApplyLinePrefix(_ prefix: String) {
        if editingMode == .rich {
            insertRichSnippet(prefix)
        } else {
            ComposerPlainTextEditing.applyLinePrefix(in: textView, prefix: prefix)
        }
        placeholderLabel.isHidden = !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSendState()
        scheduleDraftSave()
    }

    func composerReplaceFullRaw(_ raw: String) {
        applyBodyMarkdown(raw)
        placeholderLabel.isHidden = !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSendState()
        scheduleDraftSave()
    }

    func composerDidEditContent() {
        placeholderLabel.isHidden = !bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        updateSendState()
        scheduleDraftSave()
    }

    func composerSetUploading(_ uploading: Bool, statusText: String?) {
        isUploading = uploading
        uploadStatusLabel.text = statusText
        uploadStatusLabel.isHidden = !uploading
        updateSendState()
    }

    func composerCloseToolPanel(returnToKeyboard: Bool) {
        if returnToKeyboard {
            textView.becomeFirstResponder()
        }
    }

    func composerExitMarkdownPreviewIfNeeded() {}
}
