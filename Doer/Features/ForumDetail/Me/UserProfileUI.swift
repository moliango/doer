import UIKit

enum UserProfileFormatting {
    static func displayName(profile: DiscourseUserProfile?, fallbackUsername: String) -> String {
        if let name = profile?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return profile?.username ?? fallbackUsername
    }

    static func cleanBio(_ bio: String?) -> String? {
        guard let bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Recover `:shortcode:` from emoji <img> before flattening so signatures keep Discourse emojis.
        let recovered = bio.contains("<")
            ? TitleEmojiRenderer.recoverShortcodesFromHTML(bio)
            : bio
        let cleaned = CookedContentPipeline.plainTextPreview(fromCooked: recovered)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func trustLevelText(_ level: Int?) -> String? {
        switch level {
        case 0: return String(localized: "me.profile.level_0")
        case 1: return String(localized: "me.profile.level_1")
        case 2: return String(localized: "me.profile.level_2")
        case 3: return String(localized: "me.profile.level_3")
        case 4: return String(localized: "me.profile.level_4")
        default: return nil
        }
    }

    static func compactNumber(_ value: Int?) -> String {
        guard let value else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        if value >= 10_000 {
            let shortValue = Double(value) / 10_000
            return "\(formatter.string(from: NSNumber(value: shortValue)) ?? "\(shortValue)")w"
        }
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func duration(seconds: Int?) -> String {
        guard let seconds else { return "--" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.day, .hour] : [.minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "--"
    }

    static func joinedDate(_ dateString: String?) -> String {
        guard let date = parsedDate(dateString) else { return "--" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func shortDate(_ dateString: String?) -> String {
        guard let date = parsedDate(dateString) else { return "--" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }

    /// The viewer's current wall-clock time, e.g. "1:40". Shown as a user-card stat.
    static func localTime(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: now)
    }

    nonisolated static func relativeDate(_ dateString: String?) -> String {
        guard let date = parsedDate(dateString) else { return "--" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    nonisolated private static func parsedDate(_ dateString: String?) -> Date? {
        guard let dateString else { return nil }
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return isoWithFraction.date(from: dateString) ?? ISO8601DateFormatter().date(from: dateString)
    }
}

/// Geometry for the avatar-tap user card: cover banner, overlapping avatar, floating header,
/// inline stats, badge chips, and a 2×2 action grid.
enum UserProfileCardLayout {
    static let avatarRadius: CGFloat = 40
    static let avatarBorderWidth: CGFloat = 3
    static let avatarDiameter: CGFloat = avatarRadius * 2
    /// How far the avatar rises above the cover banner's bottom edge.
    static let avatarBannerOverlap: CGFloat = 26
    static let cardCornerRadius: CGFloat = 22
    static let bannerHeight: CGFloat = 120
    static let headerHeight: CGFloat = 44
    static let headerTopGap: CGFloat = 6
    static let headerCardGap: CGFloat = 10
    static let bodyTop: CGFloat = 12
    static let bodyHorizontal: CGFloat = 16
    static let bodyBottom: CGFloat = 16
    static let screenMargin: CGFloat = 16
    static let actionHeight: CGFloat = 42
    static let badgeChipHeight: CGFloat = 26
    static let nameSize: CGFloat = 21
    static let usernameSize: CGFloat = 14
    static let metaSize: CGFloat = 13
}

/// Angular gradient ring drawn behind the avatar, giving it an iridescent rim over the cover banner.
final class ProfileAvatarRingView: UIView {
    private let ringLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ringLayer.type = .conic
        ringLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        ringLayer.endPoint = CGPoint(x: 0.5, y: 0)
        layer.addSublayer(ringLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(accent: UIColor) {
        let resolved = accent.resolvedColor(with: traitCollection)
        ringLayer.colors = [
            resolved.cgColor,
            resolved.withAlphaComponent(0.32).cgColor,
            resolved.cgColor,
        ]
        ringLayer.locations = [0, 0.5, 1]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ringLayer.frame = bounds
        ringLayer.cornerRadius = bounds.width / 2
    }
}

/// A single badge rendered as a tinted pill: medal icon + name.
final class UserProfileBadgeChipView: UIControl {
    private static let iconSize: CGFloat = 13
    private static let horizontalInset: CGFloat = 8

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let contentStack = UIStackView()
    private var badge: DiscourseBadge?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        layer.cornerRadius = UserProfileCardLayout.badgeChipHeight / 2
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        clipsToBounds = true

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 12,
            weight: .medium,
            fallback: .systemFont(ofSize: 12, weight: .medium)
        )
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 4
        contentStack.isUserInteractionEnabled = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(nameLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: UserProfileCardLayout.badgeChipHeight),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(badge: DiscourseBadge, baseURL: String) {
        self.badge = badge
        nameLabel.text = badge.name
        BadgeUIStyle.badgeIconImage(
            icon: badge.icon,
            imageURL: badge.imageURL,
            type: badge.type,
            baseURL: baseURL,
            pointSize: 11,
            into: iconView
        )
        applyChrome()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyChrome()
        }
    }

    private func applyChrome() {
        guard let badge else { return }
        backgroundColor = BadgeUIStyle.cardBackgroundColor(for: badge.type, trait: traitCollection)
        layer.borderColor = BadgeUIStyle.cardBorderColor(for: badge.type, trait: traitCollection).cgColor
    }

    override var intrinsicContentSize: CGSize {
        let width = Self.horizontalInset * 2
            + Self.iconSize
            + contentStack.spacing
            + nameLabel.intrinsicContentSize.width
        return CGSize(width: ceil(width), height: UserProfileCardLayout.badgeChipHeight)
    }
}

/// Manually wraps chip subviews onto multiple lines; reports its total height as intrinsic size.
final class ProfileChipFlowView: UIView {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    private(set) var chips: [UIView] = []

    func setChips(_ views: [UIView]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = views
        views.forEach { addSubview($0) }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let maxWidth = max(bounds.width, 1)
        for chip in chips {
            let size = chip.intrinsicContentSize
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            chip.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        layoutIfNeeded()
        let maxY = chips.map(\.frame.maxY).max() ?? 0
        return CGSize(width: UIView.noIntrinsicMetric, height: maxY)
    }
}

/// Card loading placeholder — mirrors the banner, identity, stats, badges, and 2×2 actions.
final class UserProfileCardSkeletonView: DoerSkeletonPlaceholderView {
    override init(frame: CGRect) {
        super.init(frame: frame)

        let banner = makeSkeletonBlock(cornerRadius: 0)
        let avatar = makeSkeletonBlock(cornerRadius: UserProfileCardLayout.avatarRadius)
        let name = makeSkeletonBlock(cornerRadius: 7)
        let username = makeSkeletonBlock(cornerRadius: 5)
        let bio = makeSkeletonBlock(cornerRadius: 4)
        let stat1 = makeSkeletonBlock(cornerRadius: 4)
        let stat2 = makeSkeletonBlock(cornerRadius: 4)
        let chip1 = makeSkeletonBlock(cornerRadius: UserProfileCardLayout.badgeChipHeight / 2)
        let chip2 = makeSkeletonBlock(cornerRadius: UserProfileCardLayout.badgeChipHeight / 2)
        let topics = makeSkeletonBlock(cornerRadius: 4)
        let action1 = makeSkeletonBlock(cornerRadius: 12)
        let action2 = makeSkeletonBlock(cornerRadius: 12)
        let action3 = makeSkeletonBlock(cornerRadius: 12)
        let action4 = makeSkeletonBlock(cornerRadius: 12)

        [
            banner, avatar, name, username, bio, stat1, stat2, chip1, chip2, topics,
            action1, action2, action3, action4,
        ].forEach { skeletonContentView.addSubview($0) }

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: skeletonContentView.topAnchor),
            banner.leadingAnchor.constraint(equalTo: skeletonContentView.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: skeletonContentView.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.bannerHeight),

            avatar.leadingAnchor.constraint(
                equalTo: skeletonContentView.leadingAnchor,
                constant: UserProfileCardLayout.bodyHorizontal
            ),
            avatar.centerYAnchor.constraint(
                equalTo: banner.bottomAnchor,
                constant: -UserProfileCardLayout.avatarBannerOverlap + UserProfileCardLayout.avatarRadius
            ),
            avatar.widthAnchor.constraint(equalToConstant: UserProfileCardLayout.avatarDiameter),
            avatar.heightAnchor.constraint(equalTo: avatar.widthAnchor),

            name.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 12),
            name.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            name.widthAnchor.constraint(equalToConstant: 140),
            name.heightAnchor.constraint(equalToConstant: 20),

            username.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 8),
            username.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            username.widthAnchor.constraint(equalToConstant: 168),
            username.heightAnchor.constraint(equalToConstant: 13),

            bio.topAnchor.constraint(equalTo: username.bottomAnchor, constant: 14),
            bio.leadingAnchor.constraint(equalTo: skeletonContentView.leadingAnchor, constant: 16),
            bio.trailingAnchor.constraint(equalTo: skeletonContentView.trailingAnchor, constant: -16),
            bio.heightAnchor.constraint(equalToConstant: 12),

            stat1.topAnchor.constraint(equalTo: bio.bottomAnchor, constant: 12),
            stat1.leadingAnchor.constraint(equalTo: bio.leadingAnchor),
            stat1.trailingAnchor.constraint(equalTo: skeletonContentView.trailingAnchor, constant: -56),
            stat1.heightAnchor.constraint(equalToConstant: 11),

            stat2.topAnchor.constraint(equalTo: stat1.bottomAnchor, constant: 8),
            stat2.leadingAnchor.constraint(equalTo: bio.leadingAnchor),
            stat2.widthAnchor.constraint(equalToConstant: 180),
            stat2.heightAnchor.constraint(equalToConstant: 11),

            chip1.topAnchor.constraint(equalTo: stat2.bottomAnchor, constant: 12),
            chip1.leadingAnchor.constraint(equalTo: bio.leadingAnchor),
            chip1.widthAnchor.constraint(equalToConstant: 74),
            chip1.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.badgeChipHeight),

            chip2.centerYAnchor.constraint(equalTo: chip1.centerYAnchor),
            chip2.leadingAnchor.constraint(equalTo: chip1.trailingAnchor, constant: 6),
            chip2.widthAnchor.constraint(equalToConstant: 106),
            chip2.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.badgeChipHeight),

            topics.topAnchor.constraint(equalTo: chip1.bottomAnchor, constant: 12),
            topics.leadingAnchor.constraint(equalTo: bio.leadingAnchor),
            topics.widthAnchor.constraint(equalToConstant: 150),
            topics.heightAnchor.constraint(equalToConstant: 14),

            action1.topAnchor.constraint(equalTo: topics.bottomAnchor, constant: 14),
            action1.leadingAnchor.constraint(equalTo: bio.leadingAnchor),
            action1.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),

            action2.topAnchor.constraint(equalTo: action1.topAnchor),
            action2.leadingAnchor.constraint(equalTo: action1.trailingAnchor, constant: 8),
            action2.trailingAnchor.constraint(equalTo: skeletonContentView.trailingAnchor, constant: -16),
            action2.heightAnchor.constraint(equalTo: action1.heightAnchor),
            action2.widthAnchor.constraint(equalTo: action1.widthAnchor),

            action3.topAnchor.constraint(equalTo: action1.bottomAnchor, constant: 8),
            action3.leadingAnchor.constraint(equalTo: bio.leadingAnchor),
            action3.heightAnchor.constraint(equalTo: action1.heightAnchor),
            action3.widthAnchor.constraint(equalTo: action1.widthAnchor),

            action4.topAnchor.constraint(equalTo: action3.topAnchor),
            action4.leadingAnchor.constraint(equalTo: action3.trailingAnchor, constant: 8),
            action4.trailingAnchor.constraint(equalTo: skeletonContentView.trailingAnchor, constant: -16),
            action4.heightAnchor.constraint(equalTo: action1.heightAnchor),
            action4.widthAnchor.constraint(equalTo: action1.widthAnchor),
            action4.bottomAnchor.constraint(
                equalTo: skeletonContentView.bottomAnchor,
                constant: -UserProfileCardLayout.bodyBottom
            ),
        ])
        applyThemeStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyThemeStyle() {
        applySkeletonTheme(
            backgroundColor: .clear,
            blockColor: UIColor.secondarySystemFill
        )
    }
}

final class UserProfileStatView: UIControl {
    private let valueLabel = UILabel()
    private let titleLabel = UILabel()
    private let iconView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        valueLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 17,
            weight: .bold,
            fallback: .systemFont(ofSize: 17, weight: .bold)
        )
        valueLabel.textColor = .label
        valueLabel.textAlignment = .center

        titleLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 12,
            weight: .medium,
            fallback: .systemFont(ofSize: 12, weight: .medium)
        )
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75

        let labelStack = UIStackView(arrangedSubviews: [valueLabel, titleLabel])
        labelStack.axis = .vertical
        labelStack.alignment = .center
        labelStack.spacing = 2
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labelStack)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labelStack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            labelStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labelStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labelStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    func configure(title: String, value: String, symbolName: String, tintColor: UIColor, isTappable: Bool = false) {
        valueLabel.text = value
        titleLabel.text = title
        iconView.image = UIImage(systemName: symbolName)
        iconView.tintColor = tintColor
        backgroundColor = AppSettings.shared.themeStyle.topicCardBackgroundColor
        isUserInteractionEnabled = isTappable
        accessibilityTraits = isTappable ? [.button] : [.staticText]
        accessibilityLabel = "\(title) \(value)"
    }
}

final class UserProfileActionCard: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        accessibilityTraits = .button

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 15,
            weight: .semibold,
            fallback: .systemFont(ofSize: 15, weight: .semibold)
        )
        titleLabel.textColor = .label

        subtitleLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 12,
            weight: .regular,
            fallback: .systemFont(ofSize: 12)
        )
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isUserInteractionEnabled = false

        addSubview(iconView)
        addSubview(textStack)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 72),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -12),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
        ])
    }

    func configure(title: String, subtitle: String, symbolName: String, tintColor: UIColor) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        iconView.image = UIImage(systemName: symbolName)
        iconView.tintColor = tintColor
        backgroundColor = AppSettings.shared.themeStyle.topicCardBackgroundColor
        accessibilityLabel = "\(title)，\(subtitle)"
    }
}
