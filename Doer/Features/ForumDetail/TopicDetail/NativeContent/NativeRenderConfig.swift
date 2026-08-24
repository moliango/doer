import CookedHTML
import UIKit

struct NativeRenderConfig {
    let baseFont: UIFont
    let baseColor: UIColor
    let linkColor: UIColor
    let codeFont: UIFont
    let codeBackgroundColor: UIColor
    let contentWidth: CGFloat
    let baseURL: String?
    let postId: Int?
    let galleryImageURLs: [URL]
    let topicTagNames: Set<String>
    let topicCategoryPresentation: TopicCategoryBadgePresentation?
    let defaultLineSpacing: CGFloat
    let defaultParagraphSpacing: CGFloat
    let tocAnchorCounter: TocAnchorCounter
    init(
        baseFont: UIFont,
        baseColor: UIColor,
        linkColor: UIColor,
        codeFont: UIFont,
        codeBackgroundColor: UIColor,
        contentWidth: CGFloat,
        baseURL: String?,
        postId: Int? = nil,
        galleryImageURLs: [URL] = [],
        topicTagNames: Set<String> = [],
        topicCategoryPresentation: TopicCategoryBadgePresentation? = nil,
        defaultLineSpacing: CGFloat = 4,
        defaultParagraphSpacing: CGFloat = 5,
        tocAnchorCounter: TocAnchorCounter = TocAnchorCounter()
    ) {
        self.baseFont = baseFont
        self.baseColor = baseColor
        self.linkColor = linkColor
        self.codeFont = codeFont
        self.codeBackgroundColor = codeBackgroundColor
        self.contentWidth = contentWidth
        self.baseURL = baseURL
        self.postId = postId
        self.galleryImageURLs = galleryImageURLs
        self.topicTagNames = topicTagNames
        self.topicCategoryPresentation = topicCategoryPresentation
        self.defaultLineSpacing = defaultLineSpacing
        self.defaultParagraphSpacing = defaultParagraphSpacing
        self.tocAnchorCounter = tocAnchorCounter
    }

    var attributedStringConfig: AttributedStringConfig {
        AttributedStringConfig(
            baseFont: baseFont,
            baseColor: baseColor,
            linkColor: linkColor,
            codeFont: codeFont,
            // Inline ``code`` is often CJK; monospace does not change the glyphs.
            // Use a contrast fill so chips stay visible on white post backgrounds.
            // Code blocks keep `codeBackgroundColor` for their own chrome.
            codeBackgroundColor: Self.inlineCodeFill
        )
    }

    private static var inlineCodeFill: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.16)
                : UIColor.black.withAlphaComponent(0.10)
        }
    }

    static func `default`(
        contentWidth: CGFloat,
        baseURL: String? = nil,
        postId: Int? = nil,
        galleryImageURLs: [URL] = [],
        topicTagNames: Set<String> = [],
        topicCategoryPresentation: TopicCategoryBadgePresentation? = nil
    ) -> NativeRenderConfig {
        let settings = AppSettings.shared
        let comfortMode = settings.readingComfortMode
        let themeStyle = settings.themeStyle
        return NativeRenderConfig(
            baseFont: TopicDetailTypography.bodyContentFont(),
            baseColor: .label,
            linkColor: themeStyle.accentColor,
            codeFont: TopicDetailTypography.bodyCodeFont(),
            codeBackgroundColor: themeStyle.mutedContentBackgroundColor,
            contentWidth: contentWidth,
            baseURL: baseURL,
            postId: postId,
            galleryImageURLs: galleryImageURLs,
            topicTagNames: topicTagNames,
            topicCategoryPresentation: topicCategoryPresentation,
            defaultLineSpacing: comfortMode ? 3 : 2,
            defaultParagraphSpacing: comfortMode ? 5 : 3
        )
    }

    func styledAttributedString(
        from inlines: [InlineNode],
        lineSpacing: CGFloat? = nil,
        paragraphSpacing: CGFloat? = nil
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            result.append(attributedString(for: inline))
        }
        guard result.length > 0 else { return result }

        let lineSpacing = lineSpacing ?? defaultLineSpacing
        let paragraphSpacing = paragraphSpacing ?? defaultParagraphSpacing
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.paragraphSpacing = paragraphSpacing
        result.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(location: 0, length: result.length)
        )
        return TitleEmojiRenderer.replacingShortcodes(
            in: result,
            font: baseFont,
            baseURL: baseURL,
            skippingFont: codeFont
        )
    }

    private func attributedString(for inline: InlineNode) -> NSAttributedString {
        let taxonomy: (text: String, href: String, type: String?)?
        switch inline {
        case .hashtag(let text, let href, let type):
            taxonomy = (text, href, type)
        case .link(let href, let children):
            let linkedText = plainText(from: children).trimmingCharacters(in: .whitespacesAndNewlines)
            guard linkedText.hasPrefix("#"), linkedText.count > 1 else {
                return inline.attributedString(config: attributedStringConfig)
            }
            let text = String(linkedText.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            let path = URL(string: href)?.path.lowercased() ?? href.lowercased()
            let type = path.contains("/c/") ? "category" : (path.contains("/tag/") ? "tag" : nil)
            taxonomy = (text, href, type)
        default:
            taxonomy = nil
        }
        guard let taxonomy else {
            return inline.attributedString(config: attributedStringConfig)
        }
        let (text, href, type) = taxonomy

        if HeadingPresentationPolicy.shouldRenderTagBadge(
            level: 1,
            text: text,
            topicTagNames: topicTagNames
        ) {
            let tagPresentation = TopicTagIconCatalog.presentation(for: text)
            return inlineTaxonomyString(
                text: text,
                href: href,
                iconName: tagPresentation?.iconName,
                textColor: TopicTagVisualStyle.color(for: text),
                iconColor: tagPresentation
                    .flatMap { TopicTaxonomyColor.resolve(hex: $0.colorHex) }
                    ?? TopicTagVisualStyle.color(for: text)
            )
        }

        if type?.lowercased() == "category",
           let category = topicCategoryPresentation,
           HeadingPresentationPolicy.shouldRenderCategoryBadge(
               level: 1,
               text: text,
               categoryName: category.name
           ) {
            let iconName: String?
            switch category.iconSource {
            case .fontAwesome(let name): iconName = name
            case .lock: iconName = "lock"
            case .logo, .dot: iconName = nil
            }
            return inlineTaxonomyString(
                text: text,
                href: href,
                iconName: iconName,
                textColor: linkColor,
                iconColor: linkColor
            )
        }

        return inline.attributedString(config: attributedStringConfig)
    }

    private func plainText(from inlines: [InlineNode]) -> String {
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
            case .hashtag(let text, _, _):
                return "#\(text)"
            case .image(_, let alt, _, _, _):
                return alt ?? ""
            case .lineBreak:
                return "\n"
            }
        }.joined()
    }

    private func inlineTaxonomyString(
        text: String,
        href: String,
        iconName: String?,
        textColor: UIColor,
        iconColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        // Only emit FA PUA glyphs when the icon font actually loads.
        // Falling back to the body font turns private-use codepoints into
        // random CJK tofu that sits on top of the post body ("掩盖").
        if let iconName,
           let glyph = DiscourseFontAwesomeIcon.glyph(for: iconName),
           let iconFont = UIFont(
               name: DiscourseFontAwesomeIcon.fontName,
               size: max(baseFont.pointSize - 1, 1)
           ) {
            result.append(NSAttributedString(
                string: "\(glyph) ",
                attributes: [
                    .font: iconFont,
                    .foregroundColor: iconColor,
                ]
            ))
        }
        let linkedTextStart = result.length
        result.append(NSAttributedString(
            string: text,
            attributes: [
                .font: baseFont.weighted(.semibold),
                .foregroundColor: textColor,
            ]
        ))
        let linkValue: Any
        if let url = URL(string: href), url.scheme != nil {
            linkValue = url
        } else if let base = baseURL {
            linkValue = ForumInternalLinkParser.normalizedURL(
                from: URL(string: href) ?? URL(fileURLWithPath: href),
                baseURL: base
            )
        } else {
            linkValue = href
        }
        result.addAttribute(
            .link,
            value: linkValue,
            range: NSRange(location: linkedTextStart, length: result.length - linkedTextStart)
        )
        return result
    }
}

enum TopicDetailContentStyle {
    static var cardBackground: UIColor {
        AppSettings.shared.themeStyle.contentBackgroundColor
    }

    static var mutedBackground: UIColor {
        AppSettings.shared.themeStyle.mutedContentBackgroundColor
    }

    static var warmMutedBackground: UIColor {
        let style = AppSettings.shared.themeStyle
        if style != .systemDefault {
            return style.mutedContentBackgroundColor
        }
        return UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.tertiarySystemGroupedBackground
                : UIColor(red: 1.0, green: 0.98, blue: 0.94, alpha: 1)
        }
    }

    static func applySurface(
        to view: UIView,
        backgroundColor: UIColor? = nil,
        cornerRadius: CGFloat = 14,
        borderAlpha: CGFloat = 0.28
    ) {
        view.backgroundColor = backgroundColor ?? cardBackground
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1.0 / UIScreen.main.scale
        view.layer.borderColor = UIColor.separator.withAlphaComponent(borderAlpha).cgColor
    }

    static func headingAccentColor(for level: Int) -> UIColor {
        let style = AppSettings.shared.themeStyle
        guard style == .systemDefault else { return style.accentColor }
        switch level {
        case 1:
            return .systemBlue
        case 2:
            return .systemIndigo
        case 3:
            return .systemTeal
        default:
            return .secondaryLabel
        }
    }
}

// MARK: - BlockRenderer Protocol

protocol BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool
    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView
}

// MARK: - NativeContentRenderer

final class TocAnchorCounter {
    private var counts: [String: Int] = [:]

    func nextId(postId: Int, text: String) -> String {
        TocExtractor.makeAnchorId(postId: postId, text: text, counts: &counts)
    }
}

enum NativeContentRenderer {
    private static var tocAnchorCounter: TocAnchorCounter?

    static var currentTocAnchorCounter: TocAnchorCounter? { tocAnchorCounter }

    static let renderers: [BlockRenderer.Type] = [
        ParagraphRenderer.self,
        HeadingRenderer.self,
        DividerRenderer.self,
        PollRenderer.self,
        ListRenderer.self,
        BlockquoteRenderer.self,
        ImageRenderer.self,
        ImageGridRenderer.self,
        CodeBlockRenderer.self,
        DiscourseQuoteRenderer.self,
        DetailsRenderer.self,
        SpoilerRenderer.self,
        OneboxRenderer.self,
        VideoRenderer.self,
        TableRenderer.self,
    ]

    static func canRenderNatively(_ blocks: [ContentBlock]) -> Bool {
        blocks.allSatisfy { block in
            renderers.contains { $0.canRender(block) }
        }
    }

    static func renderBlocks(
        _ blocks: [ContentBlock],
        config: NativeRenderConfig,
        delegate: PostCellDelegate?,
        promoteCallouts: Bool = true
    ) -> [UIView] {
        withTocAnchorCounter(config) {
            // Promote top-level `[!question]` / `[!warning]` paragraphs into callout cards.
            // Nested renderers pass promoteCallouts=false to avoid bq→promote→bq recursion.
            let source = ImageGridPresentation.preparedBlocks(blocks)
            let prepared = promoteCallouts
                ? ObsidianCalloutSupport.promoteCalloutMarkers(in: source)
                : source
            return prepared.compactMap { block in
                for renderer in renderers where renderer.canRender(block) {
                    return renderer.render(block, config: config, delegate: delegate)
                }
                return nil
            }
        }
    }

    static func renderBlocks(
        _ annotatedBlocks: [AnnotatedBlock],
        config: NativeRenderConfig,
        delegate: PostCellDelegate?
    ) -> [UIView] {
        withTocAnchorCounter(config) {
            let prepared = annotatedBlocks.flatMap { annotated in
                ImageGridPresentation.preparedBlocks([annotated.block]).map {
                    AnnotatedBlock(block: $0, sourceHTML: annotated.sourceHTML)
                }
            }
            return prepared.compactMap { annotated in
                for renderer in renderers where renderer.canRender(annotated.block) {
                    return renderer.render(annotated.block, config: config, delegate: delegate)
                }
                return FallbackBlockView(
                    html: annotated.sourceHTML,
                    containerWidth: config.contentWidth,
                    baseURL: config.baseURL ?? ""
                )
            }
        }
    }

    private static func withTocAnchorCounter<T>(
        _ config: NativeRenderConfig,
        _ body: () -> T
    ) -> T {
        let isRoot = tocAnchorCounter == nil
        if isRoot { tocAnchorCounter = config.tocAnchorCounter }
        defer { if isRoot { tocAnchorCounter = nil } }
        return body()
    }
}

enum PollRenderer: BlockRenderer {
    static func canRender(_ block: ContentBlock) -> Bool {
        if case .poll = block { return true }
        return false
    }

    static func render(_ block: ContentBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) -> UIView {
        guard case .poll(let poll) = block else { return UIView() }
        return PollBlockView(poll: poll, config: config, delegate: delegate)
    }
}

private final class PollBlockView: UIView {
    private let poll: PollBlock
    private let config: NativeRenderConfig
    private weak var delegate: PostCellDelegate?
    private var selectedOptionIds: Set<String>
    private var optionControls: [PollOptionControl] = []
    private weak var submitButton: UIButton?
    private weak var resultsToggleButton: UIButton?
    private weak var pieChartView: UIView?
    private var isSubmitting = false
    private let hasCastVote: Bool
    private var showsResults: Bool

    private var isOpen: Bool {
        let status = poll.status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return status == nil || status == "open"
    }

    private var minSelections: Int {
        max(1, poll.minSelections ?? 1)
    }

    private var maxSelections: Int {
        max(minSelections, poll.maxSelections ?? 1)
    }

    private var canSubmitVote: Bool {
        isOpen && config.postId != nil && poll.name != nil && poll.options.contains { $0.id != nil }
    }

    private var canToggleResults: Bool {
        PollResultsPolicy.canToggleResults(
            resultsMode: poll.resultsMode,
            status: poll.status,
            hasVoted: hasCastVote
        )
    }

    init(poll: PollBlock, config: NativeRenderConfig, delegate: PostCellDelegate?) {
        self.poll = poll
        self.config = config
        self.delegate = delegate
        self.selectedOptionIds = Set(poll.options.compactMap { option in
            option.isSelected ? option.id : nil
        })
        self.hasCastVote = poll.options.contains(where: \.isSelected)
        self.showsResults = PollResultsPolicy.shouldShowResults(
            resultsMode: poll.resultsMode,
            status: poll.status,
            hasVoted: hasCastVote
        )
        super.init(frame: .zero)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        TopicDetailContentStyle.applySurface(
            to: self,
            backgroundColor: TopicDetailContentStyle.mutedBackground,
            cornerRadius: 16,
            borderAlpha: 0.2
        )

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        stack.addArrangedSubview(makeHeader())
        if let pie = makePieChartIfNeeded() {
            pie.isHidden = !showsResults
            pieChartView = pie
            stack.addArrangedSubview(pie)
        }
        for option in poll.options {
            let control = PollOptionControl(option: option, config: config)
            control.addTarget(self, action: #selector(optionTapped(_:)), for: .touchUpInside)
            optionControls.append(control)
            stack.addArrangedSubview(control)
        }
        if let votersText = votersDisplayText() {
            stack.addArrangedSubview(makeVotersLabel(votersText))
        }
        if canToggleResults {
            let toggle = makeResultsToggleButton()
            resultsToggleButton = toggle
            stack.addArrangedSubview(toggle)
        }
        if canSubmitVote {
            let button = makeSubmitButton()
            submitButton = button
            stack.addArrangedSubview(button)
        }
        updateOptionStates()

        accessibilityLabel = [String(localized: "post.poll"), votersDisplayText()]
            .compactMap { $0 }
            .joined(separator: "，")
    }

    private func makeHeader() -> UIView {
        let accentColor = AppSettings.shared.themeStyle.accentColor

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: "chart.bar.fill"))
        iconView.tintColor = accentColor
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = String(localized: "post.poll")
        titleLabel.font = config.baseFont.weighted(.semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = UILabel()
        statusLabel.text = headerStatusText()
        statusLabel.font = config.baseFont.withRelativeSize(-1).weighted(.semibold)
        statusLabel.textColor = accentColor
        statusLabel.textAlignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(titleLabel)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconView.topAnchor.constraint(equalTo: container.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            statusLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makeVotersLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = config.baseFont.withRelativeSize(-1).weighted(.medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// FluxDo-aligned pie when results are visible (closed poll or options already have %).
    private func makePieChartIfNeeded() -> UIView? {
        let slices: [(CGFloat, UIColor)] = poll.options.enumerated().compactMap { index, option in
            let fraction: CGFloat
            if let percentageText = option.percentageText {
                let allowed = CharacterSet(charactersIn: "0123456789.")
                let number = String(percentageText.unicodeScalars.filter { allowed.contains($0) })
                guard let value = Double(number), value > 0 else { return nil }
                fraction = CGFloat(min(max(value / 100, 0), 1))
            } else if let votes = option.voteCount, votes > 0 {
                let total = max(poll.options.compactMap(\.voteCount).reduce(0, +), 1)
                fraction = CGFloat(votes) / CGFloat(total)
            } else {
                return nil
            }
            guard fraction > 0 else { return nil }
            let hue = CGFloat((index * 47) % 360) / 360
            return (fraction, UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1))
        }
        guard slices.count >= 2, slices.map(\.0).reduce(0, +) > 0.01 else { return nil }

        let chart = PollPieChartView(slices: slices)
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 120).isActive = true
        return chart
    }

    private func makeSubmitButton() -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = selectedOptionIds.isEmpty ? String(localized: "post.poll.submit") : String(localized: "post.poll.update")
        configuration.baseBackgroundColor = AppSettings.shared.themeStyle.accentColor
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = TopicDetailTypography.interfaceFont(ofSize: 14, weight: .semibold)
        button.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func makeResultsToggleButton() -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = resultsToggleTitle
        configuration.baseForegroundColor = AppSettings.shared.themeStyle.accentColor
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = TopicDetailTypography.interfaceFont(ofSize: 14, weight: .medium)
        button.addTarget(self, action: #selector(resultsToggleTapped), for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private var resultsToggleTitle: String {
        showsResults ? String(localized: "post.poll.vote") : String(localized: "post.poll.view_results")
    }

    private func headerStatusText() -> String? {
        if isOpen {
            return votersDisplayText()
        }
        return String(localized: "post.poll.closed")
    }

    private func votersDisplayText() -> String? {
        if let count = poll.votersCount {
            return String(format: String(localized: "post.poll.voters_count"), count)
        }
        return poll.votersText
    }

    private func updateOptionStates() {
        let accentColor = AppSettings.shared.themeStyle.accentColor
        pieChartView?.isHidden = !showsResults
        for control in optionControls {
            let optionId = control.option.id
            let isSelected = optionId.map { selectedOptionIds.contains($0) } ?? false
            control.apply(
                isSelected: isSelected,
                canVote: canSubmitVote && !isSubmitting,
                accentColor: accentColor,
                showsResults: showsResults
            )
        }

        if var toggleConfiguration = resultsToggleButton?.configuration {
            toggleConfiguration.title = resultsToggleTitle
            resultsToggleButton?.configuration = toggleConfiguration
        }

        guard var configuration = submitButton?.configuration else { return }
        configuration.title = selectedOptionIds.isEmpty ? String(localized: "post.poll.submit") : String(localized: "post.poll.update")
        submitButton?.configuration = configuration
        submitButton?.isEnabled = canSubmitVote && !isSubmitting && selectedOptionIds.count >= minSelections
    }

    @objc private func resultsToggleTapped() {
        showsResults.toggle()
        updateOptionStates()
    }

    @objc private func optionTapped(_ sender: UIControl) {
        guard canSubmitVote,
              !isSubmitting,
              let control = sender as? PollOptionControl,
              let optionId = control.option.id
        else { return }

        if selectedOptionIds.contains(optionId) {
            if maxSelections > 1 {
                selectedOptionIds.remove(optionId)
            }
        } else if maxSelections <= 1 {
            selectedOptionIds = [optionId]
        } else if selectedOptionIds.count < maxSelections {
            selectedOptionIds.insert(optionId)
        }
        updateOptionStates()
    }

    @objc private func submitTapped() {
        guard canSubmitVote,
              !isSubmitting,
              selectedOptionIds.count >= minSelections,
              let postId = config.postId,
              let pollName = poll.name
        else { return }

        isSubmitting = true
        updateOptionStates()
        let optionIds = poll.options.compactMap { option -> String? in
            guard let id = option.id, selectedOptionIds.contains(id) else { return nil }
            return id
        }
        delegate?.postCell(didSubmitPollVoteForPostId: postId, pollName: pollName, optionIds: optionIds)
    }
}

private final class PollOptionControl: UIControl {
    let option: PollOption

    private let indicatorView = UIImageView()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.72 : 1
        }
    }

    init(option: PollOption, config: NativeRenderConfig) {
        self.option = option
        super.init(frame: .zero)
        setupUI(config: config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(isSelected: Bool, canVote: Bool, accentColor: UIColor, showsResults: Bool) {
        isEnabled = canVote && option.id != nil
        backgroundColor = isSelected ? accentColor.withAlphaComponent(0.12) : TopicDetailContentStyle.cardBackground
        layer.borderColor = (isSelected ? accentColor : UIColor.separator.withAlphaComponent(0.18)).cgColor
        indicatorView.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
        indicatorView.tintColor = isSelected ? accentColor : .tertiaryLabel
        progressView.progressTintColor = accentColor.withAlphaComponent(isSelected ? 0.7 : 0.45)

        let meta = showsResults ? metaText() : nil
        metaLabel.text = meta
        metaLabel.isHidden = meta == nil
        let progress = showsResults ? progressValue() : nil
        progressView.isHidden = progress == nil
        if let progress {
            progressView.setProgress(progress, animated: false)
        }

        var traits: UIAccessibilityTraits = isEnabled ? [.button] : [.staticText]
        if isSelected {
            traits.insert(.selected)
        }
        accessibilityTraits = traits
        accessibilityLabel = [option.text, meta].compactMap { $0 }.joined(separator: "，")
    }

    private func setupUI(config: NativeRenderConfig) {
        backgroundColor = TopicDetailContentStyle.cardBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.0 / UIScreen.main.scale
        layer.borderColor = UIColor.separator.withAlphaComponent(0.18).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true

        indicatorView.image = UIImage(systemName: "circle")
        indicatorView.tintColor = .tertiaryLabel
        indicatorView.contentMode = .scaleAspectFit
        indicatorView.translatesAutoresizingMaskIntoConstraints = false

        TitleEmojiRenderer.apply(
            option.text,
            to: titleLabel,
            font: config.baseFont,
            textColor: config.baseColor,
            baseURL: config.baseURL
        )
        titleLabel.numberOfLines = 0

        metaLabel.text = nil
        metaLabel.font = config.baseFont.withRelativeSize(-1).weighted(.medium)
        metaLabel.textColor = .secondaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.isHidden = true

        progressView.trackTintColor = UIColor.separator.withAlphaComponent(0.16)
        progressView.layer.cornerRadius = 2
        progressView.clipsToBounds = true
        progressView.isHidden = true
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let textStack = UIStackView(arrangedSubviews: [titleLabel, metaLabel, progressView])
        textStack.axis = .vertical
        textStack.spacing = 5
        textStack.alignment = .fill
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(indicatorView)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),

            indicatorView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            indicatorView.centerYAnchor.constraint(equalTo: centerYAnchor),
            indicatorView.widthAnchor.constraint(equalToConstant: 18),
            indicatorView.heightAnchor.constraint(equalToConstant: 18),

            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: indicatorView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    private func metaText() -> String? {
        var pieces: [String] = []
        if let percentageText = option.percentageText {
            pieces.append(percentageText)
        }
        if let voteCount = option.voteCount {
            pieces.append(String(format: String(localized: "post.poll.vote_count"), voteCount))
        }
        guard !pieces.isEmpty else { return nil }
        return pieces.joined(separator: " · ")
    }

    private func progressValue() -> Float? {
        guard let percentageText = option.percentageText else { return nil }
        let allowed = CharacterSet(charactersIn: "0123456789.")
        let number = String(percentageText.unicodeScalars.filter { allowed.contains($0) })
        guard let value = Float(number) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

private final class PollPieChartView: UIView {
    private let slices: [(CGFloat, UIColor)]

    init(slices: [(CGFloat, UIColor)]) {
        self.slices = slices
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "post.poll.pie", defaultValue: "投票饼图")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let total = max(slices.map(\.0).reduce(0, +), 0.0001)
        let side = min(rect.width, rect.height) - 8
        let box = CGRect(
            x: (rect.width - side) / 2,
            y: (rect.height - side) / 2,
            width: side,
            height: side
        )
        var start = -CGFloat.pi / 2
        for (fraction, color) in slices {
            let angle = CGFloat.pi * 2 * (fraction / total)
            context.setFillColor(color.cgColor)
            context.move(to: CGPoint(x: box.midX, y: box.midY))
            context.addArc(
                center: CGPoint(x: box.midX, y: box.midY),
                radius: side / 2,
                startAngle: start,
                endAngle: start + angle,
                clockwise: false
            )
            context.closePath()
            context.fillPath()
            start += angle
        }
        // Donut hole for a lighter look.
        let hole = side * 0.42
        context.setFillColor(UIColor.systemBackground.cgColor)
        context.fillEllipse(in: CGRect(
            x: box.midX - hole / 2,
            y: box.midY - hole / 2,
            width: hole,
            height: hole
        ))
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
