import UIKit

@MainActor
final class NewAPICheckInDetailViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case request
        case signInBehavior
        case attachedHeaders
        case actions
        case history
        case danger
    }

    private enum ActionRow: Int, CaseIterable {
        case signIn
        case refreshBalance
        case webSignIn
        case relogin
        case editRequest
    }

    private let store: NewAPICheckInStore
    private let service: NewAPICheckInService
    private var platform: NewAPICheckInPlatform
    private var credential: NewAPICheckInCredential?
    private var attempts: [NewAPICheckInAttempt] = []
    private var isSigningIn = false
    private var isRefreshingAccount = false
    private var isRecoveringLogin = false
    private let onChange: () -> Void

    init(
        platform: NewAPICheckInPlatform,
        store: NewAPICheckInStore,
        service: NewAPICheckInService,
        onChange: @escaping () -> Void
    ) {
        self.platform = platform
        self.store = store
        self.service = service
        self.onChange = onChange
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = platform.name
        tableView.backgroundColor = .systemGroupedBackground
        tableView.cellLayoutMarginsFollowReadableWidth = true
        Task { await reload() }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .request: return 3
        case .signInBehavior: return 1
        case .attachedHeaders: return attachedHeaderRows().count
        case .actions: return ActionRow.allCases.count
        case .history: return max(1, min(attempts.count, 5))
        case .danger: return 1
        case nil: return 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .request:
            return String(localized: "plugins.newapi.detail.request", defaultValue: "签到请求")
        case .signInBehavior:
            return String(localized: "plugins.newapi.detail.sign_in_flow", defaultValue: "签到流程")
        case .actions:
            return String(localized: "plugins.newapi.detail.actions", defaultValue: "操作")
        case .history:
            return String(localized: "plugins.newapi.detail.history", defaultValue: "最近记录")
        case .attachedHeaders, .danger, nil:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section) {
        case .request where isCustomizedRequest:
            return String(
                localized: "plugins.newapi.detail.custom_request",
                defaultValue: "已自定义请求，将覆盖 NewAPI 默认值。"
            )
        case .signInBehavior:
            return String(
                localized: "plugins.newapi.detail.relogin_before_sign_in.help",
                defaultValue: "开启后，签到前会优先无感刷新 Token；凭证失效时才打开网页登录。"
            )
        case .attachedHeaders:
            return String(
                localized: "plugins.newapi.detail.credentials_private",
                defaultValue: "凭证仅显示配置状态，具体内容不会在此页面展示。"
            )
        default:
            return nil
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .request:
            return requestCell(at: indexPath)
        case .signInBehavior:
            return signInBehaviorCell()
        case .attachedHeaders:
            return attachedHeaderCell(at: indexPath)
        case .actions:
            return actionCell(at: indexPath)
        case .history:
            return historyCell(at: indexPath)
        case .danger:
            return dangerCell(at: indexPath)
        case nil:
            return UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .actions:
            guard let action = ActionRow(rawValue: indexPath.row) else { return }
            switch action {
            case .signIn:
                Task { await signIn() }
            case .refreshBalance:
                Task { await refreshBalance() }
            case .webSignIn:
                openManualSignIn()
            case .relogin:
                openWebLogin()
            case .editRequest:
                presentRequestEditor()
            }
        case .history where !attempts.isEmpty:
            presentAttempt(attempts[indexPath.row])
        case .danger:
            confirmDelete()
        default:
            break
        }
    }

    private func requestCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = reusableCell(identifier: "request-value")
        let rows = requestRows()
        let row = rows[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = row.title
        content.secondaryText = row.value
        content.textProperties.color = .secondaryLabel
        content.secondaryTextProperties.color = .label
        content.secondaryTextProperties.font = row.monospaced
            ? .monospacedSystemFont(ofSize: 13, weight: .regular)
            : .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.numberOfLines = 3
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func signInBehaviorCell() -> UITableViewCell {
        let cell = reusableCell(identifier: "sign-in-behavior")
        var content = cell.defaultContentConfiguration()
        content.text = String(
            localized: "plugins.newapi.detail.relogin_before_sign_in",
            defaultValue: "签到前重新登录"
        )
        content.image = UIImage(systemName: "person.crop.circle.badge.clock")
        content.imageProperties.tintColor = AppSettings.shared.themeStyle.accentColor
        cell.contentConfiguration = content
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = platform.requiresReloginBeforeSignIn
        toggle.onTintColor = AppSettings.shared.themeStyle.accentColor
        toggle.addAction(UIAction { [weak self] action in
            guard let toggle = action.sender as? UISwitch else { return }
            Task { await self?.setReloginBeforeSignIn(toggle.isOn) }
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func attachedHeaderCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = reusableCell(identifier: "attached-header")
        let row = attachedHeaderRows()[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = row.title
        content.secondaryText = row.detail
        content.image = UIImage(systemName: row.isAttached ? "checkmark.circle.fill" : "minus.circle")
        content.imageProperties.tintColor = row.isAttached ? .systemGreen : .tertiaryLabel
        content.imageProperties.maximumSize = CGSize(width: 18, height: 18)
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.secondaryTextProperties.color = .secondaryLabel
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 7, leading: 0, bottom: 7, trailing: 0)
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func actionCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = reusableCell(identifier: "action")
        guard let action = ActionRow(rawValue: indexPath.row) else { return cell }
        let presentation = actionPresentation(action)
        var content = cell.defaultContentConfiguration()
        content.text = presentation.title
        content.image = UIImage(systemName: presentation.icon)
        content.imageProperties.tintColor = presentation.color
        content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
        content.textProperties.color = presentation.color
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        cell.accessoryType = presentation.showsDisclosure ? .disclosureIndicator : .none
        cell.accessoryView = nil

        let isRecoveringAction = isRecoveringLogin && (action == .signIn || action == .relogin)
        if (action == .signIn && isSigningIn)
            || (action == .refreshBalance && isRefreshingAccount)
            || isRecoveringAction {
            let indicator = UIActivityIndicatorView(style: .medium)
            indicator.startAnimating()
            cell.accessoryView = indicator
        }
        return cell
    }

    private func historyCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = reusableCell(identifier: "history")
        var content = cell.defaultContentConfiguration()
        if attempts.isEmpty {
            content.text = String(localized: "plugins.newapi.detail.no_history", defaultValue: "还没有签到记录")
            content.textProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "clock.badge.questionmark")
            content.imageProperties.tintColor = .tertiaryLabel
            cell.selectionStyle = .none
            cell.accessoryType = .none
        } else {
            let attempt = attempts[indexPath.row]
            content.text = attempt.message ?? statusTitle(attempt.status)
            content.secondaryText = attemptSubtitle(attempt)
            content.secondaryTextProperties.color = .secondaryLabel
            content.secondaryTextProperties.numberOfLines = 2
            content.image = UIImage(systemName: statusIcon(attempt.status))
            content.imageProperties.tintColor = statusColor(attempt.status)
            content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
            cell.selectionStyle = .default
            cell.accessoryType = .disclosureIndicator
        }
        content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        cell.contentConfiguration = content
        return cell
    }

    private func dangerCell(at indexPath: IndexPath) -> UITableViewCell {
        let cell = reusableCell(identifier: "danger")
        var content = cell.defaultContentConfiguration()
        content.text = String(localized: "common.delete", defaultValue: "删除")
        content.textProperties.color = .systemRed
        content.image = UIImage(systemName: "trash")
        content.imageProperties.tintColor = .systemRed
        content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        cell.contentConfiguration = content
        cell.selectionStyle = .default
        cell.accessoryType = .none
        return cell
    }

    private func reusableCell(identifier: String) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
    }

    private func requestRows() -> [(title: String, value: String, monospaced: Bool)] {
        let emptyBody = String(
            localized: "plugins.newapi.detail.empty_body",
            defaultValue: "（空 / 不发送 body）"
        )
        return [
            ("Method", platform.method.uppercased(), false),
            ("URL", resolvedRequestURL(), true),
            ("Body", platform.body?.nilIfEmpty ?? emptyBody, true),
        ]
    }

    private func attachedHeaderRows() -> [(title: String, detail: String, isAttached: Bool)] {
        let configured = String(localized: "plugins.newapi.detail.configured", defaultValue: "已配置")
        let notConfigured = String(localized: "plugins.newapi.detail.not_configured", defaultValue: "未配置")
        let tokenAttached = credential?.accessToken?.isEmpty == false || additionalHeader(named: "Authorization") != nil
        let userAttached = credential?.userID?.isEmpty == false || additionalHeader(named: "New-Api-User") != nil
        let cookieCount = credential?.cookieHeader?
            .split(separator: ";", omittingEmptySubsequences: true)
            .count ?? 0
        let cookieAttached = cookieCount > 0 || additionalHeader(named: "Cookie") != nil
        let contentType = additionalHeader(named: "Content-Type")
            ?? (platform.body?.isEmpty == false ? "application/json" : nil)
        let accept = additionalHeader(named: "Accept") ?? "application/json"

        return [
            ("Authorization", tokenAttached ? configured : notConfigured, tokenAttached),
            ("New-Api-User", userAttached ? configured : notConfigured, userAttached),
            (
                "Cookie",
                cookieAttached
                    ? String(format: String(localized: "plugins.newapi.detail.cookie_count", defaultValue: "%d 项"), max(cookieCount, 1))
                    : notConfigured,
                cookieAttached
            ),
            ("Content-Type", contentType ?? notConfigured, contentType != nil),
            ("Accept", accept, true),
        ]
    }

    private func additionalHeader(named name: String) -> String? {
        credential?.additionalHeaders.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value.nilIfEmpty
    }

    private var isCustomizedRequest: Bool {
        platform.endpoint != "/api/user/checkin"
            || platform.method.uppercased() != "POST"
            || (platform.body?.nilIfEmpty != "{}" && platform.body?.nilIfEmpty != nil)
    }

    private func resolvedRequestURL() -> String {
        guard let baseURL = URL(string: platform.baseURL) else { return platform.endpoint }
        return URL(string: platform.endpoint, relativeTo: baseURL)?.absoluteURL.absoluteString ?? platform.endpoint
    }

    private func actionPresentation(
        _ action: ActionRow
    ) -> (title: String, icon: String, color: UIColor, showsDisclosure: Bool) {
        switch action {
        case .signIn:
            return (
                String(localized: "plugins.newapi.sign_in", defaultValue: "立即签到"),
                "checkmark.circle.fill",
                .systemBlue,
                false
            )
        case .refreshBalance:
            return (
                String(localized: "plugins.newapi.detail.refresh_balance", defaultValue: "刷新余额"),
                "creditcard.fill",
                .systemBlue,
                false
            )
        case .webSignIn:
            return (
                String(localized: "plugins.newapi.detail.web_manual_sign_in", defaultValue: "网页签到"),
                "globe",
                .label,
                true
            )
        case .relogin:
            return (
                String(localized: "plugins.newapi.detail.relogin", defaultValue: "重新登录"),
                "arrow.clockwise.circle.fill",
                .label,
                true
            )
        case .editRequest:
            return (
                String(localized: "plugins.newapi.detail.edit", defaultValue: "编辑签到请求"),
                "pencil",
                .systemBlue,
                true
            )
        }
    }

    private func setReloginBeforeSignIn(_ enabled: Bool) async {
        var updated = platform
        updated.reloginBeforeSignIn = enabled
        do {
            try await store.save(updated)
            platform = updated
            onChange()
        } catch {
            await reload()
            presentMessage(
                title: String(localized: "common.error", defaultValue: "错误"),
                message: error.localizedDescription
            )
        }
    }

    private func reload() async {
        if let fresh = await store.platforms().first(where: { $0.id == platform.id }) {
            platform = fresh
            title = fresh.name
        }
        credential = try? await store.credential(for: platform.id)
        attempts = await store.attempts(platformID: platform.id)
        tableView.reloadData()
    }

    private func signIn(
        skippingConfiguredRelogin: Bool = false,
        allowExpiredRelogin: Bool = true
    ) async {
        guard !isSigningIn else { return }
        if platform.requiresReloginBeforeSignIn,
           !skippingConfiguredRelogin,
           await service.needsInteractiveRelogin(for: platform) {
            openWebLogin(signInAfterSave: true)
            return
        }

        isSigningIn = true
        reloadActionRow(.signIn)
        let result = await service.signIn(platform)
        isSigningIn = false
        await reload()
        onChange()
        if result.status == .authenticationExpired,
           allowExpiredRelogin,
           NewAPICheckInRuntime.autoReloginEnabled {
            if (await service.refreshAuthentication(platform)).isRefreshed {
                await reload()
                await signIn(
                    skippingConfiguredRelogin: true,
                    allowExpiredRelogin: false
                )
            } else {
                openWebLogin(signInAfterSave: true)
            }
        } else if result.status == .authenticationExpired {
            presentMessage(
                title: String(localized: "plugins.newapi.detail.login_expired", defaultValue: "登录已失效"),
                message: result.message
            )
        }
    }

    private func refreshBalance() async {
        guard !isRefreshingAccount else { return }
        isRefreshingAccount = true
        reloadActionRow(.refreshBalance)
        let result = await service.refreshAccount(platform)
        isRefreshingAccount = false
        await reload()
        onChange()

        let title = result.isLoggedIn
            ? String(localized: "plugins.newapi.detail.balance_updated", defaultValue: "余额已刷新")
            : String(localized: "plugins.newapi.detail.login_expired", defaultValue: "登录已失效")
        let quota = result.quotaValue.map { value in
            "\(value) \(result.quotaUnit ?? "quota")"
        }
        presentMessage(title: title, message: result.message ?? quota)
    }

    private func reloadActionRow(_ action: ActionRow) {
        tableView.reloadRows(
            at: [IndexPath(row: action.rawValue, section: Section.actions.rawValue)],
            with: .none
        )
    }

    private func presentRequestEditor() {
        let alert = UIAlertController(
            title: String(localized: "plugins.newapi.detail.edit", defaultValue: "编辑签到请求"),
            message: String(localized: "plugins.newapi.detail.edit_help", defaultValue: "可填写相对路径或完整 URL。自定义 Header 可通过 Curl 导入。"),
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "/api/user/checkin"
            field.text = self.platform.endpoint
            field.autocapitalizationType = .none
        }
        alert.addTextField { field in
            field.placeholder = "POST"
            field.text = self.platform.method
            field.autocapitalizationType = .allCharacters
        }
        alert.addTextField { field in
            field.placeholder = "{}"
            field.text = self.platform.body
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.save", defaultValue: "保存"), style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields else { return }
            var updated = self.platform
            updated.endpoint = fields[0].text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? updated.endpoint
            updated.method = fields[1].text?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().nilIfEmpty ?? "POST"
            updated.body = fields[2].text?.nilIfEmpty
            Task {
                do {
                    try await self.store.save(updated)
                    await self.reload()
                    self.onChange()
                } catch {
                    self.presentMessage(title: String(localized: "common.error", defaultValue: "错误"), message: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentAttempt(_ attempt: NewAPICheckInAttempt) {
        let lines = [
            "HTTP: \(attempt.statusCode.map(String.init) ?? "-")",
            "\(String(localized: "plugins.newapi.detail.duration", defaultValue: "耗时")): \(attempt.durationMilliseconds) ms",
            attempt.rawResponse,
        ].compactMap { $0 }.joined(separator: "\n\n")
        presentMessage(title: attempt.message ?? statusTitle(attempt.status), message: lines)
    }

    private func openWebLogin(signInAfterSave: Bool = false) {
        guard !isRecoveringLogin else { return }
        isRecoveringLogin = true
        reloadActionRow(.signIn)
        reloadActionRow(.relogin)
        Task {
            defer {
                isRecoveringLogin = false
                reloadActionRow(.signIn)
                reloadActionRow(.relogin)
            }
            let restored = await NewAPICheckInSilentLoginCoordinator.restore(
                platform: platform,
                store: store,
                service: service
            )
            if restored {
                await reload()
                if signInAfterSave {
                    await signIn(
                        skippingConfiguredRelogin: true,
                        allowExpiredRelogin: false
                    )
                }
                return
            }
            presentWebLogin(signInAfterSave: signInAfterSave)
        }
    }

    private func presentWebLogin(signInAfterSave: Bool) {
        guard let url = URL(string: platform.baseURL) else { return }
        let controller = NewAPICheckInLoginViewController(
            baseURL: url,
            mode: (platform.platformType ?? .newAPI) == .custom ? .custom : .newAPI,
            store: store,
            service: service,
            existingPlatform: platform
        ) { [weak self] in
            guard let self else { return }
            Task {
                await self.reload()
                _ = await self.service.refreshAuthentication(self.platform)
                if signInAfterSave {
                    await self.signIn(
                        skippingConfiguredRelogin: true,
                        allowExpiredRelogin: false
                    )
                }
            }
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    /// 「网页签到」— 对应原 NewAPSign `ManualSignInView`。
    /// 打开站点、预注入已存 Cookie,让用户在网页里手动点签到按钮;
    /// 不自动检测登录完成,导航结束后回写 Cookie。给被 WAF 拦截的站点用。
    private func openManualSignIn() {
        let controller = NewAPICheckInManualSignInViewController(
            platform: platform,
            store: store
        ) { [weak self] in
            Task { await self?.reload() }
        }
        navigationController?.pushViewController(controller, animated: true)
    }
    private func confirmDelete() {
        let alert = UIAlertController(
            title: String(localized: "plugins.newapi.detail.delete_title", defaultValue: "删除平台？"),
            message: String(localized: "plugins.newapi.detail.delete_help", defaultValue: "平台凭证和全部签到记录都会被删除，无法恢复。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.delete", defaultValue: "删除"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.store.delete(platformID: self.platform.id)
                    self.onChange()
                    self.navigationController?.popViewController(animated: true)
                } catch {
                    self.presentMessage(title: String(localized: "common.error", defaultValue: "错误"), message: error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func presentMessage(title: String, message: String?) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "确定"), style: .default))
        present(alert, animated: true)
    }

    private func statusTitle(_ status: NewAPICheckInStatus) -> String {
        switch status {
        case .success: return String(localized: "plugins.newapi.status.success", defaultValue: "成功")
        case .alreadySigned: return String(localized: "plugins.newapi.status.already", defaultValue: "已签到")
        case .authenticationExpired: return String(localized: "plugins.newapi.status.expired", defaultValue: "登录失效")
        case .serverError: return String(localized: "plugins.newapi.status.server_error", defaultValue: "服务错误")
        case .unknown: return String(localized: "plugins.newapi.status.unknown", defaultValue: "未知结果")
        }
    }

    private func statusIcon(_ status: NewAPICheckInStatus) -> String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .alreadySigned: return "checkmark.circle"
        case .authenticationExpired: return "person.crop.circle.badge.exclamationmark"
        case .serverError, .unknown: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: NewAPICheckInStatus) -> UIColor {
        switch status {
        case .success, .alreadySigned: return .systemGreen
        case .authenticationExpired: return .systemOrange
        case .serverError, .unknown: return .systemRed
        }
    }

    private func attemptSubtitle(_ attempt: NewAPICheckInAttempt) -> String {
        let code = attempt.statusCode.map { "HTTP \($0) · " } ?? ""
        return "\(code)\(Self.dateFormatter.string(from: attempt.attemptedAt)) · \(attempt.durationMilliseconds) ms"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
