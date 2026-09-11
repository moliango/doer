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

    static func apply(_ spec: ResolverSpec) {
        var ips = spec.bootstrapIPs
        if let host = spec.url.host {
            for ip in DohBootstrapTransport.systemAddresses(for: host) where !ips.contains(ip) {
                ips.insert(ip, at: 0)
            }
        }
        ips = orderedBootstrapIPs(ips, preferIPv6: false)
        let normalized = ResolverSpec(url: spec.url, bootstrapIPs: ips)
        applyLock.lock()
        let alreadyApplied = lastApplied == normalized
        lastApplied = normalized
        applyLock.unlock()
        let endpoints = bootstrapEndpoints(ips)
        let resolver = NWParameters.PrivacyContext.ResolverConfiguration.https(
            normalized.url,
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
            "Encrypted DNS on \(normalized.url.absoluteString) bootstrap=\(ips.joined(separator: ","))"
        )
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
        applyLock.unlock()
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            false,
            fallbackResolver: nil
        )
        NWParameters.PrivacyContext.default.flushCache()
        DohDebugLog.record("Encrypted DNS off")
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
