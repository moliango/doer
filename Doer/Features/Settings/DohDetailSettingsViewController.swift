import DohProxy
import UIKit

/// FluxDo-style DoH detail: server list, speed test, cache, advanced.
final class DohDetailSettingsViewController: ObservableViewController {
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

    private let testAllRow = DataManagementActionRowView()
    private let addServerRow = DataManagementActionRowView()
    private let cacheRow = DataManagementActionRowView()
    private let gatewayRow = ReadingToggleRowView()
    private let h2Row = ReadingToggleRowView()
    private let ipv6Row = ReadingToggleRowView()
    private let echRow = DataManagementActionRowView()
    private let echServerRow = DataManagementActionRowView()
    private let serverIPRow = DataManagementActionRowView()
    private let bootstrapRow = DataManagementActionRowView()
    private let upstreamRow = DataManagementActionRowView()
    private let debugLogRow = DataManagementActionRowView()

    private var builtInRows: [AppSettings.DoHProvider: DohServerRowView] = [:]
    private var customRows: [String: DohServerRowView] = [:]
    private var latencies: [String: LightweightDohProxyService.ProbeResult] = [:]
    private var testingURLs: Set<String> = []
    private var testingAll = false

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(settings)
        title = String(localized: "settings.network.doh_detail", defaultValue: "DoH 设置")
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

        for provider in AppSettings.DoHProvider.builtInDisplayOrder {
            let row = DohServerRowView()
            row.onSelect = { [weak self] in self?.select(provider) }
            row.onTest = { [weak self] in self?.test(url: provider.url, bootstrap: provider.bootstrapIPs) }
            builtInRows[provider] = row
        }

        testAllRow.addTarget(self, action: #selector(testAllServers), for: .touchUpInside)
        addServerRow.addTarget(self, action: #selector(addCustomServer), for: .touchUpInside)
        cacheRow.addTarget(self, action: #selector(clearDNSCache), for: .touchUpInside)
        echServerRow.addTarget(self, action: #selector(editEchServer), for: .touchUpInside)
        serverIPRow.addTarget(self, action: #selector(editServerIP), for: .touchUpInside)
        bootstrapRow.addTarget(self, action: #selector(editBootstrapIPs), for: .touchUpInside)
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

        rebuildContent()
        refreshDataViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
        refreshDataViews()
    }

    override func updateUI() {
        title = String(localized: "settings.network.doh_detail", defaultValue: "DoH 设置")
        rebuildContent()
        refreshDataViews()
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        var serverViews: [UIView] = [testAllRow, addServerRow]
        for provider in AppSettings.DoHProvider.builtInDisplayOrder {
            if let row = builtInRows[provider] {
                serverViews.append(row)
            }
        }
        for server in settings.dohCustomServers {
            serverViews.append(customRow(for: server))
        }
        let serverStack = UIStackView(arrangedSubviews: serverViews)
        serverStack.axis = .vertical
        serverStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.doh_detail.servers", defaultValue: "服务器"),
            symbolName: "server.rack",
            body: serverStack
        ))

        let advancedStack = UIStackView(arrangedSubviews: [
            cacheRow, gatewayRow, h2Row, ipv6Row, echRow, echServerRow, bootstrapRow, serverIPRow, upstreamRow,
        ])
        advancedStack.axis = .vertical
        advancedStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.network.doh_detail.advanced", defaultValue: "高级"),
            symbolName: "gearshape",
            body: advancedStack
        ))

        let debugStack = UIStackView(arrangedSubviews: [debugLogRow])
        debugStack.axis = .vertical
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

        testAllRow.configure(
            title: String(localized: "settings.network.doh_test.all", defaultValue: "测试全部服务器"),
            subtitle: testingAll
                ? String(localized: "settings.network.doh_test.running", defaultValue: "测试中…")
                : String(localized: "settings.network.doh_test.all.subtitle", defaultValue: "用当前列表解析 linux.do"),
            symbolName: "speedometer",
            tintColor: accent,
            backgroundColor: card
        )
        testAllRow.isUserInteractionEnabled = !testingAll
        testAllRow.alpha = testingAll ? 0.7 : 1

        addServerRow.configure(
            title: String(localized: "settings.network.doh_server.add", defaultValue: "添加服务器"),
            subtitle: String(
                localized: "settings.network.doh_server.add.subtitle",
                defaultValue: "自定义 DoH 地址，长按可删除"
            ),
            symbolName: "plus.circle",
            tintColor: accent,
            backgroundColor: card
        )

        for provider in AppSettings.DoHProvider.builtInDisplayOrder {
            guard let row = builtInRows[provider] else { continue }
            configureServerRow(
                row,
                title: provider.title,
                url: provider.url,
                selected: settings.dohProvider == provider,
                accent: accent,
                background: card
            )
        }
        for server in settings.dohCustomServers {
            configureServerRow(
                customRow(for: server),
                title: server.name,
                url: server.url,
                selected: settings.dohProvider == .custom && settings.dohCustomURL == server.url,
                accent: accent,
                background: card
            )
        }

        let stats = LightweightDohProxyService.shared.resolverCacheStats()
        cacheRow.configure(
            title: String(localized: "settings.network.dns_cache", defaultValue: "DNS 缓存"),
            subtitle: "\(stats.hostEntries) · "
                + String(localized: "settings.network.dns_cache.clear", defaultValue: "点按清空"),
            symbolName: "internaldrive",
            tintColor: accent,
            backgroundColor: card
        )
        gatewayRow.configure(
            title: String(localized: "settings.network.gateway", defaultValue: "Gateway 反代"),
            subtitle: String(
                localized: "settings.network.gateway.subtitle",
                defaultValue: "仅在 ECH 可用时生效"
            ),
            symbolName: "arrow.triangle.swap",
            isOn: settings.dohGatewayEnabled,
            accentColor: accent,
            backgroundColor: card
        )
        h2Row.configure(
            title: String(localized: "settings.network.h2", defaultValue: "h2 MITM"),
            subtitle: String(
                localized: "settings.network.h2.subtitle",
                defaultValue: "仅在 ECH 可用时生效"
            ),
            symbolName: "point.3.connected.trianglepath.dotted",
            isOn: settings.dohH2Mitm,
            accentColor: accent,
            backgroundColor: card
        )
        ipv6Row.configure(
            title: String(localized: "settings.network.ipv6", defaultValue: "IPv6 优先"),
            subtitle: String(localized: "settings.network.ipv6.subtitle", defaultValue: "DoH 解析优先 AAAA"),
            symbolName: "network",
            isOn: settings.dohPreferIPv6,
            accentColor: accent,
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
        echServerRow.configure(
            title: String(localized: "settings.network.ech.server", defaultValue: "ECH 查询服务器"),
            subtitle: settings.dohEchServerURL.isEmpty
                ? String(localized: "settings.network.ech.server.same", defaultValue: "与 DoH 相同")
                : settings.dohEchServerURL,
            symbolName: "lock.square",
            tintColor: accent,
            backgroundColor: card
        )
        let bootstrapIPs = settings.bootstrapIPs(forServerURL: currentDoHServerURL)
        bootstrapRow.configure(
            title: String(localized: "settings.network.bootstrap", defaultValue: "Bootstrap IP"),
            subtitle: bootstrapIPs.isEmpty
                ? String(localized: "settings.not_set")
                : bootstrapIPs.joined(separator: ", "),
            symbolName: "point.3.connected.trianglepath.dotted",
            tintColor: accent,
            backgroundColor: card
        )
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

    private func configureServerRow(
        _ row: DohServerRowView,
        title: String,
        url: String,
        selected: Bool,
        accent: UIColor,
        background: UIColor
    ) {
        let subtitle: String
        if testingURLs.contains(url) {
            subtitle = String(localized: "settings.network.doh_test.running", defaultValue: "测试中…")
        } else if let result = latencies[url] {
            subtitle = result.ok
                ? "\(result.latencyMs) ms"
                : (result.errorDescription ?? String(localized: "settings.network.doh_test.failed", defaultValue: "测试失败"))
        } else {
            let ips = settings.bootstrapIPs(forServerURL: url)
            if ips.isEmpty {
                subtitle = url
            } else {
                subtitle = url + "\n" + ips.joined(separator: ", ")
            }
        }
        row.configure(
            title: title,
            subtitle: subtitle,
            selected: selected,
            testing: testingURLs.contains(url),
            accentColor: accent,
            backgroundColor: background
        )
    }

    private func customRow(for server: AppSettings.CustomDoHServer) -> DohServerRowView {
        if let existing = customRows[server.url] { return existing }
        let row = DohServerRowView()
        row.accessibilityIdentifier = server.url
        row.onSelect = { [weak self] in self?.selectCustom(server) }
        row.onTest = { [weak self] in
            self?.test(
                url: server.url,
                bootstrap: AppSettings.lockedBootstrapIPs(for: server.url, extras: server.bootstrapIPs)
            )
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleCustomLongPress(_:)))
        row.addGestureRecognizer(longPress)
        customRows[server.url] = row
        return row
    }

    private func select(_ provider: AppSettings.DoHProvider) {
        settings.selectDoHServer(provider: provider)
        LightweightDohProxyService.shared.configureFromSettings()
        refreshDataViews()
    }

    private func selectCustom(_ server: AppSettings.CustomDoHServer) {
        settings.selectCustomDoHServer(server)
        LightweightDohProxyService.shared.configureFromSettings()
        refreshDataViews()
    }

    private func test(url: String, bootstrap: [String]) {
        guard !url.isEmpty, !testingURLs.contains(url) else { return }
        testingURLs.insert(url)
        refreshDataViews()
        LightweightDohProxyService.shared.probe(serverURL: url, bootstrapIPs: bootstrap) { [weak self] result in
            guard let self else { return }
            self.testingURLs.remove(url)
            self.latencies[url] = result
            self.refreshDataViews()
        }
    }

    @objc private func testAllServers() {
        guard !testingAll else { return }
        testingAll = true
        refreshDataViews()
        let group = DispatchGroup()
        for provider in AppSettings.DoHProvider.builtInDisplayOrder {
            group.enter()
            testingURLs.insert(provider.url)
            LightweightDohProxyService.shared.probe(
                serverURL: provider.url,
                bootstrapIPs: provider.bootstrapIPs
            ) { [weak self] result in
                self?.testingURLs.remove(provider.url)
                self?.latencies[provider.url] = result
                self?.refreshDataViews()
                group.leave()
            }
        }
        for server in settings.dohCustomServers {
            group.enter()
            testingURLs.insert(server.url)
            LightweightDohProxyService.shared.probe(
                serverURL: server.url,
                bootstrapIPs: AppSettings.lockedBootstrapIPs(for: server.url, extras: server.bootstrapIPs)
            ) { [weak self] result in
                self?.testingURLs.remove(server.url)
                self?.latencies[server.url] = result
                self?.refreshDataViews()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.testingAll = false
            self?.refreshDataViews()
        }
        refreshDataViews()
    }

    @objc private func addCustomServer() {
        let alert = UIAlertController(
            title: String(localized: "settings.network.doh_server.add", defaultValue: "添加服务器"),
            message: String(
                localized: "settings.network.doh_server.add.message",
                defaultValue: "填写名称和 https:// 地址。系统锁定的 Bootstrap IP 不能删除，可追加。"
            ),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "settings.network.doh_server.name", defaultValue: "名称")
        }
        alert.addTextField { field in
            field.placeholder = "https://dns.example.com/dns-query"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = String(
                localized: "settings.network.bootstrap.message",
                defaultValue: "Bootstrap IP，逗号分隔，如 1.1.1.1, 1.0.0.1"
            )
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            let name = alert.textFields?.first?.text ?? ""
            let url = alert.textFields?.dropFirst().first?.text ?? ""
            let bootstrap = AppSettings.parseBootstrapIPs(alert.textFields?.dropFirst(2).first?.text ?? "")
            guard let self, let server = self.settings.addCustomDoHServer(
                name: name,
                url: url,
                bootstrapIPs: bootstrap
            ) else {
                return
            }
            self.settings.selectCustomDoHServer(server)
            LightweightDohProxyService.shared.configureFromSettings()
            self.rebuildContent()
            self.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func handleCustomLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let row = gesture.view as? DohServerRowView,
              let url = row.accessibilityIdentifier
        else { return }
        let alert = UIAlertController(
            title: String(localized: "settings.network.doh_server.delete", defaultValue: "删除服务器"),
            message: url,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "action.delete", defaultValue: "删除"),
            style: .destructive
        ) { [weak self] _ in
            self?.settings.removeCustomDoHServer(url: url)
            self?.customRows.removeValue(forKey: url)
            LightweightDohProxyService.shared.configureFromSettings()
            self?.rebuildContent()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = row
        alert.popoverPresentationController?.sourceRect = row.bounds
        present(alert, animated: true)
    }

    @objc private func clearDNSCache() {
        LightweightDohProxyService.shared.clearCache()
        refreshDataViews()
    }

    @objc private func editEchServer() {
        let alert = UIAlertController(
            title: String(localized: "settings.network.ech.server", defaultValue: "ECH 查询服务器"),
            message: String(
                localized: "settings.network.ech.server.message",
                defaultValue: "HTTPS 记录查询 URL，留空则与 DoH 相同"
            ),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.text = self?.settings.dohEchServerURL
            field.placeholder = "https://cloudflare-dns.com/dns-query"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            self?.settings.dohEchServerURL = (alert.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private var currentDoHServerURL: String {
        settings.dohProvider == .custom ? settings.dohCustomURL : settings.dohProvider.url
    }

    @objc private func editBootstrapIPs() {
        let url = currentDoHServerURL
        let locked = DohServerCatalog.inferredBootstrapIPs(for: url)
        let current = settings.bootstrapIPs(forServerURL: url)
        let intro = String(
            localized: "settings.network.bootstrap.edit.message",
            defaultValue: "可追加 IP，系统锁定的地址不会被删除。"
        )
        let alert = UIAlertController(
            title: String(localized: "settings.network.bootstrap", defaultValue: "Bootstrap IP"),
            message: locked.isEmpty ? intro : intro + "\n锁定：\(locked.joined(separator: ", "))",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = current.joined(separator: ", ")
            field.placeholder = "1.1.1.1, 1.0.0.1"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default) { [weak self] _ in
            let parsed = AppSettings.parseBootstrapIPs(alert.textFields?.first?.text ?? "")
            self?.settings.setBootstrapIPs(parsed, forServerURL: url)
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
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
            self?.settings.dohServerIP = (alert.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
            self?.settings.dohUpstreamHost = (alert.textFields?.first?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self?.settings.dohUpstreamPort = Int(alert.textFields?.dropFirst().first?.text ?? "") ?? 0
            LightweightDohProxyService.shared.configureFromSettings()
            self?.refreshDataViews()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func openDebugLog() {
        navigationController?.pushViewController(DohDebugLogViewController(), animated: true)
    }
}

/// Server card: tap to select, speed button tests that server only.
final class DohServerRowView: UIControl {
    var onSelect: (() -> Void)?
    var onTest: (() -> Void)?

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let testButton = UIButton(type: .system)

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
        heightAnchor.constraint(greaterThanOrEqualToConstant: 66).isActive = true
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
        iconContainer.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.isUserInteractionEnabled = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.setImage(
            UIImage(systemName: "speedometer", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)),
            for: .normal
        )
        testButton.accessibilityLabel = String(localized: "settings.network.doh_test", defaultValue: "测试 DoH")
        testButton.addAction(UIAction { [weak self] _ in self?.onTest?() }, for: .touchUpInside)

        addSubview(iconContainer)
        addSubview(textStack)
        addSubview(testButton)
        addAction(UIAction { [weak self] _ in self?.onSelect?() }, for: .touchUpInside)

        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -8),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            testButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            testButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            testButton.widthAnchor.constraint(equalToConstant: 44),
            testButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        accessibilityTraits = [.button]
    }

    func configure(
        title: String,
        subtitle: String,
        selected: Bool,
        testing: Bool,
        accentColor: UIColor,
        backgroundColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        layer.shadowColor = accentColor.cgColor
        layer.borderColor = accentColor.withAlphaComponent(selected ? 0.35 : 0.14).cgColor
        iconContainer.backgroundColor = accentColor.withAlphaComponent(0.14)
        iconView.image = UIImage(
            systemName: selected ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        )
        iconView.tintColor = accentColor
        titleLabel.text = title
        subtitleLabel.text = subtitle
        testButton.tintColor = accentColor
        testButton.isEnabled = !testing
        testButton.alpha = testing ? 0.4 : 1
        accessibilityLabel = "\(title)，\(subtitle)"
    }
}
