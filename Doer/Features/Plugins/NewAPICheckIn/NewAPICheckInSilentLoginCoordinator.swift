import UIKit
import WebKit

@MainActor
final class NewAPICheckInSilentLoginCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let timeoutNanoseconds: UInt64 = 15_000_000_000
    private static let pollIntervalNanoseconds: UInt64 = 1_200_000_000

    private let platform: NewAPICheckInPlatform
    private let store: NewAPICheckInStore
    private let service: NewAPICheckInService
    private let baseURL: URL
    private let webView: WKWebView

    private var continuation: CheckedContinuation<Bool, Never>?
    private var pollTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var isProbing = false
    private var didFinish = false
    private var lastRefreshCookieValue: String?

    private init?(
        platform: NewAPICheckInPlatform,
        store: NewAPICheckInStore,
        service: NewAPICheckInService
    ) {
        guard let baseURL = URL(string: platform.baseURL) else { return nil }
        self.platform = platform
        self.store = store
        self.service = service
        self.baseURL = baseURL

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.applicationNameForUserAgent = "Version/17.4 Mobile/15E148 Safari/604.1"
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    static func restore(
        platform: NewAPICheckInPlatform,
        store: NewAPICheckInStore,
        service: NewAPICheckInService
    ) async -> Bool {
        guard (platform.platformType ?? .newAPI) == .newAPI,
              let coordinator = NewAPICheckInSilentLoginCoordinator(
            platform: platform,
            store: store,
            service: service
        ) else { return false }
        return await coordinator.run()
    }

    private func run() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { await self.start() }
        }
    }

    private func start() async {
        await injectStoredCookies()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
                guard !Task.isCancelled, let self else { return }
                self.scheduleProbe()
            }
        }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.finish(false)
        }
        webView.load(URLRequest(url: baseURL))
    }

    private func injectStoredCookies() async {
        guard let credential = try? await store.credential(for: platform.id),
              let header = credential.cookieHeader
        else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in Self.cookies(from: header, baseURL: baseURL) {
            await cookieStore.setCookie(cookie)
        }
    }

    private func scheduleProbe() {
        guard probeTask == nil, !didFinish else { return }
        probeTask = Task { [weak self] in
            guard let self else { return }
            await self.probe()
            self.probeTask = nil
        }
    }

    private func probe() async {
        guard !isProbing, !didFinish else { return }
        isProbing = true
        defer { isProbing = false }

        let localStorageValue = try? await webView.evaluateJavaScript(
            NewAPICheckInLoginSupport.localStorageScript
        )
        let hints = NewAPICheckInLoginSupport.parseLocalStorageResult(localStorageValue)
        let allCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let cookieHeader = NewAPICheckInLoginSupport.cookieHeader(
            from: allCookies,
            baseURL: baseURL,
            currentURL: webView.url
        )

        if let cookieHeader,
           let refreshCookie = NewAPICheckInService.cookieValue(
               named: "new_api_refresh",
               in: cookieHeader
           ),
           refreshCookie != lastRefreshCookieValue {
            lastRefreshCookieValue = refreshCookie
            let refreshResult = await service.refreshAuthentication(
                platform,
                cookieHeaderOverride: cookieHeader
            )
            if refreshResult.isRefreshed {
                finish(true)
                return
            }
        }

        guard cookieHeader != nil || hints.userID != nil || hints.accessToken != nil else {
            return
        }
        let result = await service.probeLogin(
            baseURL: baseURL,
            cookieHeader: cookieHeader,
            hints: hints
        )
        guard result.isLoggedIn else { return }

        let previous = try? await store.credential(for: platform.id)
        let credential = NewAPICheckInCredential(
            accessToken: result.accessToken ?? hints.accessToken ?? previous?.accessToken,
            userID: result.userID ?? hints.userID ?? previous?.userID,
            cookieHeader: cookieHeader ?? previous?.cookieHeader,
            additionalHeaders: previous?.additionalHeaders ?? [:]
        )
        do {
            try await store.updateExisting(platformID: platform.id, credential: credential) { _ in }
            finish(true)
        } catch {
            finish(false)
        }
    }

    private func finish(_ succeeded: Bool) {
        guard !didFinish else { return }
        didFinish = true
        pollTask?.cancel()
        timeoutTask?.cancel()
        probeTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: succeeded)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleProbe()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        switch scheme {
        case "http", "https", "about", "data", "blob":
            decisionHandler(.allow)
        default:
            decisionHandler(.cancel)
        }
    }

    private static func cookies(from header: String, baseURL: URL) -> [HTTPCookie] {
        guard let host = baseURL.host else { return [] }
        return header.split(separator: ";").compactMap { component in
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: host,
                .path: "/",
            ]
            if baseURL.scheme?.lowercased() == "https" {
                properties[.secure] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }
}
