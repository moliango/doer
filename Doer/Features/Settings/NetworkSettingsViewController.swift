import DohProxy
import UIKit

final class NetworkSettingsViewController: ObservableViewController {
    private let settings = AppSettings.shared

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        return scroll
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 22
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 32, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let dohToggleRow = ReadingToggleRowView()
    private let statusRow = DataManagementActionRowView()
    private let testRow = DataManagementActionRowView()
    private let moreRow = DataManagementActionRowView()
    private let cloudflareRow = DataManagementActionRowView()
    private let healthRow = DataManagementActionRowView()
    private let avatarLoadingCard = AvatarLoadingProfileCardView()
    private var lastProbe: LightweightDohProxyService.ProbeResult?
    private var isProbing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(settings)
        title = String(localized: "settings.network")
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        dohToggleRow.onValueChanged = { [weak self] isOn in
            guard let self else { return }
            settings.dohEnabled = isOn
            LightweightDohProxyService.shared.configureFromSettings()
            refreshDataViews()
        }
        cloudflareRow.addTarget(self, action: #selector(openCloudflare), for: .touchUpInside)
        testRow.addTarget(self, action: #selector(testDoH), for: .touchUpInside)
        moreRow.addTarget(self, action: #selector(openDoHDetail), for: .touchUpInside)
        healthRow.addTarget(self, action: #selector(openHealth), for: .touchUpInside)
        avatarLoadingCard.onValueChanged = { [weak self] profile in
            guard let self else { return }
            settings.avatarLoadingProfile = profile
            AvatarImageLoader.configureGlobalImageLoading()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            refreshDataViews()
        }

        rebuildContent()
        refreshDataViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
        refreshDataViews()
    }

    override func updateUI() {
        title = String(localized: "settings.network")
        rebuildContent()
        refreshDataViews()
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        let dohRows: [UIView] = [dohToggleRow, statusRow, testRow, moreRow]
        let dohStack = UIStackView(arrangedSubviews: dohRows)
        dohStack.axis = .vertical
        dohStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.section.doh", defaultValue: "DNS over HTTPS"),
            symbolName: "lock.shield",
            body: dohStack
        ))

        let auxStack = UIStackView(arrangedSubviews: [cloudflareRow, healthRow, avatarLoadingCard])
        auxStack.axis = .vertical
        auxStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.section.auxiliary", defaultValue: "辅助功能"),
            symbolName: "slider.horizontal.3",
            body: auxStack
        ))
    }

    private func makeSection(title: String, symbolName: String, body: UIView) -> UIView {
        let section = UIStackView()
        section.axis = .vertical
        section.spacing = 12
        section.translatesAutoresizingMaskIntoConstraints = false
        section.addArrangedSubview(
            DataManagementSectionHeaderView(
                title: title,
                symbolName: symbolName,
                tintColor: settings.themeStyle.accentColor
            )
        )
        section.addArrangedSubview(body)
        return section
    }

    private func refreshDataViews() {
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        let card = settings.themeStyle.topicCardBackgroundColor
        let accent = settings.themeStyle.accentColor

        dohToggleRow.configure(
            title: "DNS over HTTPS",
            subtitle: String(
                localized: "settings.network.doh.subtitle",
                defaultValue: "在 App 内解析 linux.do，不用去系统设置"
            ),
            symbolName: "network.badge.shield.half.filled",
            isOn: settings.dohEnabled,
            accentColor: accent,
            backgroundColor: card
        )

        statusRow.configure(
            title: String(localized: "settings.network.doh_status", defaultValue: "状态"),
            subtitle: LightweightDohProxyService.shared.statusDescription
                + " · "
                + settings.dohProvider.title,
            symbolName: "checkmark.circle",
            tintColor: accent,
            backgroundColor: card
        )
        statusRow.isUserInteractionEnabled = false
        statusRow.alpha = 0.92

        let testSubtitle: String
        if isProbing {
            testSubtitle = String(localized: "settings.network.doh_test.running", defaultValue: "测试中…")
        } else if let lastProbe {
            testSubtitle = lastProbe.subtitle
        } else {
            testSubtitle = String(
                localized: "settings.network.doh_test.idle",
                defaultValue: "解析 linux.do，确认当前服务器能用"
            )
        }
        testRow.configure(
            title: String(localized: "settings.network.doh_test", defaultValue: "测试 DoH"),
            subtitle: testSubtitle,
            symbolName: "speedometer",
            tintColor: accent,
            backgroundColor: card
        )
        testRow.isUserInteractionEnabled = !isProbing
        testRow.alpha = isProbing ? 0.7 : 1

        moreRow.configure(
            title: String(localized: "settings.network.more", defaultValue: "更多设置"),
            subtitle: String(
                localized: "settings.network.more.subtitle",
                defaultValue: "服务器、缓存与高级选项"
            ),
            symbolName: "slider.horizontal.3",
            tintColor: accent,
            backgroundColor: card
        )

        let hasClearance = URL(string: ForumInstance.linuxDoBaseURL)
            .map { WebCookieStore.shared.hasCookie(named: "cf_clearance", for: $0) } ?? false
        cloudflareRow.configure(
            title: String(localized: "settings.network.cloudflare_verify"),
            subtitle: hasClearance
                ? String(localized: "settings.network.cloudflare_ready")
                : String(localized: "settings.network.cloudflare_required"),
            symbolName: "checkmark.shield.fill",
            tintColor: accent,
            backgroundColor: card
        )
        cloudflareRow.isUserInteractionEnabled = true
        cloudflareRow.alpha = 1

        avatarLoadingCard.configure(
            profile: settings.avatarLoadingProfile,
            accentColor: accent,
            backgroundColor: card
        )

        healthRow.configure(
            title: String(localized: "network.health.title", defaultValue: "网络健康"),
            subtitle: String(
                localized: "network.health.subtitle",
                defaultValue: "只读查看当前通道、盾态、CSRF 与并发"
            ),
            symbolName: "heart.text.square",
            tintColor: accent,
            backgroundColor: card
        )
    }

    @objc private func openCloudflare() {
        guard let baseURL = URL(string: ForumInstance.linuxDoBaseURL) else { return }
        Task { @MainActor [weak self] in
            await CloudflareBackgroundVerificationService.shared.beginForegroundVerification(baseURL: baseURL)
            guard let self, let navigationController else {
                CloudflareBackgroundVerificationService.shared.endForegroundVerification(baseURL: baseURL)
                return
            }
            let vc = CloudflareVerificationViewController(baseURL: baseURL) { [weak self] in
                CloudflareBackgroundVerificationService.shared.endForegroundVerification(baseURL: baseURL)
                self?.refreshDataViews()
            }
            navigationController.pushViewController(vc, animated: true)
        }
    }

    @objc private func testDoH() {
        guard !isProbing else { return }
        isProbing = true
        refreshDataViews()
        LightweightDohProxyService.shared.probe { [weak self] result in
            guard let self else { return }
            self.isProbing = false
            self.lastProbe = result
            self.refreshDataViews()
        }
    }

    @objc private func openDoHDetail() {
        navigationController?.pushViewController(DohDetailSettingsViewController(), animated: true)
    }

    @objc private func openHealth() {
        let api = ForumAPILookup.discourseAPI(from: self)
        navigationController?.pushViewController(
            NetworkHealthViewController(snapshot: .capture(api: api)),
            animated: true
        )
    }
}

/// Three-step slider for avatar loading: 低 / 中 / 高.
final class AvatarLoadingProfileCardView: UIView {
    var onValueChanged: ((AppSettings.AvatarLoadingProfile) -> Void)?

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let slider = UISlider()
    private let lowLabel = UILabel()
    private let mediumLabel = UILabel()
    private let highLabel = UILabel()
    private var currentProfile: AppSettings.AvatarLoadingProfile = .high
    private var committedProfile: AppSettings.AvatarLoadingProfile = .high
    private var accentColor = UIColor.systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DataManagementPalette.borderColor.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 5)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 13
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.isUserInteractionEnabled = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(
            systemName: "person.crop.circle.badge.checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        )
        iconContainer.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.text = String(localized: "settings.network.avatar_loading", defaultValue: "头像加载强度")
        titleLabel.isUserInteractionEnabled = false

        valueLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        valueLabel.textColor = .secondaryLabel
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.isUserInteractionEnabled = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isUserInteractionEnabled = false

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8
        titleRow.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        let header = UIStackView(arrangedSubviews: [iconContainer, textStack])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isUserInteractionEnabled = false

        slider.minimumValue = 0
        slider.maximumValue = 2
        // Three discrete stops: low / medium / high.
        if #available(iOS 15.0, *) {
            // Keep continuous for smoother drag; we snap on change/end.
        }
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.translatesAutoresizingMaskIntoConstraints = false

        configureTickLabel(lowLabel, text: String(localized: "settings.network.avatar_loading.low", defaultValue: "低"))
        configureTickLabel(mediumLabel, text: String(localized: "settings.network.avatar_loading.medium", defaultValue: "中"))
        configureTickLabel(highLabel, text: String(localized: "settings.network.avatar_loading.high", defaultValue: "高"))
        mediumLabel.textAlignment = .center
        highLabel.textAlignment = .right

        let ticks = UIStackView(arrangedSubviews: [lowLabel, mediumLabel, highLabel])
        ticks.axis = .horizontal
        ticks.distribution = .fillEqually
        ticks.alignment = .center
        ticks.translatesAutoresizingMaskIntoConstraints = false
        ticks.isUserInteractionEnabled = false

        let body = UIStackView(arrangedSubviews: [header, slider, ticks])
        body.axis = .vertical
        body.spacing = 14
        body.isLayoutMarginsRelativeArrangement = true
        body.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        accessibilityTraits = [.adjustable]
    }

    private func configureTickLabel(_ label: UILabel, text: String) {
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .tertiaryLabel
    }

    func configure(
        profile: AppSettings.AvatarLoadingProfile,
        accentColor: UIColor,
        backgroundColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        self.accentColor = accentColor
        self.currentProfile = profile
        self.committedProfile = profile
        layer.shadowColor = accentColor.cgColor
        layer.borderColor = accentColor.withAlphaComponent(0.14).cgColor
        iconContainer.backgroundColor = accentColor.withAlphaComponent(0.14)
        iconView.tintColor = accentColor
        slider.minimumTrackTintColor = accentColor
        slider.maximumTrackTintColor = accentColor.withAlphaComponent(0.18)
        slider.thumbTintColor = accentColor
        slider.setValue(Float(profile.rawValue), animated: false)
        applyProfileLabels(profile)
        accessibilityValue = "\(profile.title)，\(profile.summary)"
        accessibilityLabel = String(localized: "settings.network.avatar_loading", defaultValue: "头像加载强度")
    }

    private func applyProfileLabels(_ profile: AppSettings.AvatarLoadingProfile) {
        valueLabel.text = profile.title
        subtitleLabel.text = String(
            format: String(
                localized: "settings.network.avatar_loading.summary_format",
                defaultValue: "下载 %@ · 预取 %@ · 首页 %@"
            ),
            "\(profile.maxConcurrentDownloads)",
            "\(profile.maxConcurrentPrefetchCount)",
            "\(profile.homeAvatarPrefetchLimit)"
        )

        let active = accentColor
        let inactive = UIColor.tertiaryLabel
        lowLabel.textColor = profile == .low ? active : inactive
        mediumLabel.textColor = profile == .medium ? active : inactive
        highLabel.textColor = profile == .high ? active : inactive
        lowLabel.font = .systemFont(ofSize: 12, weight: profile == .low ? .bold : .semibold)
        mediumLabel.font = .systemFont(ofSize: 12, weight: profile == .medium ? .bold : .semibold)
        highLabel.font = .systemFont(ofSize: 12, weight: profile == .high ? .bold : .semibold)
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let snapped = snappedProfile(for: sender.value)
        if snapped != currentProfile {
            currentProfile = snapped
            applyProfileLabels(snapped)
        }
        // Keep thumb near the discrete stop while dragging.
        sender.setValue(Float(snapped.rawValue), animated: false)
    }

    @objc private func sliderEnded(_ sender: UISlider) {
        let snapped = snappedProfile(for: sender.value)
        sender.setValue(Float(snapped.rawValue), animated: true)
        currentProfile = snapped
        applyProfileLabels(snapped)
        guard snapped != committedProfile else { return }
        committedProfile = snapped
        onValueChanged?(snapped)
    }

    private func snappedProfile(for value: Float) -> AppSettings.AvatarLoadingProfile {
        let raw = Int((value + 0.5).rounded(.down))
        return AppSettings.AvatarLoadingProfile(rawValue: max(0, min(2, raw))) ?? .high
    }

    override func accessibilityIncrement() {
        let next = min(2, currentProfile.rawValue + 1)
        let profile = AppSettings.AvatarLoadingProfile(rawValue: next) ?? .high
        guard profile != committedProfile else { return }
        slider.setValue(Float(profile.rawValue), animated: true)
        currentProfile = profile
        committedProfile = profile
        applyProfileLabels(profile)
        onValueChanged?(profile)
    }

    override func accessibilityDecrement() {
        let next = max(0, currentProfile.rawValue - 1)
        let profile = AppSettings.AvatarLoadingProfile(rawValue: next) ?? .low
        guard profile != committedProfile else { return }
        slider.setValue(Float(profile.rawValue), animated: true)
        currentProfile = profile
        committedProfile = profile
        applyProfileLabels(profile)
        onValueChanged?(profile)
    }
}

/// Four-step slider for avatar/image cache size: 500MB / 1GB / 1.5GB / 2GB.
final class AvatarCacheSizeCardView: UIView {
    var onValueChanged: ((AppSettings.AvatarCacheSizeLimit) -> Void)?

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let slider = UISlider()
    private let tickLabels: [UILabel] = AppSettings.AvatarCacheSizeLimit.allCases.map { _ in UILabel() }
    private var currentLimit: AppSettings.AvatarCacheSizeLimit = .mb500
    private var committedLimit: AppSettings.AvatarCacheSizeLimit = .mb500
    private var accentColor = UIColor.systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DataManagementPalette.borderColor.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 5)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 13
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.isUserInteractionEnabled = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(
            systemName: "internaldrive",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        )
        iconContainer.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.text = String(localized: "settings.data.avatar_cache_size", defaultValue: "头像缓存上限")
        titleLabel.isUserInteractionEnabled = false

        valueLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        valueLabel.textColor = .secondaryLabel
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.isUserInteractionEnabled = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isUserInteractionEnabled = false

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8
        titleRow.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleRow, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.isUserInteractionEnabled = false

        let header = UIStackView(arrangedSubviews: [iconContainer, textStack])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        header.isUserInteractionEnabled = false

        let maxIndex = Float(AppSettings.AvatarCacheSizeLimit.allCases.count - 1)
        slider.minimumValue = 0
        slider.maximumValue = maxIndex
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.translatesAutoresizingMaskIntoConstraints = false

        for (index, limit) in AppSettings.AvatarCacheSizeLimit.allCases.enumerated() {
            let label = tickLabels[index]
            configureTickLabel(label, text: limit.shortTickTitle)
            if index == 0 {
                label.textAlignment = .left
            } else if index == AppSettings.AvatarCacheSizeLimit.allCases.count - 1 {
                label.textAlignment = .right
            } else {
                label.textAlignment = .center
            }
        }

        let ticks = UIStackView(arrangedSubviews: tickLabels)
        ticks.axis = .horizontal
        ticks.distribution = .fillEqually
        ticks.alignment = .center
        ticks.translatesAutoresizingMaskIntoConstraints = false
        ticks.isUserInteractionEnabled = false

        let body = UIStackView(arrangedSubviews: [header, slider, ticks])
        body.axis = .vertical
        body.spacing = 14
        body.isLayoutMarginsRelativeArrangement = true
        body.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        accessibilityTraits = [.adjustable]
    }

    private func configureTickLabel(_ label: UILabel, text: String) {
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .tertiaryLabel
    }

    func configure(
        limit: AppSettings.AvatarCacheSizeLimit,
        accentColor: UIColor,
        backgroundColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        self.accentColor = accentColor
        self.currentLimit = limit
        self.committedLimit = limit
        layer.shadowColor = accentColor.cgColor
        layer.borderColor = accentColor.withAlphaComponent(0.14).cgColor
        iconContainer.backgroundColor = accentColor.withAlphaComponent(0.14)
        iconView.tintColor = accentColor
        slider.minimumTrackTintColor = accentColor
        slider.maximumTrackTintColor = accentColor.withAlphaComponent(0.18)
        slider.thumbTintColor = accentColor
        slider.setValue(Float(limit.rawValue), animated: false)
        applyLimitLabels(limit)
        accessibilityValue = "\(limit.title)，\(limit.summary)"
        accessibilityLabel = String(localized: "settings.data.avatar_cache_size", defaultValue: "头像缓存上限")
    }

    private func applyLimitLabels(_ limit: AppSettings.AvatarCacheSizeLimit) {
        valueLabel.text = limit.title
        subtitleLabel.text = limit.summary

        let active = accentColor
        let inactive = UIColor.tertiaryLabel
        for (index, caseLimit) in AppSettings.AvatarCacheSizeLimit.allCases.enumerated() {
            let label = tickLabels[index]
            let isActive = caseLimit == limit
            label.textColor = isActive ? active : inactive
            label.font = .systemFont(ofSize: 12, weight: isActive ? .bold : .semibold)
        }
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let snapped = snappedLimit(for: sender.value)
        if snapped != currentLimit {
            currentLimit = snapped
            applyLimitLabels(snapped)
        }
        sender.setValue(Float(snapped.rawValue), animated: false)
    }

    @objc private func sliderEnded(_ sender: UISlider) {
        let snapped = snappedLimit(for: sender.value)
        sender.setValue(Float(snapped.rawValue), animated: true)
        currentLimit = snapped
        applyLimitLabels(snapped)
        guard snapped != committedLimit else { return }
        committedLimit = snapped
        onValueChanged?(snapped)
    }

    private func snappedLimit(for value: Float) -> AppSettings.AvatarCacheSizeLimit {
        let maxRaw = AppSettings.AvatarCacheSizeLimit.allCases.count - 1
        let raw = Int((value + 0.5).rounded(.down))
        return AppSettings.AvatarCacheSizeLimit(rawValue: max(0, min(maxRaw, raw))) ?? .mb500
    }

    override func accessibilityIncrement() {
        let maxRaw = AppSettings.AvatarCacheSizeLimit.allCases.count - 1
        let next = min(maxRaw, currentLimit.rawValue + 1)
        let limit = AppSettings.AvatarCacheSizeLimit(rawValue: next) ?? .gb2
        guard limit != committedLimit else { return }
        slider.setValue(Float(limit.rawValue), animated: true)
        currentLimit = limit
        committedLimit = limit
        applyLimitLabels(limit)
        onValueChanged?(limit)
    }

    override func accessibilityDecrement() {
        let next = max(0, currentLimit.rawValue - 1)
        let limit = AppSettings.AvatarCacheSizeLimit(rawValue: next) ?? .mb500
        guard limit != committedLimit else { return }
        slider.setValue(Float(limit.rawValue), animated: true)
        currentLimit = limit
        committedLimit = limit
        applyLimitLabels(limit)
        onValueChanged?(limit)
    }
}
