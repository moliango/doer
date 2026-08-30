import UIKit

/// FluxDo `CompactTopicCard`: pinned topics render as a single compact row
/// (pin + category mark + title + unread/reply), not a full topic card.
final class CompactPinnedTopicCell: UITableViewCell {
    static let reuseIdentifier = "CompactPinnedTopicCell"
    /// Inner row: 6pt padding + 22pt badge + 6pt padding.
    static let innerContentHeight: CGFloat = 34
    static let estimatedHeight: CGFloat = 42

    static func rowHeight(for theme: AppSettings.ThemeStyle) -> CGFloat {
        let outerInset: CGFloat = theme.usesChatHomeList ? 0 : 4
        return outerInset * 2 + innerContentHeight
    }

    static var currentRowHeight: CGFloat {
        rowHeight(for: AppSettings.shared.themeStyle)
    }

    private let cardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()

    private let pinView: UIImageView = {
        let configuration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let view = UIImageView(image: UIImage(systemName: "pin.fill", withConfiguration: configuration))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    private let categoryHost: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let countBadge: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        return view
    }()

    private let accessoryIcon: UIImageView = {
        let icon = UIImageView(
            image: UIImage(
                systemName: "bubble.left.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            )
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        return icon
    }()

    private let accessoryLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let rowStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        return stack
    }()

    private var cardTop: NSLayoutConstraint!
    private var cardLeading: NSLayoutConstraint!
    private var cardTrailing: NSLayoutConstraint!
    private var cardBottom: NSLayoutConstraint!
    private var accessoryWidth: NSLayoutConstraint!

    private var emojiBaseURL: String?
    private var renderedTitle: String?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        let accessoryStack = UIStackView(arrangedSubviews: [accessoryIcon, accessoryLabel])
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.axis = .horizontal
        accessoryStack.alignment = .center
        accessoryStack.spacing = 4
        accessoryStack.isLayoutMarginsRelativeArrangement = true
        accessoryStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)

        countBadge.addSubview(accessoryStack)
        rowStack.addArrangedSubview(pinView)
        rowStack.addArrangedSubview(categoryHost)
        rowStack.addArrangedSubview(titleLabel)
        rowStack.addArrangedSubview(countBadge)

        contentView.addSubview(cardView)
        cardView.addSubview(rowStack)

        // Start with the standard card geometry so the first layout pass cannot
        // briefly render a full-width pinned row before configure() runs.
        cardTop = cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)
        cardLeading = cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        cardTrailing = cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        cardBottom = cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
        accessoryWidth = countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 32)

        rowStack.setContentHuggingPriority(.required, for: .vertical)
        rowStack.setContentCompressionResistancePriority(.required, for: .vertical)
        cardView.setContentHuggingPriority(.required, for: .vertical)
        cardView.setContentCompressionResistancePriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            cardTop, cardLeading, cardTrailing, cardBottom,
            cardView.heightAnchor.constraint(equalToConstant: Self.innerContentHeight),

            rowStack.topAnchor.constraint(equalTo: cardView.topAnchor),
            rowStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            rowStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            pinView.widthAnchor.constraint(equalToConstant: 14),
            pinView.heightAnchor.constraint(equalToConstant: 14),

            categoryHost.widthAnchor.constraint(equalToConstant: 12),
            categoryHost.heightAnchor.constraint(equalToConstant: 12),

            countBadge.heightAnchor.constraint(equalToConstant: 22),
            accessoryWidth,

            accessoryIcon.widthAnchor.constraint(equalToConstant: 12),
            accessoryIcon.heightAnchor.constraint(equalToConstant: 12),

            accessoryStack.topAnchor.constraint(equalTo: countBadge.topAnchor),
            accessoryStack.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor),
            accessoryStack.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor),
            accessoryStack.bottomAnchor.constraint(equalTo: countBadge.bottomAnchor),
        ])
    }

    func configure(
        with topic: DiscourseTopicList.Topic,
        categoryColor: UIColor?,
        categoryPresentation: TopicCategoryBadgePresentation?,
        categoryBaseURL: String?
    ) {
        let theme = AppSettings.shared.themeStyle
        applyCardChrome(theme: theme)
        pinView.tintColor = theme.accentColor

        let unread = topic.isUnreadForDisplay
        titleLabel.textColor = unread ? .label : .secondaryLabel
        titleLabel.font = .systemFont(ofSize: 13, weight: unread ? .medium : .regular)
        emojiBaseURL = categoryBaseURL
        renderedTitle = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
        TitleEmojiRenderer.apply(
            renderedTitle ?? topic.title,
            to: titleLabel,
            font: titleLabel.font,
            textColor: titleLabel.textColor,
            baseURL: categoryBaseURL
        )

        installCategoryMark(
            color: TopicTagVisualStyle.categoryColor(
                for: categoryPresentation?.name,
                fallback: categoryColor
            ),
            presentation: categoryPresentation,
            baseURL: categoryBaseURL
        )

        let unreadCount = topic.unreadPosts
        let replies = max(topic.postsCount - 1, 0)
        if unreadCount > 0 {
            countBadge.isHidden = false
            accessoryIcon.isHidden = true
            accessoryLabel.text = unreadCount > 99 ? "99+" : "\(unreadCount)"
            accessoryLabel.textColor = theme.accentColor
            countBadge.backgroundColor = theme.accentColor.withAlphaComponent(0.16)
            countBadge.layer.cornerRadius = 11
            accessoryWidth.constant = unreadCount > 99 ? 44 : (unreadCount > 9 ? 36 : 32)
        } else if replies > 0 {
            countBadge.isHidden = false
            accessoryIcon.isHidden = false
            accessoryIcon.tintColor = theme.topicCountForegroundColor
            accessoryLabel.text = "\(min(replies, 9_999))"
            accessoryLabel.textColor = theme.topicCountForegroundColor
            countBadge.backgroundColor = theme.topicCountBackgroundColor
            countBadge.layer.cornerRadius = max(theme.chromeCornerRadius - 1, 8)
            accessoryWidth.constant = Self.replyBadgeWidth(for: replies)
        } else {
            countBadge.isHidden = true
            accessoryLabel.text = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedTitle = nil
        emojiBaseURL = nil
        titleLabel.text = nil
        titleLabel.attributedText = nil
        accessoryLabel.text = nil
        countBadge.isHidden = false
        accessoryIcon.isHidden = false
        applyCardChrome(theme: AppSettings.shared.themeStyle)
        accessoryWidth.constant = 32
        categoryHost.subviews.forEach { $0.removeFromSuperview() }
        cardView.transform = .identity
        cardView.alpha = 1
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        AnimationOptimizer.animateCardPress(cardView, pressed: highlighted)
    }

    private func applyCardChrome(theme: AppSettings.ThemeStyle) {
        let fullBleed = theme.usesChatHomeList
        cardTop.constant = fullBleed ? 0 : 4
        cardLeading.constant = fullBleed ? 0 : 16
        cardTrailing.constant = fullBleed ? 0 : -16
        cardBottom.constant = fullBleed ? 0 : -4
        cardView.layer.cornerRadius = fullBleed ? 0 : theme.chromeCornerRadius
        cardView.backgroundColor = fullBleed
            ? theme.topicCardBackgroundColor.withAlphaComponent(0.72)
            : theme.topicCardBackgroundColor
        rowStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 6,
            leading: fullBleed ? 16 : 12,
            bottom: 6,
            trailing: fullBleed ? 16 : 12
        )
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        CGSize(width: targetSize.width, height: Self.currentRowHeight)
    }

    private static func replyBadgeWidth(for replies: Int) -> CGFloat {
        switch "\(min(replies, 9_999))".count {
        case 0, 1: return 38
        case 2: return 46
        case 3: return 54
        default: return 62
        }
    }

    private func installCategoryMark(
        color: UIColor,
        presentation: TopicCategoryBadgePresentation?,
        baseURL: String?
    ) {
        categoryHost.subviews.forEach { $0.removeFromSuperview() }
        let mark = makeCategoryMark(color: color, presentation: presentation, baseURL: baseURL)
        mark.translatesAutoresizingMaskIntoConstraints = false
        categoryHost.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: categoryHost.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: categoryHost.centerYAnchor),
        ])
    }

    private func makeCategoryMark(
        color: UIColor,
        presentation: TopicCategoryBadgePresentation?,
        baseURL: String?
    ) -> UIView {
        switch presentation?.iconSource {
        case .fontAwesome(let name):
            let label = UILabel()
            label.text = DiscourseFontAwesomeIcon.glyph(for: name)
            label.font = UIFont(name: DiscourseFontAwesomeIcon.fontName, size: 12)
                ?? .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = color
            label.textAlignment = .center
            return label
        case .logo(let rawURL):
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            ForumImageLoader.setImage(
                on: imageView,
                url: Self.resolveURL(rawURL, baseURL: baseURL ?? ""),
                placeholder: UIImage(systemName: "circle.fill"),
                cloudflareBaseURL: baseURL
            )
            imageView.widthAnchor.constraint(equalToConstant: 12).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 12).isActive = true
            return imageView
        case .lock:
            let imageView = UIImageView(
                image: UIImage(systemName: "lock.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            )
            imageView.tintColor = color
            return imageView
        case .dot, .none:
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = 3
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            return dot
        }
    }

    private static func resolveURL(_ rawURL: String, baseURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }
        guard let base = URL(string: baseURL) else { return URL(string: trimmed) }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }
}

extension CompactPinnedTopicCell: TopicPreviewTargetProviding {
    var topicPreviewTargetView: UIView { cardView }
}
