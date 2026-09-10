import Darwin
import Foundation
import Network

/// DoH RFC 8484 POST over bootstrap IPs. TLS SNI is the DoH hostname.
/// ALPN is locked to HTTP/1.1 so Cloudflare cannot stall on h2.
public enum DohBootstrapTransport {
    public static var log: ((String) -> Void)?

    static func query(
        endpoint: DohEndpoint,
        dnsQuery: Data,
        queue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard endpoint.isReady else {
            completion(.failure(DohProxyError.bootstrapUnavailable(endpoint.url)))
            return
        }
        // Same merge as v1.8.3: system DNS IPs first, then catalog.
        // Encrypted DNS must be off so getaddrinfo is real system DNS.
        var systemIPs: [String] = []
        if !DohProxyConfig.looksLikeIPAddress(endpoint.host) {
            systemIPs = systemAddresses(for: endpoint.host)
            if !systemIPs.isEmpty {
                log?("DoH server \(endpoint.host) system DNS -> \(systemIPs.joined(separator: ", "))")
            }
        }
        let addresses = resolvedBootstrapAddresses(
            host: endpoint.host,
            catalogIPs: endpoint.bootstrapIPs,
            systemIPs: systemIPs
        )
        let path = postPath(url: endpoint.url)
        query(
            addresses: addresses,
            index: 0,
            serverHost: endpoint.host,
            serverPort: endpoint.port,
            request: postRequest(host: endpoint.host, path: path, dnsQuery: dnsQuery),
            queue: queue,
            lastError: nil,
            completion: completion
        )
    }

    private static func query(
        addresses: [String],
        index: Int,
        serverHost: String,
        serverPort: UInt16,
        request: Data,
        queue: DispatchQueue,
        lastError: Error?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard index < addresses.count, let port = NWEndpoint.Port(rawValue: serverPort) else {
            completion(.failure(lastError ?? DohProxyError.bootstrapUnavailable(serverHost)))
            return
        }

        let ip = addresses[index]
        let parameters = connectionParameters(serverHost: serverHost)
        let endpoint = NWEndpoint.hostPort(host: endpointHost(ip), port: port)
        let connection = NWConnection(to: endpoint, using: parameters)
        log?("bootstrap connect \(ip) SNI=\(serverHost)")
        let timeout = DispatchWorkItem {
            log?("bootstrap timeout \(ip)")
            connection.cancel()
            query(
                addresses: addresses,
                index: index + 1,
                serverHost: serverHost,
                serverPort: serverPort,
                request: request,
                queue: queue,
                lastError: DohProxyError.queryFailed("timeout \(ip)"),
                completion: completion
            )
        }

        var buffer = Data()
        var finished = false

        func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            timeout.cancel()
            connection.cancel()
            completion(result)
        }

        func tryNext(_ error: Error) {
            guard !finished else { return }
            finished = true
            timeout.cancel()
            connection.cancel()
            log?("bootstrap failed \(ip): \(error.localizedDescription)")
            query(
                addresses: addresses,
                index: index + 1,
                serverHost: serverHost,
                serverPort: serverPort,
                request: request,
                queue: queue,
                lastError: error,
                completion: completion
            )
        }

        func parseBuffered(requireComplete: Bool) -> Bool {
            do {
                guard let body = try DohHTTPWire.extractBody(from: buffer, requireComplete: requireComplete) else {
                    return false
                }
                log?("bootstrap ok \(ip) bytes=\(body.count)")
                finish(.success(body))
                return true
            } catch {
                tryNext(error)
                return true
            }
        }

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if parseBuffered(requireComplete: false) { return }
                }
                if let error {
                    tryNext(error)
                    return
                }
                if isComplete {
                    _ = parseBuffered(requireComplete: true)
                    if !finished {
                        tryNext(DohProxyError.queryFailed("empty \(ip)"))
                    }
                    return
                }
                receiveMore()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .setup:
                log?("bootstrap setup \(ip)")
            case .preparing:
                log?("bootstrap preparing \(ip)")
            case .waiting(let error):
                log?("bootstrap waiting \(ip): \(error)")
            case .ready:
                log?("bootstrap TLS ready \(ip)")
                connection.send(
                    content: request,
                    contentContext: NWConnection.ContentContext(identifier: "doer.doh.bootstrap", isFinal: false),
                    isComplete: false,
                    completion: .contentProcessed { error in
                        if let error {
                            tryNext(error)
                            return
                        }
                        receiveMore()
                    }
                )
            case .failed(let error):
                tryNext(error)
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + connectTimeout, execute: timeout)
        connection.start(queue: queue)
    }

    /// Isolated from `PrivacyContext.default`. If Encrypted DNS is required
    /// app-wide, bootstrap DoH to a literal IP still must not wait on itself.
    static let connectTimeout: TimeInterval = 8

    static func connectionParameters(serverHost: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        serverHost.withCString { pointer in
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, pointer)
        }
        "http/1.1".withCString { pointer in
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, pointer)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if #available(iOS 16.0, *) {
            parameters.preferNoProxies = true
        }
        let privacy = NWParameters.PrivacyContext(description: "doer.doh.bootstrap")
        privacy.requireEncryptedNameResolution(false, fallbackResolver: nil)
        parameters.setPrivacyContext(privacy)
        return parameters
    }

    private static func postPath(url: String) -> String {
        let path = URL(string: url)?.path ?? ""
        return path.isEmpty ? "/dns-query" : path
    }

    private static func postRequest(host: String, path: String, dnsQuery: Data) -> Data {
        let header = [
            "POST \(path) HTTP/1.1",
            "Host: \(host)",
            "Accept: application/dns-message",
            "Content-Type: application/dns-message",
            "Content-Length: \(dnsQuery.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var data = Data(header.utf8)
        data.append(dnsQuery)
        return data
    }

    public static func connectAddresses(for endpoint: DohEndpoint) -> [String] {
        resolvedBootstrapAddresses(
            host: endpoint.host,
            catalogIPs: endpoint.bootstrapIPs,
            systemIPs: []
        )
    }

    /// v1.8.3 order: live system IPs first, catalog anycast as fallback, IPv4 first.
    public static func resolvedBootstrapAddresses(
        host: String,
        catalogIPs: [String],
        systemIPs: [String]
    ) -> [String] {
        let merged: [String]
        if DohProxyConfig.looksLikeIPAddress(host) || systemIPs.isEmpty {
            merged = catalogIPs
        } else {
            var seen = Set<String>()
            merged = (systemIPs + catalogIPs).filter { seen.insert($0).inserted }
        }
        let v4 = merged.filter { !$0.contains(":") }
        let v6 = merged.filter { $0.contains(":") }
        if !v4.isEmpty { return v4 + v6 }
        return v6
    }

    public static func systemAddresses(for host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: hostBuffer)
                if !ip.isEmpty, !addresses.contains(ip) {
                    addresses.append(ip)
                }
            }
            cursor = current.pointee.ai_next
        }
        return addresses
    }

    private static func endpointHost(_ address: String) -> NWEndpoint.Host {
        if let ipv4 = IPv4Address(address) {
            return .ipv4(ipv4)
        }
        if let ipv6 = IPv6Address(address) {
            return .ipv6(ipv6)
        }
        return .name(address, nil)
    }
}
