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
    /// 上一次清解析缓存的时刻。回前台会强制重新装 resolver，但清缓存会让
    /// 全进程所有 host 重新解析，没必要每次都付这个代价。
    private static var lastFlushAt: Date?
    private static let flushCooldown: TimeInterval = 120
    /// DoH 连续不可达退回系统 DNS 后的冷却。Encrypted DNS 把整个进程的解析都
    /// 压在这一台服务器上，它一坏就是「完全没网」，所以必须能自己退出来。
    private static let unreachableCooldown: TimeInterval = 300
    private static var retrySuppressedUntil: Date?
    private static var retrySuppressedSpec: ResolverSpec?
    private static var encryptedResolutionEnabled = false
    private static let checkQueue = DispatchQueue(
        label: "doer.encrypted-dns.bootstrap-check",
        attributes: .concurrent
    )
    private static let applyQueue = DispatchQueue(label: "doer.encrypted-dns.apply")

    /// 装上一份 resolver。
    ///
    /// 换 provider 时**先探活再交出去**：`requireEncryptedNameResolution(true)` 会把整个进程的
    /// 解析都交给这台 DoH，交给一台连不上的（Google / Quad9 / Cloudflare 在国内就是这种）
    /// 等于让整个 App 断网。探不通就回退到上一次验证通过的，再不行退回系统 DNS。
    static func apply(_ spec: ResolverSpec) {
        // 这里会做 `getaddrinfo`（阻塞，DNS 坏了能卡几十秒），而调用方常常是
        // 主线程（启动 / 回前台）。整段挪到专用串行队列上，顺序不变。
        applyQueue.async { applyNow(spec) }
    }

    private static func applyNow(_ spec: ResolverSpec) {
        applyLock.lock()
        let alreadyEncrypted = encryptedResolutionEnabled
        let cachedSystem = lastLiveSystemIPs
        let suppressedUntil = retrySuppressedUntil
        let suppressedSpec = retrySuppressedSpec
        applyLock.unlock()
        // 上一轮判定这台 DoH 不可达：冷却期内继续用系统 DNS，别再把自己锁死。
        // 换了服务器（spec 不同）就立刻允许重试。
        if let suppressedUntil, suppressedUntil > Date(), suppressedSpec == spec {
            DohDebugLog.record(
                "Encrypted DNS 冷却中（上次不可达），保持系统 DNS",
                subsystem: "DoH"
            )
            return
        }

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
        // 打开 Encrypted DNS 之后 `getaddrinfo` 就废了（会递归到同一台 DoH 上），
        // 传输层只能吃缓存；这里先把刚拿到的系统 IP 灌进去，否则它就只剩配置里
        // 那个可能连不上的 bootstrap（例如国内连不上的 8.8.8.8）。
        if let host = spec.url.host {
            DohBootstrapTransport.seedSystemAddresses(system, for: host)
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
        let alreadyApplied = lastApplied == normalized
        let alreadyVerified = lastVerified == normalized
        applyLock.unlock()
        // 同一份 spec 已经验证过就不必再探活：探活只是防止「新换的服务器
        // 根本连不上」，回前台 / 切网络时重复探一轮等于白开 4 条 TCP。
        if alreadyApplied || alreadyVerified {
            commit(normalized)
            return
        }

        checkQueue.async {
            guard canReachDoH(normalized) else {
                DohDebugLog.record(
                    "Encrypted DNS 拒绝启用 \(normalized.url.host ?? "?"): bootstrap \(ips.joined(separator: ",")) 握手或查询失败"
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
        let previous = lastApplied
        let now = Date()
        // 换服务器必须清；只是回前台重新装上同一份 resolver 时，跟着冷却走。
        let changed = previous != nil && previous != spec
        let shouldFlush = changed
            || lastFlushAt.map { now.timeIntervalSince($0) > flushCooldown } ?? true
        if shouldFlush { lastFlushAt = now }
        let alreadyApplied = previous == spec
        lastApplied = spec
        lastVerified = spec
        encryptedResolutionEnabled = true
        retrySuppressedUntil = nil
        retrySuppressedSpec = nil
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
        if shouldFlush, !alreadyApplied {
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

    /// 真的打一条 DoH 查询过去，而不是只 TCP 连一下 443。
    ///
    /// 只探 TCP 的话，一个能连上但不服务这个主机名的 IP（比如填错、CDN 换边）
    /// 会被当成可用，`requireEncryptedNameResolution(true)` 一交出去整个 App 就
    /// 没网了。这里用真实查询验证 TLS + 路径 + 应答都通。
    private static func canReachDoH(_ spec: ResolverSpec, timeout: TimeInterval = 3) -> Bool {
        guard let endpoint = DohEndpoint(
            url: spec.url.absoluteString,
            bootstrapIPs: spec.bootstrapIPs,
            preferIPv6: false
        ), endpoint.isReady,
            let query = DohDNSMessage.makeQuery(host: "linux.do", type: DohDNSMessage.typeA)
        else { return false }

        let semaphore = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "doer.encrypted-dns.probe")
        let lock = NSLock()
        var reachable = false
        DohBootstrapTransport.query(endpoint: endpoint, dnsQuery: query, queue: queue, quiet: true) { result in
            if case .success = result {
                lock.lock()
                reachable = true
                lock.unlock()
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
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

    /// DoH 已经连不上时退回系统 DNS。
    ///
    /// `requireEncryptedNameResolution(true)` 一旦指向一台坏掉的服务器，整个进程
    /// 就没有解析可用——表现为「完全没网」。这里主动退出，并冷却一段时间，
    /// 期间前台重装 resolver 不会再把同一台坏服务器交出去。
    static func fallbackToSystemDNS(reason: String) {
        applyLock.lock()
        let spec = lastApplied
        lastApplied = nil
        lastVerified = nil
        lastFlushAt = nil
        encryptedResolutionEnabled = false
        retrySuppressedUntil = Date().addingTimeInterval(unreachableCooldown)
        retrySuppressedSpec = spec
        applyLock.unlock()
        DohBootstrapTransport.skipSystemAddressLookup = false
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            false,
            fallbackResolver: nil
        )
        NWParameters.PrivacyContext.default.flushCache()
        DohDebugLog.record(
            "Encrypted DNS 退回系统 DNS（\(reason)），\(Int(unreachableCooldown))s 内不再尝试",
            subsystem: "DoH"
        )
    }

    static func disable() {
        applyLock.lock()
        lastApplied = nil
        lastVerified = nil
        lastLiveSystemIPs = []
        lastFlushAt = nil
        encryptedResolutionEnabled = false
        retrySuppressedUntil = nil
        retrySuppressedSpec = nil
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
