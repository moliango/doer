import UIKit
import WebKit

@MainActor
final class CloudflareBackgroundVerificationService {
    static let shared = CloudflareBackgroundVerificationService()
    static let needsUserInteractionNotification = Notification.Name("CloudflareBackgroundVerificationNeedsUserInteraction")

    private let attemptCooldown: TimeInterval = 12
    private var activeAttempts: [String: Task<Bool, Never>] = [:]
    private var lastAttemptAt: [String: Date] = [:]
    private var foregroundVerificationKeys = Set<String>()

    private init() {}

    func beginForegroundVerification(baseURL rawBaseURL: URL) async {
        let baseURL = normalizedBaseURL(rawBaseURL)
        let key = baseURL.absoluteString
        foregroundVerificationKeys.insert(key)
        CloudflareVerificationPolicy.markForegroundVerificationActive(baseURL: key)
        guard let task = activeAttempts[key] else { return }
        log("cancelled base=\(key) reason=foreground_verification")
        task.cancel()
        _ = await task.value
        activeAttempts[key] = nil
    }

    func endForegroundVerification(baseURL rawBaseURL: URL) {
        let key = normalizedBaseURL(rawBaseURL).absoluteString
        foregroundVerificationKeys.remove(key)
        CloudflareVerificationPolicy.clearForegroundVerificationActive(baseURL: key)
        log("foreground verification ended base=\(key)")
    }

    func ensureInBackground(baseURL rawBaseURL: String, reason: String, responseURL: URL? = nil, force: Bool = false) {
        guard let baseURL = URL(string: normalizedBaseURL(rawBaseURL)) else { return }
        ensureInBackground(baseURL: baseURL, reason: reason, responseURL: responseURL, force: force)
    }

    func ensureInBackground(baseURL: URL, reason: String, responseURL: URL? = nil, force: Bool = false) {
        Task { @MainActor in
            _ = await ensureVerified(baseURL: baseURL, reason: reason, responseURL: responseURL, force: force)
        }
    }

    @discardableResult
    func ensureVerified(baseURL rawBaseURL: URL, reason: String, responseURL: URL? = nil, force: Bool = false) async -> Bool {
        let baseURL = normalizedBaseURL(rawBaseURL)
        let key = baseURL.absoluteString

        guard !foregroundVerificationKeys.contains(key) else {
            log("skipped reason=\(reason) base=\(key) skip=foreground_verification")
            return false
        }
        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL) {
            log("skipped reason=\(reason) base=\(key) skip=verification_grace")
            return true
        }
        if !CloudflareVerificationPolicy.shouldAttemptBackgroundVerification(baseURL: key) {
            log("skipped reason=\(reason) base=\(key) skip=background_cooldown")
            postNeedsUserInteraction(baseURL: baseURL, responseURL: responseURL, reason: "background_cooldown")
            return false
        }

        if let active = activeAttempts[key] {
            log("joined active attempt reason=\(reason) base=\(key)")
            return await active.value
        }

        if !force, let lastAttempt = lastAttemptAt[key],
           Date().timeIntervalSince(lastAttempt) < attemptCooldown {
            // Only the post-pass grace counts as verified. A leftover cf_clearance
            // can be stale and must not pretend the challenge is gone.
            if CloudflareVerificationPolicy.shouldTreatCooldownAsVerified(
                isInGrace: CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL)
            ) {
                log("skipped reason=\(reason) base=\(key) skip=attempt_cooldown_in_grace")
                return true
            }
            log("skipped reason=\(reason) base=\(key) skip=attempt_cooldown")
            postNeedsUserInteraction(baseURL: baseURL, responseURL: responseURL, reason: "cooldown")
            return false
        }

        lastAttemptAt[key] = Date()
        let task = Task { @MainActor in
            let attempt = CloudflareBackgroundVerificationAttempt(baseURL: baseURL, responseURL: responseURL, reason: reason)
            return await attempt.run()
        }
        activeAttempts[key] = task
        let ok = await task.value
        let wasCancelled = task.isCancelled
        activeAttempts[key] = nil

        if wasCancelled {
            log("discarded cancelled attempt reason=\(reason) base=\(key)")
            return false
        }

        if ok {
            log("completed reason=\(reason) base=\(key)")
            CloudflareVerificationPolicy.markBackgroundAttemptSucceeded(baseURL: key)
            CloudflareVerificationPolicy.markVerificationGrace(baseURL: baseURL)
            NotificationCenter.default.post(
                name: DiscourseAPI.cloudflareVerificationCompletedNotification,
                object: nil,
                userInfo: [
                    DiscourseAPI.cloudflareBaseURLUserInfoKey: key.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                ]
            )
        } else if CloudflareVerificationPolicy.shouldPromptAfterBackgroundFailure(
            isInGrace: CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL)
        ) {
            // 交互式挑战在隐藏页面里过不去：冷却一段时间，别让每次挑战都白等。
            CloudflareVerificationPolicy.markBackgroundAttemptFailed(baseURL: key)
            postNeedsUserInteraction(baseURL: baseURL, responseURL: responseURL, reason: reason)
        } else {
            log("failed during verification grace reason=\(reason) base=\(key); skip user prompt")
        }

        return ok
    }

    private func postNeedsUserInteraction(baseURL: URL, responseURL: URL?, reason: String) {
        if !CloudflareVerificationPolicy.shouldPromptAfterBackgroundFailure(
            isInGrace: CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL)
        ) {
            log("needs user interaction suppressed reason=\(reason) base=\(baseURL.absoluteString) grace=true")
            return
        }
        log("needs user interaction reason=\(reason) base=\(baseURL.absoluteString)")
        var userInfo: [String: Any] = [
            DiscourseAPI.cloudflareBaseURLUserInfoKey: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        ]
        if let responseURL {
            userInfo[DiscourseAPI.cloudflareResponseURLUserInfoKey] = responseURL
        }
        NotificationCenter.default.post(
            name: Self.needsUserInteractionNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    private func normalizedBaseURL(_ url: URL) -> URL {
        let text = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: text) ?? url
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func log(_ message: String) {
        DohDebugLog.record("background \(message)", subsystem: "CF")
    }
}

@MainActor
private final class CloudflareBackgroundVerificationAttempt: NSObject, WKNavigationDelegate {
    private let baseURL: URL
    private let responseURL: URL?
    private let reason: String
    /// Ephemeral: the hidden challenge load must not be a second `_t` client and
    /// must not evict the in-app browser's copy of the ticket.
    private let dataStore = WKWebsiteDataStore.nonPersistent()
    /// 隐藏尝试的预算。它挡在人工过盾页前面，所以不能太长：非交互挑战一般在
    /// 1–4 秒内自动放行，8 秒还没拿到新 cookie 就基本可以判定过不去了。
    private let maxDurationNanoseconds: UInt64 = 8_000_000_000
    private let checkDelays: [UInt64] = [
        250_000_000,
        700_000_000,
        1_500_000_000,
        2_500_000_000,
        4_000_000_000,
        7_000_000_000,
        10_000_000_000,
    ]

    private var webView: WKWebView?
    private var didFinish = false
    private var didFail = false
    private var lastFailure: String?
    private var initialClearanceValue: String?

    init(baseURL: URL, responseURL: URL?, reason: String) {
        self.baseURL = baseURL
        self.responseURL = responseURL
        self.reason = reason
        super.init()
    }

    func run() async -> Bool {
        let startedAt = Date()
        log("started reason=\(reason) base=\(baseURL.absoluteString) response=\(responseURL?.absoluteString ?? "none")")
        initialClearanceValue = WebCookieStore.shared.cookieValue(named: "cf_clearance", for: baseURL)
        await LightweightDohProxyService.shared.prepareBrowserProxy()
        LightweightDohProxyService.shared.applyWebViewProxy(to: dataStore)
        await WebCookieStore.shared.syncToWebView(dataStore, for: baseURL, excluding: ["_t"])
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // WebKit 只把挂在窗口上的页面当可见：不在窗口里时 `document.hidden` 为真、
        // rAF 不跑，Turnstile 的 JS 根本不会初始化。所以这里用真实尺寸挂在窗口上，
        // 再整块移出可视区——用户看不到，但页面是「可见」的。
        // 1×1 的离屏尺寸还会被当成异常环境，直接把挑战判死。
        let window = Self.hostWindow()
        let size = window?.bounds.size ?? CGSize(width: 390, height: 844)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: -(size.height + 200), width: size.width, height: size.height),
            configuration: configuration
        )
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        // 与过盾页/登录页同一 UA：`cf_clearance` 绑定 UA，换一个就等于白过。
        webView.customUserAgent = CloudflareVerificationPolicy.browserUserAgent(
            stored: WebCookieStore.shared.userAgent
        )
        window?.addSubview(webView)
        self.webView = webView

        var request = URLRequest(url: verificationURL())
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        webView.load(request)

        let ok = await runChecks()
        if ok {
            await updateStoredUserAgentFromWebView()
        }

        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        log("finished reason=\(reason) ok=\(ok) elapsedMs=\(elapsedMs) didFinish=\(didFinish) didFail=\(didFail) failure=\(lastFailure ?? "none")")
        return ok
    }

    private func runChecks() async -> Bool {
        let startedAt = Date()
        for delay in checkDelays {
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return false }
            if UInt64(Date().timeIntervalSince(startedAt) * 1_000_000_000) > maxDurationNanoseconds {
                break
            }
            if await checkClearance() {
                return true
            }
        }
        return false
    }

    private func checkClearance() async -> Bool {
        await syncCloudflareCookieFromWebView()
        guard let webView else { return false }

        let clearanceValue = WebCookieStore.shared.cookieValue(named: "cf_clearance", for: baseURL)
        // 这次隐藏加载是「已经被拦了」才发起的，罐子里那枚旧 cookie 就是被拒的那枚，
        // 拿它当通过会让 grace 生效、盾被藏起来，而 API 依旧 403。必须拿到新的。
        let hasClearance = CloudflareVerificationPolicy.hasUsableClearance(
            currentValue: clearanceValue,
            initialValue: initialClearanceValue,
            requiresFreshValue: true
        )
        let activeChallenge = await pageHasActiveCloudflareChallenge(in: webView)
        let currentURL = webView.url?.absoluteString ?? "none"
        let visibility = (try? await webView.evaluateJavaScript("document.visibilityState") as? String) ?? "unknown"

        log("check url=\(currentURL) visibility=\(visibility) cf=\(hasClearance) activeChallenge=\(activeChallenge)")
        return hasClearance && !activeChallenge
    }

    private func verificationURL() -> URL {
        CloudflareVerificationPolicy.verificationURL(
            baseURL: baseURL,
            responseURL: responseURL
        )
    }

    private func syncCloudflareCookieFromWebView() async {
        await WebCookieStore.shared.syncFromWebView(
            dataStore,
            names: ["cf_clearance"],
            for: baseURL
        )
    }

    private func updateStoredUserAgentFromWebView() async {
        guard let webView,
              let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String
        else { return }
        WebCookieStore.shared.userAgent = userAgent
    }

    private func pageHasActiveCloudflareChallenge(in webView: WKWebView) async -> Bool {
        guard let pageText = try? await webView.evaluateJavaScript("""
            [
              document.title || '',
              document.body ? document.body.innerText : '',
              document.body ? document.body.innerHTML : ''
            ].join('\\n')
            """) as? String else {
            return true
        }
        return Self.hasActiveCloudflareChallenge(in: pageText)
    }

    private static func hasActiveCloudflareChallenge(in pageText: String) -> Bool {
        let lowerText = pageText.lowercased()
        return lowerText.contains("cf-turnstile")
            || lowerText.contains("challenge-running")
            || lowerText.contains("challenge-stage")
            || lowerText.contains("cf_chl_opt")
            || lowerText.contains("challenge-platform")
            || (lowerText.contains("just a moment") && lowerText.contains("cloudflare"))
    }

    /// 离屏页面要挂在这里：只有挂在窗口上，WebKit 才把页面算作可见。
    private static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private func log(_ message: String) {
        DohDebugLog.record("background attempt \(message)", subsystem: "CF")
    }

    /// MITM 模式下源站证书是我们自己签的，隐藏页面同样要走 `MitmTrust`，
    /// 否则加载在 TLS 阶段就失败了。
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MitmTrust.handle(challenge, completionHandler: completionHandler)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish = true
        log("didFinish url=\(webView.url?.absoluteString ?? "none")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        log("didCommit url=\(webView.url?.absoluteString ?? "none")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        didFail = true
        lastFailure = error.localizedDescription
        log("didFail url=\(webView.url?.absoluteString ?? "none") error=\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        didFail = true
        lastFailure = error.localizedDescription
        log("didFailProvisional url=\(webView.url?.absoluteString ?? "none") error=\(error.localizedDescription)")
    }
}
