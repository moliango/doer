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
    private let cloudflareRow = DataManagementActionRowView()
    private let providerRow = DataManagementActionRowView()
    private let customURLRow = DataManagementActionRowView()
    private let statusRow = DataManagementActionRowView()
    private let gatewayRow = ReadingToggleRowView()
    private let h2Row = ReadingToggleRowView()
    private let ipv6Row = ReadingToggleRowView()
    private let cacheRow = DataManagementActionRowView()
    private let echRow = DataManagementActionRowView()
    private let serverIPRow = DataManagementActionRowView()
    private let upstreamRow = DataManagementActionRowView()
    private let avatarLoadingCard = AvatarLoadingProfileCardView()
    private let debugLogRow = DataManagementActionRowView()

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
        providerRow.addTarget(self, action: #selector(pickProvider), for: .touchUpInside)
        customURLRow.addTarget(self, action: #selector(editCustomURL), for: .touchUpInside)
        cacheRow.addTarget(self, action: #selector(clearDNSCache), for: .touchUpInside)
        serverIPRow.addTarget(self, action: #selector(editServerIP), for: .touchUpInside)
        upstreamRow.addTarget(self, action: #selector(editUpstream), for: .touchUpInside)
        debugLogRow.addTarget(self, action: #selector(openDebugLog), for: .touchUpInside)
        gatewayRow.onValueChanged = { [weak self] isOn in
            self?.settings.dohGatewayEnabled = isOn
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        }
        h2Row.onValueChanged = { [weak self] isOn in
            self?.settings.dohH2Mitm = isOn
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        }
        ipv6Row.onValueChanged = { [weak self] isOn in
            self?.settings.dohPreferIPv6 = isOn
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        }
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

        let proxyStack = UIStackView(arrangedSubviews: [
            dohToggleRow, providerRow, customURLRow, statusRow,
            gatewayRow, h2Row, ipv6Row, echRow, cacheRow, serverIPRow, upstreamRow,
        ])
        proxyStack.axis = .vertical
        proxyStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.section.proxy", defaultValue: "网络代理"),
            symbolName: "lock.shield",
            body: proxyStack
        ))

        let auxStack = UIStackView(arrangedSubviews: [cloudflareRow, avatarLoadingCard])
        auxStack.axis = .vertical
        auxStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.section.auxiliary", defaultValue: "辅助功能"),
            symbolName: "slider.horizontal.3",
            body: auxStack
        ))

        let debugStack = UIStackView(arrangedSubviews: [debugLogRow])
        debugStack.axis = .vertical
        debugStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.section.debug", defaultValue: "调试"),
            symbolName: "ant.fill",
            body: debugStack
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

        let customDetail = settings.dohServerURL.isEmpty
            ? String(localized: "settings.not_set")
            : settings.dohServerURL
        providerRow.configure(
            title: String(localized: "settings.network.provider"),
            subtitle: settings.dohProvider.title,
            symbolName: "server.rack",
            tintColor: accent,
            backgroundColor: card
        )
        customURLRow.configure(
            title: String(localized: "settings.network.custom_url"),
            subtitle: customDetail,
            symbolName: "link",
            tintColor: accent,
            backgroundColor: card
        )
        statusRow.configure(
            title: String(localized: "settings.network.doh_status", defaultValue: "DoH 状态"),
            subtitle: LightweightDohProxyService.shared.statusDescription,
            symbolName: "waveform.path.ecg",
            tintColor: accent,
            backgroundColor: card
        )
        // Status is informational; don't look tappable.
        statusRow.isUserInteractionEnabled = false
        statusRow.alpha = 0.92

        gatewayRow.configure(
            title: String(localized: "settings.network.gateway", defaultValue: "Gateway 反代"),
            subtitle: String(localized: "settings.network.gateway.subtitle", defaultValue: "API 走 127.0.0.1 明文，Cookie 仍用原域名"),
            symbolName: "arrow.triangle.swap",
            isOn: settings.dohGatewayEnabled,
            accentColor: accent,
            backgroundColor: card
        )
        h2Row.configure(
            title: String(localized: "settings.network.h2", defaultValue: "h2 MITM"),
            subtitle: String(localized: "settings.network.h2.subtitle", defaultValue: "关闭锁 HTTP/1.1，打开协商 HTTP/2"),
            symbolName: "point.3.connected.trianglepath.dotted",
            isOn: settings.dohH2Mitm,
            accentColor: accent,
            backgroundColor: card
        )
        ipv6Row.configure(
            title: String(localized: "settings.network.ipv6", defaultValue: "IPv6 优先"),
            subtitle: String(localized: "settings.network.ipv6.subtitle", defaultValue: "DoH bootstrap 与解析优先 AAAA"),
            symbolName: "network",
            isOn: settings.dohPreferIPv6,
            accentColor: accent,
            backgroundColor: card
        )
        let stats = LightweightDohProxyService.shared.resolverCacheStats()
        cacheRow.configure(
            title: String(localized: "settings.network.dns_cache", defaultValue: "DNS 缓存"),
            subtitle: "\(stats.hostEntries) · "
                + String(localized: "settings.network.dns_cache.clear", defaultValue: "点按清空"),
            symbolName: "internaldrive",
            tintColor: accent,
            backgroundColor: card
        )
        echRow.configure(
            title: String(localized: "settings.network.ech", defaultValue: "ECH"),
            subtitle: stats.echAvailable > 0
                ? String(localized: "settings.network.ech.on", defaultValue: "已解析到 ECH 配置")
                : String(localized: "settings.network.ech.off", defaultValue: "无 ECH"),
            symbolName: "eye.slash",
            tintColor: accent,
            backgroundColor: card
        )
        echRow.isUserInteractionEnabled = false
        serverIPRow.configure(
            title: String(localized: "settings.network.server_ip", defaultValue: "固定 server IP"),
            subtitle: settings.dohServerIP.isEmpty
                ? String(localized: "settings.not_set")
                : settings.dohServerIP,
            symbolName: "number",
            tintColor: accent,
            backgroundColor: card
        )
        let upstream = settings.dohUpstreamHost.isEmpty
            ? String(localized: "settings.not_set")
            : "\(settings.dohUpstreamProtocol) \(settings.dohUpstreamHost):\(settings.dohUpstreamPort)"
        upstreamRow.configure(
            title: String(localized: "settings.network.upstream", defaultValue: "上游代理"),
            subtitle: upstream,
            symbolName: "point.topleft.down.to.point.bottomright.curvepath",
            tintColor: accent,
            backgroundColor: card
        )
        if #unavailable(iOS 17.0) {
            statusRow.configure(
                title: String(localized: "settings.network.doh_status", defaultValue: "DoH 状态"),
                subtitle: LightweightDohProxyService.shared.statusDescription
                    + " · "
                    + String(localized: "settings.network.ios15.webview", defaultValue: "iOS 15–16 浏览器无 CONNECT MITM"),
                symbolName: "waveform.path.ecg",
                tintColor: accent,
                backgroundColor: card
            )
        }

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
        debugLogRow.configure(
            title: String(localized: "settings.network.debug_log", defaultValue: "调试日志"),
            subtitle: String(
                localized: "settings.network.debug_log.subtitle",
                defaultValue: "查看并复制最近 200 行"
            ),
            symbolName: "doc.text.magnifyingglass",
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

    @objc private func pickProvider() {
        let alert = UIAlertController(
            title: String(localized: "settings.network.provider"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for provider in AppSettings.DoHProvider.allCases {
            let action = UIAlertAction(title: provider.title, style: .default) { [weak self] _ in
                self?.settings.dohProvider = provider
                LightweightDohProxyService.shared.configureFromSettings()
                self?.refreshDataViews()
            }
            action.setValue(provider == settings.dohProvider, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = providerRow
        alert.popoverPresentationController?.sourceRect = providerRow.bounds
        present(alert, animated: true)
    }

    @objc private func editCustomURL() {
        let alert = UIAlertController(
            title: String(localized: "settings.network.custom_url"),
            message: String(localized: "settings.network.custom_url.message"),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] textField in
            guard let self else { return }
            textField.text = settings.dohCustomURL.isEmpty ? settings.dohServerURL : settings.dohCustomURL
            textField.placeholder = "https://dns.alidns.com/dns-query"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            let value = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.settings.dohCustomURL = value
            if !value.isEmpty {
                self?.settings.dohProvider = .custom
            }
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func openDebugLog() {
        navigationController?.pushViewController(DohDebugLogViewController(), animated: true)
    }

    @objc private func clearDNSCache() {
        LightweightDohProxyService.shared.clearCache()
        refreshDataViews()
    }

    @objc private func editServerIP() {
        let alert = UIAlertController(
            title: String(localized: "settings.network.server_ip", defaultValue: "固定 server IP"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.text = self?.settings.dohServerIP
            field.placeholder = "1.2.3.4"
            field.keyboardType = .decimalPad
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            self?.settings.dohServerIP = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func editUpstream() {
        let alert = UIAlertController(
            title: String(localized: "settings.network.upstream", defaultValue: "上游代理"),
            message: String(localized: "settings.network.upstream.message", defaultValue: "host:port，留空关闭"),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.text = self?.settings.dohUpstreamHost
            field.placeholder = "host"
        }
        alert.addTextField { [weak self] field in
            field.text = self?.settings.dohUpstreamPort == 0 ? "" : "\(self?.settings.dohUpstreamPort ?? 0)"
            field.placeholder = "port"
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            self?.settings.dohUpstreamHost = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self?.settings.dohUpstreamPort = Int(alert.textFields?.dropFirst().first?.text ?? "") ?? 0
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
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
