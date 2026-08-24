import UIKit

/// Chat input bar for WeChat / Telegram themes.
/// - WeChat: [ field …………………… plus ]
/// - Telegram: official pill — [☰][📎]| Message [😊][🎤/send]
final class WeChatChatInputBar: UIView, UITextViewDelegate {
    var onSend: ((String) -> Void)?
    var onPlus: (() -> Void)?
    var onEmoji: (() -> Void)?
    var onHeightChange: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    /// When true, Return / send may fire with empty text (pending chat uploads).
    var allowsEmptySend = false {
        didSet { updateTrailingButtons() }
    }

    private let minTextHeight: CGFloat = 36
    private let maxTextHeight: CGFloat = 100

    private let topLine = UIView()
    private let replyBanner = UIView()
    private let replyLabel = UILabel()
    private let replyCloseButton = UIButton(type: .system)
    private let textBackground = UIView()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let menuButton = UIButton(type: .system)
    private let attachButton = UIButton(type: .system)
    private let plusButton = UIButton(type: .system)
    private let divider = UIView()
    private let emojiButton = UIButton(type: .system)
    private let micButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)

    private var textHeightConstraint: NSLayoutConstraint?
    private var replyBannerHeightConstraint: NSLayoutConstraint?

    private var wechatFieldLeading: NSLayoutConstraint?
    private var wechatFieldTrailing: NSLayoutConstraint?
    private var telegramFieldLeading: NSLayoutConstraint?
    private var telegramFieldTrailing: NSLayoutConstraint?
    private var wechatTextLeading: NSLayoutConstraint?
    private var wechatTextTrailing: NSLayoutConstraint?
    private var telegramTextLeading: NSLayoutConstraint?
    private var telegramTextTrailing: NSLayoutConstraint?

    private var isSending = false
    private var appliedChatStyle: ChatTopicStyle
    private var chatStyle: ChatTopicStyle { appliedChatStyle }

    private(set) var replyToPost: DiscourseTopicDetail.Post?
    /// Chat channel reply target (message id). Independent from topic post reply.
    private(set) var replyToChatMessageId: Int?

    init(chatStyle: ChatTopicStyle) {
        self.appliedChatStyle = chatStyle
        super.init(frame: .zero)
        setup()
        applyChatStyle()
    }

    override init(frame: CGRect) {
        self.appliedChatStyle = ChatTopicStyle.current ?? .weChat
        super.init(frame: frame)
        setup()
        applyChatStyle()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyChatStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var text: String {
        get { textView.text ?? "" }
        set {
            textView.text = newValue
            textViewDidChange(textView)
        }
    }

    var isComposerEnabled: Bool {
        get { textView.isEditable }
        set {
            textView.isEditable = newValue
            attachButton.isEnabled = newValue
            plusButton.isEnabled = newValue
            menuButton.isEnabled = newValue
            emojiButton.isEnabled = newValue
            micButton.isEnabled = newValue
            sendButton.isEnabled = newValue
        }
    }

    func focus() {
        textView.becomeFirstResponder()
    }

    func resign() {
        textView.resignFirstResponder()
    }

    func setReplyTarget(_ post: DiscourseTopicDetail.Post?) {
        replyToChatMessageId = nil
        replyToPost = post
        if let post {
            let name = (post.name?.isEmpty == false ? post.name : nil) ?? post.username
            let preview = CookedContentPipeline.plainTextPreview(fromCooked: post.cooked)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = preview.count > 36 ? String(preview.prefix(36)) + "…" : preview
            showReplyBanner(
                name: name,
                preview: clipped.isEmpty ? "#\(post.postNumber)" : clipped
            )
        } else {
            hideReplyBanner()
        }
        onHeightChange?()
    }

    /// Chat-room reply banner (message id, not topic post).
    func setChatReplyTarget(messageId: Int, name: String, preview: String) {
        replyToPost = nil
        replyToChatMessageId = messageId
        let clipped = preview.count > 36 ? String(preview.prefix(36)) + "…" : preview
        showReplyBanner(name: name, preview: clipped.isEmpty ? "#\(messageId)" : clipped)
        onHeightChange?()
        focus()
    }

    func clearReplyTarget() {
        replyToPost = nil
        replyToChatMessageId = nil
        hideReplyBanner()
        onHeightChange?()
    }

    func insertText(_ string: String) {
        guard !string.isEmpty else { return }
        textView.insertText(string)
        textViewDidChange(textView)
        focus()
    }

    var plusMenuAnchorView: UIView {
        if !plusButton.isHidden { return plusButton }
        if !attachButton.isHidden { return attachButton }
        return self
    }

    private func showReplyBanner(name: String, preview: String) {
        replyLabel.text = String(
            format: String(localized: "wechat_chat.reply_to_fmt", defaultValue: "回复 %@：%@"),
            name,
            preview
        )
        replyBanner.isHidden = false
        replyBannerHeightConstraint?.constant = 32
    }

    private func hideReplyBanner() {
        replyLabel.text = nil
        replyBanner.isHidden = true
        replyBannerHeightConstraint?.constant = 0
    }

    func clearAfterSend() {
        isSending = false
        textView.text = ""
        textViewDidChange(textView)
        clearReplyTarget()
        isComposerEnabled = true
    }

    func setSending(_ sending: Bool) {
        isSending = sending
        isComposerEnabled = !sending
    }

    // MARK: - Setup

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        topLine.tag = 91001
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
        addSubview(topLine)

        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        replyBanner.backgroundColor = UIColor.secondarySystemFill.withAlphaComponent(0.55)
        replyBanner.isHidden = true
        addSubview(replyBanner)

        replyLabel.translatesAutoresizingMaskIntoConstraints = false
        replyLabel.font = TopicDetailTypography.chromeFont(.inputMeta, weight: .regular)
        replyLabel.adjustsFontForContentSizeCategory = true
        replyLabel.textColor = .secondaryLabel
        replyLabel.numberOfLines = 1
        replyLabel.lineBreakMode = .byTruncatingTail
        replyBanner.addSubview(replyLabel)

        replyCloseButton.translatesAutoresizingMaskIntoConstraints = false
        replyCloseButton.setImage(
            UIImage(
                systemName: "xmark.circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            ),
            for: .normal
        )
        replyCloseButton.tintColor = .tertiaryLabel
        replyCloseButton.addAction(UIAction { [weak self] _ in
            self?.clearReplyTarget()
        }, for: .touchUpInside)
        replyBanner.addSubview(replyCloseButton)

        textBackground.translatesAutoresizingMaskIntoConstraints = false
        textBackground.layer.cornerCurve = .continuous
        addSubview(textBackground)

        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.accessibilityLabel = String(localized: "wechat_chat.more", defaultValue: "更多")
        menuButton.addAction(UIAction { [weak self] _ in
            self?.onPlus?()
        }, for: .touchUpInside)
        textBackground.addSubview(menuButton)

        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.accessibilityLabel = String(localized: "wechat_chat.more", defaultValue: "更多")
        attachButton.addAction(UIAction { [weak self] _ in
            self?.onPlus?()
        }, for: .touchUpInside)
        textBackground.addSubview(attachButton)

        plusButton.translatesAutoresizingMaskIntoConstraints = false
        plusButton.accessibilityLabel = String(localized: "wechat_chat.more", defaultValue: "更多")
        plusButton.addAction(UIAction { [weak self] _ in
            self?.onPlus?()
        }, for: .touchUpInside)
        addSubview(plusButton)

        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = UIColor.separator.withAlphaComponent(0.55)
        divider.isHidden = true
        textBackground.addSubview(divider)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .clear
        textView.font = TopicDetailTypography.chromeFont(.inputBody, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.textContainer.lineFragmentPadding = 0
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isUserInteractionEnabled = true
        textView.delegate = self
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = true
        textBackground.addSubview(textView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = TopicDetailTypography.chromeFont(.inputBody, weight: .regular)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = .tertiaryLabel
        placeholderLabel.isUserInteractionEnabled = false
        textBackground.addSubview(placeholderLabel)

        emojiButton.translatesAutoresizingMaskIntoConstraints = false
        emojiButton.accessibilityLabel = String(localized: "emoji.picker", defaultValue: "表情")
        emojiButton.addAction(UIAction { [weak self] _ in
            if let onEmoji = self?.onEmoji {
                onEmoji()
            } else {
                self?.onPlus?()
            }
        }, for: .touchUpInside)
        textBackground.addSubview(emojiButton)

        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.accessibilityLabel = String(localized: "telegram_chat.voice", defaultValue: "语音")
        micButton.addAction(UIAction { [weak self] _ in
            self?.onPlus?()
        }, for: .touchUpInside)
        textBackground.addSubview(micButton)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.isHidden = true
        sendButton.accessibilityLabel = String(localized: "action.reply", defaultValue: "发送")
        sendButton.addAction(UIAction { [weak self] _ in
            self?.sendTapped()
        }, for: .touchUpInside)
        textBackground.addSubview(sendButton)

        let textHeight = textView.heightAnchor.constraint(equalToConstant: minTextHeight)
        textHeightConstraint = textHeight
        let bannerHeight = replyBanner.heightAnchor.constraint(equalToConstant: 0)
        replyBannerHeightConstraint = bannerHeight

        wechatFieldLeading = textBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        wechatFieldTrailing = textBackground.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor, constant: -8)
        telegramFieldLeading = textBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        telegramFieldTrailing = textBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        wechatTextLeading = textView.leadingAnchor.constraint(equalTo: textBackground.leadingAnchor)
        wechatTextTrailing = textView.trailingAnchor.constraint(equalTo: textBackground.trailingAnchor)
        telegramTextLeading = textView.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8)
        telegramTextTrailing = textView.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor, constant: -4)

        let tapToFocus = UITapGestureRecognizer(target: self, action: #selector(focusTextView))
        tapToFocus.cancelsTouchesInView = false
        textBackground.addGestureRecognizer(tapToFocus)

        NSLayoutConstraint.activate([
            topLine.topAnchor.constraint(equalTo: topAnchor),
            topLine.leadingAnchor.constraint(equalTo: leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            replyBanner.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            replyBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            replyBanner.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,

            replyLabel.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor, constant: 14),
            replyLabel.centerYAnchor.constraint(equalTo: replyBanner.centerYAnchor),
            replyLabel.trailingAnchor.constraint(equalTo: replyCloseButton.leadingAnchor, constant: -8),

            replyCloseButton.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor, constant: -10),
            replyCloseButton.centerYAnchor.constraint(equalTo: replyBanner.centerYAnchor),
            replyCloseButton.widthAnchor.constraint(equalToConstant: 28),
            replyCloseButton.heightAnchor.constraint(equalToConstant: 28),

            textBackground.topAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: 6),
            textBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            plusButton.bottomAnchor.constraint(equalTo: textBackground.bottomAnchor),
            plusButton.widthAnchor.constraint(equalToConstant: 36),
            plusButton.heightAnchor.constraint(equalToConstant: 36),

            menuButton.leadingAnchor.constraint(equalTo: textBackground.leadingAnchor, constant: 4),
            menuButton.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 32),
            menuButton.heightAnchor.constraint(equalToConstant: 32),

            attachButton.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor, constant: 2),
            attachButton.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),
            attachButton.widthAnchor.constraint(equalToConstant: 28),
            attachButton.heightAnchor.constraint(equalToConstant: 28),

            divider.leadingAnchor.constraint(equalTo: attachButton.trailingAnchor, constant: 4),
            divider.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            divider.heightAnchor.constraint(equalToConstant: 18),

            textView.topAnchor.constraint(equalTo: textBackground.topAnchor),
            textView.bottomAnchor.constraint(equalTo: textBackground.bottomAnchor),
            textHeight,

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 4),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -4),
            placeholderLabel.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),

            emojiButton.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -2),
            emojiButton.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),
            emojiButton.widthAnchor.constraint(equalToConstant: 28),
            emojiButton.heightAnchor.constraint(equalToConstant: 28),

            micButton.trailingAnchor.constraint(equalTo: textBackground.trailingAnchor, constant: -4),
            micButton.centerYAnchor.constraint(equalTo: textBackground.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 32),
            micButton.heightAnchor.constraint(equalToConstant: 32),

            sendButton.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            sendButton.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @objc private func focusTextView() {
        guard textView.isEditable else { return }
        textView.becomeFirstResponder()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let view = super.hitTest(point, with: event)
        if chatStyle == .telegram,
           let view,
           view === textBackground || view === placeholderLabel {
            return textView
        }
        return view
    }

    func applyChatStyle() {
        let style = chatStyle
        backgroundColor = style.inputBarBackgroundColor
        textBackground.backgroundColor = style.inputFieldBackgroundColor
        textBackground.layer.cornerRadius = style.inputFieldCornerRadius
        textBackground.layer.shadowOpacity = 0
        textBackground.layer.borderWidth = 0
        textBackground.clipsToBounds = true

        textView.tintColor = style.accentColor
        textView.font = TopicDetailTypography.chromeFont(.inputBody, weight: .regular)
        textView.returnKeyType = .send
        textView.enablesReturnKeyAutomatically = true
        placeholderLabel.font = TopicDetailTypography.chromeFont(.inputBody, weight: .regular)
        replyLabel.font = TopicDetailTypography.chromeFont(.inputMeta, weight: .regular)
        placeholderLabel.text = style.inputPlaceholder

        wechatFieldLeading?.isActive = false
        wechatFieldTrailing?.isActive = false
        telegramFieldLeading?.isActive = false
        telegramFieldTrailing?.isActive = false
        wechatTextLeading?.isActive = false
        wechatTextTrailing?.isActive = false
        telegramTextLeading?.isActive = false
        telegramTextTrailing?.isActive = false

        if style == .telegram {
            topLine.isHidden = true
            backgroundColor = style.chatBackgroundColor
            textView.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

            styleTelegramCircle(menuButton, systemName: "line.3.horizontal", pointSize: 14)
            attachButton.setImage(
                UIImage(
                    systemName: "paperclip",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
                ),
                for: .normal
            )
            attachButton.tintColor = .secondaryLabel
            emojiButton.setImage(
                UIImage(
                    systemName: "face.smiling",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                ),
                for: .normal
            )
            emojiButton.tintColor = .secondaryLabel
            styleTelegramCircle(micButton, systemName: "mic.fill", pointSize: 14)
            styleTelegramCircle(sendButton, systemName: "arrow.up", pointSize: 14)
            sendButton.setTitle(nil, for: .normal)
            sendButton.imageView?.transform = .identity

            menuButton.isHidden = false
            attachButton.isHidden = false
            divider.isHidden = false
            emojiButton.isHidden = false
            plusButton.isHidden = true

            telegramFieldLeading?.isActive = true
            telegramFieldTrailing?.isActive = true
            telegramTextLeading?.isActive = true
            telegramTextTrailing?.isActive = true
            textBackground.bringSubviewToFront(textView)
            textBackground.bringSubviewToFront(placeholderLabel)
            textBackground.bringSubviewToFront(emojiButton)
            textBackground.bringSubviewToFront(micButton)
            textBackground.bringSubviewToFront(sendButton)
        } else {
            topLine.isHidden = false
            textView.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

            let iconConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            plusButton.setImage(
                UIImage(systemName: style.trailingActionSystemName, withConfiguration: iconConfig),
                for: .normal
            )
            plusButton.tintColor = .secondaryLabel

            menuButton.isHidden = true
            attachButton.isHidden = true
            divider.isHidden = true
            emojiButton.isHidden = true
            micButton.isHidden = true
            sendButton.isHidden = true
            plusButton.isHidden = false

            wechatFieldLeading?.isActive = true
            wechatFieldTrailing?.isActive = true
            wechatTextLeading?.isActive = true
            wechatTextTrailing?.isActive = true
        }

        updateTrailingButtons()
    }

    private func styleTelegramCircle(_ button: UIButton, systemName: String, pointSize: CGFloat) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        button.setImage(UIImage(systemName: systemName, withConfiguration: config), for: .normal)
        button.backgroundColor = chatStyle.accentColor
        button.tintColor = .white
        button.layer.cornerRadius = 16
        button.layer.cornerCurve = .circular
        button.clipsToBounds = true
    }

    private func updateTrailingButtons() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasText || allowsEmptySend
        guard chatStyle == .telegram else { return }
        micButton.isHidden = canSend
        sendButton.isHidden = !canSend
    }

    private func sendTapped() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!raw.isEmpty || allowsEmptySend), !isSending else { return }
        onSend?(raw)
    }

    // MARK: - UITextViewDelegate

    func textViewDidBeginEditing(_ textView: UITextView) {
        onBeginEditing?()
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
        updateTrailingButtons()

        let width = max(textView.bounds.width, UIScreen.main.bounds.width - 90)
        let size = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let minH = chatStyle == .telegram ? 40 : minTextHeight
        let target = min(max(size.height, minH), maxTextHeight)
        textView.isScrollEnabled = size.height > maxTextHeight
        if textHeightConstraint?.constant != target {
            textHeightConstraint?.constant = target
            onHeightChange?()
        }
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // Match WeChat: keyboard 发送 / Return sends. Do not steal IME confirm.
        if text == "\n" {
            if textView.markedTextRange != nil { return true }
            sendTapped()
            return false
        }
        return true
    }
}
