import Foundation

/// FluxDo `_defaultServers` plus custom. Bootstrap IPs come from provider docs.
public struct DohServerDescriptor: Equatable, Sendable {
    public var name: String
    public var url: String
    public var bootstrapIPs: [String]
    public var isCustom: Bool

    public init(name: String, url: String, bootstrapIPs: [String] = [], isCustom: Bool = false) {
        self.name = name
        self.url = url
        self.bootstrapIPs = bootstrapIPs
        self.isCustom = isCustom
    }
}

public enum DohServerCatalog: Sendable {
    public static let dnsPod = DohServerDescriptor(
        name: "DNSPod",
        url: "https://doh.pub/dns-query",
        bootstrapIPs: ["1.12.12.12", "120.53.53.53"]
    )
    public static let tencent = DohServerDescriptor(
        name: "腾讯 DNS",
        url: "https://dns.pub/dns-query",
        bootstrapIPs: ["119.29.29.29", "119.28.28.28"]
    )
    public static let cloudflare = DohServerDescriptor(
        name: "Cloudflare",
        url: "https://cloudflare-dns.com/dns-query",
        bootstrapIPs: [
            "1.1.1.1",
            "1.0.0.1",
            "2606:4700:4700::1111",
            "2606:4700:4700::1001",
        ]
    )
    public static let canadianShield = DohServerDescriptor(
        name: "Canadian Shield",
        url: "https://private.canadianshield.cira.ca/dns-query"
    )
    public static let aliDNS = DohServerDescriptor(
        name: "阿里 DNS",
        url: "https://dns.alidns.com/dns-query",
        bootstrapIPs: [
            "223.5.5.5",
            "223.6.6.6",
            "2400:3200::1",
            "2400:3200:baba::1",
        ]
    )
    public static let quad9 = DohServerDescriptor(
        name: "Quad9",
        url: "https://dns.quad9.net/dns-query",
        bootstrapIPs: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
    )
    public static let google = DohServerDescriptor(
        name: "Google",
        url: "https://dns.google/dns-query",
        bootstrapIPs: [
            "8.8.8.8",
            "8.8.4.4",
            "2001:4860:4860::8888",
            "2001:4860:4860::8844",
        ]
    )

    /// FluxDo order. First entry is the new-install default.
    public static let builtIn: [DohServerDescriptor] = [
        dnsPod,
        tencent,
        cloudflare,
        canadianShield,
        aliDNS,
        quad9,
        google,
    ]

    public static let defaultServer = dnsPod

    public static func builtIn(url: String) -> DohServerDescriptor? {
        let normalized = normalize(url)
        return builtIn.first { normalize($0.url) == normalized }
    }

    public static func normalize(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return defaultServer.url }
        if trimmed.contains("://") { return trimmed }
        return "https://\(trimmed)"
    }

    /// Bootstrap IPs when the user did not type any. Cloudflare Gateway
    /// hostnames share Cloudflare anycast, so 1.1.1.1 can reach them.
    public static func inferredBootstrapIPs(for urlString: String) -> [String] {
        guard let host = URL(string: normalize(urlString))?.host?.lowercased() else { return [] }
        if host.hasSuffix("cloudflare-gateway.com") {
            return ["162.159.36.1", "162.159.46.1"]
        }
        if host == "cloudflare-dns.com" || host.hasSuffix(".cloudflare-dns.com") {
            return cloudflare.bootstrapIPs
        }
        if let known = builtIn(url: urlString), !known.bootstrapIPs.isEmpty {
            return known.bootstrapIPs
        }
        return []
    }
}
