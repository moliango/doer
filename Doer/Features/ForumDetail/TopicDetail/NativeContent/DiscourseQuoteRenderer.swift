import CookedHTML
import UIKit

enum DiscourseQuoteRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        guard case .discourseQuote(_, _, _, _, _, _, _, let content) = block else { return false }
        return NativeContentRenderer.canRenderNatively(content)
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .discourseQuote(let username, let avatarURL, let topicTitle, let topicURL, let categoryName, let categoryURL, let quotePostNumber, let content) = block else {
            return UIView()
        }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.backgroundColor = TopicDetailContentStyle.mutedBackground.withAlphaComponent(0.46)
        container.layer.cornerRadius = 0
        container.layer.borderWidth = 0
        container.clipsToBounds = true
        if quotePostNumber != nil || topicURL != nil {
            container.isUserInteractionEnabled = true
            let tap = UITapGestureRecognizer(target: QuoteTapRelay.shared, action: #selector(QuoteTapRelay.handleTap(_:)))
            container.addGestureRecognizer(tap)
            QuoteTapRelay.shared.bind(container, quotePostNumber: quotePostNumber, topicURL: topicURL, delegate: delegate)
        }

        // Header: avatar + (username OR topic title + category badge)
        let headerStack = UIStackView()
        headerStack.axis = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerStack)

        let avatarSize: CGFloat = 20
        let avatarImageView = UIImageView()
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = avatarSize / 2
        avatarImageView.backgroundColor = .secondarySystemFill
        headerStack.addArrangedSubview(avatarImageView)

        NSLayoutConstraint.activate([
            avatarImageView.widthAnchor.constraint(equalToConstant: avatarSize),
            avatarImageView.heightAnchor.constraint(equalToConstant: avatarSize),
        ])

        AvatarImageLoader.setImage(
            on: avatarImageView,
            url: AvatarImageLoader.url(from: avatarURL, baseURL: config.baseURL ?? "", size: 48),
            placeholder: UIImage(systemName: "person.crop.circle")
        )

        if let topicTitle, !topicTitle.isEmpty {
            // Topic-link variant: title button + optional category badge
            let titleButton = UIButton(type: .system)
            var titleConfig = UIButton.Configuration.plain()
            titleConfig.title = topicTitle
            titleConfig.baseForegroundColor = config.linkColor
            titleConfig.contentInsets = .zero
            titleConfig.titleLineBreakMode = .byTruncatingTail
            titleConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var updated = attributes
                updated.font = config.baseFont.withRelativeSize(-1).weighted(.semibold)
                return updated
            }
            titleButton.configuration = titleConfig
            titleButton.contentHorizontalAlignment = .leading
            titleButton.titleLabel?.numberOfLines = 1
            titleButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            if let topicURL, let url = URL(string: topicURL) {
                titleButton.addAction(UIAction { _ in
                    delegate?.postCell(didTapLinkURL: url)
                }, for: .touchUpInside)
            }
            headerStack.addArrangedSubview(titleButton)

            if let categoryName, !categoryName.isEmpty {
                let badge = CategoryBadgeView(name: categoryName, font: config.baseFont.withRelativeSize(-2).weighted(.semibold))
                badge.setContentHuggingPriority(.required, for: .horizontal)
                badge.setContentCompressionResistancePriority(.required, for: .horizontal)
                if let categoryURL, let url = URL(string: categoryURL) {
                    let tap = UITapGestureRecognizer()
                    badge.addGestureRecognizer(tap)
                    badge.isUserInteractionEnabled = true
                    tap.addTarget(badge, action: #selector(CategoryBadgeView.handleTap))
                    badge.tapAction = { delegate?.postCell(didTapLinkURL: url) }
                }
                headerStack.addArrangedSubview(badge)
            }
        } else if let username, !username.isEmpty {
            // Username variant (existing behavior)
            let nameLabel = UILabel()
            nameLabel.font = config.baseFont.withRelativeSize(-1).weighted(.semibold)
            nameLabel.textColor = .secondaryLabel
            nameLabel.text = username
            headerStack.addArrangedSubview(nameLabel)
        }

        // Vertical bar + content
        let bar = UIView()
        bar.backgroundColor = AppSettings.shared.themeStyle.accentColor.withAlphaComponent(0.82)
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 5
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentStack)

        let quoteConfig = NativeRenderConfig(
            baseFont: config.baseFont.withRelativeSize(-1),
            baseColor: UIColor.label.withAlphaComponent(0.78),
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: max(config.contentWidth - 28, 0),
            baseURL: config.baseURL,
            postId: config.postId,
            galleryImageURLs: config.galleryImageURLs,
            topicTagNames: config.topicTagNames,
            topicCategoryPresentation: config.topicCategoryPresentation
        )

        // renderBlocks promotes flat `[!question]` markers once; do not pre-promote
        // here or nested blockquotes re-enter promote/render until the stack dies.
        let views = NativeContentRenderer.renderBlocks(
            normalizedQuoteContent(content),
            config: quoteConfig,
            delegate: delegate
        )
        for view in views {
            contentStack.addArrangedSubview(view)
        }

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.widthAnchor.constraint(equalToConstant: 4),

            headerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            headerStack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            headerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            contentStack.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        return container
    }

    private static func normalizedQuoteContent(_ blocks: [ContentBlock]) -> [ContentBlock] {
        blocks.flatMap { block -> [ContentBlock] in
            guard case .paragraph(let inlines) = block else { return [block] }
            var result: [ContentBlock] = []
            var textInlines: [InlineNode] = []

            func flushText() {
                let trimmed = textInlines.trimmedWhitespace()
                if !trimmed.isEmpty { result.append(.paragraph(trimmed)) }
                textInlines.removeAll(keepingCapacity: true)
            }

            for inline in inlines {
                if let imageBlock = quoteImageBlock(from: inline) {
                    flushText()
                    result.append(imageBlock)
                } else {
                    textInlines.append(inline)
                }
            }
            flushText()
            return result.isEmpty ? [block] : result
        }
    }

    private static func quoteImageBlock(from inline: InlineNode) -> ContentBlock? {
        switch inline {
        case .image(let src, let alt, let width, let height, let isEmoji):
            guard !isEmoji, !src.isEmpty else { return nil }
            return .image(src: src, alt: alt, width: width, height: height, href: src)
        case .link(let href, let children):
            if children.count == 1,
               case .image(let src, let alt, let width, let height, let isEmoji) = children[0],
               !isEmoji {
                return .image(src: src, alt: alt, width: width, height: height, href: href)
            }
            let label = plainText(children).trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeImageURL(href),
                  label.hasPrefix("["), label.hasSuffix("]") else { return nil }
            return .image(src: href, alt: String(label.dropFirst().dropLast()), width: nil, height: nil, href: href)
        default:
            return nil
        }
    }

    private static func looksLikeImageURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        let path = components.path.lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".heic"].contains { path.hasSuffix($0) }
    }

    private static func plainText(_ inlines: [InlineNode]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .styledText(let text, _), .code(let text): return text
            case .link(_, let children), .spoiler(let children): return plainText(children)
            case .mention(let username, _): return "@\(username)"
            case .mentionGroup(let name, _): return "@\(name)"
            case .hashtag(let text, _, _, _): return "#\(text)"
            case .image(_, let alt, _, _, _): return alt ?? ""
            case .lineBreak: return "\n"
            }
        }.joined()
    }
}

private final class QuoteTapRelay: NSObject {
    static let shared = QuoteTapRelay()

    private struct Target {
        weak var delegate: PostCellDelegate?
        let quotePostNumber: Int?
        let topicURL: String?
    }

    private let targets = NSMapTable<UIView, Box>.weakToStrongObjects()

    private final class Box {
        let target: Target

        init(target: Target) {
            self.target = target
        }
    }

    func bind(_ view: UIView, quotePostNumber: Int?, topicURL: String?, delegate: PostCellDelegate?) {
        targets.setObject(Box(target: Target(delegate: delegate, quotePostNumber: quotePostNumber, topicURL: topicURL)), forKey: view)
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let view = gesture.view,
              let target = targets.object(forKey: view)?.target
        else { return }

        if let topicURL = target.topicURL, let url = URL(string: topicURL) {
            target.delegate?.postCell(didTapLinkURL: url)
            return
        }

        if let quotePostNumber = target.quotePostNumber {
            target.delegate?.postCell(didTapQuotedPostNumber: quotePostNumber)
        }
    }
}

// MARK: - Category Badge

private class CategoryBadgeView: UIView {
    var tapAction: (() -> Void)?

    init(name: String, font: UIFont) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let color = TopicTagVisualStyle.categoryColor(for: name, fallback: AppSettings.shared.themeStyle.accentColor)

        let label = UILabel()
        label.text = name
        label.font = font
        // Always use the category/accent color so the chip stays readable on muted quote backgrounds.
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        backgroundColor = color.withAlphaComponent(0.14)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = color.withAlphaComponent(0.32).cgColor

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc func handleTap() {
        tapAction?()
    }
}

private extension UIFont {
    func withRelativeSize(_ offset: CGFloat) -> UIFont {
        withSize(max(pointSize + offset, 1))
    }

    func weighted(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
