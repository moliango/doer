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

    private init() {}

    var currentSignature: String {
        AppSettings.dohProxyConfig(from: .standard).signature
    }

    var sessionConfigurationSignature: String {
        "\(currentSignature)|\(configurationVersion)"
    }

    var statusDescription: String {
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
            if #available(iOS 17.0, *), browserReady {
                return "应用内 DoH · Encrypted DNS · 浏览器直通"
            }
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
        lock.lock()
        applyGeneration += 1
        let generation = applyGeneration
        let signature = currentSignature
        if signature == lastSignature {
            lock.unlock()
            return
        }
        lastSignature = signature
        configurationVersion += 1
        let shouldEnable = UserDefaults.standard.bool(forKey: "dohEnabled")
        lock.unlock()

        startQueue.async { [weak self] in
            self?.applyConfiguration(shouldEnable: shouldEnable, generation: generation)
        }
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
            DohDebugLog.record(
                "DoH starting \(config.serverURL) bootstrap=\(config.bootstrapIPs.joined(separator: ","))"
            )
            if LocalConnectProxy.originECHReady {
                EncryptedDnsService.disable()
                stop(clearError: false)
                startWebViewProxyNow()
            } else {
                stop(clearError: false)
                if let spec = EncryptedDnsService.spec(fromDefaults: .standard) {
                    EncryptedDnsService.apply(spec)
                    prewarmForumDNS()
                } else {
                    EncryptedDnsService.disable()
                    DohDebugLog.record("Encrypted DNS skipped: no bootstrap IPs")
                }
                // WKWebView ignores Network.framework Encrypted DNS. Keep CONNECT
                // pass-through (no MITM) so CF challenge / login / in-app browser
                // resolve via DoH instead of poisoned system DNS.
                startWebViewProxyNow()
                DohDebugLog.record("DoH Encrypted DNS + CONNECT pass-through for WKWebView")
            }
        } else {
            lock.lock()
            lastError = nil
            lock.unlock()
            DohDebugLog.record("DoH disabled; not starting local proxy")
            EncryptedDnsService.disable()
            stop()
        }
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
    func prepareBrowserProxy() async {
        guard UserDefaults.standard.bool(forKey: "dohEnabled") else { return }
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
            self.configurationVersion += 1
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
            }
            self.lock.unlock()
            DohDebugLog.record("WebView DoH proxy failed: \(error.localizedDescription)")
            self.publishAppClients()
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
                    "DoH prewarm linux.do -> \(answer.addresses.prefix(2).joined(separator: ", "))"
                )
            case .failure(let error):
                DohDebugLog.record("DoH prewarm linux.do failed: \(error.localizedDescription)")
            }
        }
    }

    func clearCache() {
        resolver.clearCache()
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

    /// Attach the local proxy. Gateway API sessions skip CONNECT so they can
    /// speak plaintext HTTP to 127.0.0.1 (excepted from the proxy list).
    func apply(
        to sessionConfiguration: URLSessionConfiguration,
        hostURL: String? = nil,
        preferGateway: Bool = false
    ) {
        let enabled = UserDefaults.standard.bool(forKey: "dohEnabled")
        let config = AppSettings.dohProxyConfig(from: .standard)
        let useGateway = preferGateway && config.isGatewayMode && LocalConnectProxy.originECHReady
        guard enabled, LocalConnectProxy.originECHReady, !useGateway, let port = ensureRunning() else {
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

    private func applyImageDownloaderProxy() {
        let config = SDWebImageDownloader.shared.config.sessionConfiguration
            ?? URLSessionConfiguration.default
        apply(to: config, hostURL: "https://linux.do", preferGateway: false)
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
