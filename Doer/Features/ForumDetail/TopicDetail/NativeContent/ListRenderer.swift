import CookedHTML
import UIKit

enum ListRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .list = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .list(let ordered, let start, let items) = block else { return UIView() }

        // Simple text-only lists keep the compact attributed-string path.
        // Any nested media/blocks need a real stack so images are not dropped.
        let needsRichLayout = items.contains { !$0.children.isEmpty }
        if !needsRichLayout {
            return renderPlainList(ordered: ordered, start: start, items: items, config: config)
        }
        return renderRichList(ordered: ordered, start: start, items: items, config: config, delegate: delegate)
    }

    // MARK: - Plain (text-only) lists

    private static func renderPlainList(
        ordered: Bool,
        start: Int,
        items: [ListItem],
        config: NativeRenderConfig
    ) -> UIView {
        let result = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = config.defaultLineSpacing
        paragraphStyle.paragraphSpacing = config.defaultParagraphSpacing
        paragraphStyle.minimumLineHeight = config.minimumTextLineHeight
        let firstNumber = max(start, 1)

        if ordered {
            // Wider gutter when continued lists reach double digits (10+).
            let lastNumber = firstNumber + max(items.count, 1) - 1
            let gutter = lastNumber >= 10 ? 32 : 24
            paragraphStyle.headIndent = CGFloat(gutter)
            paragraphStyle.firstLineHeadIndent = 0
            let tabStop = NSTextTab(textAlignment: .left, location: CGFloat(gutter), options: [:])
            paragraphStyle.tabStops = [tabStop]
            paragraphStyle.defaultTabInterval = CGFloat(gutter)
        } else {
            paragraphStyle.headIndent = 18
            paragraphStyle.firstLineHeadIndent = 0
            let tabStop = NSTextTab(textAlignment: .left, location: 18, options: [:])
            paragraphStyle.tabStops = [tabStop]
            paragraphStyle.defaultTabInterval = 18
        }

        for (index, item) in items.enumerated() {
            let bullet: String
            if ordered {
                bullet = "\(firstNumber + index).\t"
            } else {
                bullet = "\u{2022}\t"
            }
            let itemStart = result.length

            let bulletAttr = NSAttributedString(string: bullet, attributes: [
                .font: config.baseFont,
                .foregroundColor: config.baseColor,
                .paragraphStyle: paragraphStyle,
            ])
            result.append(bulletAttr)

            let itemAttr = config.styledAttributedString(
                from: item.content,
                paragraphSpacing: 0
            )
            result.append(itemAttr)

            if index < items.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }

            let itemEnd = result.length
            result.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: itemStart, length: itemEnd - itemStart)
            )
        }

        let textView = LinkTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.attributedText = result
        textView.linkTextAttributes = [:]
        textView.preferredMeasurementWidth = config.contentWidth
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }

    // MARK: - Rich lists (nested images / blocks / sub-lists)

    private static func renderRichList(
        ordered: Bool,
        start: Int,
        items: [ListItem],
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> UIView {
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 8
        outer.alignment = .fill
        outer.translatesAutoresizingMaskIntoConstraints = false

        let firstNumber = max(start, 1)
        // Width for "10." / "99." so multi-digit ordered lists stay aligned.
        let bulletColumnWidth: CGFloat = {
            if ordered {
                let lastNumber = firstNumber + max(items.count, 1) - 1
                let digits = String(max(lastNumber, 1)).count
                return CGFloat(12 + digits * 10)
            }
            return 18
        }()
        let innerWidth = max(config.contentWidth - bulletColumnWidth, 0)
        let itemConfig = NativeRenderConfig(
            baseFont: config.baseFont,
            baseColor: config.baseColor,
            linkColor: config.linkColor,
            codeFont: config.codeFont,
            codeBackgroundColor: config.codeBackgroundColor,
            contentWidth: innerWidth,
            baseURL: config.baseURL,
            postId: config.postId,
            galleryImageURLs: config.galleryImageURLs,
            topicTagNames: config.topicTagNames,
            topicCategoryPresentation: config.topicCategoryPresentation,
            defaultLineSpacing: config.defaultLineSpacing,
            defaultParagraphSpacing: config.defaultParagraphSpacing
        )

        for (index, item) in items.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 4
            row.translatesAutoresizingMaskIntoConstraints = false

            let bulletLabel = UILabel()
            bulletLabel.font = config.baseFont
            bulletLabel.textColor = config.baseColor
            bulletLabel.textAlignment = ordered ? .right : .center
            bulletLabel.numberOfLines = 1
            bulletLabel.text = ordered ? "\(firstNumber + index)." : "\u{2022}"
            bulletLabel.setContentHuggingPriority(.required, for: .horizontal)
            bulletLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            bulletLabel.translatesAutoresizingMaskIntoConstraints = false
            bulletLabel.widthAnchor.constraint(equalToConstant: bulletColumnWidth - 4).isActive = true

            let contentStack = UIStackView()
            contentStack.axis = .vertical
            contentStack.spacing = 6
            contentStack.alignment = .fill
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            if !item.content.isEmpty {
                let textView = makeItemTextView(inlines: item.content, config: itemConfig)
                contentStack.addArrangedSubview(textView)
            }

            if !item.children.isEmpty {
                let childViews = NativeContentRenderer.renderBlocks(
                    item.children,
                    config: itemConfig,
                    delegate: delegate
                )
                for view in childViews {
                    contentStack.addArrangedSubview(view)
                }
            }

            // Empty item still keeps the bullet row height stable.
            if contentStack.arrangedSubviews.isEmpty {
                let spacer = UIView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: config.baseFont.lineHeight).isActive = true
                contentStack.addArrangedSubview(spacer)
            }

            row.addArrangedSubview(bulletLabel)
            row.addArrangedSubview(contentStack)
            outer.addArrangedSubview(row)
        }

        return outer
    }

    private static func makeItemTextView(inlines: [InlineNode], config: NativeRenderConfig) -> LinkTextView {
        let textView = LinkTextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.backgroundColor = .clear
        textView.dataDetectorTypes = []
        textView.attributedText = config.styledAttributedString(from: inlines, paragraphSpacing: 0)
        textView.linkTextAttributes = [:]
        textView.preferredMeasurementWidth = config.contentWidth
        textView.setContentHuggingPriority(.required, for: .vertical)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.translatesAutoresizingMaskIntoConstraints = false
        return textView
    }
}
