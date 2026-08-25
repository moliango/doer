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
        guard let task = activeAttempts[key] else { return }
        log("cancelled base=\(key) reason=foreground_verification")
        task.cancel()
        _ = await task.value
        activeAttempts[key] = nil
    }

    func endForegroundVerification(baseURL rawBaseURL: URL) {
        let key = normalizedBaseURL(rawBaseURL).absoluteString
        foregroundVerificationKeys.remove(key)
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

        if let active = activeAttempts[key] {
            log("joined active attempt reason=\(reason) base=\(key)")
            return await active.value
        }

        if !force, let lastAttempt = lastAttemptAt[key],
           Date().timeIntervalSince(lastAttempt) < attemptCooldown {
            // Critical: cooldown must NOT force another human challenge if we already
            // hold clearance / are in post-pass grace. That caused Topic Detail to
            // re-prompt immediately after a successful pass while image retries settled.
            if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL)
                || WebCookieStore.shared.hasCookie(named: "cf_clearance", for: baseURL) {
                log("skipped reason=\(reason) base=\(key) skip=attempt_cooldown_with_clearance")
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
            CloudflareVerificationPolicy.markVerificationGrace(baseURL: baseURL)
            NotificationCenter.default.post(
                name: DiscourseAPI.cloudflareVerificationCompletedNotification,
                object: nil,
                userInfo: [
                    DiscourseAPI.cloudflareBaseURLUserInfoKey: key.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                ]
            )
        } else if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL)
            || WebCookieStore.shared.hasCookie(named: "cf_clearance", for: baseURL) {
            // Avoid re-prompting right after a successful pass when a flaky retry fails.
            log("failed but clearance/grace present reason=\(reason) base=\(key); skip user prompt")
        } else {
            postNeedsUserInteraction(baseURL: baseURL, responseURL: responseURL, reason: reason)
        }

        return ok
    }

    private func postNeedsUserInteraction(baseURL: URL, responseURL: URL?, reason: String) {
        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL)
            || WebCookieStore.shared.hasCookie(named: "cf_clearance", for: baseURL) {
            log("needs user interaction suppressed reason=\(reason) base=\(baseURL.absoluteString) grace_or_clearance=true")
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
    private let dataStore = WKWebsiteDataStore.default()
    private let maxDurationNanoseconds: UInt64 = 12_000_000_000
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
        await WebCookieStore.shared.syncToWebView(dataStore, for: baseURL)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.customUserAgent = WebCookieStore.shared.userAgent
            ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
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
        let hasClearance = CloudflareVerificationPolicy.hasUsableClearance(
            currentValue: clearanceValue,
            initialValue: initialClearanceValue,
            requiresFreshValue: responseURL != nil
        )
        let activeChallenge = await pageHasActiveCloudflareChallenge(in: webView)
        let currentURL = webView.url?.absoluteString ?? "none"

        log("check url=\(currentURL) cf=\(hasClearance) activeChallenge=\(activeChallenge)")
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

    private func log(_ message: String) {
        DohDebugLog.record("background attempt \(message)", subsystem: "CF")
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
