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
        if #available(iOS 17.0, *), browserReady {
            return "应用内 DoH · CONNECT MITM · 浏览器"
        }
        return "应用内 DoH · CONNECT MITM"
    }

    func configureFromSettings() {
        lock.lock()
        let signature = currentSignature
        if signature == lastSignature {
            lock.unlock()
            return
        }
        lastSignature = signature
        configurationVersion += 1
        let shouldEnable = UserDefaults.standard.bool(forKey: "dohEnabled")
        lock.unlock()

        if shouldEnable {
            let config = AppSettings.dohProxyConfig(from: .standard)
            if !config.bootstrapReady {
                lock.lock()
                lastError = DohProxyError.bootstrapUnavailable(config.serverURL)
                lock.unlock()
                EncryptedDnsService.disable()
                stop()
                return
            }
            lock.lock()
            lastError = nil
            lock.unlock()
            resolver.updateConfig(config)
            EncryptedDnsService.applyFromDefaults()
            startQueue.async { [weak self] in
                self?.startWebViewProxyNow()
            }
        } else {
            lock.lock()
            lastError = nil
            lock.unlock()
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
        let newProxy = LocalConnectProxy(resolver: resolver)
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

    func stop() {
        lock.lock()
        let oldProxy = proxy
        proxy = nil
        lastError = nil
        configurationVersion += 1
        lock.unlock()

        oldProxy?.stop()
        publishAppClients()
    }

    func clearCache() {
        resolver.clearCache()
        NWParameters.PrivacyContext.default.flushCache()
    }

    func connectionProxyDictionary(for baseURL: String) -> [AnyHashable: Any]? {
        let config = URLSessionConfiguration.ephemeral
        apply(to: config, hostURL: baseURL)
        return config.connectionProxyDictionary
    }

    /// FluxDo-style HTTP CONNECT to the in-app MITM proxy for linux.do.
    /// Other sessions keep Encrypted DNS and no proxy dictionary.
    func apply(to sessionConfiguration: URLSessionConfiguration, hostURL: String? = nil) {
        let shouldAttach: Bool
        if let hostURL, let host = Self.host(from: hostURL) {
            shouldAttach = UserDefaults.standard.bool(forKey: "dohEnabled")
        } else {
            shouldAttach = false
        }
        guard shouldAttach, let port = ensureRunning() else {
            clearProxy(on: sessionConfiguration)
            return
        }
        sessionConfiguration.connectionProxyDictionary = Self.proxyDictionary(port: port)
        if #available(iOS 17.0, *) {
            if let proxy = Self.connectProxyConfiguration(port: port) {
                sessionConfiguration.proxyConfigurations = [proxy]
            }
        }
        DohDebugLog.record("Using local CONNECT MITM proxy on 127.0.0.1:\(port)")
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
                DohDebugLog.record("WKWebView default store using CONNECT MITM 127.0.0.1:\(port)")
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
        // Images use Encrypted DNS, not SOCKS. Mixing both aborts CFNetwork.
        clearProxy(on: config)
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
