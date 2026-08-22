import Foundation

public enum DohUpstreamProtocol: String, Equatable, Sendable {
    case http
    case socks5
    case shadowsocks
}

public struct DohUpstreamConfig: Equatable, Sendable {
    public var protocolKind: DohUpstreamProtocol
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    public var cipher: String

    public init(
        protocolKind: DohUpstreamProtocol,
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        cipher: String = ""
    ) {
        self.protocolKind = protocolKind
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.cipher = cipher
    }

    public var isValid: Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedHost.isEmpty && (1 ... 65_535).contains(port)
    }

    public var signature: String {
        [
            protocolKind.rawValue,
            host,
            "\(port)",
            username ?? "",
            password?.isEmpty == false ? "pw" : "",
            cipher,
        ].joined(separator: "|")
    }
}

/// Immutable snapshot. Rebuild the proxy when `signature` changes.
public struct DohProxyConfig: Equatable, Sendable {
    public var enabled: Bool
    public var serverURL: String
    public var bootstrapIPs: [String]
    public var echServerURL: String?
    public var gatewayEnabled: Bool
    public var h2Mitm: Bool
    public var preferIPv6: Bool
    public var serverIP: String?
    public var upstream: DohUpstreamConfig?

    public init(
        enabled: Bool,
        serverURL: String,
        bootstrapIPs: [String],
        echServerURL: String? = nil,
        gatewayEnabled: Bool = true,
        h2Mitm: Bool = false,
        preferIPv6: Bool = false,
        serverIP: String? = nil,
        upstream: DohUpstreamConfig? = nil
    ) {
        self.enabled = enabled
        self.serverURL = DohServerCatalog.normalize(serverURL)
        self.bootstrapIPs = bootstrapIPs
        self.echServerURL = echServerURL.flatMap { url in
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : DohServerCatalog.normalize(trimmed)
        }
        self.gatewayEnabled = gatewayEnabled
        self.h2Mitm = h2Mitm
        self.preferIPv6 = preferIPv6
        self.serverIP = serverIP.flatMap { ip in
            let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.upstream = upstream
    }

    public var effectiveEchServerURL: String {
        echServerURL ?? serverURL
    }

    public var isGatewayMode: Bool {
        enabled && gatewayEnabled
    }

    /// Custom DoH URL must already be an IP host or have bootstrap IPs.
    public var bootstrapReady: Bool {
        guard enabled else { return true }
        if !bootstrapIPs.isEmpty { return true }
        guard let host = URL(string: serverURL)?.host else { return false }
        return Self.looksLikeIPAddress(host)
    }

    public var signature: String {
        [
            enabled ? "on" : "off",
            serverURL,
            bootstrapIPs.joined(separator: ","),
            effectiveEchServerURL,
            gatewayEnabled ? "gw" : "mitm",
            h2Mitm ? "h2" : "h1",
            preferIPv6 ? "v6" : "v4",
            serverIP ?? "",
            upstream?.signature ?? "",
        ].joined(separator: "|")
    }

    public static func looksLikeIPAddress(_ value: String) -> Bool {
        if value.contains(":") { return true }
        let parts = value.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0 ... 255).contains(number)
        }
    }
}
