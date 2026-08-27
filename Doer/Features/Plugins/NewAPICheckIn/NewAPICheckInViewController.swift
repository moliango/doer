import UIKit

@MainActor
final class NewAPICheckInViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case overview
        case platforms
    }

    private let store: NewAPICheckInStore
    private let service: NewAPICheckInService
    private var platforms: [NewAPICheckInPlatform] = []
    private var runningPlatformIDs = Set<UUID>()
    private var authenticatingPlatformIDs = Set<UUID>()
    private var isRunningBatch = false
    /// Fresh `/api/user/self` aggregates from pull-to-refresh (总消耗 / 总请求).
    private var dashboardUsedQuota: Int64?
    private var dashboardRequestCount: Int?

    private var pendingLoginContinuation: CheckedContinuation<Bool, Never>?
    private var didSavePendingLogin = false

    init(store: NewAPICheckInStore, service: NewAPICheckInService) {
        self.store = store
        self.service = service
        super.init(style: .insetGrouped)
    }

    convenience init() {
        let runtime = NewAPICheckInRuntime.shared
        self.init(store: runtime.store, service: runtime.service)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "plugins.newapi.check_in", defaultValue: "签到")
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationItem.largeTitleDisplayMode = .always
        tableView.register(NewAPIPlatformCell.self, forCellReuseIdentifier: NewAPIPlatformCell.reuseIdentifier)
        tableView.backgroundColor = .systemGroupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 76, bottom: 0, right: 16)
        tableView.sectionHeaderTopPadding = 8
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshTriggered), for: .valueChanged)

        // Match original NewAPSign toolbar: batch sign-in + add.
        let signAll = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.circle.fill"),
            style: .plain,
            target: self,
            action: #selector(toolbarSignAllTapped)
        )
        signAll.accessibilityLabel = String(localized: "plugins.newapi.sign_in_all", defaultValue: "全部签到")
        let add = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addPlatformTapped)
        )
        navigationItem.rightBarButtonItems = [add, signAll]
        Task {
            await reload()
            // First open: fetch dashboard stats in background (original PlatformListView).
            await reload(refreshDashboard: true)
        }
    }

    @objc private func toolbarSignAllTapped() {
        signInAllTapped()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard navigationController?.topViewController === self else { return }
        guard let continuation = pendingLoginContinuation else { return }
        pendingLoginContinuation = nil
        let didSave = didSavePendingLogin
        didSavePendingLogin = false
        continuation.resume(returning: didSave)
    }

    // MARK: - Static cells

    private lazy var summaryCell: NewAPISummaryCell = {
        NewAPISummaryCell()
    }()

    private lazy var emptyCell: UITableViewCell = {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .default
        var content = cell.defaultContentConfiguration()
        content.text = String(localized: "plugins.newapi.empty.title", defaultValue: "还没有平台")
        content.secondaryText = String(
            localized: "plugins.newapi.empty.action",
            defaultValue: "点这里或右上角 + 添加 NewAPI 平台"
        )
        content.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
        content.textProperties.alignment = .center
        content.secondaryTextProperties.font = .systemFont(ofSize: 12)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.alignment = .center
        content.textToSecondaryTextVerticalPadding = 4
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 16, bottom: 22, trailing: 16)
        cell.contentConfiguration = content
        return cell
    }()

    // MARK: - Table data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .overview: return 1 // auto-relogin moved to 设置 tab
        case .platforms: return max(platforms.count, 1)
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard Section(rawValue: section) == .platforms else { return nil }
        return platforms.isEmpty
            ? String(localized: "plugins.newapi.section.platforms", defaultValue: "平台")
            : String(
                format: String(localized: "plugins.newapi.section.platforms_count", defaultValue: "平台 · %d"),
                platforms.count
            )
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .overview:
            return summaryCell
        case .platforms, nil:
            guard !platforms.isEmpty else { return emptyCell }
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: NewAPIPlatformCell.reuseIdentifier,
                for: indexPath
            ) as? NewAPIPlatformCell else {
                assertionFailure("NewAPIPlatformCell was not registered")
                return UITableViewCell()
            }
            let platform = platforms[indexPath.row]
            cell.configure(
                name: platform.name,
                typeTag: typeTag(for: platform),
                isCustomType: (platform.platformType ?? .newAPI) == .custom,
                sourceTag: sourceTag(for: platform),
                isCurlSource: (platform.source ?? .webView) == .curl,
                metaText: metaText(for: platform),
                balance: balanceText(for: platform),
                statusColor: tintColor(for: platform.lastStatus),
                isRunning: runningPlatformIDs.contains(platform.id)
                    || authenticatingPlatformIDs.contains(platform.id)
            )
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .platforms else { return }
        guard !platforms.isEmpty else {
            addPlatformTapped()
            return
        }
        let platform = platforms[indexPath.row]
        let controller = NewAPICheckInDetailViewController(
            platform: platform,
            store: store,
            service: service
        ) { [weak self] in
            Task { await self?.reload() }
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard Section(rawValue: indexPath.section) == .platforms, !platforms.isEmpty else { return nil }
        let platform = platforms[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: String(localized: "common.delete", defaultValue: "删除")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            Task {
                do {
                    try await self.store.delete(platformID: platform.id)
                    await self.reload()
                    completion(true)
                } catch {
                    self.presentError(error.localizedDescription)
                    completion(false)
                }
            }
        }
        let signIn = UIContextualAction(style: .normal, title: String(localized: "plugins.newapi.sign_in", defaultValue: "签到")) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            Task {
                await self.signIn(platform)
                completion(true)
            }
        }
        signIn.backgroundColor = AppSettings.shared.themeStyle.accentColor
        return UISwipeActionsConfiguration(actions: [delete, signIn])
    }

    // MARK: - Actions

    @objc private func refreshTriggered() {
        Task { await reload(refreshDashboard: true) }
    }

    @objc private func addPlatformTapped() {
        let sheet = UIAlertController(
            title: String(localized: "plugins.newapi.add", defaultValue: "添加 NewAPI 平台"),
            message: nil,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(
            title: String(localized: "plugins.newapi.web_login", defaultValue: "网页登录"),
            style: .default
        ) { [weak self] _ in
            self?.promptForWebLoginURL()
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "plugins.newapi.manual_add", defaultValue: "手动添加"),
            style: .default
        ) { [weak self] _ in
            self?.presentManualAdd()
        })
        sheet.addAction(UIAlertAction(
            title: String(localized: "plugins.newapi.curl_import", defaultValue: "从 Curl 导入"),
            style: .default
        ) { [weak self] _ in
            self?.presentCurlImport()
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(sheet, animated: true)
    }

    private func promptForWebLoginURL() {
        let controller = NewAPICheckInWebLoginEntryViewController(
            store: store,
            service: service
        ) { [weak self] in
            Task { await self?.reload() }
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func presentManualAdd() {
        let alert = UIAlertController(
            title: String(localized: "plugins.newapi.add", defaultValue: "添加 NewAPI 平台"),
            message: String(localized: "plugins.newapi.add.help", defaultValue: "实验版支持 Token、User ID 和 Cookie Header，凭证会保存到 Keychain。"),
            preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = String(localized: "plugins.newapi.name", defaultValue: "名称") }
        alert.addTextField {
            $0.placeholder = "https://api.example.com"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
        }
        alert.addTextField {
            $0.placeholder = "Access Token"
            $0.isSecureTextEntry = true
            $0.autocapitalizationType = .none
        }
        alert.addTextField {
            $0.placeholder = "New-Api-User"
            $0.keyboardType = .numberPad
        }
        alert.addTextField {
            $0.placeholder = "Cookie: session=..."
            $0.isSecureTextEntry = true
            $0.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.save", defaultValue: "保存"), style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            Task { await self.savePlatform(fields: fields) }
        })
        present(alert, animated: true)
    }

    private func presentCurlImport() {
        let controller = UIViewController()
        controller.title = String(localized: "plugins.newapi.curl_import", defaultValue: "从 Curl 导入")
        controller.view.backgroundColor = .systemBackground

        let textView = UITextView()
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.layer.borderWidth = 1 / UIScreen.main.scale
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        controller.view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: controller.view.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(dismissPresentedController)
        )
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.import", defaultValue: "导入"),
            style: .done,
            target: self,
            action: #selector(importCurlFromPresentedController(_:))
        )
        controller.navigationItem.rightBarButtonItem?.accessibilityHint = String(localized: "plugins.newapi.curl_import.help", defaultValue: "解析 Curl 并安全保存请求和凭证")
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .formSheet
        present(navigationController, animated: true) { textView.becomeFirstResponder() }
    }

    @objc private func dismissPresentedController() {
        presentedViewController?.dismiss(animated: true)
    }

    @objc private func importCurlFromPresentedController(_ sender: UIBarButtonItem) {
        guard let navigationController = presentedViewController as? UINavigationController,
              let controller = navigationController.topViewController,
              let textView = controller.view.subviews.compactMap({ $0 as? UITextView }).first
        else { return }
        do {
            let parsed = try NewAPICurlParser.parse(textView.text)
            sender.isEnabled = false
            Task {
                do {
                    try await saveCurlRequest(parsed)
                    navigationController.dismiss(animated: true)
                    await reload()
                } catch {
                    sender.isEnabled = true
                    presentError(error.localizedDescription)
                }
            }
        } catch {
            presentError(String(localized: "plugins.newapi.curl_import.invalid", defaultValue: "Curl 内容无法解析，请检查 URL、引号和参数。"))
        }
    }

    private func saveCurlRequest(_ request: NewAPICurlRequest) async throws {
        guard let scheme = request.url.scheme, let host = request.url.host else {
            throw NewAPICurlParseError.invalidURL(request.url.absoluteString)
        }
        var baseComponents = URLComponents()
        baseComponents.scheme = scheme
        baseComponents.host = host
        baseComponents.port = request.url.port
        guard let baseURL = baseComponents.url else {
            throw NewAPICurlParseError.invalidURL(request.url.absoluteString)
        }
        var endpointComponents = URLComponents()
        endpointComponents.path = request.url.path.isEmpty ? "/" : request.url.path
        endpointComponents.query = request.url.query

        var headers = request.headers
        let authorization = removeHeader(named: "Authorization", from: &headers)
        let accessToken: String? = {
            guard let authorization else { return nil }
            let prefix = "Bearer "
            return authorization.lowercased().hasPrefix(prefix.lowercased())
                ? String(authorization.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                : authorization
        }()
        let credential = NewAPICheckInCredential(
            accessToken: accessToken,
            userID: removeHeader(named: "New-Api-User", from: &headers),
            cookieHeader: removeHeader(named: "Cookie", from: &headers),
            additionalHeaders: headers
        )
        let platform = NewAPICheckInPlatform(
            name: host,
            baseURL: baseURL.absoluteString,
            endpoint: endpointComponents.string ?? request.url.path,
            method: request.method,
            body: request.body,
            source: .curl
        )
        try await store.save(platform, credential: credential)
    }

    private func removeHeader(named name: String, from headers: inout [String: String]) -> String? {
        guard let key = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return headers.removeValue(forKey: key)
    }

    private func signInAllTapped() {
        guard !isRunningBatch, !platforms.isEmpty else { return }
        isRunningBatch = true
        refreshSummary()
        let batchPlatforms = platforms
        Task {
            var summary = NewAPICheckInBatchSummary(total: batchPlatforms.count)
            for platform in batchPlatforms {
                authenticatingPlatformIDs.insert(platform.id)
                tableView.reloadData()
                let result = await executeSignInFlow(platform)
                authenticatingPlatformIDs.remove(platform.id)
                tableView.reloadData()
                if let result {
                    summary.record(result.status)
                } else {
                    summary.record(.authenticationExpired)
                }
            }
            isRunningBatch = false
            await reload()
            presentBatchSummary(summary)
        }
    }

    private func presentBatchSummary(_ summary: NewAPICheckInBatchSummary) {
        let alert = UIAlertController(
            title: String(localized: "plugins.newapi.batch_result", defaultValue: "签到结果"),
            message: summary.localizedSummary,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "common.ok", defaultValue: "确定"),
            style: .default
        ))
        present(alert, animated: true)
    }

    private func savePlatform(fields: [UITextField]) async {
        let rawURL = fields.indices.contains(1) ? fields[1].text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        guard let url = normalizedPlatformURL(rawURL), let host = url.host else {
            presentError(String(localized: "plugins.newapi.invalid_url", defaultValue: "平台地址无效"))
            return
        }
        let name = fields.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = NewAPICheckInPlatform(
            name: {
                if let name, !name.isEmpty { return name }
                return host
            }(),
            baseURL: url.absoluteString,
            source: .manual
        )
        let credential = NewAPICheckInCredential(
            accessToken: nonEmpty(fields[safe: 2]?.text),
            userID: nonEmpty(fields[safe: 3]?.text),
            cookieHeader: nonEmpty(fields[safe: 4]?.text)
        )
        do {
            try await store.save(platform, credential: credential)
            await reload()
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func signIn(_ platform: NewAPICheckInPlatform) async {
        guard !isRunningBatch,
              !runningPlatformIDs.contains(platform.id),
              !authenticatingPlatformIDs.contains(platform.id)
        else { return }
        authenticatingPlatformIDs.insert(platform.id)
        tableView.reloadData()
        _ = await executeSignInFlow(platform)
        authenticatingPlatformIDs.remove(platform.id)
        tableView.reloadData()
    }

    // MARK: - Sign-in flow

    private func executeSignInFlow(
        _ platform: NewAPICheckInPlatform
    ) async -> NewAPICheckInResult? {
        var currentPlatform = platform
        var didInteractiveLogin = false

        if currentPlatform.requiresReloginBeforeSignIn,
           await service.needsInteractiveRelogin(for: currentPlatform) {
            guard await requestRelogin(for: currentPlatform) else { return nil }
            didInteractiveLogin = true
            currentPlatform = await freshPlatform(id: currentPlatform.id) ?? currentPlatform
            _ = await service.refreshAuthentication(currentPlatform)
        }

        var result = await performSignIn(currentPlatform)
        if result.status == .authenticationExpired,
           NewAPICheckInRuntime.autoReloginEnabled,
           !didInteractiveLogin {
            if (await service.refreshAuthentication(currentPlatform)).isRefreshed {
                result = await performSignIn(currentPlatform)
            } else if await requestRelogin(for: currentPlatform) {
                currentPlatform = await freshPlatform(id: currentPlatform.id) ?? currentPlatform
                _ = await service.refreshAuthentication(currentPlatform)
                result = await performSignIn(currentPlatform)
            }
        }
        return result
    }

    private func performSignIn(_ platform: NewAPICheckInPlatform) async -> NewAPICheckInResult {
        runningPlatformIDs.insert(platform.id)
        tableView.reloadData()
        let result = await service.signIn(platform)
        runningPlatformIDs.remove(platform.id)
        await reload()
        return result
    }

    private func freshPlatform(id: UUID) async -> NewAPICheckInPlatform? {
        await store.platforms().first(where: { $0.id == id })
    }

    private func requestRelogin(for platform: NewAPICheckInPlatform) async -> Bool {
        if await NewAPICheckInSilentLoginCoordinator.restore(
            platform: platform,
            store: store,
            service: service
        ) {
            return true
        }
        guard pendingLoginContinuation == nil,
              presentedViewController == nil,
              let navigationController,
              navigationController.topViewController === self,
              let url = URL(string: platform.baseURL)
        else { return false }

        return await withCheckedContinuation { continuation in
            pendingLoginContinuation = continuation
            didSavePendingLogin = false
            let controller = NewAPICheckInLoginViewController(
                baseURL: url,
                mode: (platform.platformType ?? .newAPI) == .custom ? .custom : .newAPI,
                store: store,
                service: service,
                existingPlatform: platform
            ) { [weak self] in
                self?.didSavePendingLogin = true
            }
            navigationController.pushViewController(controller, animated: true)
        }
    }

    // MARK: - State

    private func reload(refreshDashboard: Bool = false) async {
        platforms = await store.platforms()
        if refreshDashboard {
            await refreshDashboardStats()
        }
        refreshControl?.endRefreshing()
        tableView.reloadData()
        refreshSummary()
    }

    /// Pull-to-refresh: probe each NewAPI platform for quota / used / requests.
    private func refreshDashboardStats() async {
        guard !platforms.isEmpty else {
            dashboardUsedQuota = nil
            dashboardRequestCount = nil
            return
        }
        var totalQuota: Int64 = 0
        var hasQuota = false
        var totalUsed: Int64 = 0
        var hasUsed = false
        var totalReq = 0
        var hasReq = false

        await withTaskGroup(of: NewAPICheckInLoginProbeResult?.self) { group in
            for platform in platforms where (platform.platformType ?? .newAPI) == .newAPI {
                group.addTask { [service] in
                    await service.refreshAccount(platform)
                }
            }
            for await result in group {
                guard let result, result.isLoggedIn else { continue }
                if let q = result.quotaValue {
                    totalQuota += q
                    hasQuota = true
                }
                if let u = result.usedQuota {
                    totalUsed += u
                    hasUsed = true
                }
                if let r = result.requestCount {
                    totalReq += r
                    hasReq = true
                }
            }
        }

        // Persist updated quotas back onto platform rows.
        platforms = await store.platforms()
        dashboardUsedQuota = hasUsed ? totalUsed : nil
        dashboardRequestCount = hasReq ? totalReq : nil
        _ = (hasQuota, totalQuota)
    }

    private func refreshSummary() {
        let totalBalance = platforms.compactMap(\.lastQuotaValue).reduce(Int64(0), +)
        let hasBalance = platforms.contains(where: { $0.lastQuotaValue != nil })
        summaryCell.update(
            platformCount: platforms.count,
            totalBalanceText: hasBalance ? Self.formatQuotaDollars(totalBalance) : "—",
            totalUsedText: dashboardUsedQuota.map(Self.formatQuotaDollars) ?? "—",
            totalRequestsText: dashboardRequestCount.map(Self.formatInt) ?? "—"
        )
    }

    private static func formatQuotaDollars(_ tokens: Int64) -> String {
        String(format: "$%.2f", Double(tokens) / 500_000)
    }

    private static func formatInt(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Presentation helpers

    private func statusTitle(_ status: NewAPICheckInStatus?) -> String {
        // Labels match original NewAPSign SignInResult.Status.label
        switch status {
        case .success:
            return String(localized: "plugins.newapi.status.success", defaultValue: "成功")
        case .alreadySigned:
            return String(localized: "plugins.newapi.status.already", defaultValue: "已签到")
        case .authenticationExpired:
            return String(localized: "plugins.newapi.status.expired", defaultValue: "登录过期")
        case .serverError:
            return String(localized: "plugins.newapi.status.server_error", defaultValue: "服务器错误")
        case .unknown:
            return String(localized: "plugins.newapi.status.unknown", defaultValue: "未知")
        case nil:
            return String(localized: "plugins.newapi.detail.not_run", defaultValue: "尚未签到")
        }
    }

    private func tintColor(for status: NewAPICheckInStatus?) -> UIColor {
        // Colors match original NewAPSign SignInResult.Status.tint
        switch status {
        case .success: return .systemGreen
        case .alreadySigned: return .systemOrange
        case .authenticationExpired: return .systemRed
        case .serverError: return .systemRed
        case .unknown: return .systemGray
        case nil: return .systemGray
        }
    }

    private func metaText(for platform: NewAPICheckInPlatform) -> String {
        var parts: [String] = [statusTitle(platform.lastStatus)]
        if let attemptedAt = platform.lastAttemptAt {
            parts.append(Self.relativeFormatter.localizedString(for: attemptedAt, relativeTo: Date()))
        }
        return parts.joined(separator: " · ")
    }

    private func sourceTag(for platform: NewAPICheckInPlatform) -> String {
        // Original NewAPSign labels.
        switch platform.source ?? .webView {
        case .webView: return "WebView"
        case .curl: return "CURL"
        case .manual: return "Manual"
        }
    }

    private func typeTag(for platform: NewAPICheckInPlatform) -> String {
        (platform.platformType ?? .newAPI) == .custom ? "CUSTOM" : "NEWAPI"
    }

    private func balanceText(for platform: NewAPICheckInPlatform) -> String? {
        guard let value = platform.lastQuotaValue else { return nil }
        let unit = (platform.lastQuotaUnit ?? "quota").lowercased()
        if unit == "quota" || unit == "remain_quota" {
            return String(format: "$%.2f", Double(value) / 500_000)
        }
        let formatted = Self.numberFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return unit == "credit" || unit == "balance" ? "$\(formatted)" : formatted
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizedPlatformURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: normalized), components.host != nil else { return nil }
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "common.error", defaultValue: "错误"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "确定"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Summary cell (= CompactAggregateBanner from NewAPSign)

private final class NewAPISummaryCell: UITableViewCell {
    private let titleIcon: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "chart.pie.fill"))
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = AppSettings.shared.themeStyle.accentColor
        view.contentMode = .scaleAspectFit
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "总览"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        return label
    }()

    private let platformCountLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .right
        return label
    }()

    // Original labels: 总余额 / 总消耗 / 总请求
    private let balanceChip = NewAPIMetricChip(
        icon: "dollarsign.circle.fill",
        title: "总余额",
        color: .systemGreen
    )
    private let usedChip = NewAPIMetricChip(
        icon: "arrow.down.circle.fill",
        title: "总消耗",
        color: .systemOrange
    )
    private let requestChip = NewAPIMetricChip(
        icon: "number.circle.fill",
        title: "总请求",
        color: .systemBlue
    )

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        backgroundColor = .secondarySystemGroupedBackground

        let accent = AppSettings.shared.themeStyle.accentColor
        let iconBox = UIView()
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.backgroundColor = accent.withAlphaComponent(0.12)
        iconBox.layer.cornerRadius = 8
        iconBox.layer.cornerCurve = .continuous
        iconBox.addSubview(titleIcon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 32),
            iconBox.heightAnchor.constraint(equalToConstant: 32),
            titleIcon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            titleIcon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            titleIcon.widthAnchor.constraint(equalToConstant: 16),
            titleIcon.heightAnchor.constraint(equalToConstant: 16),
        ])

        let header = UIStackView(arrangedSubviews: [iconBox, titleLabel, UIView(), platformCountLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 10

        let metrics = UIStackView(arrangedSubviews: [balanceChip, usedChip, requestChip])
        metrics.axis = .horizontal
        metrics.spacing = 10
        metrics.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [header, metrics])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        platformCount: Int,
        totalBalanceText: String,
        totalUsedText: String,
        totalRequestsText: String
    ) {
        platformCountLabel.text = "\(platformCount) 平台"
        balanceChip.setValue(totalBalanceText)
        usedChip.setValue(totalUsedText)
        requestChip.setValue(totalRequestsText)
    }
}

/// BannerStatBox from NewAPSign — leading-aligned label + monospaced value.
private final class NewAPIMetricChip: UIView {
    private let valueLabel = UILabel()

    init(icon: String, title: String, color: UIColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = color.withAlphaComponent(0.08)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous

        let iconView = UIImageView(
            image: UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        )
        iconView.tintColor = color

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = .secondaryLabel

        let titleRow = UIStackView(arrangedSubviews: [iconView, titleLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 4
        titleRow.alignment = .center

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        valueLabel.textColor = color
        valueLabel.text = "—"
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        valueLabel.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [titleRow, valueLabel])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ text: String) {
        valueLabel.text = text
    }
}

// MARK: - Platform cell (= PlatformRow from NewAPSign)

private final class NewAPIPlatformCell: UITableViewCell {
    static let reuseIdentifier = "NewAPIPlatformCell"

    /// Original uses NewAPILogo in a 44×44 rounded rect — not monogram letters.
    private let logoContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }()

    private let logoView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "NewAPILogo"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 17, weight: .semibold) // .headline
        label.textColor = .label
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let typeTag = NewAPITagLabel()
    private let sourceTag = NewAPITagLabel()
    private let balanceChip = NewAPITagLabel()

    private let metaLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12) // .caption
        label.textColor = .secondaryLabel
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let statusDot: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 6),
            view.heightAnchor.constraint(equalToConstant: 6),
        ])
        return view
    }()

    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .secondarySystemGroupedBackground
        accessoryType = .disclosureIndicator
        let selected = UIView()
        selected.backgroundColor = .tertiarySystemGroupedBackground
        selectedBackgroundView = selected

        logoContainer.addSubview(logoView)

        let tagsRow = UIStackView(arrangedSubviews: [typeTag, sourceTag, balanceChip, UIView()])
        tagsRow.axis = .horizontal
        tagsRow.spacing = 6
        tagsRow.alignment = .center

        let statusRow = UIStackView(arrangedSubviews: [statusDot, metaLabel])
        statusRow.axis = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .center

        let textStack = UIStackView(arrangedSubviews: [nameLabel, tagsRow, statusRow])
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 6

        [logoContainer, textStack, activityIndicator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            logoContainer.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            logoContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            logoContainer.widthAnchor.constraint(equalToConstant: 44),
            logoContainer.heightAnchor.constraint(equalToConstant: 44),

            logoView.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            logoView.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 32),
            logoView.heightAnchor.constraint(equalToConstant: 32),

            textStack.leadingAnchor.constraint(equalTo: logoContainer.trailingAnchor, constant: 14),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: logoContainer.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: logoContainer.centerYAnchor),

            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        activityIndicator.stopAnimating()
        logoContainer.alpha = 1
        balanceChip.isHidden = true
    }

    func configure(
        name: String,
        typeTag typeText: String,
        isCustomType: Bool,
        sourceTag sourceText: String,
        isCurlSource: Bool,
        metaText: String,
        balance: String?,
        statusColor: UIColor,
        isRunning: Bool
    ) {
        nameLabel.text = name
        // Original: NEWAPI green / CUSTOM purple
        typeTag.configure(
            text: typeText,
            color: isCustomType ? .systemPurple : .systemGreen
        )
        // Original: WebView blue / CURL yellow
        sourceTag.configure(
            text: sourceText,
            color: isCurlSource ? .systemYellow : .systemBlue
        )
        if let balance {
            balanceChip.isHidden = false
            balanceChip.configure(text: balance, color: .systemGreen, emphasized: true)
        } else {
            balanceChip.isHidden = true
        }
        metaLabel.text = metaText
        metaLabel.isHidden = metaText.isEmpty
        statusDot.backgroundColor = statusColor
        statusDot.isHidden = metaText.isEmpty

        logoContainer.alpha = isRunning ? 0.25 : 1
        if isRunning {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }

        accessibilityLabel = [name, typeText, sourceText, metaText, balance]
            .compactMap { $0 }
            .joined(separator: ", ")
        accessibilityTraits = .button
    }
}

private final class NewAPITagLabel: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // Original cornerRadius 6
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        // Original .caption2 + .medium
        label.font = .systemFont(ofSize: 11, weight: .medium)
        addSubview(label)
        NSLayoutConstraint.activate([
            // Original padding horizontal 8, vertical 3
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, color: UIColor, emphasized: Bool = false) {
        label.text = text
        label.textColor = color
        // Original: color.opacity(0.12) type, 0.15 source; quota slightly stronger
        backgroundColor = color.withAlphaComponent(emphasized ? 0.15 : 0.12)
        isHidden = text.isEmpty
    }
}

// MARK: - Status pill

private final class NewAPIStatusPill: UIView {
    private let dotView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 3
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 6),
            view.heightAnchor.constraint(equalToConstant: 6),
        ])
        return view
    }()

    private let textLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        let stack = UIStackView(arrangedSubviews: [dotView, textLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3.5),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, color: UIColor) {
        textLabel.text = text
        textLabel.textColor = color
        dotView.backgroundColor = color
        backgroundColor = color.withAlphaComponent(0.12)
    }
}

// MARK: - Monogram

private final class NewAPIMonogramView: UIView {
    private let gradientLayer = CAGradientLayer()

    private let letterLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 19, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private static let gradientPalettes: [(UIColor, UIColor)] = [
        (.systemBlue, .systemCyan),
        (.systemIndigo, .systemPurple),
        (.systemPink, .systemOrange),
        (.systemTeal, .systemGreen),
        (.systemPurple, .systemPink),
        (.systemOrange, .systemYellow),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        layer.addSublayer(gradientLayer)
        addSubview(letterLabel)
        NSLayoutConstraint.activate([
            letterLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            letterLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(seed: String, letter: String) {
        letterLabel.text = letter
        // Stable per-host palette so a platform keeps its color across launches.
        let index = abs(seed.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.gradientPalettes.count
        let palette = Self.gradientPalettes[index]
        gradientLayer.colors = [palette.0.cgColor, palette.1.cgColor]
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientLayer.frame = bounds
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
