import UIKit

/// 对齐 FluxDo `editor_tools.dart` 全量工具 + doer 额外的 AI 预审。
enum ComposerMarkdownTool: CaseIterable {
    case image
    case attachment
    case media
    case heading
    case bold
    case italic
    case strikethrough
    case bulletList
    case numberedList
    case link
    case quote
    case callout
    case template
    case inlineCode
    case codeBlock
    case insertBlock
    case toc
    case spoiler
    case imageGrid
    case poll
    case encrypt
    case aiReview

    var title: String {
        switch self {
        case .image: return String(localized: "reply.tool.image")
        case .attachment: return String(localized: "reply.tool.attachment")
        case .media: return "音视频"
        case .heading: return String(localized: "reply.tool.heading")
        case .bold: return String(localized: "reply.tool.bold")
        case .italic: return String(localized: "reply.tool.italic")
        case .strikethrough: return String(localized: "reply.tool.strikethrough")
        case .bulletList: return String(localized: "reply.tool.bullet_list")
        case .numberedList: return String(localized: "reply.tool.numbered_list")
        case .link: return String(localized: "reply.tool.link")
        case .quote: return String(localized: "reply.tool.quote")
        case .callout: return String(localized: "reply.tool.note")
        case .template: return String(localized: "reply.tool.template")
        case .inlineCode: return "行内代码"
        case .codeBlock: return "代码块"
        case .insertBlock: return "插入块"
        case .toc: return String(localized: "reply.tool.toc", defaultValue: "目录")
        case .spoiler: return "剧透"
        case .imageGrid: return "图片网格"
        case .poll: return String(localized: "reply.tool.poll", defaultValue: "投票")
        case .encrypt: return String(localized: "crypto.encrypt.action", defaultValue: "加密")
        case .aiReview: return String(localized: "reply.tool.ai_review", defaultValue: "AI 预审")
        }
    }

    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .attachment: return "paperclip"
        case .media: return "film"
        case .heading: return "textformat.size"
        case .bold: return "bold"
        case .italic: return "italic"
        case .strikethrough: return "strikethrough"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .link: return "link"
        case .quote: return "quote.closing"
        case .callout: return "note.text"
        case .template: return "doc.on.clipboard"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .codeBlock: return "curlybraces"
        case .insertBlock: return "square.plus"
        case .toc: return "list.bullet"
        case .spoiler: return "eye.slash"
        case .imageGrid: return "rectangle.grid.2x2"
        case .poll: return "chart.bar.doc.horizontal"
        case .encrypt: return "key.fill"
        case .aiReview: return "sparkles"
        }
    }

    var closesPanelAfterAction: Bool {
        switch self {
        case .image, .attachment, .media, .heading, .callout, .template, .insertBlock, .poll, .encrypt, .aiReview:
            return false
        default:
            return true
        }
    }
}

final class ComposerToolPanelView: UIView {
    var onToolSelected: ((ComposerMarkdownTool) -> Void)?

    var isUploading = false {
        didSet {
            toolButtons.forEach { button in
                guard let tool = toolByButton[button] else { return }
                let uploadTools: Set<ComposerMarkdownTool> = [.image, .attachment, .media]
                button.isEnabled = !isUploading || !uploadTools.contains(tool)
                button.alpha = button.isEnabled ? 1 : 0.45
            }
        }
    }

    private var isCustomizing = false
    private var toolButtons: [UIButton] = []
    private var toolByButton: [UIButton: ComposerMarkdownTool] = [:]

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .secondaryLabel
        label.text = String(localized: "reply.more_tools")
        return label
    }()

    private let customizeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "reply.customize")
        config.baseForegroundColor = ComposerTypography.accentColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        return scroll
    }()

    private let gridStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(titleLabel)
        addSubview(customizeButton)
        addSubview(scrollView)
        scrollView.addSubview(gridStackView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),

            customizeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            customizeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            gridStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            gridStackView.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 28),
            gridStackView.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -28),
            gridStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -4),
        ])

        customizeButton.addTarget(self, action: #selector(customizeTapped), for: .touchUpInside)
        buildGrid()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildGrid() {
        let tools = ComposerMarkdownTool.allCases
        let columns = 4
        let rowCount = Int(ceil(Double(tools.count) / Double(columns)))
        for rowIndex in 0 ..< rowCount {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .fillEqually
            row.spacing = 8
            gridStackView.addArrangedSubview(row)

            for column in 0 ..< columns {
                let index = rowIndex * columns + column
                if tools.indices.contains(index) {
                    row.addArrangedSubview(makeToolButton(tools[index]))
                } else {
                    let spacer = UIView()
                    spacer.isUserInteractionEnabled = false
                    row.addArrangedSubview(spacer)
                }
            }
        }
    }

    private func makeToolButton(_ tool: ComposerMarkdownTool) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: tool.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        config.imagePlacement = .top
        config.imagePadding = 6
        config.title = tool.title
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var updated = attrs
            updated.font = .systemFont(ofSize: 12, weight: .regular)
            return updated
        }
        config.background.backgroundColor = .clear

        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 58).isActive = true
        button.addTarget(self, action: #selector(toolTapped(_:)), for: .touchUpInside)
        toolButtons.append(button)
        toolByButton[button] = tool
        return button
    }

    func setActiveTools(_ tools: Set<ComposerMarkdownTool>) {
        for (button, tool) in toolByButton {
            let active = tools.contains(tool)
            var config = button.configuration
            config?.baseForegroundColor = active ? ComposerTypography.accentColor : .label
            config?.background.backgroundColor = active
                ? ComposerTypography.accentColor.withAlphaComponent(0.12)
                : .clear
            button.configuration = config
        }
    }

    @objc private func toolTapped(_ sender: UIButton) {
        guard !isCustomizing, let tool = toolByButton[sender] else { return }
        onToolSelected?(tool)
    }

    @objc private func customizeTapped() {
        isCustomizing.toggle()
        var config = customizeButton.configuration
        config?.title = isCustomizing ? String(localized: "common.done") : String(localized: "reply.customize")
        customizeButton.configuration = config
        toolButtons.forEach { button in
            button.transform = isCustomizing ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
            button.alpha = isCustomizing ? 0.7 : 1
        }
    }
}

final class ComposerMarkdownPreviewView: UIView {
    private let textView: UITextView = {
        let tv = UITextView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.isEditable = false
        tv.isScrollEnabled = true
        tv.backgroundColor = ComposerTypography.backgroundColor
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)
        tv.font = ComposerTypography.bodyFont
        tv.adjustsFontForContentSizeCategory = true
        tv.tintColor = ComposerTypography.accentColor
        tv.linkTextAttributes = [
            .foregroundColor: ComposerTypography.accentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        return tv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(markdown: String) {
        textView.attributedText = ComposerMarkdownRenderer.renderPreview(markdown)
    }
}

// MARK: - Shared markdown renderer (preview + source chrome)

/// Local Discourse-ish markdown approximation for composer preview / source tinting.
/// FluxDo ships a full cook JS bundle; Doer stays native UIKit without that dependency.
enum ComposerMarkdownRenderer {
    private static var bodyFont: UIFont { ComposerTypography.bodyFont }
    private static var codeFont: UIFont { ComposerTypography.codeFont }
    private static var bodyPointSize: CGFloat { bodyFont.pointSize }

    static func renderPreview(_ markdown: String) -> NSAttributedString {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyFont = self.bodyFont
        let paragraph = ComposerTypography.paragraphStyle(paragraphSpacing: 10)

        guard !trimmed.isEmpty else {
            return NSAttributedString(
                string: String(localized: "reply.preview.empty"),
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: UIColor.placeholderText,
                    .paragraphStyle: paragraph,
                ]
            )
        }

        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        var inCodeBlock = false
        var codeLanguage = ""
        var codeLines: [String] = []

        func flushCodeBlock() {
            result.append(makeCodeBlock(language: codeLanguage, lines: codeLines))
            codeLanguage = ""
            codeLines = []
        }

        while index < lines.count {
            let rawLine = lines[index]
            if let language = fenceLanguage(rawLine) {
                if inCodeBlock {
                    flushCodeBlock()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                    codeLanguage = language
                    codeLines = []
                }
                index += 1
                continue
            }

            if inCodeBlock {
                codeLines.append(rawLine)
                index += 1
                continue
            }

            result.append(renderPreviewLine(rawLine, bodyFont: bodyFont))
            index += 1
        }

        if inCodeBlock {
            // Unclosed fence — still show as code so authors see the raw content.
            flushCodeBlock()
        }

        if result.length == 0 {
            return NSAttributedString(
                string: String(localized: "reply.preview.empty"),
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: UIColor.placeholderText,
                    .paragraphStyle: paragraph,
                ]
            )
        }
        return result
    }

    /// Soft syntax chrome for the raw source editor (keeps full markdown text editable).
    static func styleSource(_ raw: String, baseAttributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let attributed = NSMutableAttributedString(string: raw, attributes: baseAttributes)
        guard !raw.isEmpty else { return attributed }

        let ns = raw as NSString
        let full = NSRange(location: 0, length: ns.length)
        let mono = ComposerTypography.codeFont
        let markerColor = UIColor.tertiaryLabel
        let codeFill = ComposerTypography.mutedFill

        // Fenced code blocks first so inline rules skip them less painfully.
        if let fenceRegex = try? NSRegularExpression(
            pattern: #"```([^\n`]*)\n([\s\S]*?)```"#,
            options: []
        ) {
            let matches = fenceRegex.matches(in: raw, range: full)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3 else { continue }
                let whole = match.range(at: 0)
                let lang = match.range(at: 1)
                let body = match.range(at: 2)
                attributed.addAttributes([
                    .font: mono,
                    .backgroundColor: codeFill,
                    .foregroundColor: UIColor.label,
                ], range: whole)
                if lang.length > 0 {
                    attributed.addAttributes([
                        .foregroundColor: UIColor.secondaryLabel,
                        .font: ComposerTypography.codeFont,
                    ], range: lang)
                }
                // Dim the opening/closing fences.
                let openLen = 3 + lang.length + (ns.substring(with: whole).contains("\n") ? 1 : 0)
                if openLen > 0, openLen < whole.length {
                    attributed.addAttribute(.foregroundColor, value: markerColor, range: NSRange(location: whole.location, length: min(openLen, whole.length)))
                }
                let closeStart = whole.location + whole.length - 3
                if closeStart >= whole.location {
                    attributed.addAttribute(
                        .foregroundColor,
                        value: markerColor,
                        range: NSRange(location: closeStart, length: 3)
                    )
                }
                _ = body
            }
        }

        applySourceInline(
            pattern: #"`([^`\n]+)`"#,
            in: attributed,
            attributes: [
                .font: mono,
                .backgroundColor: codeFill,
                .foregroundColor: UIColor.label,
            ],
            markerColor: markerColor,
            markerLength: 1
        )
        applySourceInline(
            pattern: #"\*\*([^*\n]+)\*\*"#,
            in: attributed,
            attributes: [
                .font: AppSettings.shared.contentFont(ofSize: bodyPointSize, weight: .bold),
            ],
            markerColor: markerColor,
            markerLength: 2
        )
        applySourceInline(
            pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            in: attributed,
            attributes: [
                .font: ComposerTypography.bodyFont.withItalicTrait(),
            ],
            markerColor: markerColor,
            markerLength: 1
        )
        applySourceInline(
            pattern: #"~~([^~\n]+)~~"#,
            in: attributed,
            attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ],
            markerColor: markerColor,
            markerLength: 2
        )

        // Heading markers at line start.
        if let headingRegex = try? NSRegularExpression(pattern: #"(?m)^(#{1,5})\s+"#, options: []) {
            for match in headingRegex.matches(in: attributed.string, range: NSRange(location: 0, length: attributed.length)) {
                attributed.addAttribute(.foregroundColor, value: markerColor, range: match.range(at: 1))
                let lineRange = (attributed.string as NSString).lineRange(for: match.range)
                let level = match.range(at: 1).length
                let size = ComposerTypography.headingFont(level: level).pointSize
                attributed.addAttribute(
                    .font,
                    value: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: .bold)),
                    range: lineRange
                )
            }
        }

        return attributed
    }

    // MARK: Preview helpers

    private static func renderPreviewLine(_ rawLine: String, bodyFont: UIFont) -> NSAttributedString {
        var line = rawLine
        var attributes: [NSAttributedString.Key: Any] = [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: baseParagraphStyle(lineSpacing: 5, paragraphSpacing: 10),
        ]

        if line.trimmingCharacters(in: .whitespaces) == "---"
            || line.trimmingCharacters(in: .whitespaces) == "***"
            || line.trimmingCharacters(in: .whitespaces) == "___" {
            let rule = NSMutableParagraphStyle()
            rule.paragraphSpacing = 14
            return NSAttributedString(
                string: "────────────\n",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: UIColor.tertiaryLabel,
                    .paragraphStyle: rule,
                ]
            )
        }

        if line.hasPrefix("###### ") {
            line.removeFirst(7)
            attributes[.font] = ComposerTypography.headingFont(level: 6)
        } else if line.hasPrefix("##### ") {
            line.removeFirst(6)
            attributes[.font] = ComposerTypography.headingFont(level: 5)
        } else if line.hasPrefix("#### ") {
            line.removeFirst(5)
            attributes[.font] = ComposerTypography.headingFont(level: 4)
        } else if line.hasPrefix("### ") {
            line.removeFirst(4)
            attributes[.font] = ComposerTypography.headingFont(level: 3)
        } else if line.hasPrefix("## ") {
            line.removeFirst(3)
            attributes[.font] = ComposerTypography.headingFont(level: 2)
        } else if line.hasPrefix("# ") {
            line.removeFirst(2)
            attributes[.font] = ComposerTypography.headingFont(level: 1)
        } else if line.hasPrefix("> ") {
            line.removeFirst(2)
            attributes[.foregroundColor] = UIColor.secondaryLabel
            let quote = baseParagraphStyle(lineSpacing: 4, paragraphSpacing: 8)
            quote.headIndent = 12
            quote.firstLineHeadIndent = 12
            attributes[.paragraphStyle] = quote
        } else if let match = line.range(of: #"^\s*([-*+])\s+"#, options: .regularExpression) {
            let bulletBody = String(line[match.upperBound...])
            line = "• " + bulletBody
            let list = baseParagraphStyle(lineSpacing: 4, paragraphSpacing: 6)
            list.headIndent = 18
            list.firstLineHeadIndent = 4
            attributes[.paragraphStyle] = list
        } else if let match = line.range(of: #"^\s*(\d+)\.\s+"#, options: .regularExpression) {
            // Keep original number prefix for ordered lists.
            let list = baseParagraphStyle(lineSpacing: 4, paragraphSpacing: 6)
            list.headIndent = 22
            list.firstLineHeadIndent = 4
            attributes[.paragraphStyle] = list
            _ = match
        }

        let inline = renderInline(line, attributes: attributes)
        let ending = NSMutableAttributedString(attributedString: inline)
        ending.append(NSAttributedString(string: "\n", attributes: attributes))
        return ending
    }

    private static func makeCodeBlock(language: String, lines: [String]) -> NSAttributedString {
        let mono = ComposerTypography.codeFont
        let headerFont = AppSettings.shared.contentMonospacedFont(ofSize: max(ComposerTypography.bodyFont.pointSize - 2, 10), weight: .semibold)
        let fill = ComposerTypography.mutedFill
        let block = NSMutableAttributedString()

        let headerStyle = baseParagraphStyle(lineSpacing: 2, paragraphSpacing: 2)
        let lang = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let headerText = (lang.isEmpty ? "TEXT" : lang).uppercased() + "\n"
        block.append(NSAttributedString(string: headerText, attributes: [
            .font: headerFont,
            .foregroundColor: UIColor.secondaryLabel,
            .backgroundColor: fill,
            .paragraphStyle: headerStyle,
        ]))

        let bodyStyle = baseParagraphStyle(lineSpacing: 3, paragraphSpacing: 0)
        bodyStyle.paragraphSpacingBefore = 0
        let body = (lines.isEmpty ? [""] : lines).joined(separator: "\n") + "\n\n"
        block.append(NSAttributedString(string: body, attributes: [
            .font: mono,
            .foregroundColor: UIColor.label,
            .backgroundColor: fill,
            .paragraphStyle: bodyStyle,
        ]))
        return block
    }

    private static func renderInline(_ line: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: line, attributes: attributes)
        // Order: code first so emphasis inside code is not restyled after markers stripped.
        applyPreviewInline(
            pattern: #"`([^`]+)`"#,
            in: attributed,
            transform: { content, _ in
                var attrs = attributes
                attrs[.font] = ComposerTypography.codeFont
                attrs[.backgroundColor] = ComposerTypography.mutedFill
                return NSAttributedString(string: content, attributes: attrs)
            }
        )
        applyPreviewInline(
            pattern: #"\*\*([^*\n]+)\*\*"#,
            in: attributed,
            transform: { content, base in
                var attrs = base
                let size = (base[.font] as? UIFont)?.pointSize ?? bodyPointSize
                attrs[.font] = AppSettings.shared.contentFont(ofSize: size, weight: .bold)
                return NSAttributedString(string: content, attributes: attrs)
            }
        )
        applyPreviewInline(
            pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            in: attributed,
            transform: { content, base in
                var attrs = base
                let font = (base[.font] as? UIFont) ?? ComposerTypography.bodyFont
                attrs[.font] = font.withItalicTrait()
                return NSAttributedString(string: content, attributes: attrs)
            }
        )
        applyPreviewInline(
            pattern: #"~~([^~\n]+)~~"#,
            in: attributed,
            transform: { content, base in
                var attrs = base
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                return NSAttributedString(string: content, attributes: attrs)
            }
        )
        applyPreviewInline(
            pattern: #"\[([^\]]+)\]\((https?://[^\s)]+)\)"#,
            in: attributed,
            transform: { content, base in
                // content here is only group 1; recover URL from original match via side channel below.
                return NSAttributedString(string: content, attributes: base)
            },
            linkAware: true
        )
        return attributed
    }

    private static func applyPreviewInline(
        pattern: String,
        in attributed: NSMutableAttributedString,
        transform: (_ content: String, _ base: [NSAttributedString.Key: Any]) -> NSAttributedString,
        linkAware: Bool = false
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: attributed.length)).reversed()
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let fullRange = match.range(at: 0)
            let contentRange = match.range(at: 1)
            guard fullRange.location != NSNotFound, contentRange.location != NSNotFound else { continue }

            var base: [NSAttributedString.Key: Any] = [:]
            if attributed.length > 0 {
                base = attributed.attributes(at: min(contentRange.location, attributed.length - 1), effectiveRange: nil)
            }
            let content = (attributed.string as NSString).substring(with: contentRange)
            let replacement = NSMutableAttributedString(attributedString: transform(content, base))
            if linkAware, match.numberOfRanges > 2 {
                let urlString = (attributed.string as NSString).substring(with: match.range(at: 2))
                if let url = URL(string: urlString) {
                    replacement.addAttribute(.link, value: url, range: NSRange(location: 0, length: replacement.length))
                    replacement.addAttribute(.foregroundColor, value: ComposerTypography.accentColor, range: NSRange(location: 0, length: replacement.length))
                }
            }
            attributed.replaceCharacters(in: fullRange, with: replacement)
        }
    }

    private static func applySourceInline(
        pattern: String,
        in attributed: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any],
        markerColor: UIColor,
        markerLength: Int
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let matches = regex.matches(in: attributed.string, range: NSRange(location: 0, length: attributed.length)).reversed()
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let full = match.range(at: 0)
            let content = match.range(at: 1)
            attributed.addAttributes(attributes, range: content)
            if markerLength > 0, full.length >= markerLength * 2 {
                attributed.addAttribute(
                    .foregroundColor,
                    value: markerColor,
                    range: NSRange(location: full.location, length: markerLength)
                )
                attributed.addAttribute(
                    .foregroundColor,
                    value: markerColor,
                    range: NSRange(location: full.location + full.length - markerLength, length: markerLength)
                )
            }
        }
    }

    /// - Returns: `nil` when the line is not a fence; otherwise the language tag (may be empty).
    private static func fenceLanguage(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func baseParagraphStyle(lineSpacing: CGFloat, paragraphSpacing: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.lineBreakMode = .byWordWrapping
        return style
    }
}

private extension UIFont {
    func withItalicTrait() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitItalic) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
