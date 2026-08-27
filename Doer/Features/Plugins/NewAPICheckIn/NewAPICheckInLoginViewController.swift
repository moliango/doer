import UIKit
import WebKit

enum NewAPICheckInWebLoginMode: Int {
    case newAPI
    case custom
}

@MainActor
final class NewAPICheckInWebLoginEntryViewController: UITableViewController, UITextFieldDelegate {
    private let store: NewAPICheckInStore
    private let service: NewAPICheckInService
    private let onSaved: () -> Void
    private let urlField = UITextField()
    private let typeControl = UISegmentedControl(items: ["NewAPI", String(localized: "plugins.newapi.login.type.custom", defaultValue: "自定义")])

    init(store: NewAPICheckInStore, service: NewAPICheckInService, onSaved: @escaping () -> Void) {
        self.store = store
        self.service = service
        self.onSaved = onSaved
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "plugins.newapi.login.entry.title", defaultValue: "WebView 登录")
        tableView.keyboardDismissMode = .interactive
        configureInputs()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return String(localized: "plugins.newapi.login.site", defaultValue: "站点")
        case 1: return String(localized: "plugins.newapi.login.type", defaultValue: "类型")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return String(localized: "plugins.newapi.login.site.help", defaultValue: "输入站点首页地址，例如 https://ai.example.com")
        case 1:
            return typeControl.selectedSegmentIndex == NewAPICheckInWebLoginMode.newAPI.rawValue
                ? String(localized: "plugins.newapi.login.type.newapi.help", defaultValue: "登录会自动检测完成，并提取用户 ID、访问令牌和 Cookie。")
                : String(localized: "plugins.newapi.login.type.custom.help", defaultValue: "登录后手动完成，仅保存 Cookie；签到请求可在平台详情中配置。")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section == 0 else { return nil }
        let container = UIView()
        let label = UILabel()
        label.text = String(localized: "plugins.newapi.login.site", defaultValue: "站点")
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        let pasteButton = UIButton(type: .system)
        pasteButton.setTitle(String(localized: "plugins.newapi.login.paste", defaultValue: "粘贴"), for: .normal)
        pasteButton.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        pasteButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        pasteButton.addTarget(self, action: #selector(pasteURL), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [label, UIView(), pasteButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        return container
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        switch indexPath.section {
        case 0:
            urlField.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(urlField)
            NSLayoutConstraint.activate([
                urlField.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                urlField.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                urlField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                urlField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                urlField.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            ])
        case 1:
            typeControl.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(typeControl)
            NSLayoutConstraint.activate([
                typeControl.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                typeControl.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                typeControl.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                typeControl.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            ])
        default:
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "common.continue", defaultValue: "继续")
            content.textProperties.alignment = .center
            content.textProperties.color = canContinue ? view.tintColor : .tertiaryLabel
            content.textProperties.font = .preferredFont(forTextStyle: .headline)
            cell.contentConfiguration = content
            cell.selectionStyle = canContinue ? .default : .none
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 2,
              let baseURL = NewAPICheckInLoginSupport.normalizedLoginURL(urlField.text ?? "")
        else { return }
        view.endEditing(true)
        let mode = NewAPICheckInWebLoginMode(rawValue: typeControl.selectedSegmentIndex) ?? .newAPI
        let controller = NewAPICheckInLoginViewController(
            baseURL: baseURL,
            mode: mode,
            store: store,
            service: service,
            onSaved: onSaved
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func configureInputs() {
        urlField.placeholder = "https://example.com"
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.textContentType = .URL
        urlField.clearButtonMode = .whileEditing
        urlField.returnKeyType = .continue
        urlField.delegate = self
        urlField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        typeControl.selectedSegmentIndex = NewAPICheckInWebLoginMode.newAPI.rawValue
        typeControl.addTarget(self, action: #selector(typeChanged), for: .valueChanged)
    }

    private var canContinue: Bool {
        NewAPICheckInLoginSupport.normalizedLoginURL(urlField.text ?? "") != nil
    }

    @objc private func pasteURL() {
        urlField.text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        inputChanged()
    }

    @objc private func inputChanged() {
        tableView.reloadSections(IndexSet(integer: 2), with: .none)
    }

    @objc private func typeChanged() {
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard canContinue else { return false }
        tableView(tableView, didSelectRowAt: IndexPath(row: 0, section: 2))
        return true
    }
}

@MainActor
final class NewAPICheckInLoginViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let baseURL: URL
    private let mode: NewAPICheckInWebLoginMode
    private let store: NewAPICheckInStore
    private let service: NewAPICheckInService
    private let existingPlatform: NewAPICheckInPlatform?
    private let onSaved: () -> Void

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "Version/17.4 Mobile/15E148 Safari/604.1"
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        return view
    }()

    private let statusContainer = UIView()
    private let statusLabel = UILabel()
    private let completeButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)

    private var probeTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var isProbing = false
    private var didSave = false

    init(
        baseURL: URL,
        mode: NewAPICheckInWebLoginMode = .newAPI,
        store: NewAPICheckInStore,
        service: NewAPICheckInService,
        existingPlatform: NewAPICheckInPlatform? = nil,
        onSaved: @escaping () -> Void
    ) {
        self.baseURL = baseURL
        self.mode = mode
        self.store = store
        self.service = service
        self.existingPlatform = existingPlatform
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = baseURL.host ?? String(localized: "plugins.newapi.web_login", defaultValue: "网页登录")
        view.backgroundColor = .systemBackground
        configureLayout()
        configureNavigation()
        updateWaitingStatus(currentURL: nil)
        webView.load(URLRequest(url: baseURL))
        if mode == .newAPI {
            startPolling()
            startFallbackTimer()
        } else {
            showManualCompletionButton()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true || isBeingDismissed {
            cancelWork()
        }
    }

    @MainActor
    deinit {
        probeTask?.cancel()
        pollingTask?.cancel()
        fallbackTask?.cancel()
    }

    private func configureLayout() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        completeButton.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false

        statusContainer.backgroundColor = .secondarySystemBackground
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        activityIndicator.hidesWhenStopped = true

        completeButton.setTitle(String(localized: "plugins.newapi.login.complete", defaultValue: "完成登录"), for: .normal)
        completeButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        completeButton.addTarget(self, action: #selector(completeTapped), for: .touchUpInside)
        completeButton.isHidden = mode == .newAPI

        view.addSubview(webView)
        view.addSubview(statusContainer)
        statusContainer.addSubview(statusLabel)
        statusContainer.addSubview(activityIndicator)
        statusContainer.addSubview(completeButton)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: statusContainer.topAnchor),

            statusContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            statusContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            activityIndicator.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 16),
            activityIndicator.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: activityIndicator.trailingAnchor, constant: 10),
            statusLabel.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -10),

            completeButton.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: 12),
            completeButton.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -16),
            completeButton.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
        ])
    }

    private func configureNavigation() {
        // Match original ManualSignInView toolbar: refresh + clear-cookie menu.
        let refresh = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(refreshTapped)
        )
        refresh.accessibilityLabel = String(localized: "common.refresh", defaultValue: "刷新")

        let clearSite = UIAction(
            title: String(
                localized: "plugins.newapi.login.clear_site_cookies",
                defaultValue: "清除本站 Cookie"
            ),
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.clearCookiesAndReload(includingShared: false)
            }
        }
        let clearAll = UIAction(
            title: String(
                localized: "plugins.newapi.login.clear_all_cookies",
                defaultValue: "清除全部 Cookie（含 OAuth）"
            ),
            image: UIImage(systemName: "trash.fill"),
            attributes: .destructive
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.clearCookiesAndReload(includingShared: true)
            }
        }
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [clearSite, clearAll])
        )
        more.accessibilityLabel = String(localized: "common.more", defaultValue: "更多")

        navigationItem.rightBarButtonItems = [more, refresh]
    }

    @objc private func refreshTapped() {
        if webView.url == nil {
            webView.load(URLRequest(url: baseURL))
        } else {
            webView.reload()
        }
    }

    /// Clear cookies then reload baseURL.
    /// - `includingShared == false`: only this platform's domain (preserve LinuxDO/GitHub OAuth cookies).
    /// - `includingShared == true`: wipe entire WKWebsiteDataStore (all sites + OAuth).
    private func clearCookiesAndReload(includingShared: Bool) async {
        guard let targetHost = baseURL.host?.lowercased() else { return }
        let dataStore = webView.configuration.websiteDataStore

        if includingShared {
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            await dataStore.removeData(ofTypes: types, modifiedSince: .distantPast)
        } else {
            let allCookies = await dataStore.httpCookieStore.allCookies()
            let platformCookies = allCookies.filter {
                NewAPICheckInLoginSupport.cookieDomain($0.domain, matchesHost: targetHost)
            }
            for cookie in platformCookies {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    dataStore.httpCookieStore.delete(cookie) {
                        continuation.resume()
                    }
                }
            }
        }

        // Also drop saved platform credential cookies so the next probe is clean.
        if let existingPlatform {
            if let previous = try? await store.credential(for: existingPlatform.id) {
                let cleaned = NewAPICheckInCredential(
                    accessToken: previous.accessToken,
                    userID: previous.userID,
                    cookieHeader: nil,
                    additionalHeaders: previous.additionalHeaders
                )
                try? await store.save(existingPlatform, credential: cleaned)
            }
        }

        // Reset auto-login detection after a wipe.
        didSave = false
        isProbing = false
        if mode == .newAPI {
            completeButton.isHidden = true
            updateWaitingStatus(currentURL: nil)
            startPolling()
            startFallbackTimer()
        } else {
            showManualCompletionButton()
        }

        webView.load(URLRequest(url: baseURL))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func completeTapped() {
        Task { [weak self] in
            await self?.completeManually()
        }
    }

    private func startFallbackTimer() {
        guard fallbackTask == nil else { return }
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self, !self.didSave else { return }
            self.showManualCompletionButton()
        }
    }

    private func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, !self.didSave else { return }
                self.scheduleProbe(delayNanoseconds: 0, userInitiated: false)
            }
        }
    }

    private func scheduleProbe(delayNanoseconds: UInt64 = 700_000_000, userInitiated: Bool) {
        guard !isProbing else { return }
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            defer { self?.probeTask = nil }
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled, let self else { return }
            await self.probe(userInitiated: userInitiated)
        }
    }

    private func probe(userInitiated: Bool) async {
        guard !didSave, !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        updateStatus(String(localized: "plugins.newapi.login.probing", defaultValue: "正在验证登录状态…"), isBusy: true)

        let localStorageValue = try? await webView.evaluateJavaScript(NewAPICheckInLoginSupport.localStorageScript)
        let hints = NewAPICheckInLoginSupport.parseLocalStorageResult(localStorageValue)
        let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let cookieHeader = NewAPICheckInLoginSupport.cookieHeader(
            from: allCookies,
            baseURL: baseURL,
            currentURL: webView.url
        )
        guard cookieHeader != nil || hints.userID != nil else {
            updateWaitingStatus(currentURL: webView.url)
            return
        }
        let probeBase = resolvedProbeBaseURL()
        let result = await service.probeLogin(
            baseURL: probeBase,
            cookieHeader: cookieHeader,
            hints: hints
        )

        guard NewAPICheckInLoginSupport.hasValidLoginEvidence(
            apiLoggedIn: result.isLoggedIn,
            hints: hints,
            hasTargetCookies: cookieHeader != nil
        ) else {
            if userInitiated {
                updateStatus(
                    result.message ?? String(localized: "plugins.newapi.login.not_detected", defaultValue: "暂未检测到有效登录，请确认网页已登录"),
                    isBusy: false
                )
            } else {
                updateWaitingStatus(currentURL: webView.url)
            }
            return
        }

        await saveLogin(
            probeBase: probeBase,
            cookieHeader: cookieHeader,
            hints: hints,
            result: result
        )
    }

    private func completeManually() async {
        guard !didSave, !isProbing else { return }
        isProbing = true
        defer { isProbing = false }
        updateStatus(String(localized: "plugins.newapi.login.probing", defaultValue: "正在验证登录状态…"), isBusy: true)

        let localStorageValue = try? await webView.evaluateJavaScript(NewAPICheckInLoginSupport.localStorageScript)
        let hints = NewAPICheckInLoginSupport.parseLocalStorageResult(localStorageValue)
        let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let cookieHeader = NewAPICheckInLoginSupport.cookieHeader(
            from: allCookies,
            baseURL: baseURL,
            currentURL: webView.url
        )
        guard mode == .custom || cookieHeader != nil || hints.userID != nil else {
            updateStatus(
                String(localized: "plugins.newapi.login.not_detected", defaultValue: "暂未检测到有效登录，请确认网页已登录"),
                isBusy: false
            )
            return
        }
        let emptyResult = NewAPICheckInLoginProbeResult(
            isLoggedIn: false,
            userID: nil,
            accessToken: nil,
            quotaValue: nil,
            quotaUnit: nil,
            message: nil
        )
        await saveLogin(
            probeBase: resolvedProbeBaseURL(),
            cookieHeader: cookieHeader,
            hints: hints,
            result: emptyResult
        )
    }

    private func saveLogin(
        probeBase: URL,
        cookieHeader: String?,
        hints: NewAPICheckInLoginHints,
        result: NewAPICheckInLoginProbeResult
    ) async {

        let previousCredential: NewAPICheckInCredential?
        if let existingPlatform {
            previousCredential = try? await store.credential(for: existingPlatform.id)
        } else {
            previousCredential = nil
        }
        let credential = NewAPICheckInCredential(
            accessToken: result.accessToken ?? hints.accessToken ?? previousCredential?.accessToken,
            userID: result.userID ?? hints.userID ?? previousCredential?.userID,
            cookieHeader: cookieHeader ?? previousCredential?.cookieHeader,
            additionalHeaders: previousCredential?.additionalHeaders ?? [:]
        )
        var platform = existingPlatform ?? NewAPICheckInPlatform(
            name: baseURL.host ?? baseURL.absoluteString,
            baseURL: probeBase.absoluteString,
            platformType: mode == .newAPI ? .newAPI : .custom,
            source: .webView
        )
        if let existingPlatform,
           let latest = await store.platforms().first(where: { $0.id == existingPlatform.id }) {
            platform = latest
        }
        platform.baseURL = probeBase.absoluteString
        platform.lastQuotaValue = result.quotaValue
        platform.lastQuotaUnit = result.quotaUnit

        do {
            try await store.save(platform, credential: credential)
            didSave = true
            cancelWork()
            updateStatus(String(localized: "plugins.newapi.login.success", defaultValue: "登录成功，凭证已安全保存"), isBusy: false)
            onSaved()
            if let navigationController,
               navigationController.viewControllers.dropLast().last is NewAPICheckInWebLoginEntryViewController,
               let destination = navigationController.viewControllers.dropLast(2).last {
                navigationController.popToViewController(destination, animated: true)
            } else if let navigationController,
                      navigationController.viewControllers.first === self,
                      presentingViewController != nil {
                dismiss(animated: true)
            } else {
                navigationController?.popViewController(animated: true)
            }
        } catch {
            updateStatus(error.localizedDescription, isBusy: false)
        }
    }

    private func resolvedProbeBaseURL() -> URL {
        guard let currentURL = webView.url,
              NewAPICheckInLoginSupport.samePlatformFamily(baseURL, currentURL),
              var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false)
        else { return baseURL }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? baseURL
    }

    private func updateStatus(_ text: String, isBusy: Bool) {
        statusLabel.text = text
        completeButton.isEnabled = !isBusy
        completeButton.alpha = isBusy ? 0.55 : 1
        if isBusy {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }

    private func updateWaitingStatus(currentURL: URL?) {
        let baseText = String(localized: "plugins.newapi.login.waiting", defaultValue: "正在等待登录…")
        if let host = currentURL?.host,
           host.caseInsensitiveCompare(baseURL.host ?? "") != .orderedSame {
            let current = String(
                format: String(localized: "plugins.newapi.login.current_host", defaultValue: "当前在 %@"),
                host
            )
            updateStatus("\(baseText)\n\(current)", isBusy: mode == .newAPI && completeButton.isHidden)
        } else {
            updateStatus(baseText, isBusy: mode == .newAPI && completeButton.isHidden)
        }
    }

    private func showManualCompletionButton() {
        completeButton.isHidden = false
        updateWaitingStatus(currentURL: webView.url)
    }

    private func cancelWork() {
        probeTask?.cancel()
        probeTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateWaitingStatus(currentURL: webView.url)
        if mode == .newAPI {
            scheduleProbe(userInitiated: false)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateStatus(error.localizedDescription, isBusy: false)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        updateStatus(error.localizedDescription, isBusy: false)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let requestURL = navigationAction.request.url {
            webView.load(URLRequest(url: requestURL))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "data", "blob", nil:
            break
        default:
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
