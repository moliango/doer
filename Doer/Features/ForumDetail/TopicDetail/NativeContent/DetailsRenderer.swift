import CookedHTML
import UIKit

enum DetailsRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        guard case .details(_, let content) = block else { return false }
        return NativeContentRenderer.canRenderNatively(content)
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .details(let summary, let content) = block else { return UIView() }
        return DetailsCardView(summary: summary, content: content, config: config, delegate: delegate)
    }
}

// MARK: - DetailsCardView

private class DetailsCardView: UIView {
    private let chevron = UIImageView()
    private let headerView = UIView()
    private let dividerView = UIView()
    private var contentStack: UIStackView?
    private var isExpanded = false
    private var headerBottomConstraint: NSLayoutConstraint!
    private var contentBottomConstraint: NSLayoutConstraint?

    private var contentBlocks: [ContentBlock] = []
    private var innerConfig: NativeRenderConfig!
    private weak var delegate: PostCellDelegate?

    init(summary: [InlineNode], content: [ContentBlock], config: NativeRenderConfig, delegate: PostCellDelegate?) {
        self.contentBlocks = content
        self.delegate = delegate
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // FluxDo-style card shell: muted fill + hairline border; expands in place.
        backgroundColor = TopicDetailContentStyle.warmMutedBackground.withAlphaComponent(0.35)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.0 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        clipsToBounds = true

        innerConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: max(config.contentWidth - 24, 0),
            baseURL: config.baseURL,
            postId: config.postId,
            galleryImageURLs: config.galleryImageURLs,
            topicTagNames: config.topicTagNames,
            topicCategoryPresentation: config.topicCategoryPresentation
        )

        // MARK: Header

        chevron.image = UIImage(systemName: "chevron.right")
        chevron.tintColor = .secondaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false

        let summaryLabel = UILabel()
        summaryLabel.numberOfLines = 0
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        let summaryConfig = NativeRenderConfig(
            baseFont: config.baseFont.bold(),
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: innerConfig.contentWidth,
            baseURL: config.baseURL,
            postId: config.postId,
            galleryImageURLs: config.galleryImageURLs,
            topicTagNames: config.topicTagNames,
            topicCategoryPresentation: config.topicCategoryPresentation
        )
        let summaryText = summaryConfig.styledAttributedString(
            from: summary,
            lineSpacing: 2,
            paragraphSpacing: 0
        )
        summaryLabel.attributedText = summaryText
        TitleEmojiRenderer.loadImages(in: summaryText, cloudflareBaseURL: config.baseURL) { [weak summaryLabel] updated in
            summaryLabel?.attributedText = updated
            summaryLabel?.invalidateIntrinsicContentSize()
        }

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.backgroundColor = .clear

        headerView.addSubview(chevron)
        headerView.addSubview(summaryLabel)
        addSubview(headerView)

        dividerView.translatesAutoresizingMaskIntoConstraints = false
        dividerView.backgroundColor = UIColor.separator.withAlphaComponent(0.28)
        dividerView.isHidden = true
        addSubview(dividerView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleExpanded))
        headerView.addGestureRecognizer(tap)
        headerView.isAccessibilityElement = true
        headerView.accessibilityTraits = .button
        headerView.accessibilityLabel = summaryText.string.isEmpty
            ? String(localized: "topic.details.toggle", defaultValue: "折叠内容")
            : summaryText.string

        headerBottomConstraint = headerView.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBottomConstraint,

            dividerView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            dividerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dividerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dividerView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
            chevron.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            chevron.centerYAnchor.constraint(equalTo: summaryLabel.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 12),
            summaryLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            summaryLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func toggleExpanded() {
        isExpanded.toggle()

        if isExpanded {
            // Lazily create and add the content stack
            if contentStack == nil {
                let stack = UIStackView()
                stack.axis = .vertical
                stack.spacing = 8
                stack.translatesAutoresizingMaskIntoConstraints = false
                addSubview(stack)

                let views = NativeContentRenderer.renderBlocks(contentBlocks, config: innerConfig, delegate: delegate)
                for view in views {
                    // Wire link delegates + inline image loaders for lazy content.
                    // Block images (TappableImageContainer) self-load; this covers LinkTextView.
                    prepareLazyContentView(view)
                    stack.addArrangedSubview(view)
                }

                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: dividerView.bottomAnchor, constant: 10),
                    stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                    stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                ])

                contentBottomConstraint = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
                contentStack = stack
            }

            contentStack?.isHidden = false
            dividerView.isHidden = false
            headerBottomConstraint.isActive = false
            contentBottomConstraint?.isActive = true
        } else {
            contentBottomConstraint?.isActive = false
            headerBottomConstraint.isActive = true
            contentStack?.isHidden = true
            dividerView.isHidden = true
        }

        UIView.animate(withDuration: 0.18) {
            self.chevron.transform = self.isExpanded
                ? CGAffineTransform(rotationAngle: .pi / 2)
                : .identity
        }

        invalidateIntrinsicContentSize()
        if let cell = findPostNativeCell() {
            cell.requestHeightReconciliation()
        } else if let cell = findWeChatChatPostCell() {
            cell.requestHeightReconciliation()
        } else {
            findTableView()?.doer_invalidateSelfSizingRows()
        }
    }

    /// Attach cell text-view wiring that was skipped because details content is lazy.
    private func prepareLazyContentView(_ view: UIView) {
        if let cell = findPostNativeCell() {
            cell.setupTextViews(in: view, cloudflareBaseURL: innerConfig.baseURL)
            return
        }
        // WeChat / Telegram bubbles: load inline attachments without a full cell setup path.
        prepareInlineImagesRecursively(in: view)
    }

    private func prepareInlineImagesRecursively(in view: UIView) {
        if let textView = view as? UITextView {
            CookedInlineImageLoader.loadImages(
                in: textView,
                cloudflareBaseURL: innerConfig.baseURL
            ) { [weak self] in
                self?.findWeChatChatPostCell()?.requestHeightReconciliation()
                    ?? self?.findTableView()?.doer_invalidateSelfSizingRows()
            }
            return
        }
        if let stack = view as? UIStackView {
            for arranged in stack.arrangedSubviews {
                prepareInlineImagesRecursively(in: arranged)
            }
        }
        for subview in view.subviews {
            prepareInlineImagesRecursively(in: subview)
        }
    }

    private func findPostNativeCell() -> PostNativeCell? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let cell = next as? PostNativeCell { return cell }
            responder = next
        }
        return nil
    }

    private func findWeChatChatPostCell() -> WeChatChatPostCell? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let cell = next as? WeChatChatPostCell { return cell }
            responder = next
        }
        return nil
    }

    private func findTableView() -> UITableView? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let tv = next as? UITableView { return tv }
            responder = next
        }
        return nil
    }
}

// MARK: - UIFont + Bold Helper

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
