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
        let provider = DohProviderConfiguration.currentFromDefaults()
        return spec(urlString: provider.url, providerRaw: defaults.object(forKey: "dohProvider") as? Int)
    }

    static func spec(urlString: String, providerRaw: Int?) -> ResolverSpec? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return nil
        }
        let provider = AppSettings.DoHProvider(rawValue: providerRaw ?? AppSettings.DoHProvider.dnspod.rawValue)
            ?? .alidns
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

    static func apply(_ spec: ResolverSpec) {
        let endpoints = bootstrapEndpoints(spec.bootstrapIPs)
        let resolver = NWParameters.PrivacyContext.ResolverConfiguration.https(
            spec.url,
            serverAddresses: endpoints
        )
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            true,
            fallbackResolver: resolver
        )
        NWParameters.PrivacyContext.default.flushCache()
        DohDebugLog.record(
            "Encrypted DNS on \(spec.url.absoluteString) bootstrap=\(spec.bootstrapIPs.joined(separator: ","))"
        )
    }

    static func disable() {
        NWParameters.PrivacyContext.default.requireEncryptedNameResolution(
            false,
            fallbackResolver: nil
        )
        NWParameters.PrivacyContext.default.flushCache()
        DohDebugLog.record("Encrypted DNS off")
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
