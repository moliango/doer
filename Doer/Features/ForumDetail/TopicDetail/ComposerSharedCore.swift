import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Panel

enum ComposerPanelKind: Equatable {
    case none
    case emoji
    case tools
}

// MARK: - Text surface (Reply attributed / NewTopic plain both conform)

/// Shared editing surface used by reply + new-topic composers.
@MainActor
protocol ComposerTextSurface: AnyObject {
    var composerHostViewController: UIViewController { get }
    var composerAPI: DiscourseAPI { get }
    var composerTextView: UITextView { get }
    var composerToolsAnchorView: UIView { get }
    var composerIsUploading: Bool { get }
    var composerRawText: String { get }

    /// Raw markdown for the current selection (empty if none).
    func composerSelectedRawText() -> String
    /// Insert raw markdown at the caret / selection.
    func composerInsertRaw(_ text: String)
    func composerWrapSelection(start: String, end: String, placeholder: String)
    func composerApplyLinePrefix(_ prefix: String)
    /// Replace the entire composer raw body (e.g. image-grid wrap).
    func composerReplaceFullRaw(_ raw: String)
    func composerDidEditContent()
    func composerSetUploading(_ uploading: Bool, statusText: String?)
    func composerCloseToolPanel(returnToKeyboard: Bool)
    func composerExitMarkdownPreviewIfNeeded()
}

// MARK: - Header icon button

/// Own circle + glyph views so UIButton cannot stretch or offset the symbol.
private final class ComposerChromeIconButton: UIButton {
    private let filled: Bool
    private let idleTint: UIColor
    private let side: CGFloat
    private let circleView = UIView()
    private let glyphView = UIImageView()
    private static let filledCircleDiameter: CGFloat = 32

    init(
        systemName: String,
        pointSize: CGFloat,
        weight: UIImage.SymbolWeight,
        filled: Bool,
        tint: UIColor,
        size: CGFloat,
        accessibilityLabel: String
    ) {
        self.filled = filled
        self.idleTint = tint
        self.side = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        self.accessibilityLabel = accessibilityLabel

        circleView.isUserInteractionEnabled = false
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.isHidden = !filled
        addSubview(circleView)

        let symbol = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.isUserInteractionEnabled = false
        glyphView.contentMode = .center
        glyphView.image = UIImage(systemName: systemName, withConfiguration: symbol)?
            .withRenderingMode(.alwaysTemplate)
        addSubview(glyphView)

        let circleSide = filled ? Self.filledCircleDiameter : 0
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            circleView.centerXAnchor.constraint(equalTo: centerXAnchor),
            circleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            circleView.widthAnchor.constraint(equalToConstant: circleSide),
            circleView.heightAnchor.constraint(equalToConstant: circleSide),
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyFilledChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }

    override var isEnabled: Bool {
        get { super.isEnabled }
        set {
            super.isEnabled = newValue
            applyFilledChrome()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if filled {
            circleView.layer.cornerRadius = circleView.bounds.height / 2
            circleView.layer.cornerCurve = .continuous
        }
    }

    private func applyFilledChrome() {
        if filled {
            circleView.backgroundColor = isEnabled
                ? ComposerTypography.accentColor
                : ComposerTypography.mutedFill
            glyphView.tintColor = isEnabled ? .white : .tertiaryLabel
        } else {
            circleView.backgroundColor = .clear
            glyphView.tintColor = isEnabled ? idleTint : .tertiaryLabel
        }
    }
}

// MARK: - Toolbar factory

enum ComposerToolbarFactory {
    static func makeCloseIconButton(
        accessibilityLabel: String = String(localized: "common.close", defaultValue: "关闭")
    ) -> UIButton {
        ComposerChromeIconButton(
            systemName: "xmark",
            pointSize: 14,
            weight: .semibold,
            filled: false,
            tint: .secondaryLabel,
            size: 44,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func makeSendIconButton(
        accessibilityLabel: String = String(localized: "reply.send")
    ) -> UIButton {
        ComposerChromeIconButton(
            systemName: "paperplane.fill",
            pointSize: 18,
            weight: .semibold,
            filled: false,
            tint: ComposerTypography.accentColor,
            size: 44,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func makeSaveDraftIconButton(
        accessibilityLabel: String = String(localized: "common.save.draft", defaultValue: "保存草稿")
    ) -> UIButton {
        ComposerChromeIconButton(
            systemName: "icloud.and.arrow.up",
            pointSize: 18,
            weight: .medium,
            filled: false,
            tint: ComposerTypography.accentColor,
            size: 44,
            accessibilityLabel: accessibilityLabel
        )
    }

    static func makeCircleButton(systemName: String, accessibilityLabel: String) -> UIButton {
        let button = makePlainButton(systemName: systemName, accessibilityLabel: accessibilityLabel, pointSize: 19, weight: .regular)
        button.backgroundColor = ComposerTypography.mutedFill
        button.layer.cornerRadius = 22
        button.layer.cornerCurve = .continuous
        return button
    }

    static func makePlainButton(
        systemName: String,
        accessibilityLabel: String,
        pointSize: CGFloat = 18,
        weight: UIImage.SymbolWeight = .semibold
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(
            UIImage(
                systemName: systemName,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
            ),
            for: .normal
        )
        button.tintColor = .label
        button.accessibilityLabel = accessibilityLabel
        return button
    }

    static func makeRightPill() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = ComposerTypography.mutedFill
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        return view
    }

    static func makeUploadStatusLabel() -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.isHidden = true
        return label
    }

    static func makeBottomStack() -> UIStackView {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        return stack
    }

    static func makeToolbarContainer() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }

    static func makePanelContainer() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.backgroundColor = .systemBackground
        return view
    }

    /// Standard toolbar layout: emoji | status | [preview Aa tools] pill.
    static func installToolbarLayout(
        in toolbar: UIView,
        emojiButton: UIButton,
        uploadStatusLabel: UILabel,
        rightPill: UIView,
        previewButton: UIButton,
        modeButton: UIButton,
        toolsButton: UIButton,
        encryptButton: UIButton? = nil
    ) {
        toolbar.addSubview(emojiButton)
        toolbar.addSubview(uploadStatusLabel)
        toolbar.addSubview(rightPill)
        rightPill.addSubview(previewButton)
        rightPill.addSubview(modeButton)
        rightPill.addSubview(toolsButton)
        toolbar.heightAnchor.constraint(equalToConstant: 58).isActive = true
        toolbar.backgroundColor = ComposerTypography.backgroundColor

        let statusLeading: NSLayoutAnchor<NSLayoutXAxisAnchor>
        if let encryptButton {
            toolbar.addSubview(encryptButton)
            NSLayoutConstraint.activate([
                encryptButton.leadingAnchor.constraint(equalTo: emojiButton.trailingAnchor, constant: 4),
                encryptButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
                encryptButton.widthAnchor.constraint(equalToConstant: 44),
                encryptButton.heightAnchor.constraint(equalToConstant: 44),
            ])
            statusLeading = encryptButton.trailingAnchor
        } else {
            statusLeading = emojiButton.trailingAnchor
        }

        NSLayoutConstraint.activate([
            emojiButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            emojiButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            emojiButton.widthAnchor.constraint(equalToConstant: 44),
            emojiButton.heightAnchor.constraint(equalToConstant: 44),

            rightPill.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            rightPill.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            rightPill.heightAnchor.constraint(equalToConstant: 44),

            uploadStatusLabel.leadingAnchor.constraint(equalTo: statusLeading, constant: 12),
            uploadStatusLabel.trailingAnchor.constraint(equalTo: rightPill.leadingAnchor, constant: -12),
            uploadStatusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            previewButton.leadingAnchor.constraint(equalTo: rightPill.leadingAnchor, constant: 6),
            previewButton.topAnchor.constraint(equalTo: rightPill.topAnchor),
            previewButton.bottomAnchor.constraint(equalTo: rightPill.bottomAnchor),
            previewButton.widthAnchor.constraint(equalToConstant: 40),

            modeButton.leadingAnchor.constraint(equalTo: previewButton.trailingAnchor, constant: 2),
            modeButton.topAnchor.constraint(equalTo: rightPill.topAnchor),
            modeButton.bottomAnchor.constraint(equalTo: rightPill.bottomAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 44),

            toolsButton.leadingAnchor.constraint(equalTo: modeButton.trailingAnchor, constant: 2),
            toolsButton.trailingAnchor.constraint(equalTo: rightPill.trailingAnchor, constant: -6),
            toolsButton.topAnchor.constraint(equalTo: rightPill.topAnchor),
            toolsButton.bottomAnchor.constraint(equalTo: rightPill.bottomAnchor),
            toolsButton.widthAnchor.constraint(equalToConstant: 40),
        ])
    }

    static func installPanelLayout(
        in container: UIView,
        emojiPanel: UIView,
        toolsPanel: UIView
    ) -> NSLayoutConstraint {
        container.addSubview(emojiPanel)
        container.addSubview(toolsPanel)
        let height = container.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            emojiPanel.topAnchor.constraint(equalTo: container.topAnchor),
            emojiPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emojiPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emojiPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolsPanel.topAnchor.constraint(equalTo: container.topAnchor),
            toolsPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolsPanel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolsPanel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        emojiPanel.isHidden = true
        toolsPanel.isHidden = true
        return height
    }

    static let customPanelHeight: CGFloat = 420

    static func updateToolbarTints(
        emojiButton: UIButton,
        previewButton: UIButton,
        modeButton: UIButton,
        toolsButton: UIButton,
        panel: ComposerPanelKind,
        isPreviewing: Bool,
        editingMode: ComposerEditingMode
    ) {
        let accent = ComposerTypography.accentColor
        let idle = UIColor.label
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        previewButton.setImage(
            UIImage(systemName: isPreviewing ? "eye.slash.fill" : "eye", withConfiguration: config),
            for: .normal
        )
        previewButton.tintColor = isPreviewing ? accent : idle
        modeButton.setTitle(editingMode == .rich ? "Aa" : "MD", for: .normal)
        modeButton.setTitleColor(editingMode == .rich ? accent : idle, for: .normal)
        modeButton.tintColor = editingMode == .rich ? accent : idle
        toolsButton.tintColor = panel == .tools ? accent : idle
        emojiButton.tintColor = panel == .emoji ? accent : idle
    }

    static func makeModeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .bold)
        button.setTitle("Aa", for: .normal)
        button.accessibilityLabel = String(localized: "reply.toolbar.rich_mode", defaultValue: "Rich text")
        return button
    }
}

// MARK: - Markdown / upload coordinator

/// Owns tool menus, media upload, AI review — shared by reply & new-topic.
@MainActor
final class ComposerMarkdownCoordinator: NSObject {
    enum MediaPickKind {
        case audio
        case video
        case voice
    }

    weak var surface: ComposerTextSurface?
    private(set) var pendingMediaKind: MediaPickKind?

    func handleTool(_ tool: ComposerMarkdownTool) {
        guard let surface, !surface.composerIsUploading else { return }
        surface.composerExitMarkdownPreviewIfNeeded()

        switch tool {
        case .image:
            presentImagePicker()
        case .attachment:
            presentAttachmentPicker()
        case .media:
            presentMediaMenu()
        case .heading:
            presentHeadingMenu()
        case .bold:
            surface.composerWrapSelection(
                start: "**",
                end: "**",
                placeholder: String(localized: "reply.tool.placeholder.bold")
            )
        case .italic:
            surface.composerWrapSelection(
                start: "*",
                end: "*",
                placeholder: String(localized: "reply.tool.placeholder.italic")
            )
        case .strikethrough:
            surface.composerWrapSelection(
                start: "~~",
                end: "~~",
                placeholder: String(localized: "reply.tool.placeholder.strikethrough")
            )
        case .bulletList:
            surface.composerApplyLinePrefix("- ")
        case .numberedList:
            surface.composerApplyLinePrefix("1. ")
        case .link:
            presentLinkAlert()
        case .quote:
            surface.composerApplyLinePrefix("> ")
        case .callout:
            presentCalloutMenu()
        case .template:
            presentTemplateMenu()
        case .aiReview:
            runAIPostReview()
        case .inlineCode:
            surface.composerWrapSelection(
                start: "`",
                end: "`",
                placeholder: String(localized: "reply.tool.placeholder.code")
            )
        case .codeBlock:
            insertCodeBlock()
        case .spoiler:
            surface.composerWrapSelection(
                start: "[spoiler]",
                end: "[/spoiler]",
                placeholder: String(localized: "reply.tool.placeholder.spoiler", defaultValue: "剧透内容")
            )
        case .imageGrid:
            wrapImagesInGrid()
        case .insertBlock:
            presentInsertBlockMenu()
        case .toc:
            surface.composerWrapSelection(
                start: "\n<div data-theme-toc=\"true\">\n\n",
                end: "\n\n</div>\n",
                placeholder: String(localized: "reply.tool.placeholder.toc", defaultValue: "此话题将包含目录")
            )
        case .poll:
            presentPollBuilder()
        case .encrypt:
            presentEncryptSheet()
        }

        if tool.closesPanelAfterAction {
            surface.composerCloseToolPanel(returnToKeyboard: true)
        }
    }

    private func presentEncryptSheet() {
        guard let surface else { return }
        let selected = surface.composerSelectedRawText()
        CryptoSheetViewController.present(
            mode: .encrypt,
            text: selected,
            from: surface.composerHostViewController,
            onFinished: { [weak surface] ciphertext in
                surface?.composerInsertRaw("```enc\n\(ciphertext)\n```")
                surface?.composerDidEditContent()
            }
        )
    }

    private func presentPollBuilder() {
        guard let surface else { return }
        let alert = UIAlertController(
            title: String(localized: "reply.tool.poll", defaultValue: "插入投票"),
            message: String(localized: "reply.tool.poll.message", defaultValue: "每行一个选项，至少两个"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "reply.tool.poll.options", defaultValue: "选项 A\n选项 B")
        }
        let multi = UIAlertAction(
            title: String(localized: "reply.tool.poll.multiple", defaultValue: "多选"),
            style: .default
        ) { [weak self] _ in
            self?.insertPollBBCode(optionsText: alert.textFields?.first?.text, type: "multiple")
        }
        let single = UIAlertAction(
            title: String(localized: "reply.tool.poll.single", defaultValue: "单选"),
            style: .default
        ) { [weak self] _ in
            self?.insertPollBBCode(optionsText: alert.textFields?.first?.text, type: "regular")
        }
        alert.addAction(single)
        alert.addAction(multi)
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel) { [weak surface] _ in
            surface?.composerCloseToolPanel(returnToKeyboard: true)
        })
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func insertPollBBCode(optionsText: String?, type: String) {
        guard let surface else { return }
        let lines = (optionsText ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let options = lines.count >= 2 ? lines : [
            String(localized: "reply.tool.poll.option_a", defaultValue: "选项 A"),
            String(localized: "reply.tool.poll.option_b", defaultValue: "选项 B"),
        ]
        let body = options.map { "- \($0)" }.joined(separator: "\n")
        let bbcode = """
        [poll type=\(type) results=always public=true chartType=bar]
        \(body)
        [/poll]

        """
        surface.composerInsertRaw(bbcode)
        surface.composerCloseToolPanel(returnToKeyboard: true)
    }

    // MARK: Menus

    private func presentHeadingMenu() {
        guard let surface else { return }
        let alert = UIAlertController(
            title: String(localized: "reply.tool.heading"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for level in 1 ... 5 {
            alert.addAction(UIAlertAction(title: "H\(level)", style: .default) { [weak self] _ in
                self?.surface?.composerApplyLinePrefix(String(repeating: "#", count: level) + " ")
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        configurePopover(alert, on: surface)
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func presentCalloutMenu() {
        guard let surface else { return }
        let types = [
            "note", "tip", "info", "warning", "danger", "bug",
            "example", "quote", "abstract", "todo", "success", "question", "failure",
        ]
        let alert = UIAlertController(
            title: String(localized: "reply.tool.note"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for type in types {
            alert.addAction(UIAlertAction(title: type.capitalized, style: .default) { [weak self] _ in
                self?.insertCallout(type)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        configurePopover(alert, on: surface)
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func insertCallout(_ type: String) {
        guard let surface else { return }
        let placeholder = String(localized: "reply.tool.placeholder.note")
        let selected = surface.composerSelectedRawText()
        if !selected.isEmpty {
            let quoted = selected
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            surface.composerInsertRaw("> [!\(type)]\n\(quoted)")
        } else {
            surface.composerInsertRaw("> [!\(type)]\n> \(placeholder)\n")
        }
    }

    private func insertCodeBlock() {
        guard let surface else { return }
        let placeholder = String(localized: "reply.tool.placeholder.code")
        let selected = surface.composerSelectedRawText()
        if !selected.isEmpty {
            surface.composerInsertRaw("```\n\(selected)\n```")
        } else {
            surface.composerInsertRaw("```\n\(placeholder)\n```\n")
        }
    }

    private func presentInsertBlockMenu() {
        guard let surface else { return }
        let items: [(String, String)] = [
            (
                String(localized: "reply.tool.block.table", defaultValue: "表格"),
                "| 列 1 | 列 2 |\n|---|---|\n| 内容 | 内容 |\n"
            ),
            (
                String(localized: "reply.tool.block.math", defaultValue: "公式块"),
                "$$\nE=mc^2\n$$\n"
            ),
            (
                String(localized: "reply.tool.block.divider", defaultValue: "分隔线"),
                "---\n"
            ),
            (
                String(localized: "reply.tool.block.details", defaultValue: "折叠详情"),
                "[details=\"点开看\"]\n折叠内容\n[/details]\n"
            ),
        ]
        let alert = UIAlertController(
            title: String(localized: "reply.tool.insert_block", defaultValue: "插入块"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for item in items {
            alert.addAction(UIAlertAction(title: item.0, style: .default) { [weak self] _ in
                self?.surface?.composerInsertRaw(item.1)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        configurePopover(alert, on: surface)
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func presentTemplateMenu() {
        guard let surface else { return }
        let alert = UIAlertController(
            title: String(localized: "reply.tool.template"),
            message: nil,
            preferredStyle: .actionSheet
        )
        let templates: [(String, String)] = [
            (
                String(localized: "reply.template.summary"),
                "## \(String(localized: "reply.template.summary"))\n\n- \n"
            ),
            (
                String(localized: "reply.template.steps"),
                "## \(String(localized: "reply.template.steps"))\n\n1. \n2. \n3. \n"
            ),
            (
                String(localized: "reply.template.code"),
                "```\n\(String(localized: "reply.tool.placeholder.code"))\n```\n"
            ),
        ]
        for template in templates {
            alert.addAction(UIAlertAction(title: template.0, style: .default) { [weak self] _ in
                self?.surface?.composerInsertRaw(template.1)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        configurePopover(alert, on: surface)
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func presentLinkAlert() {
        guard let surface else { return }
        let selected = surface.composerSelectedRawText()
        let alert = UIAlertController(
            title: String(localized: "reply.tool.link"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "reply.tool.link_text")
            field.text = selected
        }
        alert.addTextField { field in
            field.placeholder = "https://"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: String(localized: "reply.tool.insert"),
            style: .default
        ) { [weak self, weak alert] _ in
            guard let self, let surface = self.surface else { return }
            let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = alert?.textFields?.dropFirst().first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url, !url.isEmpty else { return }
            let linkTitle = (title?.isEmpty == false ? title : url) ?? url
            surface.composerInsertRaw("[\(linkTitle)](\(url))")
        })
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func presentMediaMenu() {
        guard let surface else { return }
        let alert = UIAlertController(
            title: String(localized: "reply.tool.media", defaultValue: "音视频"),
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "reply.tool.media.audio", defaultValue: "上传音频"),
            style: .default
        ) { [weak self] _ in
            self?.presentMediaPicker(kind: .audio)
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "reply.tool.media.video", defaultValue: "上传视频"),
            style: .default
        ) { [weak self] _ in
            self?.presentMediaPicker(kind: .video)
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "reply.tool.media.voice", defaultValue: "语音消息"),
            style: .default
        ) { [weak self] _ in
            self?.presentMediaPicker(kind: .voice)
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        configurePopover(alert, on: surface)
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func presentImagePicker() {
        guard let surface else { return }
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        surface.composerHostViewController.present(picker, animated: true)
    }

    private func presentAttachmentPicker() {
        pendingMediaKind = nil
        presentDocumentPicker(types: [.item])
    }

    private func presentMediaPicker(kind: MediaPickKind) {
        pendingMediaKind = kind
        let types: [UTType]
        switch kind {
        case .audio, .voice:
            types = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        case .video:
            types = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
        }
        presentDocumentPicker(types: types)
    }

    private func presentDocumentPicker(types: [UTType]) {
        guard let surface else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        surface.composerHostViewController.present(picker, animated: true)
    }

    // MARK: Grid / AI

    private func wrapImagesInGrid() {
        guard let surface else { return }
        let raw = surface.composerRawText
        let imagePattern = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]+\)"#)
        let nsRaw = raw as NSString
        let matches = imagePattern.matches(in: raw, range: NSRange(location: 0, length: nsRaw.length))
        guard matches.count >= 2 else {
            presentSimpleAlert(
                message: String(
                    localized: "reply.tool.grid.min_images",
                    defaultValue: "至少需要 2 张图片才能组成网格"
                )
            )
            return
        }

        let selected = surface.composerSelectedRawText()
        if !selected.isEmpty {
            let selectedMatches = imagePattern.matches(
                in: selected,
                range: NSRange(location: 0, length: (selected as NSString).length)
            )
            if selectedMatches.count >= 2 {
                surface.composerInsertRaw("[grid]\n\(selected)\n[/grid]")
                return
            }
        }

        var bestStart = matches[0].range.location
        var bestEnd = NSMaxRange(matches[0].range)
        var runStart = bestStart
        var runEnd = bestEnd
        var runCount = 1
        var bestCount = 1

        for i in 1 ..< matches.count {
            let prevEnd = NSMaxRange(matches[i - 1].range)
            let curStart = matches[i].range.location
            let between = nsRaw.substring(with: NSRange(location: prevEnd, length: curStart - prevEnd))
            if between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runEnd = NSMaxRange(matches[i].range)
                runCount += 1
            } else {
                if runCount > bestCount {
                    bestCount = runCount
                    bestStart = runStart
                    bestEnd = runEnd
                }
                runStart = matches[i].range.location
                runEnd = NSMaxRange(matches[i].range)
                runCount = 1
            }
        }
        if runCount > bestCount {
            bestCount = runCount
            bestStart = runStart
            bestEnd = runEnd
        }
        guard bestCount >= 2 else {
            presentSimpleAlert(
                message: String(
                    localized: "reply.tool.grid.min_images",
                    defaultValue: "至少需要 2 张图片才能组成网格"
                )
            )
            return
        }

        let chunk = nsRaw.substring(with: NSRange(location: bestStart, length: bestEnd - bestStart))
        let wrapped = "[grid]\n\(chunk)\n[/grid]"
        let newRaw = nsRaw.replacingCharacters(
            in: NSRange(location: bestStart, length: bestEnd - bestStart),
            with: wrapped
        )
        surface.composerReplaceFullRaw(newRaw)
    }

    private func runAIPostReview() {
        guard let surface else { return }
        let content = surface.composerRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let host = surface.composerHostViewController
        let hud = UIAlertController(
            title: String(localized: "ai.review.running", defaultValue: "AI 预审中…"),
            message: nil,
            preferredStyle: .alert
        )
        host.present(hud, animated: true)
        Task {
            do {
                let result = try await AIPostReviewService.reviewDraft(
                    title: nil,
                    content: content,
                    categoryName: nil
                )
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        let alert = UIAlertController(
                            title: String(localized: "ai.review.result", defaultValue: "预审结果"),
                            message: result,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(
                            title: String(localized: "common.ok", defaultValue: "好"),
                            style: .default
                        ))
                        host.present(alert, animated: true)
                    }
                }
            } catch {
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        let alert = UIAlertController(
                            title: String(localized: "common.error", defaultValue: "错误"),
                            message: error.localizedDescription,
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(
                            title: String(localized: "common.ok", defaultValue: "好"),
                            style: .default
                        ))
                        host.present(alert, animated: true)
                    }
                }
            }
        }
    }

    // MARK: Upload

    private var pendingFailedUploads: [(url: URL, filename: String)] = []
    private var pendingMediaForRetry: (url: URL, kind: MediaPickKind)?

    func uploadPickedFiles(_ files: [(url: URL, filename: String)]) async {
        guard let surface, !files.isEmpty else { return }
        surface.composerSetUploading(true, statusText: String(localized: "reply.uploading"))
        defer { surface.composerSetUploading(false, statusText: nil) }

        let total = files.count
        for (index, file) in files.enumerated() {
            if total > 1 {
                surface.composerSetUploading(
                    true,
                    statusText: String(
                        localized: "reply.uploading.progress",
                        defaultValue: "上传中 \(index + 1)/\(total)"
                    )
                )
            }
            do {
                let upload = try await surface.composerAPI.uploadComposerFile(
                    fileURL: file.url,
                    filename: file.filename
                )
                insertUploadMarkdown(upload.markdown, on: surface)
            } catch {
                // Keep failed file + remaining queue so Retry can continue.
                pendingFailedUploads = Array(files[index...])
                presentUploadError(error, canRetry: true)
                return
            }
        }
        pendingFailedUploads = []
    }

    func uploadMediaFile(url: URL, kind: MediaPickKind) async {
        guard let surface else { return }
        surface.composerSetUploading(true, statusText: String(localized: "reply.uploading"))
        defer {
            surface.composerSetUploading(false, statusText: nil)
            pendingMediaKind = nil
        }
        do {
            let xzURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("xz")
            if FileManager.default.fileExists(atPath: xzURL.path) {
                try FileManager.default.removeItem(at: xzURL)
            }
            try FileManager.default.copyItem(at: url, to: xzURL)
            let upload = try await surface.composerAPI.uploadComposerFile(
                fileURL: xzURL,
                filename: xzURL.lastPathComponent
            )
            try? FileManager.default.removeItem(at: xzURL)

            let originalExt = url.pathExtension.lowercased()
            let isAudio = kind != .video
            let mime = UTType(filenameExtension: originalExt)?.preferredMIMEType
                ?? (isAudio ? "audio/mpeg" : "video/mp4")
            let src = Self.mediaPlaybackPath(from: upload.shortURL)
            let tag: String
            if isAudio {
                let audio = "<audio controls>\n  <source src=\"\(src)\" type=\"\(mime)\">\n</audio>"
                tag = kind == .voice ? "[wrap=voice]\n\(audio)\n[/wrap]" : audio
            } else {
                tag = "<video width=\"640\" height=\"360\" controls>\n  <source src=\"\(src)\" type=\"\(mime)\">\n</video>"
            }
            insertUploadMarkdown(tag, on: surface)
            pendingMediaForRetry = nil
        } catch {
            pendingMediaForRetry = (url, kind)
            presentUploadError(error, canRetry: true)
        }
    }

    private func insertUploadMarkdown(_ markdown: String, on surface: ComposerTextSurface) {
        let raw = surface.composerRawText
        let needsNewline = !raw.isEmpty && !raw.hasSuffix("\n")
        surface.composerInsertRaw("\(needsNewline ? "\n" : "")\(markdown)\n")
    }

    static func mediaPlaybackPath(from shortURL: String) -> String {
        if shortURL.hasPrefix("upload://") {
            var token = String(shortURL.dropFirst("upload://".count))
            if let dot = token.lastIndex(of: ".") {
                token = String(token[..<dot])
            }
            return "/uploads/short-url/\(token).xz"
        }
        if let dot = shortURL.lastIndex(of: ".") {
            return String(shortURL[..<dot]) + ".xz"
        }
        return shortURL
    }

    // MARK: Helpers

    private func configurePopover(_ alert: UIAlertController, on surface: ComposerTextSurface) {
        if let pop = alert.popoverPresentationController {
            pop.sourceView = surface.composerToolsAnchorView
            pop.sourceRect = surface.composerToolsAnchorView.bounds
        }
    }

    private func presentSimpleAlert(message: String) {
        guard let surface else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func presentUploadError(_ error: Error, canRetry: Bool = false) {
        guard let surface else { return }
        let alert = UIAlertController(
            title: String(localized: "reply.upload.failed"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        if canRetry, !pendingFailedUploads.isEmpty || pendingMediaForRetry != nil {
            alert.addAction(UIAlertAction(
                title: String(localized: "common.retry", defaultValue: "重试"),
                style: .default
            ) { [weak self] _ in
                self?.retryPendingUploads()
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .cancel) { [weak self] _ in
            self?.pendingFailedUploads = []
            self?.pendingMediaForRetry = nil
        })
        surface.composerHostViewController.present(alert, animated: true)
    }

    private func retryPendingUploads() {
        if let media = pendingMediaForRetry {
            pendingMediaForRetry = nil
            Task { await uploadMediaFile(url: media.url, kind: media.kind) }
            return
        }
        let files = pendingFailedUploads
        pendingFailedUploads = []
        guard !files.isEmpty else { return }
        Task { await uploadPickedFiles(files) }
    }

    private func temporaryImageFile(from result: PHPickerResult) async throws -> (url: URL, filename: String) {
        let provider = result.itemProvider
        let identifier = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        } ?? UTType.image.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(
                        throwing: NSError(
                            domain: "ComposerMarkdownCoordinator",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Missing image file"]
                        )
                    )
                    return
                }
                do {
                    let temp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
                    if FileManager.default.fileExists(atPath: temp.path) {
                        try FileManager.default.removeItem(at: temp)
                    }
                    try FileManager.default.copyItem(at: url, to: temp)
                    continuation.resume(returning: (temp, temp.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Picker delegates

extension ComposerMarkdownCoordinator: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard !results.isEmpty else { return }
        Task { @MainActor in
            var files: [(url: URL, filename: String)] = []
            for result in results {
                if let file = try? await temporaryImageFile(from: result) {
                    files.append(file)
                }
            }
            await uploadPickedFiles(files)
        }
    }
}

extension ComposerMarkdownCoordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if let kind = pendingMediaKind {
            Task { await uploadMediaFile(url: url, kind: kind) }
        } else {
            Task {
                await uploadPickedFiles([(url: url, filename: url.lastPathComponent)])
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingMediaKind = nil
    }
}

// MARK: - Plain text helpers (NewTopic)

enum ComposerPlainTextEditing {
    static func selectedText(in textView: UITextView) -> String {
        guard let range = textView.selectedTextRange else { return "" }
        return textView.text(in: range) ?? ""
    }

    static func replaceSelection(in textView: UITextView, with text: String) {
        let selected = textView.selectedRange
        let ns = (textView.text ?? "") as NSString
        let location = min(selected.location, ns.length)
        let length = min(selected.length, max(ns.length - location, 0))
        let range = NSRange(location: location, length: length)
        textView.text = ns.replacingCharacters(in: range, with: text)
        let caret = location + (text as NSString).length
        textView.selectedRange = NSRange(location: min(caret, (textView.text as NSString).length), length: 0)
    }

    static func wrapSelection(in textView: UITextView, start: String, end: String, placeholder: String) {
        let selected = selectedText(in: textView)
        let body = selected.isEmpty ? placeholder : selected
        replaceSelection(in: textView, with: "\(start)\(body)\(end)")
        // Place caret inside markers when using placeholder.
        if selected.isEmpty {
            let loc = textView.selectedRange.location - (end as NSString).length - (placeholder as NSString).length
            if loc >= 0 {
                textView.selectedRange = NSRange(location: loc, length: (placeholder as NSString).length)
            }
        }
    }

    static func applyLinePrefix(in textView: UITextView, prefix: String) {
        let nsText = (textView.text ?? "") as NSString
        let selection = textView.selectedRange
        let lineRange = nsText.lineRange(
            for: NSRange(location: min(selection.location, nsText.length), length: 0)
        )
        if nsText.substring(with: lineRange).hasPrefix(prefix) {
            textView.text = nsText.replacingCharacters(
                in: NSRange(location: lineRange.location, length: prefix.count),
                with: ""
            )
        } else {
            textView.text = nsText.replacingCharacters(
                in: NSRange(location: lineRange.location, length: 0),
                with: prefix
            )
        }
    }
}
