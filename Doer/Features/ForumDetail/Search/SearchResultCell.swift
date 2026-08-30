import SDWebImage
import UIKit

/// Search card mirrors Home `TopicCell` geometry and badge chrome, with one extra blurb line.
final class SearchResultCell: UITableViewCell, TopicPreviewTargetProviding {
    static let reuseIdentifier = "SearchResultCell"

    private var currentAvatarURL: URL?

    private enum Metrics {
        static let titleFontSize = AppSettings.topicTitleReferencePointSize
        static let titleMaxLines = 3
        static let titleTopPadding: CGFloat = 9
        static let titleToBlurb: CGFloat = 5
        static let blurbToBadge: CGFloat = 7
        static let badgeBottom: CGFloat = 8
    }

    private let cardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 17
        iv.backgroundColor = .secondarySystemFill
        return iv
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = Metrics.titleMaxLines
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let replyBadge = SearchCountBadgeView()
    private let floorBadge = SearchPillBadgeView()
    private let aiIcon: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = .systemPurple
        view.contentMode = .scaleAspectFit
        view.isHidden = true
        return view
    }()

    private let blurbLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 2
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let badgesStackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private lazy var titleTrailingStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [aiIcon, floorBadge])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        return stack
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        replyBadge.translatesAutoresizingMaskIntoConstraints = false
        floorBadge.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(cardView)
        cardView.addSubview(avatarImageView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(titleTrailingStack)
        cardView.addSubview(replyBadge)
        cardView.addSubview(blurbLabel)
        cardView.addSubview(badgesStackView)
        cardView.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            avatarImageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            avatarImageView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 13),
            avatarImageView.widthAnchor.constraint(equalToConstant: 36),
            avatarImageView.heightAnchor.constraint(equalToConstant: 36),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: Metrics.titleTopPadding),
            titleLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: titleTrailingStack.leadingAnchor, constant: -10),

            titleTrailingStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 7),
            titleTrailingStack.trailingAnchor.constraint(equalTo: replyBadge.leadingAnchor, constant: -6),
            titleTrailingStack.heightAnchor.constraint(equalToConstant: 22),

            replyBadge.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 7),
            replyBadge.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            aiIcon.widthAnchor.constraint(equalToConstant: 14),
            aiIcon.heightAnchor.constraint(equalToConstant: 14),
            replyBadge.heightAnchor.constraint(equalToConstant: 22),
            floorBadge.heightAnchor.constraint(equalToConstant: 22),

            blurbLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.titleToBlurb),
            blurbLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            blurbLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),

            badgesStackView.topAnchor.constraint(equalTo: blurbLabel.bottomAnchor, constant: Metrics.blurbToBadge),
            badgesStackView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgesStackView.heightAnchor.constraint(equalToConstant: 18),
            badgesStackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Metrics.badgeBottom),

            timeLabel.centerYAnchor.constraint(equalTo: badgesStackView.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: badgesStackView.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with post: DiscourseSearchResult.SearchPost,
        topic: DiscourseSearchResult.SearchTopic? = nil,
        baseURL: String,
        categoryName: String? = nil,
        categoryColor: UIColor? = nil,
        isAIResult: Bool = false
    ) {
        let theme = AppSettings.shared.themeStyle
        cardView.backgroundColor = theme.topicCardBackgroundColor

        let rawTitle = post.topicTitleHeadline?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSource: String = {
            if let rawTitle, !rawTitle.isEmpty { return rawTitle }
            if let fancy = topic?.fancyTitle, !fancy.isEmpty { return fancy }
            if let title = topic?.title, !title.isEmpty { return title }
            return String(localized: "search.untitled", defaultValue: "无标题")
        }()
        let titleFont = UIFont.systemFont(ofSize: Metrics.titleFontSize, weight: .semibold)
        titleLabel.font = titleFont
        titleLabel.textColor = .label

        // FluxDo parity: prefer `topic_title_headline` HTML and keep search-highlight spans.
        if let rawTitle, !rawTitle.isEmpty {
            titleLabel.attributedText = CookedContentPipeline.highlightedPreview(
                fromCooked: rawTitle,
                baseURL: baseURL,
                font: titleFont,
                textColor: .label
            )
        } else {
            let plain = CookedContentPipeline.plainTextPreview(fromCooked: titleSource, baseURL: baseURL)
            TitleEmojiRenderer.apply(
                plain.isEmpty ? titleSource : plain,
                to: titleLabel,
                font: titleFont,
                textColor: .label,
                baseURL: baseURL
            )
        }

        let replies = max((topic?.postsCount ?? 1) - 1, 0)
        replyBadge.configure(count: replies)

        if post.postNumber > 1 {
            floorBadge.isHidden = false
            floorBadge.configure(text: "#\(post.postNumber)")
        } else {
            floorBadge.isHidden = true
        }
        aiIcon.isHidden = !isAIResult

        // Blurb also carries Discourse search-highlight markup (FluxDo `_buildBlurb`).
        let rawBlurb = post.blurb ?? ""
        if rawBlurb.contains("<") {
            let blurbFont = UIFont.systemFont(ofSize: 13, weight: .regular)
            blurbLabel.attributedText = CookedContentPipeline.highlightedPreview(
                fromCooked: rawBlurb,
                baseURL: baseURL,
                font: blurbFont,
                textColor: .secondaryLabel
            )
            blurbLabel.isHidden = blurbLabel.attributedText?.length == 0
        } else {
            let blurb = CookedContentPipeline.plainTextPreview(fromCooked: rawBlurb, baseURL: baseURL)
            blurbLabel.attributedText = nil
            blurbLabel.text = blurb
            blurbLabel.isHidden = blurb.isEmpty
        }

        badgesStackView.arrangedSubviews.forEach {
            badgesStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if !post.username.isEmpty {
            let user = UILabel()
            user.font = .systemFont(ofSize: 12, weight: .medium)
            user.textColor = .secondaryLabel
            user.text = post.username
            badgesStackView.addArrangedSubview(user)
        }
        if let categoryName, !categoryName.isEmpty, AppSettings.shared.showTopicCardCategory {
            badgesStackView.addArrangedSubview(
                SearchMetaChipView(
                    text: categoryName,
                    style: .category(color: TopicTagVisualStyle.categoryColor(for: categoryName, fallback: categoryColor))
                )
            )
        }
        if AppSettings.shared.showTopicCardTags {
            for tag in (topic?.tags ?? []).prefix(3) {
                badgesStackView.addArrangedSubview(
                    SearchMetaChipView(
                        text: tag.hasPrefix("#") ? tag : "#\(tag)",
                        style: .tag(color: TopicTagVisualStyle.color(for: tag))
                    )
                )
            }
        }

        timeLabel.text = TopicCell.formatDate(post.createdAt ?? "")

        let avatarURL = post.avatarTemplate.flatMap {
            AvatarImageLoader.url(from: $0, baseURL: baseURL, size: 72)
        }
        if currentAvatarURL != avatarURL || avatarImageView.image == nil {
            currentAvatarURL = avatarURL
            AvatarImageLoader.setImage(on: avatarImageView, url: avatarURL)
        }
    }

    var topicPreviewTargetView: UIView { cardView }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        titleLabel.attributedText = nil
        blurbLabel.text = nil
        blurbLabel.attributedText = nil
        timeLabel.text = nil
        floorBadge.isHidden = true
        aiIcon.isHidden = true
        replyBadge.prepareForReuse()
        currentAvatarURL = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        badgesStackView.arrangedSubviews.forEach {
            badgesStackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

}

// MARK: - Badges (UIView-backed so continuous corner radius actually clips)

private final class SearchCountBadgeView: UIView {
    private static let hotThreshold = 50
    private var widthConstraint: NSLayoutConstraint?

    private let iconView: UIImageView = {
        let image = UIImage(systemName: "bubble.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        let view = UIImageView(image: image)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.contentMode = .scaleAspectFit
        return view
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .right
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        return label
    }()

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 8)
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true

        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(countLabel)
        addSubview(stackView)

        widthConstraint = widthAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        widthConstraint?.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(count: Int) {
        let text = "\(min(count, 9_999))"
        countLabel.text = text
        widthConstraint?.constant = width(for: text)
        let theme = AppSettings.shared.themeStyle
        let hot = count >= Self.hotThreshold
        let fg = hot ? theme.hotTopicColor : theme.topicCountForegroundColor
        iconView.tintColor = fg
        countLabel.textColor = fg
        backgroundColor = hot ? theme.hotTopicColor.withAlphaComponent(0.14) : theme.topicCountBackgroundColor
    }

    func prepareForReuse() {
        countLabel.text = nil
        widthConstraint?.constant = 38
    }

    private func width(for text: String) -> CGFloat {
        switch text.count {
        case 0, 1: return 38
        case 2: return 46
        case 3: return 54
        default: return 62
        }
    }
}

private final class SearchPillBadgeView: UIView {
    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text: String) {
        label.text = text
        let theme = AppSettings.shared.themeStyle
        label.textColor = theme.topicCountForegroundColor
        backgroundColor = theme.topicCountBackgroundColor
    }
}

private final class SearchMetaChipView: UIView {
    enum Style {
        case category(color: UIColor)
        case tag(color: UIColor)
    }

    init(text: String, style: Style) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        clipsToBounds = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.text = text

        let content = UIStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 4
        content.isLayoutMarginsRelativeArrangement = true
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7)

        switch style {
        case .category(let color):
            backgroundColor = color.withAlphaComponent(0.12)
            layer.borderWidth = 1
            layer.borderColor = color.withAlphaComponent(0.20).cgColor
            label.textColor = .secondaryLabel
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = color
            dot.layer.cornerRadius = 3
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 6),
                dot.heightAnchor.constraint(equalToConstant: 6),
            ])
            content.addArrangedSubview(dot)
            content.addArrangedSubview(label)
        case .tag(let color):
            backgroundColor = color.withAlphaComponent(0.10)
            layer.borderWidth = 1
            layer.borderColor = color.withAlphaComponent(0.18).cgColor
            label.textColor = color
            content.addArrangedSubview(label)
        }

        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
