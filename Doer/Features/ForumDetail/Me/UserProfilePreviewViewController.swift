import UIKit

private final class ProfilePreviewButton: UIButton {
    private let minimumHitTarget = CGSize(width: 44, height: 44)

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let horizontalInset = min(0, (bounds.width - minimumHitTarget.width) / 2)
        let verticalInset = min(0, (bounds.height - minimumHitTarget.height) / 2)
        return bounds.insetBy(dx: horizontalInset, dy: verticalInset).contains(point)
    }
}

final class UserProfilePreviewViewController: ObservableViewController {
    var onViewProfile: ((String) -> Void)?
    /// Topic-detail only: filter the current thread to this user.
    var onFilterPostsByUsername: ((String) -> Void)?
    var isFilteringThisUser = false

    private let api: DiscourseAPI
    private let viewModel: UserProfileViewModel

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private let dimView = UIView()
    private let cardView = UIView()
    private let clipView = UIView()
    private let backgroundImageView = UIImageView()
    private let backgroundScrimView = ProfileCardScrimView()
    private let cardStack = UIStackView()
    private let avatarHaloView = UIView()
    private let avatarImageView = UIImageView()
    private let flairImageView = UIImageView()
    private let displayNameLabel = UILabel()
    private let usernameLabel = UILabel()
    private let levelLabel = UILabel()
    private let titleLabel = UILabel()
    private let identityNameStack = UIStackView()
    private let bioLabel = UILabel()
    private let locationWebsiteStack = UIStackView()
    private let factsLabel = UILabel()
    private let statsLabel = UILabel()
    private let skeletonView = UserProfileCardSkeletonView()
    private let errorLabel = UILabel()
    private var cardStackBottomConstraint: NSLayoutConstraint?
    private var skeletonBottomConstraint: NSLayoutConstraint?
    private var lastPresentedRelationshipError: String?

    private lazy var messageButton = makeActionButton(
        title: String(localized: "user.profile.private_message"),
        symbolName: "envelope.fill",
        style: .filled
    )

    private lazy var followButton = makeActionButton(
        title: String(localized: "user.profile.follow"),
        symbolName: "person.badge.plus.fill",
        style: .tinted
    )

    private lazy var viewProfileButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "user.profile.view_profile")
        config.image = UIImage(systemName: "person.crop.circle")
        config.imagePadding = 6
        config.cornerStyle = .large
        config.baseForegroundColor = AppSettings.shared.themeStyle.accentColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        config.titleTextAttributesTransformer = compactButtonTextAttributes(size: 14)
        let button = ProfilePreviewButton(type: .system)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.borderWidth = 1
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
        button.addTarget(self, action: #selector(viewProfileTapped), for: .touchUpInside)
        return button
    }()

    private lazy var filterPostsButton: UIButton = {
        var config = UIButton.Configuration.tinted()
        config.title = String(localized: "user.profile.filter_posts", defaultValue: "只看此人")
        config.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        config.imagePadding = 6
        config.cornerStyle = .large
        config.baseForegroundColor = AppSettings.shared.themeStyle.accentColor
        config.baseBackgroundColor = AppSettings.shared.themeStyle.accentColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        config.titleTextAttributesTransformer = compactButtonTextAttributes(size: 14)
        let button = ProfilePreviewButton(type: .system)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(filterPostsTapped), for: .touchUpInside)
        button.isHidden = true
        return button
    }()

    private lazy var moreButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "ellipsis")
        config.cornerStyle = .large
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        let button = ProfilePreviewButton(type: .system)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.borderWidth = 1
        button.layer.cornerRadius = 12
        button.layer.cornerCurve = .continuous
        button.accessibilityLabel = String(localized: "user.profile.more")
        button.showsMenuAsPrimaryAction = true
        return button
    }()

    init(api: DiscourseAPI, username: String) {
        self.api = api
        self.viewModel = UserProfileViewModel(api: api, username: username)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(viewModel)
        observe(AppSettings.shared)
        setupUI()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(emojiStoreDidUpdate),
            name: EmojiStore.didUpdateNotification,
            object: nil
        )
        ensureEmojiMapLoaded()
        Task { @MainActor in
            await viewModel.load()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        cardView.layer.shadowPath = UIBezierPath(
            roundedRect: cardView.bounds,
            cornerRadius: cardView.layer.cornerRadius
        ).cgPath
    }

    override func updateUI() {
        applyTheme()

        let showsSkeleton = viewModel.userCard == nil
            && viewModel.userProfile == nil
            && viewModel.errorMessage == nil
        skeletonView.applyThemeStyle()
        skeletonView.setSkeletonActive(showsSkeleton, animated: view.window != nil)
        cardStack.isHidden = showsSkeleton
        cardStackBottomConstraint?.isActive = !showsSkeleton
        skeletonBottomConstraint?.isActive = showsSkeleton
        errorLabel.isHidden = viewModel.errorMessage == nil || showsSkeleton
        errorLabel.text = viewModel.errorMessage

        guard let profile = viewModel.userCard ?? viewModel.userProfile else {
            configurePlaceholder(showsSkeleton: showsSkeleton)
            return
        }

        cardView.alpha = 1
        configureProfile(profile, summary: viewModel.summary)
        configureActions(profile: profile)
        presentRelationshipErrorIfNeeded()
    }

    private func setupUI() {
        view.backgroundColor = .clear

        blurView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(blurView)

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTapped)))
        view.addSubview(dimView)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.layer.cornerRadius = UserProfileCardLayout.cardCornerRadius
        cardView.layer.cornerCurve = .continuous
        cardView.layer.shadowColor = UIColor.black.cgColor
        cardView.layer.shadowOpacity = 0.28
        cardView.layer.shadowRadius = 32
        cardView.layer.shadowOffset = CGSize(width: 0, height: 12)
        view.addSubview(cardView)

        clipView.translatesAutoresizingMaskIntoConstraints = false
        clipView.layer.cornerRadius = UserProfileCardLayout.cardCornerRadius
        clipView.layer.cornerCurve = .continuous
        clipView.clipsToBounds = true
        cardView.addSubview(clipView)

        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.isHidden = true
        clipView.addSubview(backgroundImageView)

        backgroundScrimView.translatesAutoresizingMaskIntoConstraints = false
        backgroundScrimView.isHidden = true
        clipView.addSubview(backgroundScrimView)

        cardStack.axis = .vertical
        cardStack.spacing = 12
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(cardStack)

        setupIdentity()
        setupBody()
        setupActions()
        setupAvatar()
        setupLoadingAndError()

        let preferredWidth = cardView.widthAnchor.constraint(
            equalTo: view.widthAnchor,
            constant: -UserProfileCardLayout.screenMargin * 2
        )
        preferredWidth.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: view.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor,
                constant: UserProfileCardLayout.screenMargin
            ),
            cardView.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor,
                constant: -UserProfileCardLayout.screenMargin
            ),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            preferredWidth,
            cardView.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: UserProfileCardLayout.avatarOverflow + UserProfileCardLayout.dockedTopGap
            ),
            cardView.bottomAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -UserProfileCardLayout.screenMargin
            ),

            clipView.topAnchor.constraint(equalTo: cardView.topAnchor),
            clipView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            clipView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            backgroundImageView.topAnchor.constraint(equalTo: clipView.topAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),

            backgroundScrimView.topAnchor.constraint(equalTo: clipView.topAnchor),
            backgroundScrimView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            backgroundScrimView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            backgroundScrimView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),

            cardStack.topAnchor.constraint(equalTo: clipView.topAnchor, constant: UserProfileCardLayout.bodyTop),
            cardStack.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: UserProfileCardLayout.bodyHorizontal),
            cardStack.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -UserProfileCardLayout.bodyHorizontal),
        ])

        let cardStackBottom = cardStack.bottomAnchor.constraint(
            equalTo: clipView.bottomAnchor,
            constant: -UserProfileCardLayout.bodyBottom
        )
        cardStackBottomConstraint = cardStackBottom
        cardStack.isHidden = true
        cardStackBottom.isActive = false
        skeletonBottomConstraint?.isActive = true
        skeletonView.setSkeletonActive(true, animated: false)
    }

    private func setupIdentity() {
        displayNameLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: UserProfileCardLayout.nameSize,
            weight: .semibold,
            fallback: .systemFont(ofSize: UserProfileCardLayout.nameSize, weight: .semibold)
        )
        displayNameLabel.textColor = .label
        displayNameLabel.numberOfLines = 1
        displayNameLabel.adjustsFontSizeToFitWidth = true
        displayNameLabel.minimumScaleFactor = 0.72

        usernameLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: UserProfileCardLayout.usernameSize,
            weight: .regular,
            fallback: .systemFont(ofSize: UserProfileCardLayout.usernameSize, weight: .regular)
        )
        usernameLabel.textColor = .secondaryLabel
        usernameLabel.numberOfLines = 1
        usernameLabel.isUserInteractionEnabled = true
        usernameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        usernameLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(copyUsernameTapped)))

        levelLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 11,
            weight: .semibold,
            fallback: .systemFont(ofSize: 11, weight: .semibold)
        )
        levelLabel.textAlignment = .center
        levelLabel.layer.cornerRadius = 4
        levelLabel.layer.cornerCurve = .continuous
        levelLabel.clipsToBounds = true
        levelLabel.isHidden = true
        levelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: UserProfileCardLayout.metaSize,
            weight: .medium,
            fallback: .systemFont(ofSize: UserProfileCardLayout.metaSize, weight: .medium)
        )
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1

        let usernameRow = UIStackView(arrangedSubviews: [usernameLabel, levelLabel])
        usernameRow.axis = .horizontal
        usernameRow.alignment = .center
        usernameRow.spacing = 8

        locationWebsiteStack.axis = .horizontal
        locationWebsiteStack.alignment = .center
        locationWebsiteStack.spacing = 8
        locationWebsiteStack.distribution = .fill
        locationWebsiteStack.isHidden = true

        identityNameStack.axis = .vertical
        identityNameStack.spacing = 2
        identityNameStack.alignment = .leading
        identityNameStack.addArrangedSubview(displayNameLabel)
        identityNameStack.addArrangedSubview(usernameRow)
        identityNameStack.addArrangedSubview(titleLabel)
        identityNameStack.addArrangedSubview(locationWebsiteStack)

        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: UserProfileCardLayout.identityLeading).isActive = true

        let row = UIStackView(arrangedSubviews: [spacer, identityNameStack])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = 0
        cardStack.addArrangedSubview(row)

        locationWebsiteStack.widthAnchor.constraint(
            lessThanOrEqualTo: identityNameStack.widthAnchor
        ).isActive = true

        let levelHeightConstraint = levelLabel.heightAnchor.constraint(equalToConstant: 20)
        levelHeightConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            levelHeightConstraint,
            levelLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    private func setupBody() {
        bioLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: UserProfileCardLayout.usernameSize,
            weight: .regular,
            fallback: .systemFont(ofSize: UserProfileCardLayout.usernameSize, weight: .regular)
        )
        bioLabel.textColor = .label
        bioLabel.numberOfLines = 3
        bioLabel.lineBreakMode = .byTruncatingTail
        cardStack.addArrangedSubview(bioLabel)

        factsLabel.numberOfLines = 0
        factsLabel.lineBreakMode = .byWordWrapping
        cardStack.addArrangedSubview(factsLabel)

        statsLabel.numberOfLines = 0
        statsLabel.lineBreakMode = .byWordWrapping
        statsLabel.adjustsFontSizeToFitWidth = true
        statsLabel.minimumScaleFactor = 0.85
        cardStack.addArrangedSubview(statsLabel)
    }

    private func setupActions() {
        messageButton.addTarget(self, action: #selector(messageTapped), for: .touchUpInside)
        followButton.addTarget(self, action: #selector(followTapped), for: .touchUpInside)

        let primaryRow = UIStackView(arrangedSubviews: [messageButton, followButton])
        primaryRow.axis = .horizontal
        primaryRow.distribution = .fillEqually
        primaryRow.spacing = 8

        let bottomRow = UIStackView(arrangedSubviews: [viewProfileButton, moreButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8

        cardStack.addArrangedSubview(primaryRow)
        cardStack.setCustomSpacing(8, after: primaryRow)
        cardStack.addArrangedSubview(filterPostsButton)
        cardStack.setCustomSpacing(8, after: filterPostsButton)
        cardStack.addArrangedSubview(bottomRow)

        NSLayoutConstraint.activate([
            messageButton.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),
            followButton.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),
            filterPostsButton.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),
            viewProfileButton.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),
            moreButton.widthAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),
            moreButton.heightAnchor.constraint(equalToConstant: UserProfileCardLayout.actionHeight),
        ])
    }

    private func setupAvatar() {
        avatarHaloView.translatesAutoresizingMaskIntoConstraints = false
        avatarHaloView.layer.cornerRadius = UserProfileCardLayout.avatarRadius
        avatarHaloView.layer.cornerCurve = .continuous
        avatarHaloView.layer.borderWidth = UserProfileCardLayout.avatarBorderWidth
        avatarHaloView.isUserInteractionEnabled = false
        view.addSubview(avatarHaloView)

        avatarImageView.contentMode = .scaleAspectFill
        avatarImageView.clipsToBounds = true
        avatarImageView.layer.cornerRadius = UserProfileCardLayout.avatarRadius - UserProfileCardLayout.avatarBorderWidth
        avatarImageView.translatesAutoresizingMaskIntoConstraints = false
        avatarImageView.backgroundColor = .secondarySystemFill
        avatarHaloView.addSubview(avatarImageView)

        flairImageView.translatesAutoresizingMaskIntoConstraints = false
        flairImageView.contentMode = .scaleAspectFit
        flairImageView.clipsToBounds = true
        flairImageView.layer.cornerRadius = 9
        flairImageView.layer.cornerCurve = .continuous
        flairImageView.layer.borderWidth = 1.5
        flairImageView.isHidden = true
        flairImageView.isUserInteractionEnabled = false
        view.addSubview(flairImageView)

        NSLayoutConstraint.activate([
            avatarHaloView.widthAnchor.constraint(equalToConstant: UserProfileCardLayout.avatarDiameter),
            avatarHaloView.heightAnchor.constraint(equalTo: avatarHaloView.widthAnchor),
            avatarHaloView.leadingAnchor.constraint(
                equalTo: cardView.leadingAnchor,
                constant: UserProfileCardLayout.bodyHorizontal
            ),
            avatarHaloView.topAnchor.constraint(
                equalTo: cardView.topAnchor,
                constant: -UserProfileCardLayout.avatarOverflow
            ),

            avatarImageView.topAnchor.constraint(equalTo: avatarHaloView.topAnchor, constant: UserProfileCardLayout.avatarBorderWidth),
            avatarImageView.leadingAnchor.constraint(equalTo: avatarHaloView.leadingAnchor, constant: UserProfileCardLayout.avatarBorderWidth),
            avatarImageView.trailingAnchor.constraint(equalTo: avatarHaloView.trailingAnchor, constant: -UserProfileCardLayout.avatarBorderWidth),
            avatarImageView.bottomAnchor.constraint(equalTo: avatarHaloView.bottomAnchor, constant: -UserProfileCardLayout.avatarBorderWidth),

            flairImageView.trailingAnchor.constraint(equalTo: avatarHaloView.trailingAnchor, constant: 2),
            flairImageView.bottomAnchor.constraint(equalTo: avatarHaloView.bottomAnchor, constant: 2),
            flairImageView.widthAnchor.constraint(equalToConstant: 20),
            flairImageView.heightAnchor.constraint(equalToConstant: 20),
        ])
        view.bringSubviewToFront(avatarHaloView)
        view.bringSubviewToFront(flairImageView)
    }

    private func setupLoadingAndError() {
        skeletonView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(skeletonView)

        errorLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 13,
            weight: .medium,
            fallback: .systemFont(ofSize: 13, weight: .medium)
        )
        errorLabel.textColor = .secondaryLabel
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(errorLabel)

        let skeletonBottom = skeletonView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor)
        skeletonBottomConstraint = skeletonBottom

        NSLayoutConstraint.activate([
            skeletonView.topAnchor.constraint(equalTo: clipView.topAnchor),
            skeletonView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            skeletonView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),

            errorLabel.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -24),
            errorLabel.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -12),
        ])
    }

    private func configurePlaceholder(showsSkeleton: Bool) {
        if showsSkeleton {
            displayNameLabel.text = nil
            usernameLabel.text = nil
        } else {
            displayNameLabel.text = viewModel.username
            usernameLabel.text = "@\(viewModel.username)"
        }
        levelLabel.text = nil
        levelLabel.isHidden = true
        titleLabel.text = nil
        titleLabel.isHidden = true
        bioLabel.text = nil
        bioLabel.attributedText = nil
        bioLabel.isHidden = true
        factsLabel.attributedText = nil
        factsLabel.isHidden = true
        statsLabel.attributedText = nil
        statsLabel.isHidden = true
        locationWebsiteStack.isHidden = true
        flairImageView.isHidden = true
        cardView.alpha = 1
    }

    private func configureProfile(_ profile: DiscourseUserProfile, summary: DiscourseUserSummary?) {
        displayNameLabel.text = UserProfileFormatting.displayName(profile: profile, fallbackUsername: viewModel.username)
        usernameLabel.text = "@\(profile.username)"
        let levelText = UserProfileFormatting.trustLevelText(profile.trustLevel)
        levelLabel.text = levelText
        levelLabel.isHidden = levelText == nil
        titleLabel.text = profile.title
        titleLabel.isHidden = (profile.title ?? "").isEmpty

        AvatarImageLoader.setImage(
            on: avatarImageView,
            template: profile.avatarTemplate,
            baseURL: api.baseURL,
            size: 240
        )
        configureFlair(profile.flairUrl)

        applyBio(UserProfileFormatting.cleanBio(profile.bioExcerpt))
        configureLocationWebsite(profile: profile)
        configureFacts(profile: profile)
        configureStats(profile: profile, summary: summary)
        configureCardBackground(profile.cardBackgroundURL)
    }

    private func configureCardBackground(_ rawURL: String?) {
        guard let url = resolvedBackgroundURL(rawURL) else {
            backgroundImageView.image = nil
            backgroundImageView.isHidden = true
            backgroundScrimView.isHidden = true
            return
        }
        backgroundImageView.isHidden = false
        backgroundScrimView.isHidden = false
        ForumImageLoader.setImage(on: backgroundImageView, url: url)
    }

    private func configureFlair(_ flairUrl: String?) {
        guard let url = resolvedFlairURL(flairUrl) else {
            flairImageView.isHidden = true
            flairImageView.image = nil
            return
        }

        flairImageView.isHidden = false
        ForumImageLoader.setImage(on: flairImageView, url: url)
    }

    private func configureLocationWebsite(profile: DiscourseUserProfile) {
        locationWebsiteStack.arrangedSubviews.forEach { view in
            locationWebsiteStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if let location = profile.location?.trimmedNonEmpty {
            locationWebsiteStack.addArrangedSubview(
                makeMetaChip(symbolName: "mappin.and.ellipse", text: location)
            )
        }

        if let website = (profile.websiteName?.trimmedNonEmpty ?? profile.website?.trimmedNonEmpty) {
            locationWebsiteStack.addArrangedSubview(
                makeMetaChip(symbolName: "link", text: website)
            )
        }

        locationWebsiteStack.isHidden = locationWebsiteStack.arrangedSubviews.isEmpty
        let spacingAfter: UIView
        if !titleLabel.isHidden {
            spacingAfter = titleLabel
        } else if let usernameRow = usernameLabel.superview,
                  identityNameStack.arrangedSubviews.contains(usernameRow) {
            spacingAfter = usernameRow
        } else {
            spacingAfter = displayNameLabel
        }
        identityNameStack.setCustomSpacing(
            locationWebsiteStack.isHidden ? 2 : 8,
            after: spacingAfter
        )
    }

    private func applyBio(_ bio: String?) {
        guard let bio else {
            bioLabel.text = nil
            bioLabel.attributedText = nil
            bioLabel.isHidden = true
            return
        }
        bioLabel.isHidden = false
        TitleEmojiRenderer.apply(
            bio,
            to: bioLabel,
            font: bioLabel.font,
            textColor: .label,
            baseURL: api.baseURL
        )
    }

    @objc private func emojiStoreDidUpdate() {
        refreshBioEmojiIfNeeded()
    }

    private func ensureEmojiMapLoaded() {
        if EmojiStore.load(for: api.baseURL) {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.api.fetchEmojiGroups()
        }
    }

    private func refreshBioEmojiIfNeeded() {
        guard let profile = viewModel.userCard ?? viewModel.userProfile else { return }
        applyBio(UserProfileFormatting.cleanBio(profile.bioExcerpt))
    }

    private func configureFacts(profile: DiscourseUserProfile) {
        var items: [(String, String)] = []
        if let lastPostedAt = profile.lastPostedAt {
            items.append((String(localized: "user.profile.last_posted"), UserProfileFormatting.relativeDate(lastPostedAt)))
        }
        if profile.createdAt != nil {
            items.append((String(localized: "user.profile.joined"), UserProfileFormatting.shortDate(profile.createdAt)))
        }
        if let timeRead = profile.timeRead, timeRead > 0 {
            items.append((String(localized: "user.profile.read_time"), UserProfileFormatting.duration(seconds: timeRead)))
        }
        factsLabel.attributedText = items.isEmpty ? nil : makeInlineMetricText(items: items, baseSize: UserProfileCardLayout.metaSize, separator: "   ")
        factsLabel.isHidden = items.isEmpty
    }

    private func configureStats(profile: DiscourseUserProfile, summary: DiscourseUserSummary?) {
        var socialItems: [(String, String)] = []
        if let following = profile.followingCount {
            socialItems.append((String(localized: "user.profile.following"), UserProfileFormatting.compactNumber(following)))
        }
        if let followers = profile.followerCount {
            socialItems.append((String(localized: "user.profile.followers"), UserProfileFormatting.compactNumber(followers)))
        }
        if let score = profile.gamificationScore {
            socialItems.append((String(localized: "user.profile.score"), UserProfileFormatting.compactNumber(score)))
        }

        let fallbackItems: [(String, String)] = [
            (String(localized: "me.stats.topics"), UserProfileFormatting.compactNumber(summary?.topicCount)),
            (String(localized: "me.stats.posts"), UserProfileFormatting.compactNumber(summary?.postCount)),
            (String(localized: "me.stats.likes"), UserProfileFormatting.compactNumber(summary?.likesReceived)),
            (String(localized: "me.stats.profile_views"), UserProfileFormatting.compactNumber(profile.profileViewCount)),
        ]
        statsLabel.attributedText = makeInlineMetricText(
            items: socialItems.isEmpty ? fallbackItems : socialItems,
            baseSize: UserProfileCardLayout.metaSize,
            separator: "   "
        )
        statsLabel.isHidden = socialItems.isEmpty && fallbackItems.isEmpty
    }

    private func configureActions(profile: DiscourseUserProfile) {
        let state = viewModel.relationshipController.state
        let currentUsername = AuthManager.shared.username(for: api.baseURL)
        let isCurrentUser = currentUsername?.caseInsensitiveCompare(profile.username) == .orderedSame

        messageButton.isHidden = isCurrentUser || !state.canSendPrivateMessage
        followButton.isHidden = isCurrentUser || !state.canFollow
        messageButton.isEnabled = !state.isMutating
        followButton.isEnabled = !state.isMutating
        moreButton.isEnabled = !state.isMutating

        var followConfig = followButton.configuration
        followConfig?.title = state.isFollowed
            ? String(localized: "user.profile.unfollow", defaultValue: "Unfollow")
            : String(localized: "user.profile.follow")
        followConfig?.image = UIImage(systemName: state.isFollowed ? "person.badge.minus.fill" : "person.badge.plus.fill")
        followButton.configuration = followConfig

        moreButton.menu = makeMoreMenu(isCurrentUser: isCurrentUser)
        configureFilterPostsButton()
    }

    private func configureFilterPostsButton() {
        let canFilter = onFilterPostsByUsername != nil
        filterPostsButton.isHidden = !canFilter
        guard canFilter else { return }
        var config = filterPostsButton.configuration
        config?.title = isFilteringThisUser
            ? String(localized: "user.profile.filter_posts.cancel", defaultValue: "取消只看此人")
            : String(localized: "user.profile.filter_posts", defaultValue: "只看此人")
        config?.image = UIImage(
            systemName: isFilteringThisUser
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
        )
        filterPostsButton.configuration = config
        filterPostsButton.accessibilityLabel = config?.title
    }

    private func makeMoreMenu(isCurrentUser: Bool) -> UIMenu {
        let state = viewModel.relationshipController.state
        var children: [UIMenuElement] = []

        if onFilterPostsByUsername != nil {
            children.append(UIAction(
                title: isFilteringThisUser
                    ? String(localized: "user.profile.filter_posts.cancel", defaultValue: "取消只看此人")
                    : String(localized: "user.profile.filter_posts", defaultValue: "只看此人"),
                image: UIImage(
                    systemName: isFilteringThisUser
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            ) { [weak self] _ in
                self?.filterPostsTapped()
            })
        }

        if !isCurrentUser {
            if state.isMuted || state.isIgnored {
                children.append(UIAction(
                    title: String(localized: "user.profile.restore_notifications", defaultValue: "Restore notifications"),
                    image: UIImage(systemName: "bell")
                ) { [weak self] _ in
                    self?.performRelationshipMutation(.restore)
                })
            } else {
                if state.canMute {
                    children.append(UIAction(
                        title: String(localized: "user.profile.mute", defaultValue: "Mute"),
                        image: UIImage(systemName: "speaker.slash")
                    ) { [weak self] _ in
                        self?.performRelationshipMutation(.mute)
                    })
                }
                if state.canIgnore {
                    children.append(makeIgnoreMenu())
                }
            }
        }

        children.append(UIAction(
            title: String(localized: "user.profile.share", defaultValue: "Share user"),
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.shareUser()
        })
        return UIMenu(children: children)
    }

    private func makeIgnoreMenu() -> UIMenu {
        let calendar = Calendar.current
        let now = Date()
        let presets: [(String, Date)] = [
            (String(localized: "user.profile.ignore.day", defaultValue: "For one day"), calendar.date(byAdding: .day, value: 1, to: now) ?? now),
            (String(localized: "user.profile.ignore.week", defaultValue: "For one week"), calendar.date(byAdding: .day, value: 7, to: now) ?? now),
            (String(localized: "user.profile.ignore.month", defaultValue: "For one month"), calendar.date(byAdding: .month, value: 1, to: now) ?? now),
        ]
        var actions: [UIAction] = presets.map { title, expiry in
            UIAction(title: title, image: UIImage(systemName: "clock")) { [weak self] _ in
                self?.performRelationshipMutation(.ignore(until: expiry))
            }
        }
        actions.append(UIAction(
            title: String(localized: "user.profile.ignore.custom", defaultValue: "Custom date"),
            image: UIImage(systemName: "calendar")
        ) { [weak self] _ in
            self?.showCustomIgnorePicker()
        })
        return UIMenu(
            title: String(localized: "user.profile.ignore", defaultValue: "Ignore"),
            image: UIImage(systemName: "person.crop.circle.badge.xmark"),
            children: actions
        )
    }

    private func performRelationshipMutation(_ mutation: UserRelationshipMutation) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { @MainActor [weak self] in
            await self?.viewModel.relationshipController.perform(mutation)
        }
    }

    private func showCustomIgnorePicker() {
        let picker = UIDatePicker()
        picker.datePickerMode = .dateAndTime
        picker.preferredDatePickerStyle = .inline
        picker.minimumDate = Date().addingTimeInterval(60 * 10)
        picker.date = Date().addingTimeInterval(60 * 60 * 24)
        picker.translatesAutoresizingMaskIntoConstraints = false

        let controller = UIViewController()
        controller.view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: controller.view.topAnchor),
            picker.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])
        controller.preferredContentSize = CGSize(width: 330, height: 360)

        let alert = UIAlertController(
            title: String(localized: "user.profile.ignore", defaultValue: "Ignore"),
            message: nil,
            preferredStyle: .alert
        )
        alert.setValue(controller, forKey: "contentViewController")
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: String(localized: "action.confirm", defaultValue: "Confirm"),
            style: .default
        ) { [weak self] _ in
            self?.performRelationshipMutation(.ignore(until: picker.date))
        })
        present(alert, animated: true)
    }

    private func shareUser() {
        let username = viewModel.userCard?.username ?? viewModel.userProfile?.username ?? viewModel.username
        let base = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/u/\(username)") else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = moreButton
        activity.popoverPresentationController?.sourceRect = moreButton.bounds
        present(activity, animated: true)
    }

    private func presentRelationshipErrorIfNeeded() {
        guard let message = viewModel.relationshipController.state.errorMessage,
              message != lastPresentedRelationshipError,
              presentedViewController == nil
        else { return }
        lastPresentedRelationshipError = message
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel) { [weak self] _ in
            self?.viewModel.relationshipController.clearError()
        })
        present(alert, animated: true)
    }

    private func makeMetaChip(symbolName: String, text: String) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: symbolName))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.font = AppSettings.shared.appInterfaceFont(
            ofSize: 12,
            weight: .medium,
            fallback: .systemFont(ofSize: 12, weight: .medium)
        )
        label.textColor = .secondaryLabel
        label.text = text
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.layer.cornerRadius = 8
        stack.layer.cornerCurve = .continuous
        stack.backgroundColor = AppSettings.shared.themeStyle.topicChipBackgroundColor
        stack.setContentHuggingPriority(.required, for: .horizontal)
        stack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
        ])

        return stack
    }

    private func makeInlineMetricText(items: [(String, String)], baseSize: CGFloat, separator: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let labelFont = AppSettings.shared.appInterfaceFont(
            ofSize: baseSize,
            weight: .medium,
            fallback: .systemFont(ofSize: baseSize, weight: .medium)
        )
        let valueFont = AppSettings.shared.appInterfaceFont(
            ofSize: baseSize,
            weight: .heavy,
            fallback: .systemFont(ofSize: baseSize, weight: .heavy)
        )

        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: separator))
            }
            result.append(NSAttributedString(
                string: "\(item.0) ",
                attributes: [.font: labelFont, .foregroundColor: UIColor.secondaryLabel]
            ))
            result.append(NSAttributedString(
                string: item.1,
                attributes: [.font: valueFont, .foregroundColor: UIColor.label]
            ))
        }
        return result
    }

    private func makeActionButton(title: String, symbolName: String, style: ActionButtonStyle) -> UIButton {
        var config: UIButton.Configuration = style == .filled ? .filled() : .tinted()
        config.title = title
        config.image = UIImage(systemName: symbolName)
        config.imagePadding = 6
        config.cornerStyle = .large
        config.baseForegroundColor = style == .filled ? .white : AppSettings.shared.themeStyle.accentColor
        config.baseBackgroundColor = AppSettings.shared.themeStyle.accentColor
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        config.titleTextAttributesTransformer = compactButtonTextAttributes(size: 14)
        let button = ProfilePreviewButton(type: .system)
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func compactButtonTextAttributes(size: CGFloat) -> UIConfigurationTextAttributesTransformer {
        let font = AppSettings.shared.appInterfaceFont(
            ofSize: size,
            weight: .bold,
            fallback: .systemFont(ofSize: size, weight: .bold)
        )
        return UIConfigurationTextAttributesTransformer { attributes in
            var updated = attributes
            updated.font = font
            return updated
        }
    }

    private func applyTheme() {
        let theme = AppSettings.shared.themeStyle
        let cardBackground = theme.topicCardBackgroundColor
        let resolvedCardBackground = cardBackground.resolvedColor(with: traitCollection)
        cardView.backgroundColor = .clear
        clipView.backgroundColor = cardBackground
        cardView.layer.borderWidth = 0.5
        cardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.28).cgColor
        backgroundScrimView.topColor = cardBackground.withAlphaComponent(0.45)
        backgroundScrimView.bottomColor = cardBackground.withAlphaComponent(0.92)

        avatarHaloView.backgroundColor = cardBackground
        avatarHaloView.layer.borderColor = resolvedCardBackground.cgColor
        flairImageView.backgroundColor = cardBackground
        flairImageView.layer.borderColor = resolvedCardBackground.cgColor

        levelLabel.backgroundColor = theme.accentColor.withAlphaComponent(0.16)
        levelLabel.textColor = theme.accentColor
        viewProfileButton.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        moreButton.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        locationWebsiteStack.arrangedSubviews.forEach {
            $0.backgroundColor = theme.topicChipBackgroundColor
        }
        skeletonView.applyThemeStyle()

        var messageConfig = messageButton.configuration
        messageConfig?.baseBackgroundColor = theme.accentColor
        messageConfig?.baseForegroundColor = .white
        messageButton.configuration = messageConfig

        var followConfig = followButton.configuration
        followConfig?.baseBackgroundColor = theme.accentColor.withAlphaComponent(0.16)
        followConfig?.baseForegroundColor = theme.accentColor
        followButton.configuration = followConfig

        var profileConfig = viewProfileButton.configuration
        profileConfig?.baseForegroundColor = .label
        viewProfileButton.configuration = profileConfig

        var filterConfig = filterPostsButton.configuration
        filterConfig?.baseBackgroundColor = theme.accentColor.withAlphaComponent(0.16)
        filterConfig?.baseForegroundColor = theme.accentColor
        filterPostsButton.configuration = filterConfig
    }

    private func resolvedFlairURL(_ flairUrl: String?) -> URL? {
        guard let flairUrl = flairUrl?.trimmedNonEmpty else { return nil }
        if flairUrl.hasPrefix(":") && flairUrl.hasSuffix(":") {
            let emojiName = String(flairUrl.dropFirst().dropLast())
            if EmojiStore.lookupMap.isEmpty {
                _ = EmojiStore.load(for: api.baseURL)
            }
            guard let urlString = EmojiStore.url(for: emojiName) else { return nil }
            return URL(string: urlString)
        }
        if let absoluteURL = URL(string: flairUrl), absoluteURL.scheme != nil {
            return absoluteURL
        }
        let normalizedPath = flairUrl.hasPrefix("/") ? flairUrl : "/\(flairUrl)"
        return URL(string: api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + normalizedPath)
    }

    private func resolvedBackgroundURL(_ rawURL: String?) -> URL? {
        guard let rawURL = rawURL?.trimmedNonEmpty else { return nil }
        if rawURL.hasPrefix("//") {
            return URL(string: "https:\(rawURL)")
        }
        if let absoluteURL = URL(string: rawURL), absoluteURL.scheme != nil {
            return absoluteURL
        }
        let normalizedBase = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        return URL(string: rawURL, relativeTo: URL(string: normalizedBase))?.absoluteURL
    }

    @objc private func copyUsernameTapped() {
        UIPasteboard.general.string = viewModel.username
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DoerFeedback.presentToast(
            String(localized: "user.profile.username_copied", defaultValue: "用户名已复制"),
            on: self
        )
    }

    @objc private func backgroundTapped() {
        dismiss(animated: true)
    }

    @objc private func filterPostsTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let username = viewModel.userCard?.username ?? viewModel.userProfile?.username ?? viewModel.username
        let handler = onFilterPostsByUsername
        dismiss(animated: true) {
            handler?(username)
        }
    }

    @objc private func viewProfileTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let username = viewModel.userProfile?.username ?? viewModel.username
        dismiss(animated: true) { [onViewProfile] in
            onViewProfile?(username)
        }
    }

    @objc private func messageTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let username = viewModel.userCard?.username ?? viewModel.userProfile?.username ?? viewModel.username
        let composer = PrivateMessageComposerViewController(api: api, recipient: username)
        present(UINavigationController(rootViewController: composer), animated: true)
    }

    @objc private func followTapped() {
        performRelationshipMutation(.toggleFollow)
    }

    private enum ActionButtonStyle: Equatable {
        case filled
        case tinted
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private final class ProfileCardScrimView: UIView {
    var topColor: UIColor = .clear {
        didSet { setNeedsLayout() }
    }
    var bottomColor: UIColor = .clear {
        didSet { setNeedsLayout() }
    }

    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(gradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
        gradientLayer.colors = [topColor.cgColor, bottomColor.cgColor]
    }
}
