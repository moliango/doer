import DohProxy
import Foundation
import Network

/// In-app DoH via Network.framework Encrypted DNS. No system DNS profile.
///
/// URLSession / Alamofire / SDWebImage honor `PrivacyContext.default`.
/// WKWebView is a separate process: iOS 17+ uses the local SOCKS helper.
nonisolated enum EncryptedDnsService {
    struct ResolverSpec: Equatable {
        var url: URL
        var bootstrapIPs: [String]
    }

    static func spec(fromDefaults defaults: UserDefaults = .standard) -> ResolverSpec? {
        let config = AppSettings.dohProxyConfig(from: defaults)
        guard let url = URL(string: config.serverURL), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let ips = orderedBootstrapIPs(config.bootstrapIPs, preferIPv6: config.preferIPv6)
        guard !ips.isEmpty else { return nil }
        return ResolverSpec(url: url, bootstrapIPs: ips)
    }

    static func spec(urlString: String, providerRaw: Int?) -> ResolverSpec? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let provider = AppSettings.DoHProvider(rawValue: providerRaw ?? AppSettings.DoHProvider.dnspod.rawValue)
            ?? .dnspod
        var ips = provider.bootstrapIPs
        if ips.isEmpty, let host = url.host, IPv4Address(host) != nil || IPv6Address(host) != nil {
            ips = [host]
        }
        return ResolverSpec(url: url, bootstrapIPs: ips)
    }

    static func applyFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: "dohEnabled")
        guard enabled, let spec = spec(fromDefaults: .standard) else {
            disable()
            return
        }
        apply(spec)
    }

    private static let applyLock = NSLock()
    private static var lastApplied: ResolverSpec?
    /// 上一次验证通过的 spec。新服务器探不通时回退到它。
    private static var lastVerified: ResolverSpec?
    private static var lastLiveSystemIPs: [String] = []
    private static var encryptedResolutionEnabled = false
    private static let checkQueue = DispatchQueue(
        label: "doer.encrypted-dns.bootstrap-check",
        attributes: .concurrent
    )

    /// 装上一份 resolver。
    ///
    /// 换 provider 时**先探活再交出去**：`requireEncryptedNameResolution(true)` 会把整个进程的
    /// 解析都交给这台 DoH，交给一台连不上的（Google / Quad9 / Cloudflare 在国内就是这种）
    /// 等于让整个 App 断网。探不通就回退到上一次验证通过的，再不行退回系统 DNS。
    static func apply(_ spec: ResolverSpec) {
        applyLock.lock()
        let alreadyEncrypted = encryptedResolutionEnabled
        let cachedSystem = lastLiveSystemIPs
        applyLock.unlock()

        let system: [String]
        if alreadyEncrypted {
            // `getaddrinfo` honors PrivacyContext. Probing the DoH host after
            // Encrypted DNS is on waits on the same resolver (~30s timeout).
            system = cachedSystem
        } else if let host = spec.url.host {
            system = DohBootstrapTransport.systemAddresses(for: host)
            applyLock.lock()
            lastLiveSystemIPs = system
            applyLock.unlock()
        } else {
            system = []
        }
        let ips = encryptedDNSBootstrapIPs(
            configured: spec.bootstrapIPs,
            system: system,
            serverURL: spec.url
        )
        guard !ips.isEmpty else {
            disable()
            DohDebugLog.record("Encrypted DNS skipped: no usable bootstrap IPs")
            return
        }
        let normalized = ResolverSpec(url: spec.url, bootstrapIPs: ips)

        applyLock.lock()
        let unchanged = lastApplied == normalized
        applyLock.unlock()
        if unchanged {
            commit(normalized)
            return
        }

        checkQueue.async {
            guard hasReachableBootstrap(ips) else {
                DohDebugLog.record(
                    "Encrypted DNS 拒绝启用 \(normalized.url.host ?? "?"): bootstrap \(ips.joined(separator: ",")) 都连不上"
                )
                fallBackOrDisable()
                return
            }
            commit(normalized)
        }
    }

    /// 真正把 resolver 交给 Network.framework。调用方已确认这台服务器可用。
    private static func commit(_ spec: ResolverSpec) {
        applyLock.lock()
        let alreadyApplied = lastApplied == spec
        lastApplied = spec
        lastVerified = spec
        encryptedResolutionEnabled = true
        applyLock.unlock()
        DohBootstrapTransport.skipSystemAddressLookup = true
        let endpoints = bootstrapEndpoints(spec.bootstrapIPs)
        let resolver = NWParameters.PrivacyContext.ResolverConfiguration.https(
            spec.url,
            serverAddresses: endpoints
        )
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            true,
            fallbackResolver: resolver
        )
        if !alreadyApplied {
            NWParameters.PrivacyContext.default.flushCache()
        }
        DohDebugLog.record(
            "Encrypted DNS on \(spec.url.absoluteString) bootstrap=\(spec.bootstrapIPs.joined(separator: ","))"
        )
    }

    /// 新服务器不可用时回退到上一次验证通过的；没有就退回系统 DNS。
    /// 无论哪条路，都不会留一个连不上的 resolver。
    private static func fallBackOrDisable() {
        applyLock.lock()
        let fallback = lastVerified
        let current = lastApplied
        applyLock.unlock()
        guard let fallback, fallback != current else {
            DohDebugLog.record("Encrypted DNS 无可用回退，退回系统 DNS")
            disable()
            return
        }
        DohDebugLog.record("Encrypted DNS 回退到上一次可用的 \(fallback.url.host ?? "?")")
        commit(fallback)
    }

    /// bootstrap IP 里至少有一个能在预算内连上 443。
    private static func hasReachableBootstrap(_ ips: [String], timeout: TimeInterval = 1.2) -> Bool {
        let candidates = ips.prefix(4).compactMap { ip -> NWEndpoint.Host? in
            if let v4 = IPv4Address(ip) { return .ipv4(v4) }
            if let v6 = IPv6Address(ip) { return .ipv6(v6) }
            return nil
        }
        guard !candidates.isEmpty else { return false }

        let lock = NSLock()
        var reachable = false
        let group = DispatchGroup()
        for host in candidates {
            group.enter()
            var settled = false
            let connection = NWConnection(host: host, port: 443, using: .tcp)
            let settle: (Bool) -> Void = { ok in
                lock.lock()
                let first = !settled
                settled = true
                if ok { reachable = true }
                lock.unlock()
                guard first else { return }
                connection.cancel()
                group.leave()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: settle(true)
                case .failed, .cancelled: settle(false)
                default: break
                }
            }
            connection.start(queue: checkQueue)
            checkQueue.asyncAfter(deadline: .now() + timeout) { settle(false) }
        }
        _ = group.wait(timeout: .now() + timeout + 0.3)
        lock.lock()
        let result = reachable
        lock.unlock()
        return result
    }

    /// Force-apply after foreground / path restore. `apply` skips flush when
    /// the spec is unchanged, but iOS can drop PrivacyContext while suspended.
    static func reassertFromDefaults() {
        applyLock.lock()
        lastApplied = nil
        applyLock.unlock()
        applyFromDefaults()
    }

    static func disable() {
        applyLock.lock()
        lastApplied = nil
        lastLiveSystemIPs = []
        encryptedResolutionEnabled = false
        applyLock.unlock()
        DohBootstrapTransport.skipSystemAddressLookup = false
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            false,
            fallbackResolver: nil
        )
        NWParameters.PrivacyContext.default.flushCache()
        DohDebugLog.record("Encrypted DNS off")
    }

    /// Clash / Surge fake-ip (198.18.0.0/15). Encrypted DNS must not use these
    /// as bootstrap or steal URLSession from the tunnel — that surfaces as
    /// `SSL错误，无法建立与该服务器的安全连接`.
    static func isTunnelFakeIP(_ ip: String) -> Bool {
        guard let v4 = IPv4Address(ip) else { return false }
        let bytes = [UInt8](v4.rawValue)
        guard bytes.count >= 2 else { return false }
        return bytes[0] == 198 && (bytes[1] == 18 || bytes[1] == 19)
    }

    static func shouldSkipEncryptedDNS(systemIPs: [String], forumIPs: [String] = []) -> Bool {
        _ = (systemIPs, forumIPs)
        return false
    }

    static func usableBootstrapIPs(_ ips: [String]) -> [String] {
        orderedBootstrapIPs(ips.filter { !isTunnelFakeIP($0) }, preferIPv6: false)
    }

    /// Live system IPs of the DoH host first, configured IPs as fallback.
    /// Drops Clash fake-ip and recursive resolver IPs that are not this host
    /// (e.g. `119.29.29.29` is only valid for `dns.pub`).
    static func encryptedDNSBootstrapIPs(
        configured: [String],
        system: [String],
        serverURL: URL
    ) -> [String] {
        var ips = configured
        for ip in system.reversed() where !ips.contains(ip) && !isTunnelFakeIP(ip) {
            ips.insert(ip, at: 0)
        }
        return usableEncryptedDNSBootstrapIPs(ips, serverURL: serverURL)
    }

    /// Encrypted DNS must reach the DoH hostname, not an unrelated recursive
    /// resolver. `119.29.29.29` is Tencent DNS and is only valid for `dns.pub`.
    static func usableEncryptedDNSBootstrapIPs(_ ips: [String], serverURL: URL) -> [String] {
        let inferred = DohServerCatalog.inferredBootstrapIPs(for: serverURL.absoluteString)
        let host = (serverURL.host ?? "").lowercased()
        return orderedBootstrapIPs(
            ips.filter { isUsableEncryptedDNSBootstrapIP($0, host: host, inferred: inferred) },
            preferIPv6: false
        )
    }

    static func isUsableEncryptedDNSBootstrapIP(
        _ ip: String,
        host: String,
        inferred: [String]
    ) -> Bool {
        if isTunnelFakeIP(ip) { return false }
        if inferred.contains(ip) { return true }
        if host == ip.lowercased() { return true }
        if isForeignBuiltinResolver(ip, host: host) { return false }
        return true
    }

    static func isForeignBuiltinResolver(_ ip: String, host: String) -> Bool {
        for server in DohServerCatalog.builtIn {
            let serverHost = URL(string: server.url)?.host?.lowercased()
            if serverHost == host { continue }
            if server.bootstrapIPs.contains(ip) { return true }
        }
        return false
    }

    /// Live resolver IPs first, IPv4 before IPv6. Hardcoded anycast like
    /// 162.159.36.1 often times out on the same network that can reach .5/.20.
    static func orderedBootstrapIPs(_ ips: [String], preferIPv6: Bool) -> [String] {
        var seen = Set<String>()
        let unique = ips.filter { seen.insert($0).inserted }
        let v4 = unique.filter { IPv4Address($0) != nil }
        let v6 = unique.filter { IPv6Address($0) != nil }
        if preferIPv6, !v6.isEmpty { return v6 + v4 }
        if !v4.isEmpty { return v4 }
        return v6
    }

    static func bootstrapEndpoints(_ ips: [String]) -> [NWEndpoint] {
        ips.compactMap { ip in
            if let v4 = IPv4Address(ip) {
                return .hostPort(host: .ipv4(v4), port: 443)
            }
            if let v6 = IPv6Address(ip) {
                return .hostPort(host: .ipv6(v6), port: 443)
            }
            return nil
        }
    }
}
