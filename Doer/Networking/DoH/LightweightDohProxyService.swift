import DohProxy
import Foundation
import Network
import SDWebImage
import WebKit

nonisolated final class LightweightDohProxyService: @unchecked Sendable {
    static let shared = LightweightDohProxyService()

    private let lock = NSLock()
    private let resolver = DohResolver()
    private let startQueue = DispatchQueue(label: "doer.doh.proxy-start")
    private var proxy: LocalConnectProxy?
    private(set) var lastError: Error?
    private(set) var configurationVersion: Int = 0
    private var lastSignature = ""
    private var applyGeneration = 0
    private var consecutiveStartFailures = 0
    /// True while `applyConfiguration` is in flight. Prevents a second start
    /// from `ensureProxyAlive` before the first listener is bound.
    private var isStartingProxy = false
    /// Encrypted DNS (and CONNECT, when used) finished applying for the
    /// current signature. iOS 16 has no CONNECT listener; this still counts
    /// as live so resume does not restart DoH in a loop.
    private var stackReady = false

    private init() {
        // DoH 连续不可达就退回系统 DNS。Encrypted DNS 一旦指向一台坏掉的服务器，
        // 整个进程的解析都没了（用户看到的就是「完全没网」），必须能自己退出来。
        // 只认当前配置的那台：优选候选里的公共解析器连不上是常态，不该触发。
        DohBootstrapTransport.onRepeatedFailure = { host in
            let configured = AppSettings.dohProxyConfig(from: .standard)
            guard URL(string: configured.serverURL)?.host?.lowercased() == host.lowercased() else {
                return
            }
            EncryptedDnsService.fallbackToSystemDNS(reason: "DoH \(host) 连续查询失败")
        }
    }

    enum DohProxyLiveness {
        /// Config changed, or DoH is on but the loopback listener is not ready.
        /// Same-signature + live proxy is a no-op so an in-flight start is not
        /// doubled by `sceneWillEnterForeground`.
        static func shouldReapply(
            enabled: Bool,
            signatureChanged: Bool,
            isLive: Bool
        ) -> Bool {
            if signatureChanged { return true }
            return enabled && !isLive
        }

        /// API sessions use the loopback CONNECT proxy so name lookup stays on
        /// the HTTP/1.1 DoH client. Apple Encrypted DNS speaks HTTP/2 to the
        /// same Cloudflare host and fails the request before any HTTP status.
        static func shouldAttachConnectProxy(
            enabled: Bool,
            useGateway: Bool,
            port: UInt16?
        ) -> Bool {
            enabled && !useGateway && port != nil
        }

        /// 「连接方式」→ 是否走本地 CONNECT + ECH。
        ///
        /// 运行时回退过就不再自动切回来，否则每次 reapply 都会把刚回退掉的那条路又打开。
        static func shouldEnableOriginECH(
            enabled: Bool,
            mode: AppSettings.DohConnectionMode,
            runtimeEscaped: Bool
        ) -> Bool {
            enabled && mode == .localECH && !runtimeEscaped
        }
    }

    var currentSignature: String {
        AppSettings.dohProxyConfig(from: .standard).signature
    }

    var sessionConfigurationSignature: String {
        "\(currentSignature)|\(configurationVersion)"
    }

    var statusDescription: String {
        let base = baseStatusDescription
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else { return base }
        return base + preferredNodeSuffix
    }

    private var preferredNodeSuffix: String {
        guard AppSettings.preferredNodeEnabled(from: .standard),
              AppSettings.preferredNodeMode(from: .standard) != .off
        else { return "" }
        // Encrypted DNS 那条路没有东西消费钉选，别谎报已生效。
        guard LocalConnectProxy.originECHReady else { return " · 优选待生效" }
        guard let node = PreferredNodeStore.shared.node else { return " · 优选 未选" }
        return " · 优选 \(node.ip) \(node.latencyMs)ms"
    }

    private var baseStatusDescription: String {
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else {
            return "未启用"
        }

        lock.lock()
        let activeError = lastError
        lock.unlock()

        if let activeError {
            return "启动失败：\(activeError.localizedDescription)"
        }
        let config = AppSettings.dohProxyConfig(from: .standard)
        guard config.bootstrapReady else {
            return "启动失败：DoH 服务器没有 bootstrap IP"
        }
        lock.lock()
        let browserReady = proxy?.isRunning == true
        lock.unlock()
        if !LocalConnectProxy.originECHReady {
            return "应用内 DoH · Encrypted DNS"
        }
        let mode = config.isGatewayMode ? "Gateway" : "CONNECT MITM"
        let h2 = config.h2Mitm ? " · h2" : ""
        lock.lock()
        let port = proxy?.proxyPort
        lock.unlock()
        let portText = port.map { " · :\($0)" } ?? ""
        if #available(iOS 17.0, *), browserReady {
            return "应用内 DoH · \(mode)\(h2)\(portText) · 浏览器"
        }
        return "应用内 DoH · \(mode)\(h2)\(portText)"
    }

    func configureFromSettings() {
        applyConnectionMode()
        lock.lock()
        let signature = currentSignature
        let shouldEnable = UserDefaults.standard.bool(forKey: "dohEnabled")
        let shouldApply = DohProxyLiveness.shouldReapply(
            enabled: shouldEnable,
            signatureChanged: signature != lastSignature,
            isLive: proxy?.isRunning == true || stackReady || isStartingProxy
        )
        if !shouldApply {
            lock.unlock()
            return
        }
        applyGeneration += 1
        let generation = applyGeneration
        lastSignature = signature
        configurationVersion += 1
        isStartingProxy = true
        lock.unlock()

        if shouldEnable {
            syncPreferredNode()
        }

        startQueue.async { [weak self] in
            self?.applyConfiguration(shouldEnable: shouldEnable, generation: generation)
        }
    }

    /// Origin ECH / Gateway flipped at runtime (iOS 16 after a WebView CF pass).
    func forceReapplyFromSettings() {
        lock.lock()
        lastSignature = ""
        lock.unlock()
        configureFromSettings()
    }

    /// FluxDo `ensureProxyAlive`. iOS can drop the loopback listener and
    /// Encrypted DNS PrivacyContext while suspended; resume must restore
    /// them without requiring a process kill.
    func ensureProxyAlive() {
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else { return }
        startQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.consecutiveStartFailures = 0
            let isLive = self.proxy?.isRunning == true
            let starting = self.isStartingProxy
            let ready = self.stackReady
            self.lock.unlock()
            self.reassertNameResolution()
            if isLive || starting || ready {
                if isLive {
                    self.publishAppClients()
                }
                return
            }
            DohDebugLog.record("DoH proxy not alive; restarting")
            self.configureFromSettings()
        }
    }

    /// Wi‑Fi ↔ cellular keeps the path `.satisfied`, so Encrypted DNS and
    /// sticky bootstrap IPs from the previous interface must be rebuilt.
    func recoverAfterPathChange() {
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else { return }
        DohDebugLog.record("DoH recovering after network path change")
        clearCache()
        ensureProxyAlive()
        PreferredNodeSelector.shared.reselect(trigger: .networkChange)
    }

    // MARK: - Cloudflare 本地优选

    /// 「连接方式」决定 URLSession 走 Encrypted DNS 还是本地 CONNECT + ECH。
    ///
    /// 运行时回退过（WebView 过盾后）就不再自动切回来，否则每次 reapply 都会把
    /// 刚回退掉的那条路又打开。
    private func applyConnectionMode() {
        let mode = AppSettings.dohConnectionMode(from: .standard)
        let enabled = UserDefaults.standard.bool(forKey: "dohEnabled")
        let ready = DohProxyLiveness.shouldEnableOriginECH(
            enabled: enabled,
            mode: mode,
            runtimeEscaped: LocalConnectProxy.runtimeECHEscaped
        )
        guard LocalConnectProxy.originECHReady != ready else { return }
        LocalConnectProxy.originECHReady = ready
        DohDebugLog.record(
            "连接方式 -> \(ready ? "本地 CONNECT + ECH" : "Encrypted DNS")"
                + (enabled && mode == .localECH && !ready ? "（运行时已回退）" : "")
        )
    }

    /// 用户重新选连接方式：清掉运行时回退标记并重新应用。
    /// 设置本身由调用方写入 `AppSettings`。
    func clearRuntimeECHEscapeAndReapply() {
        LocalConnectProxy.runtimeECHEscaped = false
        forceReapplyFromSettings()
    }

    /// 优选只在 DoH 开着且模式不是「关闭」时有意义；关掉时清掉赢家，回到普通 DoH 解析。
    func syncPreferredNode() {
        guard UserDefaults.standard.bool(forKey: "dohEnabled"),
              AppSettings.preferredNodeEnabled(from: .standard),
              AppSettings.preferredNodeMode(from: .standard) != .off
        else {
            if PreferredNodeStore.shared.node != nil {
                DohDebugLog.record("优选关闭，清除钉住", subsystem: "优选")
                PreferredNodeStore.shared.clear()
            }
            return
        }
        PreferredNodeSelector.shared.start()
        // 冷启动没有赢家时先跑一轮，别让 linux.do 落在被投毒的解析结果上。
        guard PreferredNodeStore.shared.node == nil else { return }
        PreferredNodeSelector.shared.reselect(trigger: .manual)
    }

    /// 设置页「重新优选」。`completion` 在主线程回调。
    func reselectPreferredNode(completion: ((PreferredNode?) -> Void)? = nil) {
        guard UserDefaults.standard.bool(forKey: "dohEnabled"),
              AppSettings.preferredNodeEnabled(from: .standard),
              AppSettings.preferredNodeMode(from: .standard) != .off
        else {
            completion?(nil)
            return
        }
        PreferredNodeSelector.shared.reselect(trigger: .manual, completion: completion)
    }

    private func applyConfiguration(shouldEnable: Bool, generation: Int) {
        lock.lock()
        let current = applyGeneration
        lock.unlock()
        guard current == generation else { return }

        if shouldEnable {
            let config = AppSettings.dohProxyConfig(from: .standard)
            if !config.bootstrapReady {
                lock.lock()
                lastError = DohProxyError.bootstrapUnavailable(config.serverURL)
                isStartingProxy = false
                stackReady = false
                lock.unlock()
                DohDebugLog.record("DoH start aborted: no bootstrap IP for \(config.serverURL)")
                EncryptedDnsService.disable()
                stop(clearError: false)
                publishAppClients()
                return
            }
            if let upstream = config.upstream, !upstream.isValid {
                lock.lock()
                lastError = DohProxyError.queryFailed("upstream")
                isStartingProxy = false
                stackReady = false
                lock.unlock()
                DohDebugLog.record("DoH start aborted: invalid upstream \(upstream.host):\(upstream.port)")
                EncryptedDnsService.disable()
                stop(clearError: false)
                publishAppClients()
                return
            }
            lock.lock()
            lastError = nil
            lock.unlock()
            resolver.updateConfig(config)
            // 优选用自己的解析器收候选和 ECH 钥匙；换了服务器/上游之后它还拿着
            // 启动时那份配置，会一直朝旧 DoH 端点查（换了 provider 后优选仍按
            // 旧地址解析，表现为「优选不对」）。
            PreferredNodeSelector.shared.updateConfig(config)
            DohDebugLog.record(
                "DoH starting \(config.serverURL) bootstrap=\(config.bootstrapIPs.joined(separator: ","))"
            )
            if LocalConnectProxy.originECHReady {
                EncryptedDnsService.disable()
                stop(clearError: false)
                startWebViewProxyNow()
                prewarmForumDNS()
                DohDebugLog.record("DoH Gateway + origin ECH for URLSession")
            } else {
                stop(clearError: false)
                if let spec = EncryptedDnsService.spec(fromDefaults: .standard) {
                    EncryptedDnsService.apply(spec)
                    prewarmForumDNS()
                } else {
                    EncryptedDnsService.disable()
                    DohDebugLog.record("Encrypted DNS skipped: no bootstrap IPs")
                }
                LocalConnectProxy.preferSafariWebViewHTTP = false
                DohDebugLog.record("DoH Encrypted DNS for URLSession")
            }
        } else {
            lock.lock()
            lastError = nil
            isStartingProxy = false
            stackReady = false
            lock.unlock()
            DohDebugLog.record("DoH disabled; not starting local proxy")
            EncryptedDnsService.disable()
            stop()
        }
        lock.lock()
        if applyGeneration == generation {
            isStartingProxy = false
            if shouldEnable {
                stackReady = true
            }
        }
        lock.unlock()
        publishAppClients()
    }

    func ensureRunning() -> UInt16? {
        lock.lock()
        let port = proxy?.proxyPort
        lock.unlock()
        return port
    }

    /// WKWebView ignores Encrypted DNS. Wait for CONNECT pass-through so
    /// Cloudflare challenge / login pages resolve via DoH, not system DNS.
    /// iOS 16 WKWebView cannot attach CONNECT; skip the listener.
    func prepareBrowserProxy() async {
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else { return }
        guard LocalConnectProxy.supportsWebViewCONNECTProxy,
              LocalConnectProxy.originECHReady
        else { return }
        startWebViewProxyNow()
        for _ in 0..<40 {
            if ensureRunning() != nil { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        applyWebViewProxy()
    }

    private func startWebViewProxyNow() {
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else {
            stop()
            return
        }
        lock.lock()
        if let proxy, proxy.isRunning {
            lock.unlock()
            publishAppClients()
            return
        }
        let newProxy = LocalConnectProxy(
            resolver: resolver,
            config: AppSettings.dohProxyConfig(from: .standard)
        )
        newProxy.onListening = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.consecutiveStartFailures = 0
            self.configurationVersion += 1
            self.stackReady = true
            self.lock.unlock()
            self.publishAppClients()
        }
        newProxy.onFailed = { [weak self, weak newProxy] error in
            guard let self else { return }
            self.lock.lock()
            if let newProxy, self.proxy === newProxy {
                self.proxy = nil
                self.lastError = error
                self.configurationVersion += 1
                self.stackReady = false
                self.isStartingProxy = false
            }
            self.lock.unlock()
            DohDebugLog.record("WebView DoH proxy failed: \(error.localizedDescription)")
            self.publishAppClients()
            self.scheduleAliveRestartIfNeeded()
        }
        proxy = newProxy
        lock.unlock()
        do {
            try newProxy.start()
        } catch {
            lock.lock()
            if proxy === newProxy {
                proxy = nil
                lastError = error
                configurationVersion += 1
            }
            lock.unlock()
            DohDebugLog.record("WebView DoH proxy start failed: \(error.localizedDescription)")
            publishAppClients()
            scheduleAliveRestartIfNeeded()
        }
    }

    private func reassertNameResolution() {
        if LocalConnectProxy.originECHReady {
            EncryptedDnsService.disable()
        } else {
            EncryptedDnsService.reassertFromDefaults()
        }
    }

    private func scheduleAliveRestartIfNeeded() {
        lock.lock()
        consecutiveStartFailures += 1
        let failures = consecutiveStartFailures
        lock.unlock()
        guard failures <= 3 else {
            DohDebugLog.record("DoH proxy restart gave up after \(failures) failures")
            return
        }
        startQueue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            guard UserDefaults.standard.bool(forKey: "dohEnabled") else { return }
            self.lock.lock()
            let isLive = self.proxy?.isRunning == true
            self.lock.unlock()
            guard !isLive else { return }
            DohDebugLog.record("DoH proxy retry \(failures)")
            self.configureFromSettings()
        }
    }

    func stop(clearError: Bool = true) {
        lock.lock()
        let oldProxy = proxy
        proxy = nil
        if clearError { lastError = nil }
        configurationVersion += 1
        lock.unlock()

        oldProxy?.stop()
        publishAppClients()
    }

    private func prewarmForumDNS() {
        resolver.resolve(host: "linux.do") { result in
            switch result {
            case .success(let answer):
                DohDebugLog.record(
                    "DoH prewarm linux.do -> \(answer.addresses.prefix(2).joined(separator: ", ")) ech=\(answer.echConfig?.count ?? 0)"
                )
            case .failure(let error):
                DohDebugLog.record("DoH prewarm linux.do failed: \(error.localizedDescription)")
            }
        }
    }

    func clearCache() {
        resolver.clearCache()
        // 解析器和 DoH 自身的缓存一起清：换网络后旧的系统解析结果和复用的
        // DoH 连接都会指向已经不可达的出口。
        DohBootstrapTransport.clearSystemAddressCache()
        DohBootstrapTransport.closeIdleConnections()
        NWParameters.PrivacyContext.default.flushCache()
    }

    func resolverCacheStats() -> DohCacheStats {
        resolver.cacheStats()
    }

    struct ProbeResult: Equatable {
        var ok: Bool
        var latencyMs: Int
        var host: String
        var addresses: [String]
        var errorDescription: String?

        var subtitle: String {
            if ok {
                let ips = addresses.prefix(2).joined(separator: ", ")
                return "\(latencyMs) ms · \(host) → \(ips)"
            }
            return errorDescription
                ?? String(localized: "settings.network.doh_test.failed", defaultValue: "测试失败")
        }
    }

    /// Resolves `host` through the given DoH server (or the current one).
    func probe(
        serverURL: String? = nil,
        bootstrapIPs: [String]? = nil,
        host: String = "linux.do",
        completion: @escaping (ProbeResult) -> Void
    ) {
        var config = AppSettings.dohProxyConfig(from: .standard)
        if let serverURL {
            config.serverURL = serverURL
            if let bootstrapIPs, !bootstrapIPs.isEmpty {
                config.bootstrapIPs = bootstrapIPs
            } else if let builtIn = DohServerCatalog.builtIn(url: serverURL) {
                config.bootstrapIPs = builtIn.bootstrapIPs
            } else {
                config.bootstrapIPs = DohServerCatalog.inferredBootstrapIPs(for: serverURL)
            }
        }
        config.enabled = true
        guard config.bootstrapReady else {
            completion(
                ProbeResult(
                    ok: false,
                    latencyMs: 0,
                    host: host,
                    addresses: [],
                    errorDescription: String(
                        localized: "settings.network.doh_test.no_bootstrap",
                        defaultValue: "没有 Bootstrap IP，无法连接 DoH 服务器"
                    )
                )
            )
            return
        }
        let started = Date()
        let probeResolver = DohResolver(config: config)
        probeResolver.resolve(host: host) { result in
            let ms = max(1, Int(Date().timeIntervalSince(started) * 1000))
            let probe: ProbeResult
            switch result {
            case .success(let answer):
                probe = ProbeResult(
                    ok: !answer.addresses.isEmpty,
                    latencyMs: ms,
                    host: host,
                    addresses: answer.addresses,
                    errorDescription: answer.addresses.isEmpty
                        ? String(localized: "settings.network.doh_test.empty", defaultValue: "没有解析到地址")
                        : nil
                )
            case .failure(let error):
                probe = ProbeResult(
                    ok: false,
                    latencyMs: ms,
                    host: host,
                    addresses: [],
                    errorDescription: error.localizedDescription
                )
            }
            DispatchQueue.main.async {
                completion(probe)
            }
        }
    }

    func connectionProxyDictionary(for baseURL: String) -> [AnyHashable: Any]? {
        let config = URLSessionConfiguration.ephemeral
        apply(to: config, hostURL: baseURL)
        return config.connectionProxyDictionary
    }

    /// URLSession stays on Encrypted DNS so the system TLS stack presents
    /// the fingerprint Cloudflare already cleared. CONNECT is only attached
    /// when origin ECH MITM is on.
    func apply(
        to sessionConfiguration: URLSessionConfiguration,
        hostURL: String? = nil,
        preferGateway: Bool = false
    ) {
        let enabled = UserDefaults.standard.bool(forKey: "dohEnabled")
        let config = AppSettings.dohProxyConfig(from: .standard)
        let useGateway = preferGateway && config.isGatewayMode && LocalConnectProxy.originECHReady
        let port = ensureRunning()
        guard LocalConnectProxy.originECHReady,
              DohProxyLiveness.shouldAttachConnectProxy(
                enabled: enabled,
                useGateway: useGateway,
                port: port
              ),
              let port
        else {
            clearProxy(on: sessionConfiguration)
            return
        }
        sessionConfiguration.connectionProxyDictionary = Self.proxyDictionary(port: port)
        if #available(iOS 17.0, *) {
            if let proxy = Self.connectProxyConfiguration(port: port) {
                sessionConfiguration.proxyConfigurations = [proxy]
            }
        }
        let mode = LocalConnectProxy.originECHReady ? "MITM" : "pass-through"
        DohDebugLog.record("Using local CONNECT \(mode) proxy on 127.0.0.1:\(port)")
    }

    private func publishAppClients() {
        let work = { [weak self] in
            self?.applyWebViewProxy()
            self?.applyImageDownloaderProxy()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func applyWebViewProxy() {
        guard #available(iOS 17.0, *) else { return }
        let enabled = UserDefaults.standard.bool(forKey: "dohEnabled")
        lock.lock()
        let port = (enabled && proxy?.isRunning == true) ? proxy?.proxyPort : nil
        lock.unlock()
        let apply = {
            if let port, let proxy = Self.connectProxyConfiguration(port: port) {
                WKWebsiteDataStore.default().proxyConfigurations = [proxy]
                let mode = LocalConnectProxy.originECHReady ? "MITM" : "pass-through"
                DohDebugLog.record("WKWebView default store using CONNECT \(mode) 127.0.0.1:\(port)")
            } else {
                WKWebsiteDataStore.default().proxyConfigurations = []
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Each `WKWebsiteDataStore` carries its own `proxyConfigurations`; an
    /// ephemeral store does not inherit `.default()`. The challenge WebViews use
    /// private stores, so without this they would fall back to system DNS while
    /// DoH is on and fail to load the challenge page at all.
    func applyWebViewProxy(to dataStore: WKWebsiteDataStore) {
        guard #available(iOS 17.0, *) else { return }
        let enabled = UserDefaults.standard.bool(forKey: "dohEnabled")
        lock.lock()
        let port = (enabled && proxy?.isRunning == true) ? proxy?.proxyPort : nil
        lock.unlock()
        let apply = {
            if let port, let proxy = Self.connectProxyConfiguration(port: port) {
                dataStore.proxyConfigurations = [proxy]
                DohDebugLog.record(
                    "WKWebView private store using CONNECT 127.0.0.1:\(port)",
                    subsystem: "Auth"
                )
            } else {
                dataStore.proxyConfigurations = []
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func applyImageDownloaderProxy() {
        let config = SDWebImageDownloader.shared.config.sessionConfiguration
            ?? URLSessionConfiguration.default
        apply(to: config, hostURL: "https://linux.do", preferGateway: true)
        SDWebImageDownloader.shared.config.sessionConfiguration = config
    }

    private func clearProxy(on sessionConfiguration: URLSessionConfiguration) {
        sessionConfiguration.connectionProxyDictionary = nil
        if #available(iOS 17.0, *) {
            sessionConfiguration.proxyConfigurations = []
        }
    }

    static func proxyDictionary(port: UInt16) -> [AnyHashable: Any] {
        [
            "HTTPEnable": NSNumber(value: 1),
            "HTTPProxy": "127.0.0.1",
            "HTTPPort": NSNumber(value: Int(port)),
            "HTTPSEnable": NSNumber(value: 1),
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": NSNumber(value: Int(port)),
            "ExceptionsList": ["127.0.0.1", "localhost", "::1"],
        ]
    }

    @available(iOS 17.0, *)
    private static func connectProxyConfiguration(port: UInt16) -> ProxyConfiguration? {
        guard let ipv4 = IPv4Address("127.0.0.1"),
              let nwPort = NWEndpoint.Port(rawValue: port)
        else {
            return nil
        }
        let endpoint = NWEndpoint.hostPort(host: .ipv4(ipv4), port: nwPort)
        return ProxyConfiguration(httpCONNECTProxy: endpoint)
    }

    private static func host(from baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: trimmed)?.host {
            return host
        }
        return URL(string: "https://\(trimmed)")?.host
    }

}
