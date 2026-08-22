import Foundation

public struct DohEndpoint: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var url: String
    public var bootstrapIPs: [String]

    public init?(url rawURL: String, bootstrapIPs: [String], preferIPv6: Bool) {
        let url = DohServerCatalog.normalize(rawURL)
        guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty else { return nil }
        self.url = url
        self.host = host
        let port = parsed.port ?? 443
        guard (1 ... Int(UInt16.max)).contains(port) else { return nil }
        self.port = UInt16(port)
        var ips = bootstrapIPs
        if ips.isEmpty, DohProxyConfig.looksLikeIPAddress(host) {
            ips = [host]
        }
        let v4 = ips.filter { !$0.contains(":") }
        let v6 = ips.filter { $0.contains(":") }
        self.bootstrapIPs = preferIPv6 ? v6 + v4 : v4 + v6
    }

    public var isReady: Bool { !bootstrapIPs.isEmpty }
}
