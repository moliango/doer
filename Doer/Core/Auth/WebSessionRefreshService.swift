import Foundation
import WebKit

enum WebSessionRefreshPolicy {
    /// A failed, timed-out, or Cloudflare-challenge WK load must not pull cookies
    /// into the jar. Challenge hops often mint a short-lived `cf_clearance` that
    /// would replace a still-valid token.
    static func shouldImportWebViewCookies(didFinishLoad: Bool, isChallengePage: Bool = false) -> Bool {
        didFinishLoad && !isChallengePage
    }

    static func isSuccessfulRefresh(
        didFinishLoad: Bool,
        isChallengePage: Bool,
        hasSessionCookie: Bool
    ) -> Bool {
        didFinishLoad && !isChallengePage && hasSessionCookie
    }

    static func isChallengePage(url: URL?, title: String?) -> Bool {
        if let url {
            if CloudflareVerificationPolicy.hasCloudflareChallengeToken(in: url) {
                return true
            }
            let path = url.path.lowercased()
            if path.contains("/cdn-cgi/") {
                return true
            }
            if url.host?.lowercased().contains("challenges.cloudflare.com") == true {
                return true
            }
        }
        if let title, title.lowercased().contains("just a moment") {
            return true
        }
        return false
    }
}

@MainActor
final class WebSessionRefreshService: NSObject {
    static let shared = WebSessionRefreshService()

    private struct SuccessState {
        let date: Date
        let token: String?
    }

    private let attemptCooldown: TimeInterval = 45
    private let successTTL: TimeInterval = 15 * 60
    private let loadTimeout: TimeInterval = 10
    private let scriptTimeoutNanoseconds: UInt64 = 12_000_000_000

    private var activeRefreshes: [String: Task<Bool, Never>] = [:]
    private var lastAttemptAt: [String: Date] = [:]
    private var lastSuccess: [String: SuccessState] = [:]

    private override init() {
        super.init()
    }

    func markSynced(forum: ForumInstance, reason: String = "external") {
        markSynced(baseURL: forum.baseURL, reason: reason)
    }

    func markSynced(baseURL rawBaseURL: String, reason: String = "external") {
        let baseURL = normalizedBaseURL(rawBaseURL)
        let token = URL(string: baseURL).flatMap { WebCookieStore.shared.cookieValue(named: "_t", for: $0) }
        lastSuccess[baseURL] = SuccessState(date: Date(), token: token)
        DohDebugLog.record("web session refresh marked synced reason=\(reason)", subsystem: "Auth")
    }

    func ensureInBackground(forum: ForumInstance, reason: String, force: Bool = false) {
        ensureInBackground(baseURL: forum.baseURL, reason: reason, force: force)
    }

    func ensureInBackground(baseURL: String, reason: String, force: Bool = false) {
        Task { @MainActor in
            _ = await ensureSynced(baseURL: baseURL, reason: reason, force: force)
        }
    }

    func ensureSynced(forum: ForumInstance, reason: String, force: Bool = false) async -> Bool {
        await ensureSynced(baseURL: forum.baseURL, reason: reason, force: force)
    }

    func ensureSynced(baseURL rawBaseURL: String, reason: String, force: Bool = false) async -> Bool {
        let baseURL = normalizedBaseURL(rawBaseURL)
        guard let base = URL(string: baseURL) else { return false }
        guard WebCookieStore.shared.hasDiscourseWebSessionCookie(for: base) else {
            DohDebugLog.record("web session refresh skipped reason=\(reason) skip=no_session_cookie", subsystem: "Auth")
            return false
        }

        if DiscourseAPI.isCloudflareForegroundGateActive(baseURL: baseURL)
            || CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL) {
            DohDebugLog.record(
                "web session refresh skipped reason=\(reason) skip=cf_gate_or_grace",
                subsystem: "Auth"
            )
            return false
        }

        let token = WebCookieStore.shared.cookieValue(named: "_t", for: base)
        if !force, let state = lastSuccess[baseURL],
           state.token == token,
           Date().timeIntervalSince(state.date) < successTTL {
            DohDebugLog.record("web session refresh skipped reason=\(reason) skip=success_ttl", subsystem: "Auth")
            return true
        }

        if let active = activeRefreshes[baseURL] {
            DohDebugLog.record("web session refresh joined active reason=\(reason)", subsystem: "Auth")
            return await active.value
        }

        if !force, let lastAttempt = lastAttemptAt[baseURL],
           Date().timeIntervalSince(lastAttempt) < attemptCooldown {
            DohDebugLog.record("web session refresh skipped reason=\(reason) skip=attempt_cooldown", subsystem: "Auth")
            return false
        }

        lastAttemptAt[baseURL] = Date()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.refresh(baseURL: base, reason: reason)
        }
        activeRefreshes[baseURL] = task
        let ok = await task.value
        activeRefreshes[baseURL] = nil

        if ok {
            let refreshedToken = WebCookieStore.shared.cookieValue(named: "_t", for: base)
            lastSuccess[baseURL] = SuccessState(date: Date(), token: refreshedToken)
        }
        return ok
    }

    private func refresh(baseURL: URL, reason: String) async -> Bool {
        let startedAt = Date()
        DohDebugLog.record("web session refresh started reason=\(reason)", subsystem: "Auth")

        let dataStore = WKWebsiteDataStore.default()
        let primed = await WebCookieStore.shared.primeBrowserSession(
            to: dataStore,
            forumURL: baseURL,
            pageURL: baseURL
        )
        if !primed {
            DohDebugLog.record(
                "web session refresh skipped WK path reason=\(reason) cookie_store_timeout=true",
                subsystem: "Auth"
            )
            return false
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.customUserAgent = WebCookieStore.shared.userAgent

        let delegate = LoadWaiter(timeout: loadTimeout)
        webView.navigationDelegate = delegate

        let refreshURL = URL(string: "/?__doer_session_refresh=\(Int(Date().timeIntervalSince1970))", relativeTo: baseURL)?.absoluteURL ?? baseURL
        var request = URLRequest(url: refreshURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        webView.load(request)

        await delegate.wait()
        let didFinishLoad = delegate.didFinishLoad
        let isChallengePage = WebSessionRefreshPolicy.isChallengePage(
            url: webView.url,
            title: webView.title
        )
        if WebSessionRefreshPolicy.shouldImportWebViewCookies(
            didFinishLoad: didFinishLoad,
            isChallengePage: isChallengePage
        ) {
            await runSessionBootstrap(in: webView, baseURL: baseURL)
            await runBrowserProbes(in: webView)
            await WebCookieStore.shared.syncFromWebView(dataStore, for: baseURL)
        } else {
            DohDebugLog.record(
                "web session refresh skipped cookie import reason=\(reason) finished=\(didFinishLoad) challenge=\(isChallengePage)",
                subsystem: "Auth"
            )
            if isChallengePage {
                DiscourseAPI.postCloudflareChallengeDetected(
                    baseURL: baseURL.absoluteString,
                    responseURL: webView.url,
                    source: "api.session.refresh"
                )
            }
        }

        webView.stopLoading()
        webView.navigationDelegate = nil

        let hasSessionCookie = WebCookieStore.shared.hasDiscourseWebSessionCookie(for: baseURL)
        let ok = WebSessionRefreshPolicy.isSuccessfulRefresh(
            didFinishLoad: didFinishLoad,
            isChallengePage: isChallengePage,
            hasSessionCookie: hasSessionCookie
        )
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        DohDebugLog.record(
            "web session refresh completed reason=\(reason) ok=\(ok) elapsedMs=\(elapsedMs)",
            subsystem: "Auth"
        )
        DohDebugLog.record(
            "completed reason=\(reason) ok=\(ok) elapsedMs=\(elapsedMs)",
            subsystem: "session.refresh"
        )
        return ok
    }

    private func runSessionBootstrap(in webView: WKWebView, baseURL: URL) async {
        let script = sessionBootstrapScript(baseURL: baseURL)
        let timeoutNanoseconds = scriptTimeoutNanoseconds
        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                await self.evaluate(script, in: webView)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }

        DohDebugLog.record("web session bootstrap result=\(result ?? "timeout")", subsystem: "Auth")
    }

    private func runBrowserProbes(in webView: WKWebView) async {
        let timeoutNanoseconds = scriptTimeoutNanoseconds
        let script = """
        (async function() {
          const result = {};
          async function hit(url) {
            const response = await fetch(url, {
              method: 'GET',
              credentials: 'include',
              cache: 'no-store',
              headers: {
                'Accept': 'application/json',
                'X-Requested-With': 'XMLHttpRequest'
              }
            });
            try { await response.text(); } catch (_) {}
            return response.status;
          }
          try { result.csrf = await hit('/session/csrf.json'); } catch (e) { result.csrfError = String(e); }
          try { result.current = await hit('/session/current.json'); } catch (e) { result.currentError = String(e); }
          return JSON.stringify(result);
        })();
        """

        let result = await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in
                await self.evaluate(script, in: webView)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }

        DohDebugLog.record("web session browser probes result=\(result ?? "timeout")", subsystem: "Auth")
    }

    private func sessionBootstrapScript(baseURL: URL) -> String {
        let base = Self.javascriptStringLiteral(baseURL.absoluteString)
        return #"""
        (async function() {
          const appBaseUrl = \#(base);

          function payload(data) {
            return JSON.stringify(data || {});
          }

          async function readCsrfToken() {
            try {
              const response = await fetch('/session/csrf.json', {
                method: 'GET',
                credentials: 'include',
                cache: 'no-store',
                headers: {
                  'Accept': 'application/json',
                  'X-Requested-With': 'XMLHttpRequest'
                }
              });
              if (!response.ok) return null;
              const json = await response.json();
              return json && json.csrf ? String(json.csrf) : null;
            } catch (_) {
              return null;
            }
          }

          async function postForm(url, data) {
            const params = new URLSearchParams();
            Object.keys(data || {}).forEach(function(key) {
              params.append(key, data[key] == null ? '' : String(data[key]));
            });
            const headers = {
              'Accept': 'application/json, text/javascript, */*; q=0.01',
              'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
              'X-Requested-With': 'XMLHttpRequest'
            };
            const csrf = await readCsrfToken();
            if (csrf) headers['X-CSRF-Token'] = csrf;

            const response = await fetch(url, {
              method: 'POST',
              credentials: 'include',
              cache: 'no-store',
              headers,
              body: params.toString()
            });
            const text = await response.text();
            if (!response.ok) {
              throw new Error('POST ' + url + ' -> ' + response.status + ': ' + text.slice(0, 160));
            }
            return {
              url,
              status: response.status,
              ok: response.ok,
              bodyLength: text.length
            };
          }

          function normalizeAssetUrl(raw) {
            if (!raw) return null;
            const cleaned = String(raw).replace(/&amp;/g, '&');
            try {
              return new URL(cleaned, appBaseUrl + '/').toString();
            } catch (_) {
              return null;
            }
          }

          function collectPluginUrlsFromHtml(html) {
            const urls = new Set();
            const assetPattern = /(https?:\/\/[^"'\s<>]+\/assets\/[^"'\s<>]*plugins\/[^"'\s<>]+?\.js(?:\?[^"'\s<>]*)?|\/assets\/[^"'\s<>]*plugins\/[^"'\s<>]+?\.js(?:\?[^"'\s<>]*)?)/g;
            let match;
            while ((match = assetPattern.exec(html || '')) !== null) {
              const url = normalizeAssetUrl(match[1]);
              if (url) urls.add(url);
            }
            return Array.from(urls);
          }

          async function discoverPluginUrls() {
            const currentHtml = document.documentElement ? document.documentElement.outerHTML : '';
            const existing = collectPluginUrlsFromHtml(currentHtml);
            if (existing.length) return existing;

            const response = await fetch('/?__doer_session_bootstrap=' + Date.now(), {
              method: 'GET',
              credentials: 'include',
              cache: 'no-store',
              headers: { 'Accept': 'text/html,*/*' }
            });
            const html = await response.text();
            if (!response.ok) {
              throw new Error('home fetch -> ' + response.status + ': ' + html.slice(0, 120));
            }
            return collectPluginUrlsFromHtml(html);
          }

          async function findFingerprintPlugin() {
            const candidates = await discoverPluginUrls();
            for (const url of candidates) {
              try {
                const response = await fetch(url, {
                  method: 'GET',
                  credentials: 'omit',
                  cache: 'force-cache'
                });
                if (!response.ok) continue;
                const source = await response.text();
                if (
                  source.indexOf('initializers/fingerprint') >= 0 &&
                  source.indexOf('visitor_id') >= 0 &&
                  source.indexOf('Fingerprint') >= 0
                ) {
                  return { url, source };
                }
              } catch (_) {}
            }
            return null;
          }

          function extractFingerprintRunner(source) {
            const endpointMatch = source.match(/_\("([^"]+)",\{type:"POST",data:\{visitor_id:/);
            if (!endpointMatch) {
              throw new Error('fingerprint endpoint not found');
            }
            const fpMatch = source.match(/[A-Za-z_\$][\w\$]*=(function\(n\)\{function e[\s\S]*?Object\.defineProperty\(n,"__esModule",\{value:!0\}\),n\})\(\{\}\)/);
            if (!fpMatch) {
              throw new Error('fingerprint engine not found');
            }
            return {
              endpoint: endpointMatch[1],
              engineFactory: fpMatch[1]
            };
          }

          async function runFingerprintSource(plugin) {
            const runner = extractFingerprintRunner(plugin.source);
            const fingerprint = (0, eval)('(' + runner.engineFactory + ')({})');
            if (!fingerprint || typeof fingerprint.load !== 'function') {
              throw new Error('fingerprint engine invalid');
            }
            const agent = await fingerprint.load();
            const result = await agent.get();
            const data = {};
            Object.keys(result.components || {}).forEach(function(key) {
              data[key] = result.components[key] && result.components[key].value;
            });
            const post = await postForm(runner.endpoint, {
              visitor_id: result.visitorId,
              version: result.version,
              data: JSON.stringify(data)
            });
            post.endpoint = runner.endpoint;
            post.plugin = plugin.url;
            return post;
          }

          try {
            if (location.origin !== new URL(appBaseUrl).origin) {
              return payload({ ok: false, phase: 'origin', error: 'unexpected origin: ' + location.origin });
            }
            const plugin = await findFingerprintPlugin();
            if (!plugin) {
              return payload({ ok: false, phase: 'discover', error: 'fingerprint plugin not found' });
            }
            const post = await runFingerprintSource(plugin);
            return payload({
              ok: post && post.ok === true,
              phase: 'post',
              plugin: post && post.plugin,
              status: post && post.status,
              endpoint: post && post.endpoint
            });
          } catch (e) {
            const msg = String(e && e.message ? e.message : e);
            const statusMatch = msg.match(/->\s*(\d{3})/);
            const status = statusMatch ? parseInt(statusMatch[1], 10) : null;
            return payload({
              ok: false,
              phase: 'exception',
              error: msg,
              status,
              cfBlocked: status === 403 || status === 429
            });
          }
        })();
        """#
    }

    private func evaluate(_ script: String, in webView: WKWebView) async -> String? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = trimmed.hasSuffix(";") ? String(trimmed.dropLast()) : trimmed
        let body = "return await (\(expression));"
        do {
            let value: Any? = try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(
                    body,
                    arguments: [:],
                    in: nil,
                    in: .page
                ) { result in
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            if let string = value as? String {
                return string
            }
            if let value {
                return String(describing: value)
            }
            return nil
        } catch {
            return "error:\(error.localizedDescription)"
        }
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }
}

@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isCompleted = false
    private(set) var didFinishLoad = false
    private let timeout: TimeInterval

    init(timeout: TimeInterval) {
        self.timeout = timeout
        super.init()
    }

    func wait() async {
        guard !isCompleted else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishLoad = true
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DohDebugLog.record("web session refresh load failed: \(error.localizedDescription)", subsystem: "Auth")
        finish()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DohDebugLog.record("web session refresh provisional load failed: \(error.localizedDescription)", subsystem: "Auth")
        finish()
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        MitmTrust.handle(challenge, completionHandler: completionHandler)
    }

    private func finish() {
        guard !isCompleted else { return }
        isCompleted = true
        continuation?.resume()
        continuation = nil
    }
}
