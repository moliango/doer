import Alamofire
import DohProxy
import Foundation
import ObjectiveC
import Security
import UIKit
import WebKit

nonisolated struct MitmTrustEvaluator: ServerTrustEvaluating {
    func evaluate(_ trust: SecTrust, forHost host: String) throws {
        if MitmCertificateAuthority.shared.evaluate(trust, host: host) {
            return
        }
        try DefaultTrustEvaluator().evaluate(trust, forHost: host)
    }
}

nonisolated final class AnyHostMitmTrustManager: ServerTrustManager {
    nonisolated init() {
        super.init(allHostsMustBeEvaluated: true, evaluators: [:])
    }

    nonisolated override func serverTrustEvaluator(forHost host: String) throws -> (any ServerTrustEvaluating)? {
        MitmTrustEvaluator()
    }
}

enum FluxDoMitmTrustManager {
    static func make() -> ServerTrustManager {
        AnyHostMitmTrustManager()
    }
}

enum MitmTrust {
    private static let lock = NSLock()
    private static var hooked = false

    static func handle(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              MitmCertificateAuthority.shared.evaluate(trust, host: challenge.protectionSpace.host)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func installWKWebViewHook() {
        lock.lock()
        defer { lock.unlock() }
        guard !hooked else { return }
        hooked = true
        guard let original = class_getInstanceMethod(WKWebView.self, #selector(setter: WKWebView.navigationDelegate)),
              let replacement = class_getInstanceMethod(WKWebView.self, #selector(WKWebView.doer_setMitmNavigationDelegate(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

private final class MitmNavigationDelegateBox: NSObject, WKNavigationDelegate {
    weak var original: WKNavigationDelegate?

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if UserDefaults.standard.bool(forKey: "dohEnabled") {
            MitmTrust.handle(challenge, completionHandler: completionHandler)
            return
        }
        original?.webView?(webView, didReceive: challenge, completionHandler: completionHandler)
            ?? completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        original?.webView?(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        original?.webView?(webView, didFail: navigation, withError: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        original?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        original?.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
            ?? decisionHandler(.allow)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return original?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original
    }
}

private var mitmBoxKey: UInt8 = 0

private extension WKWebView {
    @objc func doer_setMitmNavigationDelegate(_ delegate: WKNavigationDelegate?) {
        let box = MitmNavigationDelegateBox()
        box.original = delegate
        objc_setAssociatedObject(self, &mitmBoxKey, box, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        doer_setMitmNavigationDelegate(box)
    }
}

/// iOS 16 WKWebView cannot use CONNECT, so Gateway ECH and the challenge page
/// have different TLS fingerprints. `cf_clearance` from Turnstile is then
/// rejected on API/images and the shield loops. JSON API goes through a
/// hidden WKWebView instead, sharing Safari TLS and the default cookie store.
@MainActor
final class WebViewHTTPClient: NSObject, WKNavigationDelegate {
    static let shared = WebViewHTTPClient()

    nonisolated static var isEnabled: Bool {
        LocalConnectProxy.usesWebViewHTTPTransport
    }

    private var webView: WKWebView?
    private var didPrimeCookies = false
    private var hasOrigin = false
    private var isRunning = false
    private var runWaiters: [CheckedContinuation<Void, Never>] = []
    private var navigationWaiters: [CheckedContinuation<Void, Error>] = []
    private var navigationGeneration = 0
    private var lastHTTPResponse: HTTPURLResponse?
    private var inflightGets: [String: [(CheckedContinuation<(Data, HTTPURLResponse), Error>)]] = [:]
    private var inflightGetLeaders: Set<String> = []

    private let fetchScript = """
        try {
          const init = {
            method: method,
            credentials: 'include',
            cache: 'no-store',
            headers: headers || {}
          };
          if (typeof bodyBase64 === 'string' && bodyBase64.length > 0) {
            const binary = atob(bodyBase64);
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            init.body = bytes;
          }
          const res = await fetch(url, init);
          const buf = new Uint8Array(await res.arrayBuffer());
          let binary = '';
          for (let i = 0; i < buf.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
          }
          const outHeaders = {};
          res.headers.forEach((value, key) => { outHeaders[key] = value; });
          return JSON.stringify({
            status: res.status,
            url: res.url,
            headers: outHeaders,
            bodyBase64: btoa(binary)
          });
        } catch (e) {
          return JSON.stringify({
            error: String((e && e.message) || e),
            name: String((e && e.name) || '')
          });
        }
        """

    func data(for request: URLRequest, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        let method = (request.httpMethod ?? "GET").uppercased()
        if method == "GET" || method == "HEAD", let url = request.url?.absoluteString {
            return try await coalescedGET(url, request: request, baseURL: baseURL)
        }
        return try await enqueue {
            try await self.perform(request, baseURL: baseURL)
        }
    }

    private func coalescedGET(
        _ url: String,
        request: URLRequest,
        baseURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        if inflightGetLeaders.contains(url) {
            DohDebugLog.record("webview http join GET \(request.url?.path ?? "")", subsystem: "Auth")
            return try await withCheckedThrowingContinuation { continuation in
                inflightGets[url, default: []].append(continuation)
            }
        }
        inflightGetLeaders.insert(url)
        do {
            let result = try await enqueue {
                try await self.perform(request, baseURL: baseURL)
            }
            inflightGetLeaders.remove(url)
            let waiters = inflightGets.removeValue(forKey: url) ?? []
            waiters.forEach { $0.resume(returning: result) }
            return result
        } catch {
            inflightGetLeaders.remove(url)
            let waiters = inflightGets.removeValue(forKey: url) ?? []
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    private func perform(_ request: URLRequest, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        try await ensureWebView(baseURL: baseURL)
        let method = (request.httpMethod ?? "GET").uppercased()
        let originReady = hasOrigin && isSameOrigin(baseURL)
        if originReady {
            do {
                let result = try await performFetch(request)
                await syncClearance(baseURL)
                return result
            } catch {
                DohDebugLog.record(
                    "webview http fetch fallback to nav \(method) \(request.url?.path ?? "") error=\(error.localizedDescription)",
                    subsystem: "Auth"
                )
                if method != "GET" && method != "HEAD" {
                    throw error
                }
            }
        }
        let result = try await performNavigation(request)
        hasOrigin = isSameOrigin(baseURL)
        await syncClearance(baseURL)
        return result
    }

    private func isSameOrigin(_ baseURL: URL) -> Bool {
        let host = webView?.url?.host?.lowercased()
        let origin = baseURL.host?.lowercased()
        guard let host, let origin else { return false }
        return host == origin || host.hasSuffix(".\(origin)")
    }

    private func syncClearance(_ baseURL: URL) async {
        await WebCookieStore.shared.syncFromWebView(
            .default(),
            names: ["cf_clearance"],
            for: baseURL
        )
    }

    private func ensureWebView(baseURL: URL) async throws {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .default()
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: config)
            view.isOpaque = true
            view.backgroundColor = .white
            view.isUserInteractionEnabled = false
            view.navigationDelegate = self
            view.customUserAgent = WebCookieStore.shared.userAgent
                ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1"
            webView = view
            didPrimeCookies = false
        }
        attachToKeyWindowIfNeeded()
        if !didPrimeCookies {
            await WebCookieStore.shared.syncToWebView(.default(), for: baseURL)
            didPrimeCookies = true
        }
        guard webView?.superview != nil else {
            throw URLError(.cannotFindHost)
        }
    }

    private func performNavigation(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let webView else { throw URLError(.cannotFindHost) }
        var navRequest = request
        navRequest.timeoutInterval = 20
        lastHTTPResponse = nil
        DohDebugLog.record(
            "webview http nav \(request.httpMethod ?? "GET") \(request.url?.path ?? "")",
            subsystem: "Auth"
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationWaiters.append(continuation)
            let generation = navigationGeneration
            webView.load(navRequest)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard generation == self.navigationGeneration else { return }
                    self.logNavigationTimeout(request)
                    self.resetWebView(reason: "nav timeout")
                    LocalConnectProxy.abandonWebViewHTTPTransport(reason: "nav timeout")
                    self.failNavigation(URLError(.timedOut))
            }
        }
        let responseURL = lastHTTPResponse?.url ?? webView.url ?? request.url
        guard let responseURL else { throw URLError(.badServerResponse) }
        let status = lastHTTPResponse?.statusCode ?? 200
        let headers = lastHTTPResponse?.allHeaderFields ?? [:]
        var headerFields: [String: String] = [:]
        for (key, value) in headers {
            headerFields[String(describing: key)] = String(describing: value)
        }
        guard let httpResponse = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else {
            throw URLError(.badServerResponse)
        }
        let body = try await documentBody(on: webView)
        DohDebugLog.record(
            "webview http \(request.httpMethod ?? "GET") \(request.url?.path ?? "") status=\(status) bytes=\(body.count) via=nav",
            subsystem: "Auth"
        )
        return (body, httpResponse)
    }

    private func performFetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let webView else { throw URLError(.cannotFindHost) }
        var headers: [String: String] = [:]
        request.allHTTPHeaderFields?.forEach { key, value in
            if key.caseInsensitiveCompare("Cookie") == .orderedSame { return }
            if key.caseInsensitiveCompare("User-Agent") == .orderedSame { return }
            headers[key] = value
        }
        let method = request.httpMethod ?? "GET"
        DohDebugLog.record("webview http fetch \(method) \(request.url?.path ?? "")", subsystem: "Auth")
        let raw: Any?
        do {
            raw = try await callFetchJavaScript(
                on: webView,
                url: request.url?.absoluteString ?? "",
                method: method,
                headers: headers,
                bodyBase64: request.httpBody?.base64EncodedString() ?? ""
            )
        } catch {
            DohDebugLog.record(
                "webview http js failed \(method) \(request.url?.path ?? "") error=\(error.localizedDescription)",
                subsystem: "Auth"
            )
            throw error
        }
        let parsed: (Data, HTTPURLResponse)
        do {
            parsed = try Self.parseFetchResult(raw)
        } catch {
            DohDebugLog.record(
                "webview http parse failed \(method) \(request.url?.path ?? "") value=\(Self.describeJSResult(raw))",
                subsystem: "Auth"
            )
            throw error
        }
        DohDebugLog.record(
            "webview http \(method) \(request.url?.path ?? "") status=\(parsed.1.statusCode) bytes=\(parsed.0.count) via=fetch",
            subsystem: "Auth"
        )
        return parsed
    }

    private func documentBody(on webView: WKWebView) async throws -> Data {
        let script = """
            (function() {
              const pre = document.querySelector('pre');
              if (pre && pre.innerText) return pre.innerText;
              return (document.body && document.body.innerText) || '';
            })()
            """
        let raw: Any? = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result)
                }
            }
        }
        let text = raw as? String ?? ""
        return Data(text.utf8)
    }

    nonisolated static func parseFetchResult(_ raw: Any?) throws -> (Data, HTTPURLResponse) {
        let payload = try payloadDictionary(raw)
        if let error = payload["error"] as? String, !error.isEmpty {
            throw NSError(
                domain: "WebViewHTTPClient",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
        guard let status = intValue(payload["status"]),
              let responseURLString = payload["url"] as? String,
              let responseURL = URL(string: responseURLString),
              let httpResponse = HTTPURLResponse(
                url: responseURL,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: stringHeaders(payload["headers"])
              )
        else {
            throw URLError(.badServerResponse)
        }
        let data: Data
        if let bodyBase64 = payload["bodyBase64"] as? String, !bodyBase64.isEmpty {
            data = Data(base64Encoded: bodyBase64) ?? Data()
        } else {
            data = Data()
        }
        return (data, httpResponse)
    }

    private func attachToKeyWindowIfNeeded() {
        guard let webView else { return }
        if webView.superview != nil { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        guard let host = windows.first(where: \.isKeyWindow)
            ?? windows.first(where: { !$0.isHidden })
        else {
            DohDebugLog.record("webview http host window missing", subsystem: "Auth")
            return
        }
        webView.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isUserInteractionEnabled = false
        host.insertSubview(webView, at: 0)
        DohDebugLog.record("webview http hosted in key window", subsystem: "Auth")
    }

    func adoptChallengeWebView(_ view: WKWebView, baseURL: URL) {
        if webView === view {
            hasOrigin = true
            didPrimeCookies = true
            return
        }
        failNavigation(URLError(.cancelled))
        resetWebView(reason: "adopt challenge")
        view.translatesAutoresizingMaskIntoConstraints = true
        view.removeFromSuperview()
        view.navigationDelegate = self
        webView = view
        hasOrigin = true
        didPrimeCookies = true
        attachToKeyWindowIfNeeded()
        DohDebugLog.record(
            "webview http adopted challenge url=\(view.url?.absoluteString ?? "")",
            subsystem: "Auth"
        )
        _ = baseURL
    }

    private func resetWebView(reason: String) {
        DohDebugLog.record("webview http reset reason=\(reason)", subsystem: "Auth")
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        hasOrigin = false
        didPrimeCookies = false
    }

    private func logNavigationTimeout(_ request: URLRequest) {
        let ips = DohBootstrapTransport.systemAddresses(for: "linux.do")
        let fake = ips.filter { EncryptedDnsService.isTunnelFakeIP($0) }
        DohDebugLog.record(
            "webview http nav timeout \(request.url?.path ?? "") hosted=\(webView?.superview != nil) inWindow=\(webView?.window != nil) dns=\(ips.prefix(4).joined(separator: ",")) fakeIP=\(!fake.isEmpty)",
            subsystem: "Auth"
        )
    }

    private func finishNavigation() {
        navigationGeneration += 1
        let waiters = navigationWaiters
        navigationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func failNavigation(_ error: Error) {
        navigationGeneration += 1
        let waiters = navigationWaiters
        navigationWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func enqueue<T>(_ work: () async throws -> T) async throws -> T {
        if isRunning {
            await withCheckedContinuation { runWaiters.append($0) }
        }
        isRunning = true
        defer {
            if runWaiters.isEmpty {
                isRunning = false
            } else {
                runWaiters.removeFirst().resume()
            }
        }
        return try await work()
    }

    private func callFetchJavaScript(
        on webView: WKWebView,
        url: String,
        method: String,
        headers: [String: String],
        bodyBase64: String
    ) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ body: (CheckedContinuation<Any?, Error>) -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                body(continuation)
            }
            webView.callAsyncJavaScript(
                fetchScript,
                arguments: [
                    "url": url,
                    "method": method,
                    "headers": headers,
                    "bodyBase64": bodyBase64,
                ],
                in: nil,
                in: .page,
                completionHandler: { result in
                    switch result {
                    case .success(let value):
                        finish { $0.resume(returning: value) }
                    case .failure(let error):
                        finish { $0.resume(throwing: error) }
                    }
                }
            )
        }
    }

    nonisolated static func describeJSResult(_ raw: Any?) -> String {
        guard let raw else { return "nil" }
        let text = String(describing: raw)
        return "\(Swift.type(of: raw)) \(text.prefix(240))"
    }

    nonisolated static func payloadDictionary(_ raw: Any?) throws -> [String: Any] {
        if let payload = raw as? [String: Any] {
            return payload
        }
        if let payload = raw as? [AnyHashable: Any] {
            var result: [String: Any] = [:]
            for (key, value) in payload {
                result[String(describing: key)] = value
            }
            return result
        }
        if let payload = raw as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, value) in payload {
                result[String(describing: key)] = value
            }
            return result
        }
        if let string = raw as? String {
            guard let data = string.data(using: .utf8) else {
                throw URLError(.badServerResponse)
            }
            let object = try JSONSerialization.jsonObject(with: data)
            return try payloadDictionary(object)
        }
        throw URLError(.badServerResponse)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        lastHTTPResponse = navigationResponse.response as? HTTPURLResponse
        if let response = lastHTTPResponse {
            DohDebugLog.record(
                "webview http response \(response.statusCode) \(response.url?.path ?? "")",
                subsystem: "Auth"
            )
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DohDebugLog.record(
            "webview http nav finished \(webView.url?.path ?? "")",
            subsystem: "Auth"
        )
        finishNavigation()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        DohDebugLog.record("webview http nav failed: \(error.localizedDescription)", subsystem: "Auth")
        failNavigation(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        DohDebugLog.record("webview http nav provisional failed: \(error.localizedDescription)", subsystem: "Auth")
        failNavigation(error)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MitmTrust.handle(challenge, completionHandler: completionHandler)
    }

    private nonisolated static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }

    private nonisolated static func stringHeaders(_ raw: Any?) -> [String: String] {
        if let headers = raw as? [String: String] { return headers }
        guard let headers = raw as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in headers {
            result[key] = String(describing: value)
        }
        return result
    }
}
