import UIKit
import WebKit

/// Presents a WKWebView so users can log in to a Discourse forum via their browser.
/// Fires onSuccess once the Discourse session cookie `_t` is detected.
final class WebLoginViewController: UIViewController {
    private let targetURL: URL
    private let onSuccess: ([HTTPCookie], String?) -> Void
    private let credentialStore: AccountCredentialStore
    /// When set, auto-fill this saved account after the login form appears.
    private let preferredUsername: String?

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // Same persistent default store as in-app browser / mini-programs,
        // so a successful login is immediately visible to those WebViews.
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // iOS 16+ WKWebView can present the system passkey sheet for Discourse
        // WebAuthn (`navigator.credentials`). Do not isolate cookies/process.

        let wv = WKWebView(frame: .zero, configuration: config)
        config.userContentController.add(coordinator, name: "doerLoginCredentials")
        wv.navigationDelegate = coordinator
        wv.uiDelegate = coordinator
        wv.allowsBackForwardNavigationGestures = true
        wv.translatesAutoresizingMaskIntoConstraints = false
        return wv
    }()

    private var popupWebView: WKWebView?
    private lazy var popupContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.isHidden = true
        return view
    }()
    private lazy var popupCloseButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "xmark.circle.fill")
        config.baseForegroundColor = .secondaryLabel
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(closePopupTapped), for: .touchUpInside)
        button.accessibilityLabel = String(localized: "common.close")
        return button
    }()

    private lazy var coordinator = Coordinator(
        targetURL: targetURL,
        onCookiesReady: { [weak self] cookies in self?.handleCookiesReady(cookies) },
        onCredentialsCaptured: { [weak self] username, password in
            self?.credentialStore.save(username: username, password: password)
        }
    )

    private lazy var progressView: UIProgressView = {
        let pv = UIProgressView(progressViewStyle: .bar)
        pv.translatesAutoresizingMaskIntoConstraints = false
        return pv
    }()

    private var progressObservation: NSKeyValueObservation?

    init(
        targetURL: URL,
        preferredUsername: String? = nil,
        onSuccess: @escaping ([HTTPCookie], String?) -> Void
    ) {
        self.targetURL = targetURL
        self.preferredUsername = preferredUsername
        self.onSuccess = onSuccess
        credentialStore = AccountCredentialStore(host: targetURL.host ?? "forum")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "weblogin.title")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped)
        )
        let doneButton = UIBarButtonItem(
            title: String(localized: "weblogin.done"), style: .done, target: self, action: #selector(doneTapped)
        )
        let pasteButton = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.clipboard"), style: .plain, target: self, action: #selector(pasteLoginLinkTapped)
        )
        pasteButton.accessibilityLabel = String(localized: "weblogin.paste_link", defaultValue: "粘贴邮箱登录链接")
        let credentialsButton = UIBarButtonItem(
            image: UIImage(systemName: "key.fill"), style: .plain, target: self, action: #selector(credentialsTapped)
        )
        credentialsButton.accessibilityLabel = String(localized: "weblogin.saved_password", defaultValue: "已保存的账号密码")
        navigationItem.rightBarButtonItems = [doneButton, credentialsButton, pasteButton]

        view.addSubview(webView)
        view.addSubview(progressView)
        view.addSubview(popupContainer)
        popupContainer.addSubview(popupCloseButton)
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            popupContainer.topAnchor.constraint(equalTo: view.topAnchor),
            popupContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            popupContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            popupContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            popupCloseButton.topAnchor.constraint(equalTo: popupContainer.safeAreaLayoutGuide.topAnchor, constant: 8),
            popupCloseButton.trailingAnchor.constraint(equalTo: popupContainer.trailingAnchor, constant: -12),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            self?.progressView.progress = Float(wv.estimatedProgress)
            self?.progressView.isHidden = wv.estimatedProgress >= 1.0
        }

        coordinator.owner = self
        coordinator.attach(to: webView.configuration.websiteDataStore)
        webView.load(URLRequest(url: targetURL))
    }

    func presentLoginPopup(_ popup: WKWebView) {
        popupWebView?.removeFromSuperview()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popupContainer.insertSubview(popup, at: 0)
        NSLayoutConstraint.activate([
            popup.topAnchor.constraint(equalTo: popupCloseButton.bottomAnchor, constant: 4),
            popup.leadingAnchor.constraint(equalTo: popupContainer.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: popupContainer.trailingAnchor),
            popup.bottomAnchor.constraint(equalTo: popupContainer.bottomAnchor),
        ])
        popupWebView = popup
        popupContainer.isHidden = false
        view.bringSubviewToFront(popupContainer)
    }

    func dismissLoginPopup(_ webView: WKWebView? = nil) {
        if let webView, popupWebView !== webView { return }
        popupWebView?.removeFromSuperview()
        popupWebView = nil
        popupContainer.isHidden = true
    }

    @objc private func closePopupTapped() {
        dismissLoginPopup()
    }

    @objc private func cancelTapped() {
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func doneTapped() {
        coordinator.collectAndFireIfPossible(from: webView, force: true)
    }

    @objc private func pasteLoginLinkTapped() {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text),
              url.host?.caseInsensitiveCompare(targetURL.host ?? "") == .orderedSame,
              url.path.hasPrefix("/session/email-login/")
        else {
            showMessage(String(localized: "weblogin.invalid_email_link", defaultValue: "剪切板中没有有效的邮箱登录链接。"))
            return
        }
        webView.load(URLRequest(url: url))
    }

    @objc private func credentialsTapped() {
        let accounts = credentialStore.accounts
        let sheet = UIAlertController(
            title: String(localized: "weblogin.saved_password", defaultValue: "已保存的账号密码"),
            message: accounts.isEmpty
                ? String(localized: "weblogin.no_credentials", defaultValue: "登录时输入的账号密码会安全保存在 Keychain。")
                : String(localized: "weblogin.accounts.count", defaultValue: "已保存 \(accounts.count) 个账号"),
            preferredStyle: .actionSheet
        )
        for account in accounts {
            sheet.addAction(UIAlertAction(
                title: String(localized: "weblogin.fill_account", defaultValue: "填充 @\(account.username)"),
                style: .default
            ) { [weak self] _ in
                self?.injectCredentialHelpers(username: account.username, password: account.password)
            })
        }
        if !accounts.isEmpty {
            sheet.addAction(UIAlertAction(
                title: String(localized: "weblogin.clear_credentials", defaultValue: "清除保存的账号密码"),
                style: .destructive
            ) { [weak self] _ in
                self?.credentialStore.clear()
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?[1]
        present(sheet, animated: true)
    }

    /// Called after page load to auto-fill preferred / last-used credentials.
    func injectCredentialHelpers(fillSavedCredentials: Bool = true) {
        guard fillSavedCredentials else {
            injectCredentialHelpers(username: nil, password: nil)
            return
        }
        let account: AccountCredentialStore.Account? = {
            if let preferred = preferredUsername,
               let match = credentialStore.accounts.first(where: {
                   $0.username.caseInsensitiveCompare(preferred) == .orderedSame
               }) {
                return match
            }
            return credentialStore.lastUsedAccount
        }()
        injectCredentialHelpers(username: account?.username, password: account?.password)
    }

    private func injectCredentialHelpers(username: String?, password: String?) {
        let usernameLiteral = Self.javascriptLiteral(username)
        let passwordLiteral = Self.javascriptLiteral(password)
        let script = """
        (function() {
          const savedUser = \(usernameLiteral);
          const savedPass = \(passwordLiteral);
          let attempts = 0;
          const timer = setInterval(function() {
            const user = document.getElementById('login-account-name');
            const pass = document.getElementById('login-account-password');
            if (user && pass) {
              if (savedUser && savedPass) {
                user.value = savedUser;
                pass.value = savedPass;
                user.dispatchEvent(new Event('input', {bubbles:true}));
                pass.dispatchEvent(new Event('input', {bubbles:true}));
              }
              const button = document.getElementById('login-button');
              if (button && !button.dataset.doerCredentialHook) {
                button.dataset.doerCredentialHook = '1';
                button.addEventListener('click', function() {
                  if (user.value && pass.value) {
                    window.webkit.messageHandlers.doerLoginCredentials.postMessage({username:user.value,password:pass.value});
                  }
                }, true);
              }
              clearInterval(timer);
            }
            if (++attempts > 30) clearInterval(timer);
          }, 300);
        })();
        """
        webView.evaluateJavaScript(script)
    }

    private static func javascriptLiteral(_ value: String?) -> String {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8) else { return "null" }
        return String(array.dropFirst().dropLast())
    }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func handleCookiesReady(_ cookies: [HTTPCookie]) {
        Task { @MainActor in
            await WebCookieStore.shared.syncFromWebView(webView.configuration.websiteDataStore)
            if let ua = try? await webView.evaluateJavaScript("navigator.userAgent") as? String {
                WebCookieStore.shared.userAgent = ua
            }
            let ua = WebCookieStore.shared.userAgent
            dismiss(animated: true) {
                self.onSuccess(cookies, ua)
            }
        }
    }

    private final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, WKScriptMessageHandler {
        private let targetHost: String
        private let onCookiesReady: ([HTTPCookie]) -> Void
        private let onCredentialsCaptured: (String, String) -> Void
        private(set) var didCallback = false
        weak var owner: WebLoginViewController?

        init(
            targetURL: URL,
            onCookiesReady: @escaping ([HTTPCookie]) -> Void,
            onCredentialsCaptured: @escaping (String, String) -> Void
        ) {
            self.targetHost = targetURL.host ?? ""
            self.onCookiesReady = onCookiesReady
            self.onCredentialsCaptured = onCredentialsCaptured
        }

        func attach(to dataStore: WKWebsiteDataStore) {
            dataStore.httpCookieStore.add(self)
        }

        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            MitmTrust.handle(challenge, completionHandler: completionHandler)
        }

        func collectAndFireIfPossible(from webView: WKWebView, force: Bool = false) {
            guard !didCallback else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.didCallback else { return }
                let relevant = cookies.filter { $0.domain.contains(self.targetHost) }
                let hasSession = relevant.contains { $0.name == "_t" }
                guard hasSession || force else { return }
                self.didCallback = true
                Task { @MainActor in
                    self.onCookiesReady(relevant)
                }
            }
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cookies = await cookieStore.allCookies()
                guard !self.didCallback else { return }
                let relevant = cookies.filter { $0.domain.contains(self.targetHost) }
                let hasSession = relevant.contains { $0.name == "_t" }
                guard hasSession else { return }
                self.didCallback = true
                self.onCookiesReady(relevant)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            collectAndFireIfPossible(from: webView)
            owner?.injectCredentialHelpers()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "doerLoginCredentials",
                  let body = message.body as? [String: Any],
                  let username = body["username"] as? String, !username.isEmpty,
                  let password = body["password"] as? String, !password.isEmpty else { return }
            onCredentialsCaptured(username, password)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Passkey / OAuth often open a new document. Loading it in the login
            // webview aborts WebAuthn. Keep a real popup that shares the store.
            configuration.websiteDataStore = webView.configuration.websiteDataStore
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popup.allowsBackForwardNavigationGestures = true
            owner?.presentLoginPopup(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            owner?.dismissLoginPopup(webView)
        }
    }
}
