import SDWebImage
import UIKit

enum TopicTagVisualStyle {
    static func color(for tag: String) -> UIColor {
        let settings = AppSettings.shared
        if settings.themeTaxonomyColorsEnabled {
            return settings.themeStyle.topicTagColor(for: tag)
        }
        if let hex = TopicTagIconCatalog.presentation(for: tag)?.colorHex,
           let color = TopicTaxonomyColor.resolve(hex: hex) {
            return color
        }
        return .secondaryLabel
    }

    static func categoryColor(for name: String?, fallback: UIColor?) -> UIColor {
        let settings = AppSettings.shared
        if settings.themeTaxonomyColorsEnabled {
            return settings.themeStyle.topicCategoryColor(for: name, fallback: fallback)
        }
        return fallback ?? .systemGray
    }
}

struct XiaohongshuTopicCardModel {
    let id: Int
    let title: String
    let excerpt: String?
    let avatarURL: URL?
    let avatarUserId: Int?
    let username: String?
    let categoryName: String?
    let categoryColor: UIColor?
    let categoryPresentation: TopicCategoryBadgePresentation?
    let categoryBaseURL: String
    let tags: [String]
    let replyCount: Int
    let views: Int
    let timeText: String
    let isUnread: Bool
}

final class TopicCell: UITableViewCell {
    static let reuseIdentifier = "TopicCell"
    static let estimatedHeight: CGFloat = 96
    private var currentAvatarURL: URL?
    private var renderedTitle: String?
    private var emojiBaseURL: String?
    private var emojiUpdateObserver: NSObjectProtocol?

    private enum Metrics {
        static let titleFontSize = AppSettings.topicTitleReferencePointSize
        static let titleLineHeight: CGFloat = 20
        static let titleMaxLines = 3
        static let titleTopPadding: CGFloat = 9
        static let titleToBadgeMinimumSpacing: CGFloat = 7
        static let badgeBottomPadding: CGFloat = 8
    }

    private let cardView: UIView = {
        let view = UIView()
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 17
        iv.backgroundColor = ImagePaintPolicy.waitingFillColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let titleLabel: TopicTitleLabel = {
        let label = TopicTitleLabel()
        label.font = TopicListTypography.topicTitleFont(relativeTo: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = Metrics.titleMaxLines
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }()

    private let replyCountBadge: TopicCountBadgeView = {
        let badge = TopicCountBadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        return badge
    }()

    private let badgesStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = TopicListTypography.fixedFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
        emojiUpdateObserver = NotificationCenter.default.addObserver(
            forName: EmojiStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshTitleEmojiIfNeeded()
        }
    }

    deinit {
        if let emojiUpdateObserver {
            NotificationCenter.default.removeObserver(emojiUpdateObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(cardView)
        cardView.addSubview(avatarImageView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(replyCountBadge)
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
            titleLabel.trailingAnchor.constraint(equalTo: replyCountBadge.leadingAnchor, constant: -10),
            titleLabel.heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.titleLineHeight * CGFloat(Metrics.titleMaxLines)),

            replyCountBadge.centerYAnchor.constraint(
                equalTo: titleLabel.topAnchor,
                constant: Metrics.titleLineHeight / 2
            ),
            replyCountBadge.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            replyCountBadge.heightAnchor.constraint(equalToConstant: 22),

            badgesStackView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: Metrics.titleToBadgeMinimumSpacing),
            badgesStackView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            badgesStackView.heightAnchor.constraint(equalToConstant: 18),
            badgesStackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -Metrics.badgeBottomPadding),

            timeLabel.centerYAnchor.constraint(equalTo: badgesStackView.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: badgesStackView.trailingAnchor, constant: 8),
        ])
    }

    func configure(
        with topic: DiscourseTopicList.Topic,
        avatarURL: URL?,
        avatarUserId: Int? = nil,
        categoryName: String?,
        categoryColor: UIColor?,
        tags: [String] = [],
        categoryPresentation: TopicCategoryBadgePresentation? = nil,
        categoryBaseURL: String? = nil
    ) {
        let themeStyle = AppSettings.shared.themeStyle
        cardView.backgroundColor = themeStyle.topicCardBackgroundColor
        cardView.layer.cornerRadius = themeStyle.chromeCornerRadius
        applyTypography()
        let unread = topic.isUnreadForDisplay
        titleLabel.textColor = unread ? .label : .secondaryLabel
        titleLabel.font = TopicListTypography.font(
            for: .title,
            weight: unread ? .semibold : .regular
        )
        emojiBaseURL = categoryBaseURL
        configureTitleWithEmoji(TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title))

        let replies = max(topic.postsCount - 1, 0)
        replyCountBadge.isHidden = !AppSettings.shared.showTopicCardCounts
        replyCountBadge.configure(count: replies)

        configureBadges(
            categoryName: categoryName,
            categoryColor: categoryColor,
            tags: tags,
            categoryPresentation: categoryPresentation,
            categoryBaseURL: categoryBaseURL
        )

        // Time
        timeLabel.text = Self.formatDate(topic.lastPostedAt ?? topic.createdAt)

        // Let AvatarImageLoader decide cache/gate/retry; placeholder is not a loaded state.
        currentAvatarURL = avatarURL
        AvatarImageLoader.setImage(
            on: avatarImageView,
            url: avatarURL,
            cloudflareBaseURL: categoryBaseURL,
            avatarBaseURL: categoryBaseURL,
            userId: avatarUserId
        )
    }

    private func applyTypography() {
        titleLabel.font = TopicListTypography.font(for: .title, weight: .semibold)
        timeLabel.font = TopicListTypography.font(for: .meta, weight: .regular)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedTitle = nil
        emojiBaseURL = nil
        titleLabel.text = nil
        titleLabel.attributedText = nil
        replyCountBadge.prepareForReuse()
        badgesStackView.arrangedSubviews.forEach { view in
            badgesStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        timeLabel.text = nil
        currentAvatarURL = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        cardView.transform = .identity
        cardView.alpha = 1
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        AnimationOptimizer.animateCardPress(cardView, pressed: highlighted)
    }

    // MARK: - Emoji title

    private func configureTitleWithEmoji(_ title: String) {
        renderedTitle = title
        let titleFont = titleLabel.font ?? .systemFont(ofSize: Metrics.titleFontSize, weight: .semibold)
        TitleEmojiRenderer.apply(
            title,
            to: titleLabel,
            font: titleFont,
            textColor: titleLabel.textColor,
            baseURL: emojiBaseURL
        )
    }

    private func refreshTitleEmojiIfNeeded() {
        guard let renderedTitle else { return }
        configureTitleWithEmoji(renderedTitle)
    }

    private func configureBadges(
        categoryName: String?,
        categoryColor: UIColor?,
        tags: [String],
        categoryPresentation: TopicCategoryBadgePresentation?,
        categoryBaseURL: String?
    ) {
        badgesStackView.arrangedSubviews.forEach { view in
            badgesStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if AppSettings.shared.showTopicCardCategory, let categoryPresentation, let categoryBaseURL {
            badgesStackView.addArrangedSubview(
                TopicTaxonomyBadgeView(
                    category: categoryPresentation,
                    baseURL: categoryBaseURL,
                    variant: .compact
                )
            )
        } else if AppSettings.shared.showTopicCardCategory, let categoryName {
            let themedColor = TopicTagVisualStyle.categoryColor(for: categoryName, fallback: categoryColor)
            let categoryBadge = TopicBadgeView(
                text: categoryName,
                style: .category(color: themedColor)
            )
            badgesStackView.addArrangedSubview(categoryBadge)
        }

        let visibleTags = AppSettings.shared.showTopicCardTags ? tags : []
        for tag in visibleTags.prefix(2) where !tag.isEmpty {
            let tagBadge = TopicTaxonomyBadgeView(
                tag: tag,
                color: TopicTagVisualStyle.color(for: tag),
                variant: .compact
            )
            badgesStackView.addArrangedSubview(tagBadge)
        }
    }

    // MARK: - Helpers

    static func formatDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else { return isoString }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated
        return relative.localizedString(for: date, relativeTo: Date())
    }

}

extension TopicCell: TopicPreviewTargetProviding {
    var topicPreviewTargetView: UIView { cardView }
}

final class XiaohongshuTopicGridCell: UITableViewCell {
    static let reuseIdentifier = "XiaohongshuTopicGridCell"
    static let estimatedHeight: CGFloat = 274
    static let staggeredEstimatedHeight: CGFloat = 292
    private static let staggerOffset: CGFloat = 18

    var onTopicSelected: ((Int) -> Void)?

    private let leftCard = XiaohongshuTopicCardView()
    private let rightCard = XiaohongshuTopicCardView()
    private var stackBottomConstraint: NSLayoutConstraint?

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .top
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        clipsToBounds = false
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false

        leftCard.addTarget(self, action: #selector(leftCardTapped), for: .touchUpInside)
        rightCard.addTarget(self, action: #selector(rightCardTapped), for: .touchUpInside)

        stackView.addArrangedSubview(leftCard)
        stackView.addArrangedSubview(rightCard)
        contentView.addSubview(stackView)

        let bottomConstraint = stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        stackBottomConstraint = bottomConstraint
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            bottomConstraint,
        ])
    }

    func configure(
        left: XiaohongshuTopicCardModel?,
        right: XiaohongshuTopicCardModel?,
        staggered: Bool,
        rowIndex: Int
    ) {
        leftCard.configure(with: left)
        rightCard.configure(with: right)
        applyStaggeredLayout(staggered: staggered, rowIndex: rowIndex)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onTopicSelected = nil
        applyStaggeredLayout(staggered: false, rowIndex: 0)
        leftCard.prepareForReuse()
        rightCard.prepareForReuse()
    }

    private func applyStaggeredLayout(staggered: Bool, rowIndex: Int) {
        guard staggered else {
            leftCard.transform = .identity
            rightCard.transform = .identity
            stackBottomConstraint?.constant = -6
            return
        }

        let offset = Self.staggerOffset
        let leftOffset = rowIndex.isMultiple(of: 2) ? CGFloat(0) : offset
        let rightOffset = rowIndex.isMultiple(of: 2) ? offset : CGFloat(0)
        leftCard.transform = CGAffineTransform(translationX: 0, y: leftOffset)
        rightCard.transform = CGAffineTransform(translationX: 0, y: rightOffset)
        stackBottomConstraint?.constant = -(6 + offset)
    }

    @objc private func leftCardTapped() {
        guard let topicId = leftCard.topicId else { return }
        onTopicSelected?(topicId)
    }

    @objc private func rightCardTapped() {
        guard let topicId = rightCard.topicId else { return }
        onTopicSelected?(topicId)
    }

    func topicPreviewHit(at pointInCell: CGPoint) -> (topicId: Int, targetView: UIView)? {
        let leftPoint = leftCard.convert(pointInCell, from: self)
        if leftCard.bounds.contains(leftPoint), let topicId = leftCard.topicId {
            return (topicId, leftCard)
        }
        let rightPoint = rightCard.convert(pointInCell, from: self)
        if rightCard.bounds.contains(rightPoint), let topicId = rightCard.topicId {
            return (topicId, rightCard)
        }
        guard let side = XiaohongshuPreviewSelection.side(at: pointInCell, in: bounds) else {
            return nil
        }
        switch side {
        case .left:
            return leftCard.topicId.map { ($0, leftCard) }
        case .right:
            return rightCard.topicId.map { ($0, rightCard) }
        }
    }
}

private final class XiaohongshuTopicCardView: UIControl {
    private static let decorationSymbols = [
        "sparkles",
        "diamond.fill",
        "flame.fill",
        "gamecontroller.fill",
        "camera.fill",
        "mic.fill",
        "target",
        "bubble.left.and.bubble.right.fill",
        "star.fill",
    ]

    private(set) var topicId: Int?
    private var currentAvatarURL: URL?

    private let topPanel: UIView = {
        let view = UIView()
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let badgeStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let decorationIconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let cornerIconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        let view = UIImageView(image: UIImage(systemName: "heart.fill", withConfiguration: config))
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let previewLabel: UILabel = {
        let label = UILabel()
        label.font = TopicListTypography.fixedFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let titleLabel: TopicTitleLabel = {
        let label = TopicTitleLabel()
        label.font = TopicListTypography.scaledFont(
            ofSize: 14,
            weight: .semibold,
            relativeTo: .subheadline
        )
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let avatarImageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 9
        view.backgroundColor = ImagePaintPolicy.waitingFillColor
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let usernameLabel: UILabel = {
        let label = UILabel()
        label.font = TopicListTypography.fixedFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let replyIconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let view = UIImageView(image: UIImage(systemName: "bubble.left", withConfiguration: config))
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let replyCountLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let viewsIconView: UIImageView = {
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let view = UIImageView(image: UIImage(systemName: "eye", withConfiguration: config))
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let viewsLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let metaRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let statsRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override var isHighlighted: Bool {
        didSet {
            DoerMotion.animate(duration: DoerMotion.quick) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
                self.alpha = self.isHighlighted ? 0.86 : 1
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        backgroundColor = AppSettings.shared.themeStyle.topicCardBackgroundColor
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 5)

        metaRow.addArrangedSubview(avatarImageView)
        metaRow.addArrangedSubview(usernameLabel)
        statsRow.addArrangedSubview(replyIconView)
        statsRow.addArrangedSubview(replyCountLabel)
        statsRow.addArrangedSubview(viewsIconView)
        statsRow.addArrangedSubview(viewsLabel)
        [
            topPanel,
            badgeStackView,
            decorationIconView,
            cornerIconView,
            previewLabel,
            titleLabel,
            avatarImageView,
            usernameLabel,
            replyIconView,
            replyCountLabel,
            viewsIconView,
            viewsLabel,
            metaRow,
            statsRow,
        ].forEach { $0.isUserInteractionEnabled = false }

        addSubview(topPanel)
        topPanel.addSubview(badgeStackView)
        topPanel.addSubview(decorationIconView)
        topPanel.addSubview(cornerIconView)
        topPanel.addSubview(previewLabel)
        addSubview(titleLabel)
        addSubview(metaRow)
        addSubview(statsRow)

        NSLayoutConstraint.activate([
            topPanel.topAnchor.constraint(equalTo: topAnchor),
            topPanel.leadingAnchor.constraint(equalTo: leadingAnchor),
            topPanel.trailingAnchor.constraint(equalTo: trailingAnchor),
            topPanel.heightAnchor.constraint(equalToConstant: 136),

            badgeStackView.topAnchor.constraint(equalTo: topPanel.topAnchor, constant: 10),
            badgeStackView.leadingAnchor.constraint(equalTo: topPanel.leadingAnchor, constant: 10),
            badgeStackView.trailingAnchor.constraint(lessThanOrEqualTo: topPanel.trailingAnchor, constant: -34),
            badgeStackView.heightAnchor.constraint(equalToConstant: 18),

            cornerIconView.topAnchor.constraint(equalTo: topPanel.topAnchor, constant: 12),
            cornerIconView.trailingAnchor.constraint(equalTo: topPanel.trailingAnchor, constant: -12),
            cornerIconView.widthAnchor.constraint(equalToConstant: 14),
            cornerIconView.heightAnchor.constraint(equalToConstant: 14),

            decorationIconView.topAnchor.constraint(equalTo: badgeStackView.bottomAnchor, constant: 8),
            decorationIconView.leadingAnchor.constraint(equalTo: topPanel.leadingAnchor, constant: 12),
            decorationIconView.widthAnchor.constraint(equalToConstant: 26),
            decorationIconView.heightAnchor.constraint(equalToConstant: 26),

            previewLabel.topAnchor.constraint(equalTo: decorationIconView.bottomAnchor, constant: 10),
            previewLabel.leadingAnchor.constraint(equalTo: topPanel.leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(equalTo: topPanel.trailingAnchor, constant: -12),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: topPanel.bottomAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: topPanel.bottomAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            metaRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            metaRow.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaRow.trailingAnchor.constraint(lessThanOrEqualTo: statsRow.leadingAnchor, constant: -8),
            metaRow.heightAnchor.constraint(equalToConstant: 20),

            avatarImageView.widthAnchor.constraint(equalToConstant: 18),
            avatarImageView.heightAnchor.constraint(equalToConstant: 18),

            statsRow.centerYAnchor.constraint(equalTo: metaRow.centerYAnchor),
            statsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statsRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            replyIconView.widthAnchor.constraint(equalToConstant: 11),
            replyIconView.heightAnchor.constraint(equalToConstant: 11),
            viewsIconView.widthAnchor.constraint(equalToConstant: 11),
            viewsIconView.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    func configure(with model: XiaohongshuTopicCardModel?) {
        guard let model else {
            resetContent()
            alpha = 0
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            return
        }

        alpha = 1
        isUserInteractionEnabled = true
        accessibilityElementsHidden = false
        topicId = model.id
        accessibilityLabel = model.title
        accessibilityTraits = [.button]
        applyTypography()

        let seed = model.tags.first ?? model.categoryName ?? model.title
        let accentColor = TopicTagVisualStyle.color(for: seed)
        let themeStyle = AppSettings.shared.themeStyle
        let radius = themeStyle.chromeCornerRadius + 4
        backgroundColor = themeStyle.topicCardBackgroundColor
        layer.cornerRadius = radius
        topPanel.layer.cornerRadius = radius
        topPanel.backgroundColor = accentColor.withAlphaComponent(0.13)
        previewLabel.textColor = readableTextColor(for: accentColor)
        previewLabel.text = Self.cleanPreviewText(model.excerpt) ?? model.title
        titleLabel.textColor = model.isUnread ? .label : .secondaryLabel
        TitleEmojiRenderer.apply(
            model.title,
            to: titleLabel,
            font: titleLabel.font ?? TopicListTypography.topicTitleFont(relativeTo: .headline),
            textColor: titleLabel.textColor,
            baseURL: model.categoryBaseURL
        )
        usernameLabel.text = model.username.map { "@\($0)" } ?? model.timeText
        replyCountLabel.text = Self.compactCount(model.replyCount)
        viewsLabel.text = Self.compactCount(model.views)

        decorationIconView.image = UIImage(
            systemName: Self.symbolName(for: seed),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        )
        decorationIconView.tintColor = accentColor
        cornerIconView.tintColor = accentColor.withAlphaComponent(0.42)
        replyIconView.tintColor = accentColor.withAlphaComponent(0.72)
        viewsIconView.tintColor = accentColor.withAlphaComponent(0.72)

        configureBadges(model: model)
        // Let AvatarImageLoader decide cache/gate/retry; placeholder is not a loaded state.
        currentAvatarURL = model.avatarURL
        AvatarImageLoader.setImage(
            on: avatarImageView,
            url: model.avatarURL,
            cloudflareBaseURL: model.categoryBaseURL,
            avatarBaseURL: model.categoryBaseURL,
            userId: model.avatarUserId
        )
    }

    func prepareForReuse() {
        resetContent()
        alpha = 1
        isUserInteractionEnabled = true
        accessibilityElementsHidden = false
    }

    private func resetContent() {
        topicId = nil
        titleLabel.text = nil
        titleLabel.attributedText = nil
        previewLabel.text = nil
        usernameLabel.text = nil
        replyCountLabel.text = nil
        viewsLabel.text = nil
        currentAvatarURL = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
        badgeStackView.arrangedSubviews.forEach { view in
            badgeStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func applyTypography() {
        previewLabel.font = TopicListTypography.fixedFont(ofSize: 13, weight: .medium)
        titleLabel.font = TopicListTypography.topicTitleFont(relativeTo: .headline)
        usernameLabel.font = TopicListTypography.fixedFont(ofSize: 11, weight: .medium)
    }

    private func configureBadges(model: XiaohongshuTopicCardModel) {
        badgeStackView.arrangedSubviews.forEach { view in
            badgeStackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let categoryPresentation = model.categoryPresentation {
            badgeStackView.addArrangedSubview(
                TopicTaxonomyBadgeView(
                    category: categoryPresentation,
                    baseURL: model.categoryBaseURL,
                    variant: .compact
                )
            )
        } else if let categoryName = model.categoryName {
            let themedColor = TopicTagVisualStyle.categoryColor(for: categoryName, fallback: model.categoryColor)
            badgeStackView.addArrangedSubview(TopicBadgeView(text: categoryName, style: .category(color: themedColor)))
        }
        if let tag = model.tags.first, !tag.isEmpty {
            badgeStackView.addArrangedSubview(
                TopicTaxonomyBadgeView(
                    tag: tag,
                    color: TopicTagVisualStyle.color(for: tag),
                    variant: .compact
                )
            )
        }
    }

    private func readableTextColor(for color: UIColor) -> UIColor {
        AppSettings.shared.themeStyle == .xiaohongshu
            ? UIColor(red: 0.22, green: 0.12, blue: 0.13, alpha: 1)
            : .label
    }

    private static func cleanPreviewText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        let text = CookedContentPipeline.plainTextPreview(fromCooked: html)
        return text.isEmpty ? nil : text
    }

    private static func compactCount(_ count: Int) -> String {
        if count >= 10_000 {
            return "\(count / 10_000)w"
        }
        if count >= 1_000 {
            return "\(count / 1_000)k"
        }
        return "\(count)"
    }

    private static func symbolName(for seed: String) -> String {
        let hash = seed.unicodeScalars.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1.value) }
        return decorationSymbols[Int(hash % UInt64(decorationSymbols.count))]
    }
}

private final class TopicTitleLabel: UILabel {
    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        var rect = super.textRect(forBounds: bounds, limitedToNumberOfLines: numberOfLines)
        rect.origin.x = bounds.origin.x
        rect.origin.y = bounds.origin.y
        rect.size.width = bounds.width
        rect.size.height = min(rect.height, bounds.height)
        return rect
    }

    override func drawText(in rect: CGRect) {
        let topAlignedRect = textRect(forBounds: rect, limitedToNumberOfLines: numberOfLines)
        super.drawText(in: topAlignedRect)
    }
}

private final class TopicCountBadgeView: UIView {
    private static let hotCountThreshold = 50
    private var widthConstraint: NSLayoutConstraint?

    private let iconView: UIImageView = {
        let image = UIImage(systemName: "bubble.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let countLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textAlignment = .right
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        clipsToBounds = true

        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(countLabel)
        addSubview(stackView)

        widthConstraint = widthAnchor.constraint(equalToConstant: 38)
        widthConstraint?.priority = .required

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        widthConstraint?.isActive = true
    }

    func configure(count: Int) {
        let displayText = "\(min(count, 9_999))"
        countLabel.text = displayText
        widthConstraint?.constant = Self.width(forDisplayText: displayText)
        let themeStyle = AppSettings.shared.themeStyle
        layer.cornerRadius = max(themeStyle.chromeCornerRadius - 1, 8)
        let isHot = count >= Self.hotCountThreshold
        let hotColor = themeStyle.hotTopicColor
        let foreground: UIColor = isHot ? hotColor : themeStyle.topicCountForegroundColor
        iconView.tintColor = foreground
        countLabel.textColor = foreground
        backgroundColor = isHot
            ? hotColor.withAlphaComponent(0.14)
            : themeStyle.topicCountBackgroundColor
    }

    func prepareForReuse() {
        countLabel.text = nil
        widthConstraint?.constant = 38
    }

    private static func width(forDisplayText text: String) -> CGFloat {
        switch text.count {
        case 0, 1:
            return 38
        case 2:
            return 46
        case 3:
            return 54
        default:
            return 62
        }
    }
}

private final class TopicBadgeView: UIView {
    enum Style {
        case category(color: UIColor)
        case tag(color: UIColor)
    }

    private let contentStack = UIStackView()

    init(text: String, style: Style) {
        super.init(frame: .zero)
        setup(text: text, style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(text: String, style: Style) {
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 4
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        switch style {
        case .category(let color):
            backgroundColor = color.withAlphaComponent(0.08)
            layer.borderColor = color.withAlphaComponent(0.20).cgColor
            layer.borderWidth = 1
            contentStack.addArrangedSubview(makeDot(color: color))
        case .tag(let color):
            backgroundColor = color.withAlphaComponent(0.10)
            layer.borderColor = color.withAlphaComponent(0.18).cgColor
            layer.borderWidth = 1
            contentStack.addArrangedSubview(makeSymbolIcon(name: "tag.fill", color: color))
        }

        let label = UILabel()
        label.text = text
        label.font = TopicListTypography.fixedFont(ofSize: 10, weight: .medium)
        label.textColor = style.textColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: style.maxTextWidth).isActive = true
        contentStack.addArrangedSubview(label)
    }

    private func makeDot(color: UIColor) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        return dot
    }

    private func makeSymbolIcon(name: String, color: UIColor) -> UIImageView {
        let config = UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold)
        let imageView = UIImageView(image: UIImage(systemName: name, withConfiguration: config))
        imageView.tintColor = color
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 9),
            imageView.heightAnchor.constraint(equalToConstant: 9),
        ])
        return imageView
    }
}

private extension TopicBadgeView.Style {
    var textColor: UIColor {
        switch self {
        case .category(let color):
            return AppSettings.shared.themeStyle == .systemDefault ? .label : color
        case .tag(let color):
            return color
        }
    }

    var maxTextWidth: CGFloat {
        switch self {
        case .category:
            return 96
        case .tag:
            return 80
        }
    }
}
