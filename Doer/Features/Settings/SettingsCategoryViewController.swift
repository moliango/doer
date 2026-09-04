import UIKit

final class SettingsCategoryViewController: ObservableViewController {
    private let settings = AppSettings.shared
    private let category: SettingsViewController.Category

    private enum Row {
        case appearanceMode
        case appLanguage
        case themeStyle
        case readingComfort
        case contentFontSize
        case hideScrollIndicators
        case dohToggle
        case dohDebugLog
        case dohStatus
        case dohProvider
        case dohCustomURL
        case avatarLoadingProfile
        case cloudflareVerify
        case bottomBarLayout
        case bottomAutoHide
        case clearImageCache
        case autoOpen
        case currentVersion
        case checkForUpdates
        case automaticUpdateCheck
        case githubReleases
        #if DEBUG
        case renderPreview
        #endif
    }

    // MARK: legacy table path (kept for any residual category routing)
    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .systemGroupedBackground
        table.dataSource = self
        table.delegate = self
        return table
    }()

    init(category: SettingsViewController.Category) {
        self.category = category
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(settings)
        title = category.title
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
    }

    override func updateUI() {
        title = category.title
        tableView.reloadData()
    }

    private var rows: [Row] {
        switch category {
        case .appearance:
            return [.appearanceMode, .appLanguage, .themeStyle]
        case .reading:
            return [.readingComfort, .contentFontSize, .hideScrollIndicators]
        case .network:
            return [.cloudflareVerify, .avatarLoadingProfile, .dohToggle, .dohProvider, .dohCustomURL, .dohStatus]
        case .preferences, .notion, .miniPrograms:
            return []
        case .bottomBar:
            return [.bottomBarLayout, .bottomAutoHide]
        case .dataManagement:
            return [.clearImageCache, .autoOpen]
        case .about:
            return [.currentVersion, .checkForUpdates, .automaticUpdateCheck, .githubReleases]
        }
    }
}

// ponytail: SettingsCategoryViewController remains as a thin legacy fallback; hub routes no longer use it for primary categories.

extension SettingsCategoryViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        switch row {
        case .appearanceMode:
            return valueCell(title: String(localized: "settings.dark_mode"), detail: settings.appearanceMode.title)
        case .appLanguage:
            return valueCell(title: String(localized: "settings.language"), detail: settings.appLanguage.title)
        case .themeStyle:
            return valueCell(title: String(localized: "settings.theme_style"), detail: settings.themeStyle.title)
        case .readingComfort:
            return switchCell(title: String(localized: "settings.reading.comfort"), isOn: settings.readingComfortMode, action: #selector(readingComfortChanged(_:)))
        case .contentFontSize:
            return valueCell(title: String(localized: "settings.content_font_size"), detail: "\(settings.contentFontScalePercent)%")
        case .hideScrollIndicators:
            return switchCell(title: String(localized: "settings.reading.hide_scroll_indicators"), isOn: settings.hideScrollIndicators, action: #selector(hideScrollIndicatorsChanged(_:)))
        case .dohToggle:
            return switchCell(title: "DNS over HTTPS", isOn: settings.dohEnabled, action: #selector(dohToggleChanged(_:)))
        case .dohDebugLog:
            return valueCell(title: "调试日志", detail: "查看并复制最近 200 行")
        case .dohStatus:
            return infoCell(title: "DoH 状态", detail: LightweightDohProxyService.shared.statusDescription)
        case .dohProvider:
            return valueCell(title: String(localized: "settings.network.provider"), detail: settings.dohProvider.title)
        case .dohCustomURL:
            return valueCell(
                title: String(localized: "settings.network.custom_url"),
                detail: settings.dohServerURL.isEmpty ? String(localized: "settings.not_set") : settings.dohServerURL
            )
        case .avatarLoadingProfile:
            let profile = settings.avatarLoadingProfile
            return valueCell(
                title: String(localized: "settings.network.avatar_loading", defaultValue: "头像加载强度"),
                detail: "\(profile.title) · \(profile.summary)"
            )
        case .cloudflareVerify:
            let hasClearance = URL(string: ForumInstance.linuxDoBaseURL)
                .map { WebCookieStore.shared.hasCookie(named: "cf_clearance", for: $0) } ?? false
            return valueCell(
                title: String(localized: "settings.network.cloudflare_verify"),
                detail: hasClearance
                    ? String(localized: "settings.network.cloudflare_ready")
                    : String(localized: "settings.network.cloudflare_required")
            )
        case .bottomBarLayout:
            return valueCell(
                title: String(localized: "settings.bottom_bar"),
                detail: bottomBarLayoutSummary()
            )
        case .bottomAutoHide:
            return switchCell(title: String(localized: "settings.bottom_bar.auto_hide"), isOn: settings.bottomBarAutoHideEnabled, action: #selector(bottomAutoHideChanged(_:)))
        case .clearImageCache:
            return valueCell(title: String(localized: "settings.data.clear_image_cache"), detail: nil)
        case .autoOpen:
            return switchCell(title: String(localized: "settings.auto_open_last_forum"), isOn: settings.autoOpenLastForum, action: #selector(autoOpenToggleChanged(_:)))
        case .currentVersion:
            return infoCell(
                title: String(localized: "settings.update.current_version"),
                detail: AppVersion.installed().displayString
            )
        case .checkForUpdates:
            return valueCell(title: String(localized: "settings.update.check_now"), detail: nil)
        case .automaticUpdateCheck:
            return switchCell(
                title: String(localized: "settings.update.auto_check"),
                isOn: settings.autoCheckForUpdates,
                action: #selector(autoCheckForUpdatesChanged(_:))
            )
        case .githubReleases:
            return valueCell(title: String(localized: "settings.update.release_page"), detail: nil)
        #if DEBUG
        case .renderPreview:
            return valueCell(title: "Render Preview", detail: nil)
        #endif
        }
    }

    private func valueCell(title: String, detail: String?) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.textColor = detail == nil ? .placeholderText : .secondaryLabel
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func switchCell(title: String, isOn: Bool, action: Selector) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func infoCell(title: String, detail: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = title
        cell.detailTextLabel?.text = detail
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2
        cell.selectionStyle = .none
        return cell
    }
}

extension SettingsCategoryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows[indexPath.row]
        switch row {
        case .appearanceMode:
            showAppearancePicker(sourceView: tableView.cellForRow(at: indexPath))
        case .appLanguage:
            showLanguagePicker(sourceView: tableView.cellForRow(at: indexPath))
        case .themeStyle:
            showThemeStylePicker(sourceView: tableView.cellForRow(at: indexPath))
        case .contentFontSize:
            showContentFontSizePicker(sourceView: tableView.cellForRow(at: indexPath))
        case .dohProvider:
            showDohProviderPicker(sourceView: tableView.cellForRow(at: indexPath))
        case .dohCustomURL:
            showCustomURLInput()
        case .avatarLoadingProfile:
            showAvatarLoadingProfilePicker(sourceView: tableView.cellForRow(at: indexPath))
        case .dohDebugLog:
            navigationController?.pushViewController(DohDebugLogViewController(), animated: true)
        case .cloudflareVerify:
            guard let baseURL = URL(string: ForumInstance.linuxDoBaseURL) else { return }
            Task { @MainActor [weak self] in
                await CloudflareBackgroundVerificationService.shared.beginForegroundVerification(
                    baseURL: baseURL
                )
                guard let self, let navigationController = self.navigationController else {
                    CloudflareBackgroundVerificationService.shared.endForegroundVerification(
                        baseURL: baseURL
                    )
                    return
                }
                let vc = CloudflareVerificationViewController(baseURL: baseURL) { [weak self] in
                    CloudflareBackgroundVerificationService.shared.endForegroundVerification(
                        baseURL: baseURL
                    )
                    self?.tableView.reloadData()
                }
                navigationController.pushViewController(vc, animated: true)
            }
        case .bottomBarLayout:
            navigationController?.pushViewController(BottomBarLayoutViewController(), animated: true)
        case .clearImageCache:
            clearImageCache()
        case .checkForUpdates:
            AppUpdateCoordinator.shared.checkManually(from: self)
        case .githubReleases:
            AppUpdateCoordinator.openReleasePage()
        #if DEBUG
        case .renderPreview:
            showRenderPreviewInput()
        #endif
        default:
            break
        }
    }
}

extension SettingsCategoryViewController {
    @objc func autoOpenToggleChanged(_ sender: UISwitch) {
        settings.autoOpenLastForum = sender.isOn
    }

    @objc func autoCheckForUpdatesChanged(_ sender: UISwitch) {
        settings.autoCheckForUpdates = sender.isOn
        AppUpdateCoordinator.shared.automaticCheckPreferenceDidChange()
    }

    @objc func readingComfortChanged(_ sender: UISwitch) {
        settings.readingComfortMode = sender.isOn
    }

    @objc func hideScrollIndicatorsChanged(_ sender: UISwitch) {
        settings.hideScrollIndicators = sender.isOn
    }

    @objc func bottomAutoHideChanged(_ sender: UISwitch) {
        settings.bottomBarAutoHideEnabled = sender.isOn
    }

    func bottomBarLayoutSummary() -> String {
        let visibleItems = settings.forumVisibleDynamicTabItems.map(\.title).joined(separator: " / ")
        if visibleItems.isEmpty {
            return String(
                localized: "settings.bottom_bar.summary_empty",
                defaultValue: "当前实际底栏：首页 + 我的。"
            )
        }
        return String(
            format: String(
                localized: "settings.bottom_bar.summary_format",
                defaultValue: "当前实际底栏：首页 + %@ + 我的。"
            ),
            visibleItems
        )
    }

    @objc func dohToggleChanged(_ sender: UISwitch) {
        settings.dohEnabled = sender.isOn
        LightweightDohProxyService.shared.configureFromSettings()
        tableView.reloadData()
    }

    func showAppearancePicker(sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.dark_mode"), message: nil, preferredStyle: .actionSheet)
        for mode in AppSettings.AppearanceMode.allCases {
            let action = UIAlertAction(title: mode.title, style: .default) { [weak self] _ in
                self?.settings.appearanceMode = mode
                self?.tableView.reloadData()
            }
            action.setValue(mode == settings.appearanceMode, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView ?? view
        alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
        present(alert, animated: true)
    }

    func showLanguagePicker(sourceView: UIView?) {
        let alert = UIAlertController(
            title: String(localized: "settings.language"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for language in AppSettings.AppLanguage.allCases {
            let action = UIAlertAction(title: language.title, style: .default) { [weak self] _ in
                guard let self else { return }
                settings.appLanguage = language
                tableView.reloadData()
            }
            action.setValue(language == settings.appLanguage, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView ?? view
        alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
        present(alert, animated: true)
    }

    func showThemeStylePicker(sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.theme_style"), message: nil, preferredStyle: .actionSheet)
        for style in AppSettings.ThemeStyle.allCases {
            let action = UIAlertAction(title: style.title, style: .default) { [weak self] _ in
                guard let self else { return }
                settings.themeStyle = style
                tableView.reloadData()
            }
            action.setValue(style == settings.themeStyle, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView ?? view
        alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
        present(alert, animated: true)
    }

    func showContentFontSizePicker(sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.content_font_size"), message: nil, preferredStyle: .actionSheet)
        let presetValues = [30, 50, 70, 90, 100, 110, 120, 150]
        for value in presetValues {
            let action = UIAlertAction(title: "\(value)%", style: .default) { [weak self] _ in
                guard let self else { return }
                settings.contentFontSize = .standard
                settings.contentFontScalePercent = value
                tableView.reloadData()
            }
            action.setValue(value == settings.contentFontScalePercent, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView ?? view
        alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
        present(alert, animated: true)
    }

    func showDohProviderPicker(sourceView: UIView?) {
        let alert = UIAlertController(title: String(localized: "settings.network.provider"), message: nil, preferredStyle: .actionSheet)
        for provider in AppSettings.DoHProvider.allCases {
            let action = UIAlertAction(title: provider.title, style: .default) { [weak self] _ in
                self?.settings.dohProvider = provider
                LightweightDohProxyService.shared.configureFromSettings()
                self?.tableView.reloadData()
            }
            action.setValue(provider == settings.dohProvider, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView ?? view
        alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
        present(alert, animated: true)
    }

    func showAvatarLoadingProfilePicker(sourceView: UIView?) {
        let alert = UIAlertController(
            title: String(localized: "settings.network.avatar_loading", defaultValue: "头像加载强度"),
            message: String(localized: "settings.network.avatar_loading.message", defaultValue: "格式为：最大下载并发 / 最大预取并发 / 首页头像预取数量。高档就是当前默认值。"),
            preferredStyle: .actionSheet
        )
        for profile in AppSettings.AvatarLoadingProfile.allCases {
            let action = UIAlertAction(title: "\(profile.title) · \(profile.summary)", style: .default) { [weak self] _ in
                guard let self else { return }
                settings.avatarLoadingProfile = profile
                AvatarImageLoader.configureGlobalImageLoading()
                tableView.reloadData()
                DohDebugLog.record(
                    "avatar loading profile changed profile=\(profile.title) maxDownloads=\(profile.maxConcurrentDownloads) maxPrefetch=\(profile.maxConcurrentPrefetchCount) homePrefetch=\(profile.homeAvatarPrefetchLimit)",
                    subsystem: "Avatar"
                )
            }
            action.setValue(profile == settings.avatarLoadingProfile, forKey: "checked")
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = sourceView ?? view
        alert.popoverPresentationController?.sourceRect = sourceView?.bounds ?? view.bounds
        present(alert, animated: true)
    }

    func showCustomURLInput() {
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
            self?.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func clearImageCache() {
        AvatarImageLoader.clearAllCaches { [weak self] in
            let alert = UIAlertController(
                title: nil,
                message: String(localized: "settings.data.cache_cleared"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
            self?.present(alert, animated: true)
        }
    }

    #if DEBUG
    func showRenderPreviewInput() {
        let alert = UIAlertController(title: "Render Preview", message: "Enter Topic URL", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "https://linux.do/t/topic/12345"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
            guard let self,
                  let text = alert.textFields?.first?.text,
                  let url = URL(string: text),
                  let host = url.host,
                  let topicId = url.pathComponents.last.flatMap(Int.init)
            else { return }
            let scheme = url.scheme ?? "https"
            let api = DiscourseAPI(baseURL: "\(scheme)://\(host)")
            let vc = TopicDetailFactory.make(api: api, topicId: topicId)
            self.navigationController?.pushViewController(vc, animated: true)
        })
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        present(alert, animated: true)
    }
    #endif
}
