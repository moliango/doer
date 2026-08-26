import UIKit
import WebKit

/// FluxDo-style login: hCaptcha + CSRF + POST /session.json inside WKWebView
/// so TLS/JA3 matches the store that holds `cf_clearance`.
@MainActor
final class NativeLoginSessionRunner: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    enum Outcome {
        case success
        case secondFactor(totpEnabled: Bool)
        case failure(String)
        case canceled
    }

    private let baseURL: URL
    private let siteKey: String?
    private var webView: WKWebView?
    private var overlay: UIView?
    private var identifier = ""
    private var password = ""
    private var finished = false
    private var continuation: CheckedContinuation<Outcome, Never>?

    init(baseURL: URL, siteKey: String?) {
        self.baseURL = baseURL
        self.siteKey = siteKey
        super.init()
    }

    func run(
        identifier: String,
        password: String,
        from host: UIViewController,
        onNeedSecondFactor: @escaping () async -> String?
    ) async -> Outcome {
        self.identifier = identifier
        self.password = password
        finished = false
        let webView = makeWebView()
        self.webView = webView
        if siteKey == nil {
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            webView.isHidden = true
            host.view.addSubview(webView)
        } else {
            attachCaptchaOverlay(to: host, webView: webView)
        }

        await WebCookieStore.shared.syncToWebView(webView.configuration.websiteDataStore, for: baseURL)
        webView.loadHTMLString(Self.html(siteKey: siteKey), baseURL: baseURL)
        let first = await waitForOutcome()
        switch first {
        case .secondFactor:
            overlay?.isHidden = true
            while true {
                let code = await onNeedSecondFactor()
                guard let code, !code.isEmpty else {
                    teardown()
                    return .canceled
                }
                finished = false
                evaluateLogin(hcaptchaToken: nil, secondFactorToken: code)
                let next = await waitForOutcome()
                if case .secondFactor = next {
                    continue
                }
                teardown()
                return next
            }
        default:
            teardown()
            return first
        }
    }

    private func waitForOutcome() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func teardown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "doerNativeLogin")
        overlay?.removeFromSuperview()
        overlay = nil
        webView?.removeFromSuperview()
        webView = nil
    }

    private func attachCaptchaOverlay(to host: UIViewController, webView: WKWebView) {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(overlay)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(card)

        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(header)

        let icon = UIImageView(image: UIImage(systemName: "checkmark.shield.fill"))
        icon.tintColor = AppSettings.shared.themeStyle.accentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(icon)

        let title = UILabel()
        title.text = String(localized: "native_login.captcha.title", defaultValue: "完成人机验证")
        title.font = AppSettings.shared.appInterfaceFont(ofSize: 17, weight: .semibold, fallback: .systemFont(ofSize: 17, weight: .semibold))
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        close.tintColor = .secondaryLabel
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(cancelCaptcha), for: .touchUpInside)
        header.addSubview(close)

        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.keyboardDismissMode = .interactive
        card.addSubview(webView)

        let screen = host.view.bounds
        let panelHeight = min(640, max(420, screen.height - 96))
        let widthConstraint = card.widthAnchor.constraint(equalTo: overlay.widthAnchor, constant: -24)
        widthConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: host.view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
            card.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -12),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            widthConstraint,
            card.heightAnchor.constraint(equalToConstant: panelHeight),
            header.topAnchor.constraint(equalTo: card.topAnchor),
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 36),
            close.heightAnchor.constraint(equalToConstant: 36),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        self.overlay = overlay
    }

    @objc private func cancelCaptcha() {
        finish(.canceled)
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController.add(self, name: "doerNativeLogin")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if siteKey == nil {
            evaluateLogin(hcaptchaToken: nil, secondFactorToken: nil)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "doerNativeLogin" else { return }
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        switch event {
        case "hcaptcha_pass":
            overlay?.isHidden = true
            let token = body["token"] as? String
            evaluateLogin(hcaptchaToken: token, secondFactorToken: nil)
        case "hcaptcha_error", "hcaptcha_expired":
            finish(.failure(String(localized: "native_login.captcha_failed", defaultValue: "人机验证失败，请重试")))
        case "login_result":
            handleLoginResult(body)
        default:
            break
        }
    }

    private func evaluateLogin(hcaptchaToken: String?, secondFactorToken: String?) {
        let id = Self.jsString(identifier)
        let pwd = Self.jsString(password)
        let tok = hcaptchaToken.map(Self.jsString) ?? "null"
        let sf = secondFactorToken.map(Self.jsString) ?? "null"
        webView?.evaluateJavaScript("window.__doerLogin(\(id), \(pwd), \(tok), \(sf));")
    }

    private func handleLoginResult(_ body: [String: Any]) {
        let phase = body["phase"] as? String ?? ""
        let status = Self.intValue(body["status"])
        let raw = body["body"] as? String ?? ""
        switch phase {
        case "csrf":
            finish(.failure(String(localized: "native_login.csrf_failed", defaultValue: "登录校验失败，请先完成 Cloudflare 验证后重试")))
        case "hcaptcha":
            finish(.failure(String(localized: "native_login.captcha_failed", defaultValue: "人机验证失败，请重试")))
        case "exception":
            finish(.failure(raw.isEmpty ? String(localized: "native_login.network", defaultValue: "网络异常") : raw))
        case "session":
            finish(Self.parseSession(status: status, body: raw))
        default:
            finish(.failure(String(localized: "native_login.unknown", defaultValue: "登录失败")))
        }
    }

    nonisolated static func parseSession(status: Int, body: String) -> Outcome {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure("Discourse 返回非 JSON: HTTP \(status)")
        }
        let reason = json["reason"] as? String ?? ""
        let error = (json["error"] as? String) ?? (json["message"] as? String) ?? ""
        if needsSecondFactor(reason: reason, error: error, json: json) {
            let totp = json["totp_enabled"] as? Bool
            return .secondFactor(totpEnabled: totp != false)
        }
        if !reason.isEmpty {
            switch reason {
            case "invalid_credentials":
                return .failure(String(localized: "native_login.invalid_credentials", defaultValue: "用户名或密码错误"))
            case "not_activated":
                let email = json["sent_to_email"] as? String ?? ""
                return .failure(String(localized: "native_login.not_activated", defaultValue: "账号未激活，请到邮箱完成激活") + (email.isEmpty ? "" : " (\(email))"))
            case "not_approved":
                return .failure(String(localized: "native_login.not_approved", defaultValue: "账号尚未通过审核"))
            case "expired":
                return .failure(String(localized: "native_login.password_expired", defaultValue: "密码已过期，请用浏览器登录重设密码"))
            default:
                return .failure(error.isEmpty ? reason : error)
            }
        }
        if json["error"] != nil, json["user"] == nil {
            return .failure(error.isEmpty ? String(localized: "native_login.unknown", defaultValue: "登录失败") : error)
        }
        return .success
    }

    nonisolated static func needsSecondFactor(reason: String, error: String, json: [String: Any]) -> Bool {
        let reasonKey = reason.lowercased()
        if reasonKey == "invalid_second_factor"
            || reasonKey == "second_factor"
            || reasonKey.contains("second_factor") {
            return true
        }
        if json["totp_enabled"] != nil
            || json["backup_enabled"] != nil
            || json["security_key_enabled"] != nil
            || json["allowed_second_factor_methods"] != nil {
            return true
        }
        let hay = (reason + error).lowercased()
        return hay.contains("second factor")
            || error.contains("双重身份")
            || error.contains("二步验证")
            || error.contains("两步验证")
    }

    nonisolated private static func intValue(_ any: Any?) -> Int {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? Double { return Int(value) }
        if let value = any as? String, let parsed = Int(value) { return parsed }
        return 0
    }

    private static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func html(siteKey: String?) -> String {
        let endpoints = "['/captcha/hcaptcha/create.json','/hcaptcha/create.json']"
        let captchaBlock: String
        if let siteKey, !siteKey.isEmpty {
            captchaBlock = """
            <p class="tip">勾选下方方框，<b>确认你不是机器人</b>即可继续登录</p>
            <div id="cap" class="h-captcha" data-sitekey="\(siteKey)" data-callback="onPass" data-error-callback="onErr" data-expired-callback="onExp" data-size="normal"></div>
            <script src="https://js.hcaptcha.com/1/api.js" async defer></script>
            """
        } else {
            captchaBlock = "<p class=\"tip\">正在登录…</p>"
        }
        return """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
        <style>
          html,body{margin:0;padding:0;width:100%;height:100%;font-family:-apple-system,system-ui,sans-serif;background:transparent;overflow:auto}
          .wrap{box-sizing:border-box;min-height:100%;display:flex;flex-direction:column;align-items:center;justify-content:flex-start;gap:18px;padding:20px 16px 40px;text-align:center}
          .tip{font-size:15px;line-height:1.6;color:#666;max-width:280px;margin:0}
          .tip b{color:#111;font-weight:600}
          .h-captcha{min-height:78px}
        </style></head><body>
        <div class="wrap">\(captchaBlock)</div>
        <script>
        function call(event, extra) {
          try {
            var payload = extra || {};
            payload.event = event;
            window.webkit.messageHandlers.doerNativeLogin.postMessage(payload);
          } catch (e) {}
        }
        function onPass(token) { call('hcaptcha_pass', {token: token}); }
        function onErr(err) { call('hcaptcha_error', {token: String(err || '')}); }
        function onExp() { call('hcaptcha_expired', {}); }
        window.__doerLogin = async function(identifier, password, hcaptchaToken, secondFactorToken) {
          function done(p) { p.event = 'login_result'; call('login_result', p); }
          try {
            var c = await fetch('/session/csrf', {
              method: 'GET',
              headers: { 'X-Requested-With': 'XMLHttpRequest', 'Accept': 'application/json' },
              credentials: 'include', cache: 'no-store'
            });
            if (c.status !== 200) { return done({ phase: 'csrf', status: c.status, body: await c.text() }); }
            var csrf = (await c.json()).csrf;
            if (hcaptchaToken) {
              var endpoints = \(endpoints);
              var ok = false, last = null;
              for (var i = 0; i < endpoints.length; i++) {
                try {
                  var h = await fetch(endpoints[i], {
                    method: 'POST', credentials: 'include',
                    headers: {
                      'Content-Type': 'application/x-www-form-urlencoded',
                      'X-CSRF-Token': csrf,
                      'X-Requested-With': 'XMLHttpRequest'
                    },
                    body: 'token=' + encodeURIComponent(hcaptchaToken)
                  });
                  last = { status: h.status, body: await h.text() };
                  if (h.status === 200) { ok = true; break; }
                  if (h.status !== 404) break;
                } catch (e) { last = { status: 0, body: String(e) }; }
              }
              if (!ok) return done({ phase: 'hcaptcha', status: last ? last.status : 0, body: JSON.stringify(last) });
            }
            var form = 'login=' + encodeURIComponent(identifier) + '&password=' + encodeURIComponent(password);
            if (secondFactorToken) {
              form += '&second_factor_token=' + encodeURIComponent(secondFactorToken) + '&second_factor_method=1';
            }
            var s = await fetch('/session.json', {
              method: 'POST', credentials: 'include',
              headers: {
                'Content-Type': 'application/x-www-form-urlencoded',
                'X-CSRF-Token': csrf,
                'X-Requested-With': 'XMLHttpRequest',
                'Accept': 'application/json'
              },
              body: form
            });
            return done({ phase: 'session', status: s.status, body: await s.text() });
          } catch (e) {
            return done({ phase: 'exception', status: 0, body: String(e) });
          }
        };
        </script>
        </body></html>
        """
    }
}
