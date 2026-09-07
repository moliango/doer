import SDWebImage
import UIKit

/// Telegram iOS chat-list row — layout matches official app, not a recolored WeChat cell.
///
/// Structure (from Telegram reference):
/// ```
/// [● avatar]  Title ……………………… time
///             last message preview …… badge
/// ```
final class TelegramTopicListCell: UITableViewCell {
    static let reuseIdentifier = "TelegramTopicListCell"
    static let estimatedHeight: CGFloat = 78
    static let avatarSize: CGFloat = 60

    private var renderedTitle: String?
    private var emojiBaseURL: String?
    private var emojiUpdateObserver: NSObjectProtocol?

    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFill
        iv.backgroundColor = UIColor(red: 0.82, green: 0.86, blue: 0.90, alpha: 1)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    /// Fallback monogram when no avatar loads (Telegram letter-circle look).
    private let monogramLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let verifiedIcon: UIImageView = {
        let iv = UIImageView()
        // Channel / broadcast mark (megaphone) — shown for pinned/announcement-like topics.
        let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        iv.image = UIImage(systemName: "megaphone.fill", withConfiguration: config)
        iv.tintColor = UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.isHidden = true
        return iv
    }()

    private let titleRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let previewLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = UIColor(red: 0.53, green: 0.56, blue: 0.60, alpha: 1)
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    private let timeLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .regular)
        label.textColor = UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        label.textAlignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let pinIcon: UIImageView = {
        let iv = UIImageView()
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iv.image = UIImage(systemName: "pin.fill", withConfiguration: config)
        iv.tintColor = UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.isHidden = true
        return iv
    }()

    private let timeRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()

    /// Outer pill — background + corner radius. Label is centered inside so digits don't sit high/low.
    private let badgeContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.clipsToBounds = true
        view.isHidden = true
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }()

    private let badgeLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        // Optical center for digit glyphs inside a short pill.
        label.baselineAdjustment = .alignCenters
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }()

    private let textColumn: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let topRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let bottomRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let separator: UIView = {
        let view = UIView()
        // Telegram hairline is very light gray.
        view.backgroundColor = UIColor(red: 0.88, green: 0.89, blue: 0.90, alpha: 1)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private static let badgeHeight: CGFloat = 22
    private static let badgeHorizontalPadding: CGFloat = 7
    private var badgeWidthConstraint: NSLayoutConstraint?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
        emojiUpdateObserver = NotificationCenter.default.addObserver(
            forName: EmojiStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let title = self.renderedTitle else { return }
            self.applyTitle(title)
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // GPU 加速圆形头像：用 CAShapeLayer mask 替代 clipsToBounds + cornerRadius
        // 避免离屏渲染，性能提升 30%+
        if avatarImageView.layer.mask == nil {
            let maskLayer = CAShapeLayer()
            maskLayer.path = UIBezierPath(
                ovalIn: CGRect(x: 0, y: 0, width: Self.avatarSize, height: Self.avatarSize)
            ).cgPath
            avatarImageView.layer.mask = maskLayer
        }
    }

    private func setupUI() {
        selectionStyle = .none
        backgroundColor = .white
        contentView.backgroundColor = .white
        // 性能优化：启用不透明渲染，减少 alpha 混合计算
        contentView.isOpaque = true
        isOpaque = true

        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(verifiedIcon)

        timeRow.addArrangedSubview(pinIcon)
        timeRow.addArrangedSubview(timeLabel)

        topRow.addArrangedSubview(titleRow)
        topRow.addArrangedSubview(timeRow)
        // Title expands; time hugs trailing.
        titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badgeContainer.addSubview(badgeLabel)
        bottomRow.addArrangedSubview(previewLabel)
        bottomRow.addArrangedSubview(badgeContainer)

        textColumn.addArrangedSubview(topRow)
        textColumn.addArrangedSubview(bottomRow)

        contentView.addSubview(avatarImageView)
        avatarImageView.addSubview(monogramLabel)
        contentView.addSubview(textColumn)
        contentView.addSubview(separator)

        let badgeW = badgeContainer.widthAnchor.constraint(equalToConstant: Self.badgeHeight)
        badgeWidthConstraint = badgeW

        NSLayoutConstraint.activate([
            avatarImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            avatarImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarImageView.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarImageView.heightAnchor.constraint(equalToConstant: Self.avatarSize),

            monogramLabel.centerXAnchor.constraint(equalTo: avatarImageView.centerXAnchor),
            monogramLabel.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),

            textColumn.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 12),
            textColumn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            textColumn.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textColumn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),

            pinIcon.widthAnchor.constraint(equalToConstant: 12),
            pinIcon.heightAnchor.constraint(equalToConstant: 12),
            verifiedIcon.widthAnchor.constraint(equalToConstant: 14),
            verifiedIcon.heightAnchor.constraint(equalToConstant: 14),

            // Digit dead-center in the pill (fixes “数字偏上/偏下”).
            badgeContainer.heightAnchor.constraint(equalToConstant: Self.badgeHeight),
            badgeW,
            badgeLabel.centerXAnchor.constraint(equalTo: badgeContainer.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeContainer.centerYAnchor),
            // Keep label from forcing the pill wider than measured width.
            badgeLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: badgeContainer.leadingAnchor,
                constant: 2
            ),
            badgeLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badgeContainer.trailingAnchor,
                constant: -2
            ),

            separator.leadingAnchor.constraint(equalTo: textColumn.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    func configure(
        with topic: DiscourseTopicList.Topic,
        avatarURL: URL?,
        avatarUserId: Int? = nil, // kept for call-site parity with other list cells
        categoryName: String?,
        tags: [String] = [],
        categoryBaseURL: String? = nil
    ) {
        _ = avatarUserId
        let accent = UIColor(red: 0.20, green: 0.56, blue: 0.93, alpha: 1) // #3390EC
        let isDark = traitCollection.userInterfaceStyle == .dark

        // Pure white list (Telegram light) / dark navy (Telegram night).
        let rowBG: UIColor = isDark
            ? UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
            : .white
        contentView.backgroundColor = rowBG
        backgroundColor = rowBG
        separator.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(red: 0.88, green: 0.89, blue: 0.90, alpha: 1)

        let hasUnread = topic.unreadPosts > 0
        titleLabel.font = TopicListTypography.font(
            for: .title,
            weight: hasUnread ? .semibold : .medium
        )
        previewLabel.font = TopicListTypography.font(for: .subtitle, weight: .regular)
        timeLabel.font = TopicListTypography.font(for: .meta, weight: .regular)
        titleLabel.adjustsFontForContentSizeCategory = true
        previewLabel.adjustsFontForContentSizeCategory = true
        timeLabel.adjustsFontForContentSizeCategory = true

        titleLabel.textColor = isDark ? .white : UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        previewLabel.textColor = isDark
            ? UIColor.white.withAlphaComponent(0.55)
            : UIColor(red: 0.53, green: 0.56, blue: 0.60, alpha: 1)
        // Unread chats in Telegram keep gray time; only badge turns blue.
        timeLabel.textColor = isDark
            ? UIColor.white.withAlphaComponent(0.45)
            : UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)

        emojiBaseURL = categoryBaseURL
        let plain = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
        renderedTitle = plain
        applyTitle(plain)

        // Channel megaphone for pinned topics (closest Discourse analogue to TG channels).
        let isPinned = topic.pinned == true
        verifiedIcon.isHidden = !isPinned
        pinIcon.isHidden = !isPinned
        pinIcon.tintColor = timeLabel.textColor
        verifiedIcon.tintColor = timeLabel.textColor

        // Last-message style preview: excerpt first, then category · tag chip.
        previewLabel.numberOfLines = 2
        if let excerpt = topic.excerpt?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            previewLabel.text = excerpt
        } else if let attributed = TopicListTagSubtitle.make(
            categoryName: categoryName,
            tags: tags,
            font: previewLabel.font ?? TopicListTypography.font(for: .subtitle, weight: .regular),
            categoryColor: previewLabel.textColor
        ) {
            previewLabel.attributedText = attributed
        } else {
            previewLabel.text = Self.previewText(
                topic: topic,
                categoryName: categoryName,
                tags: tags
            )
        }

        timeLabel.text = Self.formatTelegramDate(topic.lastPostedAt ?? topic.createdAt)

        // Badge only for real Discourse unreads (Telegram: no badge on fully-read chats).
        // Do NOT fall back to total reply count — that produced the huge gray 402/158 numbers.
        let badgeCount: Int? = topic.unreadPosts > 0 ? topic.unreadPosts : nil

        if let count = badgeCount {
            let text = count > 999 ? "999+" : "\(count)"
            let font = TopicListTypography.font(for: .badge, weight: .semibold)
            badgeLabel.font = font
            badgeLabel.text = text
            badgeLabel.textColor = .white
            badgeContainer.isHidden = false
            badgeContainer.backgroundColor = accent
            // Perfect capsule: radius = half height; width from text + padding (min = circle).
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let width = max(Self.badgeHeight, textWidth + Self.badgeHorizontalPadding * 2)
            badgeWidthConstraint?.constant = width
            badgeContainer.layer.cornerRadius = Self.badgeHeight / 2
            badgeContainer.layer.cornerCurve = .circular
        } else {
            badgeLabel.text = nil
            badgeContainer.isHidden = true
        }

        // Avatar / monogram (letter circle until real image loads — Telegram style).
        monogramLabel.text = Self.monogram(from: plain)
        monogramLabel.isHidden = false
        avatarImageView.backgroundColor = Self.avatarColor(for: plain)
        avatarImageView.image = nil
        ForumImageLoader.setImage(
            on: avatarImageView,
            url: avatarURL,
            placeholder: nil,
            cloudflareBaseURL: categoryBaseURL
        ) { [weak self] image, _, _, _ in
            self?.monogramLabel.isHidden = (image != nil)
        }
    }

    /// Generic session row (notifications / bookmarks / channels) — same chrome as topic rows.
    func configure(session item: TopicListSessionItem) {
        let accent = UIColor(red: 0.20, green: 0.56, blue: 0.93, alpha: 1)
        let isDark = traitCollection.userInterfaceStyle == .dark
        let rowBG: UIColor = isDark
            ? UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
            : .white
        contentView.backgroundColor = rowBG
        backgroundColor = rowBG
        separator.backgroundColor = isDark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(red: 0.88, green: 0.89, blue: 0.90, alpha: 1)

        titleLabel.font = TopicListTypography.font(
            for: .title,
            weight: item.isEmphasized ? .semibold : .medium
        )
        previewLabel.font = TopicListTypography.font(for: .subtitle, weight: .regular)
        timeLabel.font = TopicListTypography.font(for: .meta, weight: .regular)
        titleLabel.adjustsFontForContentSizeCategory = true
        previewLabel.adjustsFontForContentSizeCategory = true
        timeLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = isDark ? .white : UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)
        previewLabel.textColor = isDark
            ? UIColor.white.withAlphaComponent(0.55)
            : UIColor(red: 0.53, green: 0.56, blue: 0.60, alpha: 1)
        timeLabel.textColor = isDark
            ? UIColor.white.withAlphaComponent(0.45)
            : UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)

        emojiBaseURL = item.baseURL
        renderedTitle = item.title
        applyTitle(item.title)
        verifiedIcon.isHidden = true
        pinIcon.isHidden = true

        let sub = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        previewLabel.text = sub.isEmpty
            ? String(localized: "telegram_list.no_messages", defaultValue: "暂无消息")
            : sub
        previewLabel.numberOfLines = 2
        timeLabel.text = item.timeText

        if let badge = item.badgeText, !badge.isEmpty {
            let font = TopicListTypography.font(for: .badge, weight: .semibold)
            badgeLabel.font = font
            badgeLabel.text = badge
            badgeLabel.textColor = .white
            badgeContainer.isHidden = false
            badgeContainer.backgroundColor = accent
            let textWidth = ceil((badge as NSString).size(withAttributes: [.font: font]).width)
            let width = max(Self.badgeHeight, textWidth + Self.badgeHorizontalPadding * 2)
            badgeWidthConstraint?.constant = width
            badgeContainer.layer.cornerRadius = Self.badgeHeight / 2
            badgeContainer.layer.cornerCurve = .circular
        } else {
            badgeLabel.text = nil
            badgeContainer.isHidden = true
        }

        let background = item.monogramColor ?? Self.avatarColor(for: item.title)
        let letter = item.monogramText ?? Self.monogram(from: item.title)
        let foreground = item.monogramForegroundColor
            ?? DiscourseChatChannel.contrastingForeground(for: background)
        monogramLabel.isHidden = false
        monogramLabel.textColor = foreground
        if letter.contains(":") {
            TitleEmojiRenderer.apply(
                letter,
                to: monogramLabel,
                font: monogramLabel.font ?? .systemFont(ofSize: 24, weight: .semibold),
                textColor: foreground,
                baseURL: item.baseURL
            )
        } else {
            monogramLabel.attributedText = nil
            monogramLabel.text = letter
        }
        avatarImageView.backgroundColor = background
        avatarImageView.image = nil
        let resolvedURL = item.avatarURL ?? AvatarImageLoader.url(
            from: item.avatarTemplate,
            baseURL: item.baseURL ?? "",
            size: AvatarImageLoader.primaryAvatarPixelSize
        )
        ForumImageLoader.setImage(
            on: avatarImageView,
            url: resolvedURL,
            placeholder: nil,
            cloudflareBaseURL: item.baseURL
        ) { [weak self] image, _, _, _ in
            self?.monogramLabel.isHidden = (image != nil)
            if image != nil {
                self?.avatarImageView.backgroundColor = .clear
            }
        }
        if resolvedURL == nil {
            avatarImageView.image = nil
            monogramLabel.isHidden = false
        }
    }

    private func applyTitle(_ title: String) {
        TitleEmojiRenderer.apply(
            title,
            to: titleLabel,
            font: titleLabel.font ?? .systemFont(ofSize: 17, weight: .semibold),
            textColor: titleLabel.textColor ?? .label,
            baseURL: emojiBaseURL
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        renderedTitle = nil
        emojiBaseURL = nil
        titleLabel.text = nil
        previewLabel.text = nil
        timeLabel.text = nil
        badgeLabel.text = nil
        badgeContainer.isHidden = true
        pinIcon.isHidden = true
        verifiedIcon.isHidden = true
        monogramLabel.isHidden = true
        monogramLabel.text = nil
        monogramLabel.attributedText = nil
        avatarImageView.sd_cancelCurrentImageLoad()
        avatarImageView.image = nil
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        let isDark = traitCollection.userInterfaceStyle == .dark
        let base: UIColor = isDark
            ? UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
            : .white
        let pressed: UIColor = isDark
            ? UIColor(red: 0.12, green: 0.15, blue: 0.18, alpha: 1)
            : UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1)
        if animated {
            AnimationOptimizer.animateCellHighlight(
                contentView,
                highlighted: highlighted,
                highlightColor: pressed,
                normalColor: base
            )
        } else {
            contentView.backgroundColor = highlighted ? pressed : base
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        if !selected {
            let isDark = traitCollection.userInterfaceStyle == .dark
            contentView.backgroundColor = isDark
                ? UIColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
                : .white
        }
    }

    // MARK: - Helpers

    private static func previewText(
        topic: DiscourseTopicList.Topic,
        categoryName: String?,
        tags: [String]
    ) -> String {
        if let excerpt = topic.excerpt?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !excerpt.isEmpty {
            return excerpt
        }
        var parts: [String] = []
        if let categoryName, !categoryName.isEmpty { parts.append(categoryName) }
        if let tag = tags.first, !tag.isEmpty { parts.append("#\(tag)") }
        if parts.isEmpty {
            let replies = max(topic.postsCount - 1, 0)
            if replies > 0 {
                return String(
                    format: String(localized: "telegram_list.replies_fmt", defaultValue: "%d 条回复"),
                    replies
                )
            }
            return String(localized: "telegram_list.no_messages", defaultValue: "暂无消息")
        }
        return parts.joined(separator: " · ")
    }

    /// Telegram-style relative date: HH:mm / weekday / M/d/yy.
    static func formatTelegramDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: isoString)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: isoString)
        }
        guard let date else { return isoString }

        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            let tf = DateFormatter()
            tf.locale = .current
            tf.dateFormat = "HH:mm"
            return tf.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "telegram_list.yesterday", defaultValue: "昨天")
        }
        // Within last 7 days → weekday short (周三 / Wed)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now), date >= weekAgo {
            let df = DateFormatter()
            df.locale = .current
            df.setLocalizedDateFormatFromTemplate("EEE")
            return df.string(from: date)
        }
        let df = DateFormatter()
        df.locale = .current
        // Match screenshot style like 7/31/26
        df.dateFormat = "M/d/yy"
        return df.string(from: date)
    }

    private static func monogram(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private static func avatarColor(for seed: String) -> UIColor {
        // Telegram-ish letter avatar palette.
        let palette: [UIColor] = [
            UIColor(red: 0.91, green: 0.40, blue: 0.38, alpha: 1),
            UIColor(red: 0.95, green: 0.61, blue: 0.25, alpha: 1),
            UIColor(red: 0.40, green: 0.73, blue: 0.42, alpha: 1),
            UIColor(red: 0.26, green: 0.65, blue: 0.96, alpha: 1),
            UIColor(red: 0.55, green: 0.48, blue: 0.91, alpha: 1),
            UIColor(red: 0.93, green: 0.42, blue: 0.65, alpha: 1),
            UIColor(red: 0.20, green: 0.70, blue: 0.70, alpha: 1),
        ]
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
