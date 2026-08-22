import DohProxy
import UIKit
import ObjectiveC
import CoreText
import Security

// MARK: - DNS over HTTPS
extension AppSettings {

    enum DoHProvider: Int, CaseIterable {
        case cloudflare = 0
        case google = 1
        case quad9 = 2
        case alidns = 3
        case custom = 4
        case dnspod = 5
        case tencent = 6
        case canadianShield = 7

        var title: String {
            switch self {
            case .cloudflare: return "Cloudflare (1.1.1.1)"
            case .google: return "Google (8.8.8.8)"
            case .quad9: return "Quad9 (9.9.9.9)"
            case .alidns: return "AliDNS (223.5.5.5)"
            case .custom: return String(localized: "doh.provider.custom")
            case .dnspod: return "DNSPod (doh.pub)"
            case .tencent: return "腾讯 DNS (dns.pub)"
            case .canadianShield: return "Canadian Shield"
            }
        }

        var url: String {
            switch self {
            case .cloudflare: return "https://cloudflare-dns.com/dns-query"
            case .google: return "https://dns.google/dns-query"
            case .quad9: return "https://dns.quad9.net/dns-query"
            case .alidns: return "https://dns.alidns.com/dns-query"
            case .custom: return ""
            case .dnspod: return "https://doh.pub/dns-query"
            case .tencent: return "https://dns.pub/dns-query"
            case .canadianShield: return "https://private.canadianshield.cira.ca/dns-query"
            }
        }

        /// IPs used to reach the DoH server without system DNS.
        var bootstrapIPs: [String] {
            switch self {
            case .cloudflare:
                return ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
            case .google:
                return ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
            case .quad9:
                return ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
            case .alidns:
                return ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"]
            case .dnspod:
                return ["1.12.12.12", "120.53.53.53"]
            case .tencent:
                return ["119.29.29.29", "119.28.28.28"]
            case .canadianShield, .custom:
                return []
            }
        }
    }

    var dohEnabled: Bool {
        get { defaults.bool(forKey: "dohEnabled") }
        set {
            defaults.set(newValue, forKey: "dohEnabled")
            notifyChanged()
        }
    }

    var dohProvider: DoHProvider {
        get {
            guard defaults.object(forKey: "dohProvider") != nil else { return .dnspod }
            return DoHProvider(rawValue: defaults.integer(forKey: "dohProvider")) ?? .dnspod
        }
        set {
            defaults.set(newValue.rawValue, forKey: "dohProvider")
            notifyChanged()
        }
    }

    var dohCustomURL: String {
        get { defaults.string(forKey: "dohCustomURL") ?? "" }
        set {
            defaults.set(newValue, forKey: "dohCustomURL")
            notifyChanged()
        }
    }

    var dohServerURL: String {
        if dohProvider == .custom {
            return dohCustomURL
        }
        return dohProvider.url
    }

    var dohGatewayEnabled: Bool {
        get { bool(forKey: "dohGatewayEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "dohGatewayEnabled")
            notifyChanged()
        }
    }

    var dohH2Mitm: Bool {
        get { bool(forKey: "dohH2Mitm", defaultValue: false) }
        set {
            defaults.set(newValue, forKey: "dohH2Mitm")
            notifyChanged()
        }
    }

    var dohPreferIPv6: Bool {
        get { defaults.bool(forKey: "dohPreferIPv6") }
        set {
            defaults.set(newValue, forKey: "dohPreferIPv6")
            notifyChanged()
        }
    }

    var dohServerIP: String {
        get { defaults.string(forKey: "dohServerIP") ?? "" }
        set {
            defaults.set(newValue, forKey: "dohServerIP")
            notifyChanged()
        }
    }

    var dohEchServerURL: String {
        get { defaults.string(forKey: "dohEchServerURL") ?? "" }
        set {
            defaults.set(newValue, forKey: "dohEchServerURL")
            notifyChanged()
        }
    }

    var dohCustomBootstrapIPs: [String] {
        get {
            (defaults.string(forKey: "dohCustomBootstrapIPs") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            defaults.set(newValue.joined(separator: ","), forKey: "dohCustomBootstrapIPs")
            notifyChanged()
        }
    }

    var dohUpstreamProtocol: String {
        get { defaults.string(forKey: "dohUpstreamProtocol") ?? DohUpstreamProtocol.http.rawValue }
        set {
            defaults.set(newValue, forKey: "dohUpstreamProtocol")
            notifyChanged()
        }
    }

    var dohUpstreamHost: String {
        get { defaults.string(forKey: "dohUpstreamHost") ?? "" }
        set {
            defaults.set(newValue, forKey: "dohUpstreamHost")
            notifyChanged()
        }
    }

    var dohUpstreamPort: Int {
        get { defaults.object(forKey: "dohUpstreamPort") as? Int ?? 0 }
        set {
            defaults.set(newValue, forKey: "dohUpstreamPort")
            notifyChanged()
        }
    }

    var dohUpstreamUsername: String {
        get { defaults.string(forKey: "dohUpstreamUsername") ?? "" }
        set {
            defaults.set(newValue, forKey: "dohUpstreamUsername")
            notifyChanged()
        }
    }

    var dohUpstreamCipher: String {
        get { defaults.string(forKey: "dohUpstreamCipher") ?? "" }
        set {
            defaults.set(newValue, forKey: "dohUpstreamCipher")
            notifyChanged()
        }
    }

    var dohUpstreamPassword: String {
        get { Self.readUpstreamPassword() ?? "" }
        set {
            Self.writeUpstreamPassword(newValue)
            notifyChanged()
        }
    }

    func makeDohProxyConfig() -> DohProxyConfig {
        Self.dohProxyConfig(from: defaults)
    }

    nonisolated static func dohProxyConfig(from defaults: UserDefaults) -> DohProxyConfig {
        let raw = defaults.object(forKey: "dohProvider") as? Int
        let provider = DoHProvider(rawValue: raw ?? DoHProvider.dnspod.rawValue) ?? .dnspod
        let customURL = defaults.string(forKey: "dohCustomURL") ?? ""
        let serverURL = provider == .custom ? customURL : provider.url
        let bootstrap: [String]
        if provider == .custom {
            let hostIsIP = URL(string: DohServerCatalog.normalize(customURL))?.host
                .map(DohProxyConfig.looksLikeIPAddress) ?? false
            bootstrap = hostIsIP ? [] : customBootstrapIPs(from: defaults)
        } else {
            bootstrap = provider.bootstrapIPs
        }
        let upstreamHost = defaults.string(forKey: "dohUpstreamHost") ?? ""
        let upstreamPort = defaults.object(forKey: "dohUpstreamPort") as? Int ?? 0
        var upstream: DohUpstreamConfig?
        if !upstreamHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, upstreamPort > 0 {
            let username = defaults.string(forKey: "dohUpstreamUsername") ?? ""
            let password = readUpstreamPassword() ?? ""
            upstream = DohUpstreamConfig(
                protocolKind: DohUpstreamProtocol(rawValue: defaults.string(forKey: "dohUpstreamProtocol") ?? "") ?? .http,
                host: upstreamHost,
                port: upstreamPort,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password,
                cipher: defaults.string(forKey: "dohUpstreamCipher") ?? ""
            )
        }
        let gateway: Bool
        if defaults.object(forKey: "dohGatewayEnabled") == nil {
            gateway = true
        } else {
            gateway = defaults.bool(forKey: "dohGatewayEnabled")
        }
        return DohProxyConfig(
            enabled: defaults.bool(forKey: "dohEnabled"),
            serverURL: serverURL,
            bootstrapIPs: bootstrap,
            echServerURL: defaults.string(forKey: "dohEchServerURL"),
            gatewayEnabled: gateway,
            h2Mitm: defaults.bool(forKey: "dohH2Mitm"),
            preferIPv6: defaults.bool(forKey: "dohPreferIPv6"),
            serverIP: defaults.string(forKey: "dohServerIP"),
            upstream: upstream
        )
    }

    nonisolated private static func customBootstrapIPs(from defaults: UserDefaults) -> [String] {
        (defaults.string(forKey: "dohCustomBootstrapIPs") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private static let upstreamPasswordTag = "com.naine.doer.doh.upstream-password"

    nonisolated private static func readUpstreamPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: upstreamPasswordTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func writeUpstreamPassword(_ password: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: upstreamPasswordTag,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: upstreamPasswordTag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(add as CFDictionary, nil)
    }
}
