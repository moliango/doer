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
            case .tencent: return String(localized: "doh.provider.tencent", defaultValue: "腾讯 DNS (dns.pub)")
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

        /// Built-in catalog order. Custom servers are stored separately.
        static var builtInDisplayOrder: [DoHProvider] {
            [.dnspod, .tencent, .cloudflare, .canadianShield, .alidns, .quad9, .google]
        }
    }

    struct CustomDoHServer: Codable, Equatable {
        var name: String
        var url: String
        var bootstrapIPs: [String]
    }

    // MARK: - Cloudflare 本地优选

    /// URLSession 走哪条路连 linux.do。
    ///
    /// `originECHReady` 只能走本地 CONNECT + MITM + ECH 那条路（谁做 TCP 连接谁才能决定 IP），
    /// 而 Encrypted DNS 只换了解析器、连不上注入 ECH，也没有地方消费优选钉选。
    enum DohConnectionMode: Int, CaseIterable {
        /// 现状：Network.framework Encrypted DNS。明文 SNI，优选不生效。
        case encryptedDNS = 0
        /// 本地 CONNECT + MITM + ECH：能藏 SNI，优选钉选才会被消费。
        case localECH = 1

        var title: String {
            switch self {
            case .encryptedDNS:
                return String(
                    localized: "settings.network.connection_mode.encrypted_dns",
                    defaultValue: "Encrypted DNS"
                )
            case .localECH:
                return String(
                    localized: "settings.network.connection_mode.local_ech",
                    defaultValue: "本地代理 + ECH"
                )
            }
        }

        var summary: String {
            switch self {
            case .encryptedDNS:
                return String(
                    localized: "settings.network.connection_mode.encrypted_dns.summary",
                    defaultValue: "系统 TLS 直连 DoH 解析出的 IP。出口 IP 会变，节点优选不生效"
                )
            case .localECH:
                return String(
                    localized: "settings.network.connection_mode.local_ech.summary",
                    defaultValue: "本地代理终结 TLS 并注入 ECH，藏住 SNI；linux.do 及子域钉同一个出口 IP"
                )
            }
        }
    }

    var dohConnectionMode: DohConnectionMode {
        get { Self.dohConnectionMode(from: defaults) }
        set {
            defaults.set(newValue.rawValue, forKey: "dohConnectionMode")
            notifyChanged()
        }
    }

    /// 默认保持现状（Encrypted DNS），切到本地 ECH 由用户显式选择。
    nonisolated static func dohConnectionMode(from defaults: UserDefaults) -> DohConnectionMode {
        guard defaults.object(forKey: "dohConnectionMode") != nil else { return .encryptedDNS }
        return DohConnectionMode(rawValue: defaults.integer(forKey: "dohConnectionMode")) ?? .encryptedDNS
    }

    /// 优选模式：本地优选 + atlas 池一起竞速（默认），或只用 atlas 池。
    enum PreferredNodeMode: Int, CaseIterable {
        case off = 0
        case localAndAtlas = 1
        case atlasOnly = 2

        var title: String {
            switch self {
            case .off:
                return String(localized: "settings.network.preferred_node.mode.off", defaultValue: "关闭")
            case .localAndAtlas:
                return String(
                    localized: "settings.network.preferred_node.mode.local_atlas",
                    defaultValue: "本地优选 + atlas"
                )
            case .atlasOnly:
                return String(
                    localized: "settings.network.preferred_node.mode.atlas_only",
                    defaultValue: "仅 atlas 池"
                )
            }
        }

        var summary: String {
            switch self {
            case .off:
                return String(
                    localized: "settings.network.preferred_node.mode.off.summary",
                    defaultValue: "不做优选，只按 DoH 解析结果连"
                )
            case .localAndAtlas:
                return String(
                    localized: "settings.network.preferred_node.mode.local_atlas.summary",
                    defaultValue: "自己在大厂域名与随机抽样里找节点，并合并社区节点表"
                )
            case .atlasOnly:
                return String(
                    localized: "settings.network.preferred_node.mode.atlas_only.summary",
                    defaultValue: "只从社区节点表取候选"
                )
            }
        }
    }

    var preferredNodeEnabled: Bool {
        get { Self.preferredNodeEnabled(from: defaults) }
        set {
            defaults.set(newValue, forKey: "preferredNodeEnabled")
            notifyChanged()
        }
    }

    var preferredNodeMode: PreferredNodeMode {
        get { Self.preferredNodeMode(from: defaults) }
        set {
            defaults.set(newValue.rawValue, forKey: "preferredNodeMode")
            notifyChanged()
        }
    }

    var preferredNodeAtlasURL: String {
        get { Self.preferredNodeAtlasURL(from: defaults) }
        set {
            defaults.set(newValue, forKey: "preferredNodeAtlasURL")
            notifyChanged()
        }
    }

    /// 优选默认开启。
    nonisolated static func preferredNodeEnabled(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: "preferredNodeEnabled") != nil else { return true }
        return defaults.bool(forKey: "preferredNodeEnabled")
    }

    nonisolated static func preferredNodeMode(from defaults: UserDefaults) -> PreferredNodeMode {
        guard defaults.object(forKey: "preferredNodeMode") != nil else { return .localAndAtlas }
        return PreferredNodeMode(rawValue: defaults.integer(forKey: "preferredNodeMode")) ?? .localAndAtlas
    }

    nonisolated static func preferredNodeAtlasURL(from defaults: UserDefaults) -> String {
        let trimmed = (defaults.string(forKey: "preferredNodeAtlasURL") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AtlasRoutesClient.defaultURL : trimmed
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

    var dohCustomServers: [CustomDoHServer] {
        get {
            if let data = defaults.data(forKey: "dohCustomServers"),
               let list = try? JSONDecoder().decode([CustomDoHServer].self, from: data)
            {
                return list
            }
            let legacy = dohCustomURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !legacy.isEmpty else { return [] }
            return [
                CustomDoHServer(
                    name: String(localized: "doh.provider.custom"),
                    url: DohServerCatalog.normalize(legacy),
                    bootstrapIPs: Self.lockedBootstrapIPs(for: legacy, extras: dohCustomBootstrapIPs)
                ),
            ]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "dohCustomServers")
            }
            notifyChanged()
        }
    }

    /// Inferred bootstrap IPs cannot be dropped; extras are appended.
    nonisolated static func lockedBootstrapIPs(for url: String, extras: [String] = []) -> [String] {
        var seen = Set<String>()
        return (DohServerCatalog.inferredBootstrapIPs(for: url) + extras)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated static func parseBootstrapIPs(_ text: String) -> [String] {
        text
            .split { $0 == "," || $0 == ";" || $0 == "\n" || $0 == " " }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func bootstrapIPs(forServerURL url: String) -> [String] {
        let normalized = DohServerCatalog.normalize(url)
        if let custom = dohCustomServers.first(where: { $0.url == normalized }) {
            return Self.lockedBootstrapIPs(for: normalized, extras: custom.bootstrapIPs)
        }
        return Self.lockedBootstrapIPs(for: normalized, extras: bootstrapExtras(for: normalized))
    }

    func setBootstrapIPs(_ ips: [String], forServerURL url: String) {
        let normalized = DohServerCatalog.normalize(url)
        let locked = DohServerCatalog.inferredBootstrapIPs(for: normalized)
        let extras = ips.filter { ip in !locked.contains(ip) }
        if let index = dohCustomServers.firstIndex(where: { $0.url == normalized }) {
            updateCustomDoHServer(url: normalized, bootstrapIPs: extras)
            return
        }
        setBootstrapExtras(extras, for: normalized)
        if dohProvider != .custom, DohServerCatalog.normalize(dohProvider.url) == normalized {
            notifyChanged()
        }
    }

    private func bootstrapExtras(for url: String) -> [String] {
        Self.bootstrapExtras(from: defaults, url: url)
    }

    private func setBootstrapExtras(_ extras: [String], for url: String) {
        var map = Self.bootstrapExtrasMap(from: defaults)
        let normalized = DohServerCatalog.normalize(url)
        if extras.isEmpty {
            map.removeValue(forKey: normalized)
        } else {
            map[normalized] = extras
        }
        if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: "dohBootstrapExtrasByURL")
        }
        notifyChanged()
    }

    nonisolated static func bootstrapExtras(from defaults: UserDefaults, url: String) -> [String] {
        bootstrapExtrasMap(from: defaults)[DohServerCatalog.normalize(url)] ?? []
    }

    nonisolated static func bootstrapExtrasMap(from defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: "dohBootstrapExtrasByURL"),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return map
    }

    func addCustomDoHServer(name: String, url: String, bootstrapIPs: [String] = []) -> CustomDoHServer? {
        let normalized = DohServerCatalog.normalize(url)
        guard let parsed = URL(string: normalized), parsed.scheme?.lowercased() == "https" else {
            return nil
        }
        var list = dohCustomServers
        if list.contains(where: { $0.url == normalized }) { return nil }
        let server = CustomDoHServer(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? parsed.host ?? String(localized: "doh.provider.custom")
                : name.trimmingCharacters(in: .whitespacesAndNewlines),
            url: normalized,
            bootstrapIPs: Self.lockedBootstrapIPs(for: normalized, extras: bootstrapIPs)
        )
        list.append(server)
        dohCustomServers = list
        return server
    }

    func updateCustomDoHServer(url: String, name: String? = nil, bootstrapIPs: [String]? = nil) {
        let normalized = DohServerCatalog.normalize(url)
        var list = dohCustomServers
        guard let index = list.firstIndex(where: { $0.url == normalized }) else { return }
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { list[index].name = trimmed }
        }
        if let bootstrapIPs {
            list[index].bootstrapIPs = Self.lockedBootstrapIPs(for: normalized, extras: bootstrapIPs)
        }
        dohCustomServers = list
        if dohProvider == .custom, dohCustomURL == normalized {
            dohCustomBootstrapIPs = list[index].bootstrapIPs
        }
    }

    func removeCustomDoHServer(url: String) {
        let normalized = DohServerCatalog.normalize(url)
        var list = dohCustomServers.filter { $0.url != normalized }
        dohCustomServers = list
        if dohProvider == .custom, dohCustomURL == normalized {
            if let next = list.first {
                dohCustomURL = next.url
                dohCustomBootstrapIPs = next.bootstrapIPs
            } else {
                dohProvider = .dnspod
                dohCustomURL = ""
                dohCustomBootstrapIPs = []
            }
        }
    }

    func selectDoHServer(provider: DoHProvider) {
        dohProvider = provider
    }

    func selectCustomDoHServer(_ server: CustomDoHServer) {
        dohProvider = .custom
        dohCustomURL = server.url
        dohCustomBootstrapIPs = Self.lockedBootstrapIPs(for: server.url, extras: server.bootstrapIPs)
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
            if hostIsIP {
                bootstrap = []
            } else {
                let storedServers = (defaults.data(forKey: "dohCustomServers"))
                    .flatMap { try? JSONDecoder().decode([CustomDoHServer].self, from: $0) } ?? []
                let match = storedServers.first { $0.url == DohServerCatalog.normalize(customURL) }
                bootstrap = lockedBootstrapIPs(
                    for: customURL,
                    extras: match?.bootstrapIPs ?? customBootstrapIPs(from: defaults)
                )
            }
        } else {
            bootstrap = lockedBootstrapIPs(
                for: provider.url,
                extras: bootstrapExtras(from: defaults, url: provider.url)
            )
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
        let connectionMode = dohConnectionMode(from: defaults)
        let gateway: Bool
        if connectionMode == .localECH {
            // Gateway hop 走 HTTP/1.1，Cloudflare 会对 linux.do 回 403 cf-mitigated: challenge。
            // iOS 17+ 的 WKWebView 也能挂 CONNECT 代理，所以那条路不需要 gateway。
            gateway = !LocalConnectProxy.supportsWebViewCONNECTProxy
        } else if defaults.object(forKey: "dohGatewayEnabled") == nil {
            gateway = true
        } else {
            gateway = defaults.bool(forKey: "dohGatewayEnabled")
        }
        // 本地 ECH 必须开 h2，否则 CF 一样会拿 HTTP/1.1 回 challenge。
        let h2Mitm = connectionMode == .localECH || defaults.bool(forKey: "dohH2Mitm")
        return DohProxyConfig(
            enabled: defaults.bool(forKey: "dohEnabled"),
            serverURL: serverURL,
            bootstrapIPs: bootstrap,
            echServerURL: defaults.string(forKey: "dohEchServerURL"),
            gatewayEnabled: gateway,
            h2Mitm: h2Mitm,
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
