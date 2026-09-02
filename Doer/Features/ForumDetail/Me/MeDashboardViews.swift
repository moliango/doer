import UIKit

final class MeDashboardSkeletonView: DoerSkeletonPlaceholderView {
    private var cardSurfaces: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        skeletonContentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: skeletonContentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: skeletonContentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: skeletonContentView.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: skeletonContentView.bottomAnchor),
        ])

        stack.addArrangedSubview(makeProfileCard())
        stack.addArrangedSubview(makeStatsCard())
        stack.addArrangedSubview(makeActionsCard())
        applyThemeStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyThemeStyle() {
        let themeStyle = AppSettings.shared.themeStyle
        applySkeletonTheme(
            backgroundColor: .clear,
            blockColor: themeStyle.accentColor.withAlphaComponent(0.12)
        )
        cardSurfaces.forEach {
            $0.backgroundColor = themeStyle.topicCardBackgroundColor
            $0.layer.borderColor = UIColor.separator.withAlphaComponent(0.20).cgColor
        }
    }

    private func makeCardSurface(height: CGFloat) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0.5
        cardSurfaces.append(card)
        card.heightAnchor.constraint(equalToConstant: height).isActive = true
        return card
    }

    private func makeProfileCard() -> UIView {
        let card = makeCardSurface(height: 108)
        let avatar = makeSkeletonBlock(cornerRadius: 36)
        let name = makeSkeletonBlock(cornerRadius: 6)
        let username = makeSkeletonBlock(cornerRadius: 5)
        let badge = makeSkeletonBlock(cornerRadius: 11)

        [avatar, name, username, badge].forEach { card.addSubview($0) }

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            avatar.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 72),
            avatar.heightAnchor.constraint(equalToConstant: 72),

            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16),
            name.topAnchor.constraint(equalTo: avatar.topAnchor, constant: 6),
            name.widthAnchor.constraint(equalToConstant: 156),
            name.heightAnchor.constraint(equalToConstant: 20),

            username.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            username.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 10),
            username.widthAnchor.constraint(equalToConstant: 118),
            username.heightAnchor.constraint(equalToConstant: 14),

            badge.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            badge.topAnchor.constraint(equalTo: username.bottomAnchor, constant: 10),
            badge.widthAnchor.constraint(equalToConstant: 82),
            badge.heightAnchor.constraint(equalToConstant: 22),
        ])

        return card
    }

    private func makeStatsCard() -> UIView {
        let card = makeCardSurface(height: 142)
        let title = makeSkeletonBlock(cornerRadius: 6)
        card.addSubview(title)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            title.widthAnchor.constraint(equalToConstant: 110),
            title.heightAnchor.constraint(equalToConstant: 16),
        ])

        var previous: UIView?
        for index in 0 ..< 4 {
            let column = UIView()
            column.translatesAutoresizingMaskIntoConstraints = false
            let icon = makeSkeletonBlock(cornerRadius: 12)
            let value = makeSkeletonBlock(cornerRadius: 5)
            let label = makeSkeletonBlock(cornerRadius: 4)
            column.addSubview(icon)
            column.addSubview(value)
            column.addSubview(label)
            card.addSubview(column)

            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 20),
                column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
                column.widthAnchor.constraint(equalTo: card.widthAnchor, multiplier: 0.20),

                icon.topAnchor.constraint(equalTo: column.topAnchor),
                icon.centerXAnchor.constraint(equalTo: column.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: 34),
                icon.heightAnchor.constraint(equalToConstant: 34),

                value.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 9),
                value.centerXAnchor.constraint(equalTo: column.centerXAnchor),
                value.widthAnchor.constraint(equalToConstant: 44),
                value.heightAnchor.constraint(equalToConstant: 16),

                label.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 8),
                label.centerXAnchor.constraint(equalTo: column.centerXAnchor),
                label.widthAnchor.constraint(equalToConstant: 52),
                label.heightAnchor.constraint(equalToConstant: 10),
            ])

            if let previous {
                column.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 8).isActive = true
            } else {
                column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14).isActive = true
            }
            if index == 3 {
                column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14).isActive = true
            }
            previous = column
        }

        return card
    }

    private func makeActionsCard() -> UIView {
        let card = makeCardSurface(height: 224)
        let title = makeSkeletonBlock(cornerRadius: 6)
        card.addSubview(title)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            title.widthAnchor.constraint(equalToConstant: 128),
            title.heightAnchor.constraint(equalToConstant: 16),
        ])

        var previousRow: UIView = title
        for _ in 0 ..< 3 {
            let row = UIView()
            row.translatesAutoresizingMaskIntoConstraints = false
            let icon = makeSkeletonBlock(cornerRadius: 11)
            let rowTitle = makeSkeletonBlock(cornerRadius: 5)
            let subtitle = makeSkeletonBlock(cornerRadius: 4)
            row.addSubview(icon)
            row.addSubview(rowTitle)
            row.addSubview(subtitle)
            card.addSubview(row)

            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: previousRow.bottomAnchor, constant: previousRow === title ? 14 : 0),
                row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                row.heightAnchor.constraint(equalToConstant: 56),

                icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 38),
                icon.heightAnchor.constraint(equalToConstant: 38),

                rowTitle.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
                rowTitle.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
                rowTitle.widthAnchor.constraint(equalToConstant: 136),
                rowTitle.heightAnchor.constraint(equalToConstant: 14),

                subtitle.leadingAnchor.constraint(equalTo: rowTitle.leadingAnchor),
                subtitle.topAnchor.constraint(equalTo: rowTitle.bottomAnchor, constant: 8),
                subtitle.widthAnchor.constraint(equalToConstant: 188),
                subtitle.heightAnchor.constraint(equalToConstant: 11),
            ])
            previousRow = row
        }

        return card
    }
}

final class MeInsetLabel: UILabel {
    private let insets: UIEdgeInsets

    init(insets: UIEdgeInsets) {
        self.insets = insets
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}

final class MeProfileCardView: UIView {
    var onLoginTapped: (() -> Void)?
    var onProfileTapped: (() -> Void)?

    private let cardView = MeCardSurfaceView()
    private let avatarImageView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.backgroundColor = .tertiarySystemFill
        iv.layer.cornerRadius = 36
        return iv
    }()
    private let nameLabel = UILabel()
    private let usernameLabel = UILabel()
    private let levelLabel = MeInsetLabel(
        insets: UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    )
    private let loginButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "me.login")
        configuration.cornerStyle = .large
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()
    private let chevronImageView: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "chevron.right"))
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.tintColor = .tertiaryLabel
        return iv
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
        translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 1
        usernameLabel.font = .systemFont(ofSize: 14, weight: .regular)
        usernameLabel.textColor = .secondaryLabel
        levelLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        levelLabel.textAlignment = .center
        levelLabel.textColor = .systemBlue
        levelLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.12)
        levelLabel.layer.cornerRadius = 8
        levelLabel.layer.cornerCurve = .continuous
        levelLabel.layer.masksToBounds = true
        levelLabel.isHidden = true
        levelLabel.setContentHuggingPriority(.required, for: .horizontal)

        let infoStack = UIStackView(arrangedSubviews: [nameLabel, usernameLabel, levelLabel])
        infoStack.axis = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 6
        infoStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cardView)
        cardView.addSubview(avatarImageView)
        cardView.addSubview(infoStack)
        cardView.addSubview(chevronImageView)
        cardView.addSubview(loginButton)

        let tap = UITapGestureRecognizer(target: self, action: #selector(profileTapped))
        cardView.addGestureRecognizer(tap)
        cardView.isUserInteractionEnabled = true
        loginButton.addTarget(self, action: #selector(loginTapped), for: .touchUpInside)

        let levelHeightConstraint = levelLabel.heightAnchor.constraint(equalToConstant: 26)
        levelHeightConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

            avatarImageView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18),
            avatarImageView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            avatarImageView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),
            avatarImageView.widthAnchor.constraint(equalToConstant: 72),
            avatarImageView.heightAnchor.constraint(equalToConstant: 72),

            infoStack.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 16),
            infoStack.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: chevronImageView.leadingAnchor, constant: -12),
            infoStack.trailingAnchor.constraint(lessThanOrEqualTo: loginButton.leadingAnchor, constant: -12),

            levelHeightConstraint,

            chevronImageView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            chevronImageView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 10),

            loginButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            loginButton.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            loginButton.heightAnchor.constraint(equalToConstant: 42),
        ])
    }

    func configure(user: DiscourseCurrentUser?, profile: DiscourseUserProfile?, baseURL: String) {
        guard let user else {
            avatarImageView.image = UIImage(systemName: "person.crop.circle.fill")
            avatarImageView.tintColor = .tertiaryLabel
            nameLabel.text = String(localized: "me.not_logged_in")
            usernameLabel.text = String(localized: "me.login_prompt")
            levelLabel.isHidden = true
            chevronImageView.isHidden = true
            loginButton.isHidden = false
            return
        }

        loginButton.isHidden = true
        chevronImageView.isHidden = false
        nameLabel.text = profile?.name ?? user.name ?? user.username
        usernameLabel.text = "@\(user.username)"
        let levelText = UserProfileFormatting.trustLevelText(profile?.trustLevel)
        levelLabel.text = levelText
        levelLabel.isHidden = levelText == nil

        let avatarTemplate = profile?.avatarTemplate ?? user.avatarTemplate
        AvatarImageLoader.setImage(
            on: avatarImageView,
            template: avatarTemplate,
            baseURL: baseURL,
            size: 240,
            placeholder: UIImage(systemName: "person.crop.circle.fill")
        )
    }

    @objc private func loginTapped() {
        onLoginTapped?()
    }

    @objc private func profileTapped() {
        if loginButton.isHidden {
            onProfileTapped?()
        }
    }
}

/// Horizontal stats strip that refuses vertical pans so the Me dashboard can scroll.
private final class MeHorizontalStatsScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            let translation = panGestureRecognizer.translation(in: self)
            let dx = abs(velocity.x) > abs(translation.x) ? abs(velocity.x) : abs(translation.x)
            let dy = abs(velocity.y) > abs(translation.y) ? abs(velocity.y) : abs(translation.y)
            if dy > dx {
                return false
            }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

final class MeStatsCardView: UIView {
    var onCustomizeTapped: (() -> Void)?

    private let cardView = MeCardSurfaceView()
    private let titleLabel = UILabel()
    private let customizeButton = UIButton(type: .system)
    private let layoutCanvas = MeStatsLayoutCanvas()
    private let emptyLabel = UILabel()

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
        titleLabel.text = String(localized: "me.stats.title")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)

        var customizeConfiguration = UIButton.Configuration.plain()
        customizeConfiguration.title = String(localized: "me.stats.customize")
        customizeConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 0)
        customizeConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 13, weight: .medium)
            return outgoing
        }
        customizeButton.configuration = customizeConfiguration
        customizeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        customizeButton.addTarget(self, action: #selector(customizeTapped), for: .touchUpInside)

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, UIView(), customizeButton])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        layoutCanvas.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = String(localized: "me.stats.login_required")
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cardView)
        cardView.addSubview(layoutCanvas)
        cardView.addSubview(emptyLabel)
        cardView.addSubview(headerStack)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            layoutCanvas.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 14),
            layoutCanvas.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            layoutCanvas.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            layoutCanvas.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),

            emptyLabel.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 18),
            emptyLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            emptyLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardView.bottomAnchor, constant: -18),
        ])
    }

    func configure(items: [MeStatItem], isLoggedIn: Bool, layout: MeStatsLayout) {
        customizeButton.isHidden = !isLoggedIn
        emptyLabel.isHidden = isLoggedIn
        layoutCanvas.isHidden = !isLoggedIn
        guard isLoggedIn else {
            layoutCanvas.configure(items: [], layout: .grid)
            return
        }
        layoutCanvas.configure(items: items, layout: layout)
    }

    @objc private func customizeTapped() {
        onCustomizeTapped?()
    }
}

final class MeStatsLayoutCanvas: UIView {
    private let scrollView = MeHorizontalStatsScrollView()
    private let stackView = UIStackView()
    private var stackWidthToFrame: NSLayoutConstraint?
    private var canvasHeight: NSLayoutConstraint?
    private var horizontalWidthConstraints: [NSLayoutConstraint] = []
    private var items: [MeStatItem] = []
    private var layout: MeStatsLayout = .grid
    private var lastAppliedWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stackView)

        let widthConstraint = stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        stackWidthToFrame = widthConstraint
        let heightConstraint = heightAnchor.constraint(equalToConstant: MeStatsLayoutGeometry.horizontalItemHeight)
        canvasHeight = heightConstraint

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            widthConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(items: [MeStatItem], layout: MeStatsLayout) {
        self.items = items
        self.layout = layout
        lastAppliedWidth = 0
        rebuild()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyHorizontalWidthsIfNeeded()
    }

    private func rebuild() {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        horizontalWidthConstraints.removeAll()
        canvasHeight?.constant = MeStatsLayoutGeometry.contentHeight(for: items.count, layout: layout)

        switch layout {
        case .grid:
            scrollView.isScrollEnabled = false
            scrollView.alwaysBounceHorizontal = false
            stackView.axis = .vertical
            stackView.alignment = .fill
            stackView.distribution = .fill
            stackView.spacing = MeStatsLayoutGeometry.gridSpacing
            stackWidthToFrame?.isActive = true

            let columns = MeStatsLayoutGeometry.gridColumns
            let rows = stride(from: 0, to: items.count, by: columns).map {
                Array(items[$0..<min($0 + columns, items.count)])
            }
            for rowItems in rows {
                let rowStack = UIStackView()
                rowStack.axis = .horizontal
                rowStack.distribution = .fillEqually
                rowStack.spacing = MeStatsLayoutGeometry.gridSpacing
                rowItems.forEach { rowStack.addArrangedSubview(MeStatView(item: $0, layout: .grid)) }
                if rowItems.count < columns {
                    for _ in rowItems.count..<columns {
                        rowStack.addArrangedSubview(UIView())
                    }
                }
                rowStack.heightAnchor.constraint(equalToConstant: MeStatsLayoutGeometry.gridItemHeight).isActive = true
                stackView.addArrangedSubview(rowStack)
            }
        case .horizontal:
            let canScroll = items.count > Int(MeStatsLayoutGeometry.horizontalVisibleCount)
            scrollView.isScrollEnabled = canScroll
            scrollView.alwaysBounceHorizontal = canScroll
            stackView.axis = .horizontal
            stackView.alignment = .fill
            stackView.distribution = .fill
            stackView.spacing = MeStatsLayoutGeometry.horizontalSpacing
            stackWidthToFrame?.isActive = false
            let tileWidth = MeStatsLayoutGeometry.horizontalItemWidth(in: max(scrollView.bounds.width, 240))
            for item in items {
                let statView = MeStatView(item: item, layout: .horizontal)
                let width = statView.widthAnchor.constraint(equalToConstant: tileWidth)
                width.isActive = true
                horizontalWidthConstraints.append(width)
                stackView.addArrangedSubview(statView)
            }
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyHorizontalWidthsIfNeeded() {
        guard layout == .horizontal else { return }
        let width = scrollView.bounds.width
        guard width > 1, abs(width - lastAppliedWidth) > 0.5 else { return }
        lastAppliedWidth = width
        let tileWidth = MeStatsLayoutGeometry.horizontalItemWidth(in: width)
        horizontalWidthConstraints.forEach { $0.constant = tileWidth }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: canvasHeight?.constant ?? MeStatsLayoutGeometry.horizontalItemHeight)
    }
}

final class MeStatView: UIView {
    init(item: MeStatItem, layout: MeStatsLayout = .grid) {
        super.init(frame: .zero)
        setup(item: item, layout: layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(item: MeStatItem, layout _: MeStatsLayout) {
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: UIImage(systemName: item.type.symbolName))
        iconView.tintColor = item.type.tintColor
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = item.type.tintColor.withAlphaComponent(0.12)
        iconContainer.layer.cornerRadius = 12
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.addSubview(iconView)

        let valueLabel = UILabel()
        valueLabel.text = item.valueText
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.75

        let titleLabel = UILabel()
        titleLabel.text = item.type.title
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabel
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75

        let stack = UIStackView(arrangedSubviews: [iconContainer, valueLabel, titleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconContainer.widthAnchor.constraint(equalToConstant: 34),
            iconContainer.heightAnchor.constraint(equalToConstant: 34),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
}

final class MeActionCardView: UIView {
    var onCustomizeTapped: (() -> Void)?

    private let cardView = MeCardSurfaceView()
    private let titleLabel = UILabel()
    private let customizeButton = UIButton(type: .system)
    private let stackView = UIStackView()

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
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        customizeButton.setTitle(String(localized: "common.customize", defaultValue: "自定义"), for: .normal)
        customizeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        customizeButton.addTarget(self, action: #selector(customizeTapped), for: .touchUpInside)

        let headerStack = UIStackView(arrangedSubviews: [titleLabel, UIView(), customizeButton])
        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 10
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        stackView.axis = .vertical
        stackView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cardView)
        cardView.addSubview(headerStack)
        cardView.addSubview(stackView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

            headerStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            headerStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            headerStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),

            stackView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -6),
        ])
    }

    func configure(title: String, rows: [MeActionRow]) {
        titleLabel.text = title
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            let rowView = MeActionRowView(row: row, showsDivider: index < rows.count - 1)
            stackView.addArrangedSubview(rowView)
        }
    }

    @objc private func customizeTapped() {
        onCustomizeTapped?()
    }
}

final class MeActionRowView: UIControl {
    private let action: () -> Void

    init(row: MeActionRow, showsDivider: Bool) {
        self.action = row.action
        super.init(frame: .zero)
        setup(row: row, showsDivider: showsDivider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(row: MeActionRow, showsDivider: Bool) {
        isEnabled = row.isEnabled
        isUserInteractionEnabled = row.isEnabled
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = row.title
        accessibilityHint = row.subtitle
        alpha = row.isEnabled ? 1 : 0.48
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        // Visuals live in a non-interactive layer so the UIControl owns the full-row hit target.
        // UIStackView as a direct subview otherwise swallows taps (only the icon well fired).
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.isUserInteractionEnabled = false

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = row.tintColor.withAlphaComponent(0.12)
        iconContainer.layer.cornerRadius = 11
        iconContainer.layer.cornerCurve = .continuous

        let iconView = UIImageView(image: UIImage(systemName: row.symbolName))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = row.tintColor
        iconView.contentMode = .scaleAspectFit
        iconContainer.addSubview(iconView)

        let titleLabel = UILabel()
        titleLabel.text = row.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label

        let subtitleLabel = UILabel()
        subtitleLabel.text = row.subtitle
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 1

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let badgeLabel = UILabel()
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.backgroundColor = .systemRed
        badgeLabel.layer.cornerRadius = 10
        badgeLabel.layer.cornerCurve = .continuous
        badgeLabel.clipsToBounds = true
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        if let text = DiscourseChatChannelsResponse.badgeText(for: row.badgeCount) {
            badgeLabel.text = " \(text) "
            badgeLabel.isHidden = false
        } else {
            badgeLabel.isHidden = true
        }

        let trailingStack = UIStackView(arrangedSubviews: [badgeLabel, chevron])
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 8
        trailingStack.translatesAutoresizingMaskIntoConstraints = false

        let divider = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.backgroundColor = UIColor.separator.withAlphaComponent(0.35)
        divider.isHidden = !showsDivider

        addSubview(contentView)
        contentView.addSubview(iconContainer)
        contentView.addSubview(textStack)
        contentView.addSubview(trailingStack)
        contentView.addSubview(divider)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 62),

            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 38),
            iconContainer.heightAnchor.constraint(equalToConstant: 38),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 19),
            iconView.heightAnchor.constraint(equalToConstant: 19),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            textStack.trailingAnchor.constraint(equalTo: trailingStack.leadingAnchor, constant: -10),

            trailingStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            trailingStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            badgeLabel.heightAnchor.constraint(equalToConstant: 20),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            chevron.widthAnchor.constraint(equalToConstant: 10),

            divider.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        accessibilityValue = DiscourseChatChannelsResponse.badgeText(for: row.badgeCount)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isEnabled, isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override var isHighlighted: Bool {
        didSet {
            guard isEnabled else { return }
            alpha = isHighlighted ? 0.55 : 1
        }
    }

    @objc private func tapped() {
        action()
    }
}

class MeCardSurfaceView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.withAlphaComponent(0.22).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
