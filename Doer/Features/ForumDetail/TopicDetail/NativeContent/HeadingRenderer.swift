import UIKit
import CookedHTML

enum HeadingPresentationPolicy {
    static let usesAccentRail = false

    static func shouldRenderTagBadge(
        level: Int,
        text: String,
        topicTagNames: Set<String>
    ) -> Bool {
        guard level == 1 else { return false }
        let normalizedText = normalize(text)
        guard !normalizedText.isEmpty else { return false }
        if topicTagNames.contains(where: { normalize($0) == normalizedText }) {
            return true
        }
        return TopicTagIconCatalog.presentation(for: normalizedText) != nil
    }

    static func shouldRenderCategoryBadge(
        level: Int,
        text: String,
        categoryName: String?
    ) -> Bool {
        guard level == 1, let categoryName else { return false }
        let normalizedText = normalize(text)
        return !normalizedText.isEmpty && normalize(categoryName) == normalizedText
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum HeadingRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .heading = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .heading(let level, let inlines) = block else { return UIView() }

        let headingText = plainHeadingText(from: inlines)
        if let category = config.topicCategoryPresentation,
           HeadingPresentationPolicy.shouldRenderCategoryBadge(
               level: level,
               text: headingText,
               categoryName: category.name
           ) {
            let badge = TopicTaxonomyBadgeView(
                category: category,
                baseURL: config.baseURL ?? "",
                variant: .regular,
                isInteractive: true
            )
            if let url = ForumInternalLinkParser.categoryURL(
                slug: category.name,
                id: category.categoryId,
                baseURL: config.baseURL ?? ""
            ) {
                badge.addAction(UIAction { [weak delegate] _ in
                    delegate?.postCell(didTapLinkURL: url)
                }, for: .touchUpInside)
            }
            return badge
        }
        if HeadingPresentationPolicy.shouldRenderTagBadge(
            level: level,
            text: headingText,
            topicTagNames: config.topicTagNames
        ) {
            let badge = TopicTaxonomyBadgeView(
                tag: headingText,
                color: TopicTagVisualStyle.color(for: headingText),
                variant: .regular,
                isInteractive: true
            )
            if let url = ForumInternalLinkParser.tagURL(name: headingText, baseURL: config.baseURL ?? "") {
                badge.addAction(UIAction { [weak delegate] _ in
                    delegate?.postCell(didTapLinkURL: url)
                }, for: .touchUpInside)
            }
            return badge
        }

        let baseSize = config.baseFont.pointSize
        let fontSize: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: fontSize = baseSize + 6; weight = .bold
        case 2: fontSize = baseSize + 5; weight = .bold
        case 3: fontSize = baseSize + 4; weight = .semibold
        case 4: fontSize = baseSize + 2; weight = .semibold
        case 5: fontSize = baseSize + 1; weight = .semibold
        default: fontSize = baseSize; weight = .medium
        }

        let headingConfig = NativeRenderConfig(
            baseFont: AppSettings.shared.contentFont(ofSize: fontSize, weight: weight),
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: config.contentWidth,
            baseURL: config.baseURL,
            postId: config.postId,
            galleryImageURLs: config.galleryImageURLs,
            topicTagNames: config.topicTagNames,
            topicCategoryPresentation: config.topicCategoryPresentation
        )

        let attributedText = headingConfig.styledAttributedString(
            from: inlines,
            lineSpacing: 2,
            paragraphSpacing: 8
        )
        let textView = makeTextView(attributedText: attributedText, config: config)
        let view = HeadingBlockView(level: level, textView: textView)
        if let postId = config.postId {
            view.tocAnchorId = NativeContentRenderer.currentTocAnchorCounter?.nextId(
                postId: postId,
                text: headingText
            )
        }
        return view
    }

    private static func makeTextView(attributedText: NSAttributedString, config: NativeRenderConfig) -> LinkTextView {
        let textView = LinkTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        // 首次测量时 bounds 还是 0，必须给测量宽度，否则标题高度被低估、
        // 文本视图偏短导致首行被顶出可视区（内容顶部“被掩盖”）。
        textView.preferredMeasurementWidth = config.contentWidth
        textView.attributedText = attributedText
        textView.linkTextAttributes = [:]
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }

    private static func plainHeadingText(from inlines: [InlineNode]) -> String {
        plainText(from: inlines)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
    }

    private static func plainText(from inlines: [InlineNode]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .styledText(let text, _), .code(let text):
                return text
            case .link(_, let children), .spoiler(let children):
                return plainText(from: children)
            case .mention(let username, _):
                return "@\(username)"
            case .mentionGroup(let name, _):
                return "@\(name)"
            case .hashtag(let text, _, _, _):
                return text
            case .image(_, let alt, _, _, _):
                return alt ?? ""
            case .lineBreak:
                return "\n"
            }
        }
        .joined()
    }
}

final class HeadingBlockView: UIView {
    var tocAnchorId: String?

    init(level: Int, textView: UIView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        layer.borderWidth = 0

        addSubview(textView)

        let topPadding: CGFloat = level <= 2 ? 8 : 4
        let bottomPadding: CGFloat = level <= 2 ? 6 : 3
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor, constant: topPadding),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -bottomPadding),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

