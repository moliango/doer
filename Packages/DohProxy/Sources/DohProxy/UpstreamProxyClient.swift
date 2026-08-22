import Foundation

public enum UpstreamHandshake {
    public static func httpConnect(host: String, port: UInt16, username: String?, password: String?) -> Data {
        var header = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
        if let username, let password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            header += "Proxy-Authorization: Basic \(token)\r\n"
        }
        header += "\r\n"
        return Data(header.utf8)
    }

    public static func socks5Greeting(userpass: Bool) -> Data {
        userpass ? Data([0x05, 0x01, 0x02]) : Data([0x05, 0x01, 0x00])
    }

    public static func socks5UserPass(username: String, password: String) -> Data {
        var data = Data([0x01, UInt8(min(username.utf8.count, 255))])
        data.append(contentsOf: username.utf8.prefix(255))
        data.append(UInt8(min(password.utf8.count, 255)))
        data.append(contentsOf: password.utf8.prefix(255))
        return data
    }

    public static func socks5Connect(host: String, port: UInt16) -> Data {
        var data = Data([0x05, 0x01, 0x00, 0x03, UInt8(min(host.utf8.count, 255))])
        data.append(contentsOf: host.utf8.prefix(255))
        data.append(UInt8(port >> 8))
        data.append(UInt8(port & 0xFF))
        return data
    }

    public static func shadowsocksKeyLength(cipher: String) -> Int {
        switch cipher.lowercased() {
        case "aes-128-gcm": return 16
        case "aes-256-gcm", "chacha20-ietf-poly1305": return 32
        case "2022-blake3-aes-256-gcm": return 32
        default: return 0
        }
    }
}

public struct DohGatewayHTTPRequest: Equatable, Sendable {
    public var host: String
    public var port: UInt16
    public var originForm: Data

    public static func parse(_ data: Data) throws -> DohGatewayHTTPRequest? {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else { return nil }
        guard let header = String(data: data.subdata(in: data.startIndex ..< range.lowerBound), encoding: .utf8) else {
            throw DohProxyError.malformedHTTPResponse
        }
        let lines = header.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let method = parts[0].uppercased()
        if method == "CONNECT" { return nil }
        let target = parts[1]
        let hostHeader = lines.dropFirst().compactMap { line -> String? in
            let lower = line.lowercased()
            guard lower.hasPrefix("host:") else { return nil }
            return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }.first
        let host: String
        var port: UInt16 = 443
        if let hostHeader {
            if let parsed = try? parseHostPort(hostHeader) {
                host = parsed.host
                port = parsed.port == 80 ? 443 : parsed.port
            } else {
                host = hostHeader
            }
        } else if let url = URL(string: target), let urlHost = url.host, target.contains("://") {
            host = urlHost
            if let urlPort = url.port { port = UInt16(urlPort) }
        } else {
            return nil
        }
        let path: String
        if let url = URL(string: target), target.contains("://") {
            path = url.path.isEmpty ? "/" : (url.query.map { "\(url.path)?\($0)" } ?? url.path)
        } else {
            path = target
        }
        var rebuilt = "\(method) \(path) HTTP/1.1\r\n"
        for line in lines.dropFirst() {
            rebuilt += line + "\r\n"
        }
        rebuilt += "\r\n"
        var origin = Data(rebuilt.utf8)
        origin.append(data.subdata(in: range.upperBound ..< data.endIndex))
        return DohGatewayHTTPRequest(host: host.lowercased(), port: port, originForm: origin)
    }

    private static func parseHostPort(_ value: String) throws -> (host: String, port: UInt16) {
        if let idx = value.lastIndex(of: ":"), let parsed = UInt16(value[value.index(after: idx)...]) {
            return (String(value[..<idx]), parsed)
        }
        return (value, 443)
    }
}
