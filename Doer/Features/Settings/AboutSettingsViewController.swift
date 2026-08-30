import UIKit

final class AboutSettingsViewController: ObservableViewController {
    private enum Link {
        static let source = URL(string: "https://github.com/moliango/doer")!
        static let issues = URL(string: "https://github.com/moliango/doer/issues")!
    }

    private let settings = AppSettings.shared
    private let checkUpdateRow = DataManagementActionRowView()
    private let githubProxyRow = DataManagementActionRowView()
    private let licenseRow = DataManagementActionRowView()
    private let sourceRow = DataManagementActionRowView()
    private let logsRow = DataManagementActionRowView()
    private let perfRow = DataManagementActionRowView()
    private let feedbackRow = DataManagementActionRowView()
    private let developerModeRow = ReadingToggleRowView()

    private let versionLabel = UILabel()
    private var versionTapCount = 0
    private var lastVersionTapAt: Date?

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
        stack.spacing = 24
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 18, bottom: 36, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(settings)
        title = String(localized: "settings.about", defaultValue: "关于")
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

        checkUpdateRow.addTarget(self, action: #selector(checkForUpdates), for: .touchUpInside)
        githubProxyRow.addTarget(self, action: #selector(editGithubProxy), for: .touchUpInside)
        licenseRow.addTarget(self, action: #selector(openLicenses), for: .touchUpInside)
        sourceRow.addTarget(self, action: #selector(openSource), for: .touchUpInside)
        logsRow.addTarget(self, action: #selector(openLogs), for: .touchUpInside)
        perfRow.addTarget(self, action: #selector(openPerf), for: .touchUpInside)
        feedbackRow.addTarget(self, action: #selector(openFeedback), for: .touchUpInside)
        developerModeRow.onValueChanged = { [weak self] isOn in
            guard let self, !isOn else { return }
            AboutDeveloperMode.setEnabled(false)
            refreshDataViews()
            rebuildContent()
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
        title = String(localized: "settings.about", defaultValue: "关于")
        rebuildContent()
        refreshDataViews()
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        contentStack.addArrangedSubview(makeHero())

        let infoStack = UIStackView(arrangedSubviews: [checkUpdateRow, githubProxyRow, licenseRow])
        infoStack.axis = .vertical
        infoStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.about.section.info", defaultValue: "信息"),
            body: infoStack
        ))

        var developRows: [UIView] = []
        if AboutDeveloperMode.isEnabled {
            developRows.append(developerModeRow)
        }
        developRows.append(contentsOf: [sourceRow, logsRow, perfRow, feedbackRow])
        let developStack = UIStackView(arrangedSubviews: developRows)
        developStack.axis = .vertical
        developStack.spacing = 12
        contentStack.addArrangedSubview(makeSection(
            title: String(localized: "settings.about.section.develop", defaultValue: "开发"),
            body: developStack
        ))

        let footer = UILabel()
        footer.text = String(
            localized: "settings.about.footer",
            defaultValue: "Made with UIKit & ❤️"
        )
        footer.font = .systemFont(ofSize: 13, weight: .medium)
        footer.textColor = .tertiaryLabel
        footer.textAlignment = .center
        contentStack.addArrangedSubview(footer)
    }

    private func makeHero() -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = UIImageView(image: Self.appIconImage())
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFill
        iconView.clipsToBounds = true
        iconView.layer.cornerRadius = 50
        iconView.layer.cornerCurve = .continuous
        iconView.backgroundColor = settings.themeStyle.accentColor.withAlphaComponent(0.12)
        iconView.widthAnchor.constraint(equalToConstant: 100).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 100).isActive = true
        if iconView.image == nil {
            iconView.image = UIImage(
                systemName: "app.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 42, weight: .semibold)
            )
            iconView.tintColor = settings.themeStyle.accentColor
            iconView.contentMode = .center
        }

        let nameLabel = UILabel()
        nameLabel.text = "Doer"
        nameLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.textAlignment = .center

        versionLabel.font = .systemFont(ofSize: 15, weight: .regular)
        versionLabel.textColor = .secondaryLabel
        versionLabel.textAlignment = .center
        versionLabel.isUserInteractionEnabled = true
        versionLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleVersionTap))
        )

        container.addArrangedSubview(iconView)
        container.setCustomSpacing(20, after: iconView)
        container.addArrangedSubview(nameLabel)
        container.setCustomSpacing(8, after: nameLabel)
        container.addArrangedSubview(versionLabel)
        return container
    }

    private func makeSection(title: String, body: UIView) -> UIView {
        let section = UIStackView()
        section.axis = .vertical
        section.spacing = 10
        section.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = settings.themeStyle.accentColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titlePad = UIView()
        titlePad.translatesAutoresizingMaskIntoConstraints = false
        titlePad.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: titlePad.leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titlePad.trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: titlePad.topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: titlePad.bottomAnchor),
        ])

        section.addArrangedSubview(titlePad)
        section.addArrangedSubview(body)
        return section
    }

    private func refreshDataViews() {
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        let card = settings.themeStyle.topicCardBackgroundColor
        let accent = settings.themeStyle.accentColor
        let version = AppVersion.installed()
        versionLabel.text = String(
            format: String(localized: "settings.about.version_format %@", defaultValue: "Version %@"),
            version.displayString
        )

        checkUpdateRow.configure(
            title: String(localized: "settings.update.check_now", defaultValue: "检查更新"),
            subtitle: String(
                localized: "settings.update.check_now.subtitle",
                defaultValue: "立即检查是否有新版本"
            ),
            symbolName: "arrow.triangle.2.circlepath",
            tintColor: accent,
            backgroundColor: card
        )
        let proxy = settings.githubProxyPrefix
        githubProxyRow.configure(
            title: String(localized: "update.github_proxy", defaultValue: "GitHub 镜像"),
            subtitle: proxy.isEmpty
                ? String(localized: "update.github_proxy.direct", defaultValue: "直连 GitHub")
                : proxy,
            symbolName: "arrow.triangle.branch",
            tintColor: accent,
            backgroundColor: card
        )
        licenseRow.configure(
            title: String(localized: "settings.about.open_source_license", defaultValue: "开源许可"),
            subtitle: String(
                localized: "settings.about.open_source_license.subtitle",
                defaultValue: "第三方依赖与许可证"
            ),
            symbolName: "doc.text",
            tintColor: accent,
            backgroundColor: card
        )
        sourceRow.configure(
            title: String(localized: "settings.about.source_code", defaultValue: "项目源码"),
            subtitle: "GitHub",
            symbolName: "chevron.left.forwardslash.chevron.right",
            tintColor: accent,
            backgroundColor: card
        )
        logsRow.configure(
            title: String(localized: "settings.about.app_logs", defaultValue: "应用日志"),
            subtitle: String(
                localized: "settings.about.app_logs.subtitle",
                defaultValue: "查看并复制最近调试日志"
            ),
            symbolName: "doc.plaintext",
            tintColor: accent,
            backgroundColor: card
        )
        perfRow.configure(
            title: String(localized: "settings.about.perf_diagnostics", defaultValue: "性能诊断"),
            subtitle: String(
                localized: "settings.about.perf_diagnostics.subtitle",
                defaultValue: "设备与运行时摘要"
            ),
            symbolName: "speedometer",
            tintColor: accent,
            backgroundColor: card
        )
        feedbackRow.configure(
            title: String(localized: "settings.about.feedback", defaultValue: "反馈问题"),
            subtitle: "GitHub Issues",
            symbolName: "ladybug",
            tintColor: accent,
            backgroundColor: card
        )
        if AboutDeveloperMode.isEnabled {
            developerModeRow.configure(
                title: String(localized: "settings.about.developer_mode", defaultValue: "开发者模式"),
                subtitle: String(
                    localized: "settings.about.developer_mode.subtitle",
                    defaultValue: "点击关闭开发者模式"
                ),
                symbolName: "hammer",
                isOn: true,
                accentColor: accent,
                backgroundColor: card
            )
        }
    }

    @objc private func handleVersionTap() {
        let now = Date()
        if let last = lastVersionTapAt, now.timeIntervalSince(last) > 2 {
            versionTapCount = 0
        }
        lastVersionTapAt = now
        versionTapCount += 1
        guard versionTapCount >= 7 else { return }
        versionTapCount = 0
        if AboutDeveloperMode.isEnabled {
            presentSimpleAlert(
                title: nil,
                message: String(
                    localized: "settings.about.developer_mode.already_enabled",
                    defaultValue: "开发者模式已启用"
                )
            )
            return
        }
        AboutDeveloperMode.setEnabled(true)
        rebuildContent()
        refreshDataViews()
        presentSimpleAlert(
            title: nil,
            message: String(
                localized: "settings.about.developer_mode.enabled",
                defaultValue: "已启用开发者模式"
            )
        )
    }

    @objc private func checkForUpdates() {
        AppUpdateCoordinator.shared.checkManually(from: self)
    }

    @objc private func editGithubProxy() {
        let alert = UIAlertController(
            title: String(localized: "update.github_proxy", defaultValue: "GitHub 镜像"),
            message: String(
                localized: "update.github_proxy.hint",
                defaultValue: "填写反代前缀，例如 https://ghproxy.com/ ，空则直连。"
            ),
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.placeholder = "https://ghproxy.com/"
            field.text = self?.settings.githubProxyPrefix
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.save", defaultValue: "保存"), style: .default) { [weak self] _ in
            guard let self else { return }
            let raw = alert.textFields?.first?.text ?? ""
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.settings.githubProxyPrefix = ""
                self.refreshDataViews()
                return
            }
            guard GitHubProxy.isValid(raw) else {
                let invalid = UIAlertController(
                    title: String(localized: "update.github_proxy", defaultValue: "GitHub 镜像"),
                    message: GitHubProxyError.invalidPrefix.localizedDescription,
                    preferredStyle: .alert
                )
                invalid.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
                self.present(invalid, animated: true)
                return
            }
            self.settings.githubProxyPrefix = raw
            self.refreshDataViews()
        })
        present(alert, animated: true)
    }

    @objc private func openLicenses() {
        navigationController?.pushViewController(OpenSourceLicensesViewController(), animated: true)
    }

    @objc private func openSource() {
        UIApplication.shared.open(Link.source)
    }

    @objc private func openLogs() {
        navigationController?.pushViewController(DohDebugLogViewController(), animated: true)
    }

    @objc private func openPerf() {
        navigationController?.pushViewController(PerfDiagnosticsViewController(), animated: true)
    }

    @objc private func openFeedback() {
        UIApplication.shared.open(Link.issues)
    }

    private func presentSimpleAlert(title: String?, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }

    private static func appIconImage() -> UIImage? {
        if let image = UIImage(named: "AboutAppIcon") { return image }
        if let image = UIImage(named: "AppIcon") { return image }
        if let image = UIImage(named: "launchImg") { return image }
        return nil
    }
}

enum AboutDeveloperMode {
    private static let key = "about.developerMode"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: key)
    }
}

final class OpenSourceLicensesViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private struct LicenseEntry {
        let name: String
        let license: String
        let detail: String
    }

    private let entries: [LicenseEntry] = [
        .init(
            name: "Alamofire",
            license: "MIT",
            detail: """
            Copyright (c) 2014-2022 Alamofire Software Foundation (http://alamofire.org/)

            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
            """
        ),
        .init(
            name: "GRDB.swift",
            license: "MIT",
            detail: """
            Copyright (C) 2015-2025 Gwendal Roué

            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
            """
        ),
        .init(
            name: "SDWebImage",
            license: "MIT",
            detail: """
            Copyright (c) 2009-2020 Olivier Poitrey rs@dailymotion.com

            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
            """
        ),
        .init(
            name: "SDWebImageSVGCoder",
            license: "MIT",
            detail: """
            Copyright (c) 2018 lizhuoli1126@126.com

            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
            """
        ),
        .init(
            name: "Lightbox",
            license: "MIT",
            detail: """
            Copyright (c) 2015 Hyper Interaktiv AS

            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
            """
        ),
        .init(
            name: "SwiftSoup",
            license: "MIT",
            detail: """
            Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>

            Permission is hereby granted, free of charge, to any person obtaining a copy \
            of this software and associated documentation files (the "Software"), to deal \
            in the Software without restriction, including without limitation the rights \
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
            copies of the Software, and to permit persons to whom the Software is \
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in \
            all copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
            """
        ),
        .init(
            name: "CookedHTML",
            license: "Local",
            detail: """
            Local Swift package for parsing Discourse cooked HTML into BlockNode / InlineNode \
            trees, with NSAttributedString rendering support.
            """
        ),
    ]

    private lazy var tableView: UITableView = {
        let table = UITableView(frame: .zero, style: .insetGrouped)
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .systemGroupedBackground
        table.dataSource = self
        table.delegate = self
        return table
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.about.open_source_license", defaultValue: "开源许可")
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

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        String(
            localized: "settings.about.legalese",
            defaultValue: "非官方 Linux.do 客户端\n基于 UIKit"
        )
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = entry.name
        cell.detailTextLabel?.text = entry.license
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let entry = entries[indexPath.row]
        let detail = LicenseDetailViewController(name: entry.name, text: entry.detail)
        navigationController?.pushViewController(detail, animated: true)
    }
}

final class LicenseDetailViewController: UIViewController {
    private let name: String
    private let text: String

    init(name: String, text: String) {
        self.name = name
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = name
        view.backgroundColor = .systemGroupedBackground
        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .label
        textView.text = text
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 14, bottom: 16, right: 14)
        textView.layer.cornerRadius = 14
        textView.layer.cornerCurve = .continuous
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
    }
}

final class PerfDiagnosticsViewController: UIViewController {
    private lazy var textView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.textColor = .label
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isEditable = false
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.about.perf_diagnostics", defaultValue: "性能诊断")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "action.copy", defaultValue: "复制"),
            style: .plain,
            target: self,
            action: #selector(copyReport)
        )
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        reloadReport()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
        reloadReport()
    }

    private func reloadReport() {
        textView.text = Self.buildReport()
    }

    @objc private func copyReport() {
        UIPasteboard.general.string = textView.text
        let alert = UIAlertController(
            title: nil,
            message: String(localized: "settings.about.perf_copied", defaultValue: "诊断报告已复制"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }

    private static func buildReport() -> String {
        let version = AppVersion.installed()
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        let log = DohDebugLog.snapshot()
        let logLines = log.isEmpty ? 0 : log.split(separator: "\n", omittingEmptySubsequences: false).count
        let logTail: String = {
            guard !log.isEmpty else { return "(empty)" }
            let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(20).joined(separator: "\n")
        }()

        return """
        Doer Performance Diagnostics
        ================================
        App: \(version.displayString)
        iOS: \(device.systemVersion)
        Model: \(device.model)
        Name: \(device.name)
        Idiom: \(device.userInterfaceIdiom == .pad ? "pad" : "phone")
        Processors: \(process.processorCount)
        Physical memory: \(ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory))
        Low power mode: \(process.isLowPowerModeEnabled)
        Thermal: \(thermalStateDescription(process.thermalState))
        Active processor count: \(process.activeProcessorCount)
        Debug log lines: \(logLines)
        Developer mode: \(AboutDeveloperMode.isEnabled)

        Recent log tail:
        \(logTail)
        """
    }

    private static func thermalStateDescription(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
