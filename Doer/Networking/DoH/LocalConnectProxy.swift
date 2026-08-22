import Foundation
import Network

nonisolated final class LocalConnectProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "doer.doh.connect-proxy")
    private let stateLock = NSLock()
    private let resolver: DohResolver
    private let requestedPort: UInt16
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var mitmBridges: [ObjectIdentifier: MitmTLSBridge] = [:]
    private var hostAttemptOffsets: [String: Int] = [:]
    var onTLSHandshakeReset: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onFailed: ((Error) -> Void)?

    init(resolver: DohResolver, port: UInt16 = 0) {
        self.resolver = resolver
        self.requestedPort = port
    }

    var proxyPort: UInt16? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return boundPort
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return listener != nil && boundPort != nil
    }

    /// Starts the loopback listener without blocking the caller.
    /// Waiting here from the main thread deadlocks: NWListener callbacks can
    /// hop to MainActor while launch is still inside `didFinishLaunching`.
    func start() throws {
        guard listener == nil else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw LocalConnectProxyError.invalidPort
        }

        let parameters = Self.streamTCPParameters()
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: endpointPort)
        }
        let listener = try NWListener(using: parameters, on: endpointPort)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleClient(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener?.port?.rawValue else {
                    self.onFailed?(LocalConnectProxyError.invalidPort)
                    return
                }
                self.stateLock.lock()
                self.boundPort = port
                self.stateLock.unlock()
                DohDebugLog.record("Local CONNECT proxy ready on 127.0.0.1:\(port)")
                self.onListening?(port)
            case .failed(let error):
                DohDebugLog.record("Local CONNECT proxy failed: \(error)")
                self.stateLock.lock()
                self.boundPort = nil
                self.stateLock.unlock()
                self.onFailed?(LocalConnectProxyError.listenerFailed(error))
            case .cancelled:
                self.stateLock.lock()
                self.boundPort = nil
                self.stateLock.unlock()
            default:
                break
            }
        }
        stateLock.lock()
        self.listener = listener
        stateLock.unlock()
        listener.start(queue: queue)
    }

    func stop() {
        let active = connections.values
        connections.removeAll()
        active.forEach { $0.cancel() }
        stateLock.lock()
        let currentListener = listener
        listener = nil
        boundPort = nil
        stateLock.unlock()
        currentListener?.cancel()
    }

    private func handleClient(_ client: NWConnection) {
        let id = ObjectIdentifier(client)
        connections[id] = client
        var didStartReading = false
        client.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                guard !didStartReading else { return }
                didStartReading = true
                self.readFirstBytes(from: client, buffer: Data())
            case .failed(let error):
                DohDebugLog.record("Client connection failed: \(error)")
                self.close(client)
            case .cancelled:
                self.connections.removeValue(forKey: ObjectIdentifier(client))
            default:
                break
            }
        }
        client.start(queue: queue)
    }

    private func readFirstBytes(from client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                DohDebugLog.record("Proxy greeting receive failed: \(error)")
                self.close(client)
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard let first = nextBuffer.first else {
                if isComplete { self.close(client) }
                else { self.readFirstBytes(from: client, buffer: nextBuffer) }
                return
            }
            if first == Socks5Handshake.version {
                self.readSocksGreeting(from: client, buffer: nextBuffer, isComplete: isComplete)
            } else {
                self.readHTTPConnectHeader(from: client, buffer: nextBuffer, isComplete: isComplete)
            }
        }
    }

    private func readSocksGreeting(from client: NWConnection, buffer: Data, isComplete: Bool) {
        do {
            guard let rest = try Socks5Handshake.consumeGreeting(buffer) else {
                if isComplete { close(client) }
                else { readMore(from: client, buffer: buffer, socksGreeting: true) }
                return
            }
            sendStreaming(client, content: Socks5Handshake.authOK) { [weak self, weak client] error in
                guard let self, let client else { return }
                if error != nil {
                    self.close(client)
                    return
                }
                self.readSocksConnect(from: client, buffer: rest)
            }
        } catch {
            DohDebugLog.record("SOCKS5 greeting failed: \(error)")
            close(client)
        }
    }

    private func readSocksConnect(from client: NWConnection, buffer: Data) {
        do {
            if let parsed = try Socks5Handshake.consumeConnect(buffer) {
                guard parsed.port == 443 else {
                    reject(client, reason: "unsupported target \(parsed.host):\(parsed.port)", socks: true)
                    return
                }
                DohDebugLog.record("SOCKS5 \(parsed.host):\(parsed.port)")
                openTunnel(
                    host: parsed.host,
                    port: parsed.port,
                    client: client,
                    bufferedClientData: parsed.remainder,
                    readyReply: Socks5Handshake.connectOK
                )
                return
            }
            readMore(from: client, buffer: buffer, socksGreeting: false)
        } catch {
            DohDebugLog.record("SOCKS5 connect failed: \(error)")
            reject(client, reason: "invalid SOCKS5 request", socks: true)
        }
    }

    private func readMore(from client: NWConnection, buffer: Data, socksGreeting: Bool) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.close(client)
                return
            }
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= 16_384 else {
                self.close(client)
                return
            }
            if socksGreeting {
                self.readSocksGreeting(from: client, buffer: next, isComplete: isComplete)
            } else if isComplete, next.isEmpty {
                self.close(client)
            } else {
                self.readSocksConnect(from: client, buffer: next)
            }
        }
    }

    private func readHTTPConnectHeader(from client: NWConnection, buffer: Data, isComplete: Bool) {
        var nextBuffer = buffer
        guard nextBuffer.count <= 16_384 else {
            reject(client, reason: "CONNECT header too large")
            return
        }

        let headerSeparator = Data([13, 10, 13, 10])
        if let headerRange = nextBuffer.range(of: headerSeparator) {
            let headerData = nextBuffer.subdata(in: nextBuffer.startIndex ..< headerRange.upperBound)
            let remainder = nextBuffer.subdata(in: headerRange.upperBound ..< nextBuffer.endIndex)
            do {
                let request = try DohConnectRequest.parse(headerData)
                guard request.port == 443 else {
                    reject(client, reason: "unsupported target \(request.host):\(request.port)")
                    return
                }
                DohDebugLog.record("CONNECT \(request.host):\(request.port)")
                openTunnel(
                    host: request.host,
                    port: request.port,
                    client: client,
                    bufferedClientData: remainder,
                    readyReply: Self.connectSuccessResponse
                )
            } catch {
                DohDebugLog.record("CONNECT parse failed: \(error), first bytes: \(Self.hexPrefix(nextBuffer))")
                reject(client, reason: "invalid CONNECT request")
            }
            return
        }

        if isComplete {
            close(client)
            return
        }
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                self.close(client)
                return
            }
            var next = nextBuffer
            if let data { next.append(data) }
            self.readHTTPConnectHeader(from: client, buffer: next, isComplete: complete)
        }
    }

    private func openTunnel(
        host: String,
        port: UInt16,
        client: NWConnection,
        bufferedClientData: Data,
        readyReply: Data
    ) {
        guard let upstreamPort = NWEndpoint.Port(rawValue: port) else {
            reject(client, reason: "invalid port", socks: readyReply == Socks5Handshake.connectOK)
            return
        }

        let useMITM = Self.shouldMITM(host)
        resolver.resolve(host: host) { [weak self, weak client] result in
            guard let self, let client else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    DohDebugLog.record("Resolve failed for \(host): \(error.localizedDescription)")
                    self.reject(client, reason: "resolve failed", socks: readyReply == Socks5Handshake.connectOK)
                case .success(let answer):
                    let addresses = self.rotatedAddresses(
                        for: host,
                        addresses: Self.preferredUpstreamAddresses(answer.addresses)
                    )
                    DohDebugLog.record("Resolved \(host) -> \(addresses.joined(separator: ", "))")
                    guard !addresses.isEmpty else {
                        self.reject(client, reason: "empty resolved address", socks: readyReply == Socks5Handshake.connectOK)
                        return
                    }
                    self.connectUpstream(
                        addresses: addresses,
                        port: upstreamPort,
                        addressIndex: 0,
                        client: client,
                        bufferedClientData: bufferedClientData,
                        hostname: host,
                        readyReply: readyReply,
                        useMITM: useMITM
                    )
                }
            }
        }
    }

    private func connectUpstream(
        addresses: [String],
        port: NWEndpoint.Port,
        addressIndex: Int,
        client: NWConnection,
        bufferedClientData: Data,
        hostname: String,
        readyReply: Data,
        replayHello: Data? = nil,
        useMITM: Bool = false
    ) {
        guard addressIndex < addresses.count else {
            reject(client, reason: "all upstream addresses failed")
            return
        }

        let target = addresses[addressIndex]
        let host = Self.endpointHost(from: target)
        let parameters = useMITM
            ? Self.tlsTCPParameters(serverName: hostname)
            : Self.streamTCPParameters()
        let upstream = NWConnection(host: host, port: port, using: parameters)
        let upstreamId = ObjectIdentifier(upstream)
        var didBindTunnel = false
        connections[upstreamId] = upstream
        upstream.stateUpdateHandler = { [weak self, weak upstream, weak client] state in
            guard let self, let upstream else { return }
            switch state {
            case .ready:
                guard !didBindTunnel else { return }
                didBindTunnel = true
                DohDebugLog.record("Upstream connected \(target):\(port.rawValue)")
                if let replayHello, !replayHello.isEmpty {
                    DohDebugLog.record("Replaying ClientHello to \(target)")
                    self.startByteTunnel(
                        client: client,
                        upstream: upstream,
                        bufferedClientData: replayHello,
                        addresses: addresses,
                        addressIndex: addressIndex,
                        hostname: hostname,
                        readyReply: readyReply
                    )
                } else {
                    self.sendConnectSuccess(
                        to: client,
                        upstream: upstream,
                        bufferedClientData: bufferedClientData,
                        addresses: addresses,
                        addressIndex: addressIndex,
                        hostname: hostname,
                        readyReply: readyReply,
                        useMITM: useMITM
                    )
                }
            case .failed, .cancelled:
                self.connections.removeValue(forKey: ObjectIdentifier(upstream))
                if didBindTunnel { return }
                if case .failed = state, let client {
                    DohDebugLog.record("Upstream failed \(target):\(port.rawValue), trying next")
                    self.connectUpstream(
                        addresses: addresses,
                        port: port,
                        addressIndex: addressIndex + 1,
                        client: client,
                        bufferedClientData: bufferedClientData,
                        hostname: hostname,
                        readyReply: readyReply,
                        replayHello: replayHello,
                        useMITM: useMITM
                    )
                }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func sendConnectSuccess(
        to client: NWConnection?,
        upstream: NWConnection,
        bufferedClientData: Data,
        addresses: [String],
        addressIndex: Int,
        hostname: String,
        readyReply: Data,
        useMITM: Bool
    ) {
        guard let client else {
            close(upstream)
            return
        }

        sendStreaming(client, content: readyReply) { [weak self, weak client, weak upstream] error in
            guard let self, let client, let upstream else { return }
            if error != nil {
                DohDebugLog.record("CONNECT success response send failed: \(String(describing: error))")
                self.close(client)
                self.close(upstream)
                return
            }
            if useMITM {
                self.startMITM(client: client, upstream: upstream, hostname: hostname, leftover: bufferedClientData)
                return
            }
            DohDebugLog.record("CONNECT tunnel established")
            self.startByteTunnel(
                client: client,
                upstream: upstream,
                bufferedClientData: bufferedClientData,
                addresses: addresses,
                addressIndex: addressIndex,
                hostname: hostname,
                readyReply: readyReply
            )
        }
    }

    private func startMITM(
        client: NWConnection,
        upstream: NWConnection,
        hostname: String,
        leftover: Data
    ) {
        guard let identity = MitmCertificateAuthority.shared.identity(for: hostname) else {
            DohDebugLog.record("MITM identity missing for \(hostname)")
            reject(client, reason: "mitm identity", socks: false)
            close(upstream)
            return
        }
        let bridge = MitmTLSBridge(client: client, upstream: upstream)
        mitmBridges[ObjectIdentifier(client)] = bridge
        if !leftover.isEmpty {
            bridge.preload(leftover)
        }
        DohDebugLog.record("MITM CONNECT \(hostname)")
        bridge.start(identity: identity) { [weak self, weak client, weak upstream] ok in
            guard let self, !ok else { return }
            self.queue.async {
                if let client {
                    self.mitmBridges.removeValue(forKey: ObjectIdentifier(client))
                    self.close(client)
                }
                self.close(upstream)
            }
        }
    }

    private func startByteTunnel(
        client: NWConnection?,
        upstream: NWConnection,
        bufferedClientData: Data,
        addresses: [String],
        addressIndex: Int,
        hostname: String,
        readyReply: Data
    ) {
        guard let client else {
            close(upstream)
            return
        }
        let diagnostics = TunnelDiagnostics()
        let beginPipes = { [weak self, weak client, weak upstream] (hello: Data) in
            guard let self, let client, let upstream else { return }
            self.pipe(
                from: client,
                to: upstream,
                sourceRole: "client",
                diagnostics: diagnostics,
                relay: (hello, addresses, addressIndex, hostname, readyReply)
            )
            self.pipe(
                from: upstream,
                to: client,
                sourceRole: "upstream",
                diagnostics: nil,
                relay: (hello, addresses, addressIndex, hostname, readyReply)
            )
        }

        if !bufferedClientData.isEmpty {
            diagnostics.logClientHelloIfNeeded(bufferedClientData)
            sendStreaming(upstream, content: bufferedClientData) { [weak self, weak client, weak upstream] sendError in
                guard let self, let client, let upstream else { return }
                if sendError != nil {
                    DohDebugLog.record("Buffered client data send failed: \(String(describing: sendError))")
                    self.retryOrClose(
                        client: client,
                        upstream: upstream,
                        hello: bufferedClientData,
                        addresses: addresses,
                        addressIndex: addressIndex,
                        hostname: hostname,
                        readyReply: readyReply
                    )
                    return
                }
                beginPipes(bufferedClientData)
            }
            return
        }

        receiveFirstPayload(from: client, sourceRole: "client", diagnostics: diagnostics) { [weak self, weak client, weak upstream] firstBytes in
            guard let self, let client, let upstream else { return }
            guard let firstBytes else {
                self.close(client)
                self.close(upstream)
                return
            }
            self.sendStreaming(upstream, content: firstBytes) { [weak self, weak client, weak upstream] sendError in
                guard let self, let client, let upstream else { return }
                if sendError != nil {
                    DohDebugLog.record("First client payload send failed: \(String(describing: sendError))")
                    self.retryOrClose(
                        client: client,
                        upstream: upstream,
                        hello: firstBytes,
                        addresses: addresses,
                        addressIndex: addressIndex,
                        hostname: hostname,
                        readyReply: readyReply
                    )
                    return
                }
                beginPipes(firstBytes)
            }
        }
    }

    private func receiveFirstPayload(
        from source: NWConnection,
        sourceRole: String,
        diagnostics: TunnelDiagnostics?,
        allowSpuriousComplete: Bool = true,
        completion: @escaping (Data?) -> Void
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak source] data, _, isComplete, error in
            guard let self, let source else {
                completion(nil)
                return
            }
            if let data, !data.isEmpty {
                diagnostics?.logClientHelloIfNeeded(data)
                completion(data)
                return
            }
            if let error {
                DohDebugLog.record("Tunnel receive failed (\(sourceRole)): \(error)")
                completion(nil)
                return
            }
            if isComplete {
                if allowSpuriousComplete {
                    DohDebugLog.record("Ignoring empty complete on \(sourceRole) before first payload")
                    self.receiveFirstPayload(
                        from: source,
                        sourceRole: sourceRole,
                        diagnostics: diagnostics,
                        allowSpuriousComplete: false,
                        completion: completion
                    )
                    return
                }
                DohDebugLog.record("Tunnel side closed (\(sourceRole)) before first payload")
                completion(nil)
                return
            }
            self.receiveFirstPayload(
                from: source,
                sourceRole: sourceRole,
                diagnostics: diagnostics,
                allowSpuriousComplete: allowSpuriousComplete,
                completion: completion
            )
        }
    }

    private func pipe(
        from source: NWConnection,
        to target: NWConnection,
        sourceRole: String,
        diagnostics: TunnelDiagnostics? = nil,
        relay: (hello: Data, addresses: [String], addressIndex: Int, hostname: String, readyReply: Data),
        sawUpstreamData: Bool = false
    ) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak source, weak target] data, _, isComplete, error in
            guard let self, let source, let target else { return }
            if let data, !data.isEmpty {
                diagnostics?.logClientHelloIfNeeded(data)
                let isUpstream = sourceRole == "upstream"
                self.sendStreaming(target, content: data) { [weak self, weak source, weak target] sendError in
                    guard let self, let source, let target else { return }
                    if sendError != nil {
                        DohDebugLog.record("Tunnel send failed (\(sourceRole)): \(String(describing: sendError))")
                        if isUpstream {
                            self.close(source)
                            self.close(target)
                        } else {
                            self.retryOrClose(
                                client: source,
                                upstream: target,
                                hello: relay.hello,
                                addresses: relay.addresses,
                                addressIndex: relay.addressIndex,
                                hostname: relay.hostname,
                                readyReply: relay.readyReply,
                                sawUpstreamData: sawUpstreamData
                            )
                        }
                        return
                    }
                    // Never FIN the TCP stream: URLSession TLS through CONNECT
                    // can mark a message complete without ending the socket.
                    self.pipe(
                        from: source,
                        to: target,
                        sourceRole: sourceRole,
                        diagnostics: diagnostics,
                        relay: relay,
                        sawUpstreamData: sawUpstreamData || isUpstream
                    )
                }
                return
            }

            if let error {
                DohDebugLog.record("Tunnel receive failed (\(sourceRole)): \(error)")
                if sourceRole == "upstream", !sawUpstreamData {
                    self.retryOrClose(
                        client: target,
                        upstream: source,
                        hello: relay.hello,
                        addresses: relay.addresses,
                        addressIndex: relay.addressIndex,
                        hostname: relay.hostname,
                        readyReply: relay.readyReply,
                        sawUpstreamData: false
                    )
                } else {
                    self.close(source)
                    self.close(target)
                }
                return
            }

            if isComplete {
                DohDebugLog.record("Tunnel side closed (\(sourceRole)); keeping peer open")
                return
            }
            self.pipe(
                from: source,
                to: target,
                sourceRole: sourceRole,
                diagnostics: diagnostics,
                relay: relay,
                sawUpstreamData: sawUpstreamData
            )
        }
    }

    private func retryOrClose(
        client: NWConnection,
        upstream: NWConnection,
        hello: Data,
        addresses: [String],
        addressIndex: Int,
        hostname: String,
        readyReply: Data,
        sawUpstreamData: Bool = false
    ) {
        close(upstream)
        guard !sawUpstreamData, addressIndex + 1 < addresses.count else {
            DohDebugLog.record("All DoH IPs RST TLS for \(hostname)")
            onTLSHandshakeReset?(hostname)
            reject(client, reason: "tls reset", socks: readyReply == Socks5Handshake.connectOK)
            return
        }
        let current = addresses[addressIndex]
        let next = addresses[addressIndex + 1]
        DohDebugLog.record("TLS reset on DoH IP \(current); trying \(next)")
        guard let tlsPort = NWEndpoint.Port(rawValue: 443) else {
            reject(client, reason: "tls reset", socks: readyReply == Socks5Handshake.connectOK)
            return
        }
        connectUpstream(
            addresses: addresses,
            port: tlsPort,
            addressIndex: addressIndex + 1,
            client: client,
            bufferedClientData: hello,
            hostname: hostname,
            readyReply: readyReply,
            replayHello: hello
        )
    }

    private func sendStreaming(
        _ connection: NWConnection,
        content: Data?,
        completion: @escaping (NWError?) -> Void
    ) {
        guard let content, !content.isEmpty else {
            completion(nil)
            return
        }
        connection.send(
            content: content,
            contentContext: Self.streamContext(),
            isComplete: false,
            completion: .contentProcessed { error in
                completion(error)
            }
        )
    }

    private func reject(_ connection: NWConnection, reason: String, socks: Bool = false) {
        DohDebugLog.record("Reject proxy: \(reason)")
        let response = socks
            ? Socks5Handshake.connectFailed
            : Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8)
        sendStreaming(connection, content: response) { [weak self, weak connection] _ in
            if let connection {
                self?.close(connection)
            }
        }
    }

    /// TCP streaming context. `defaultMessage` is final and can FIN the
    /// socket after the CONNECT 200, so URLSession never sends ClientHello.
    private static func streamContext() -> NWConnection.ContentContext {
        NWConnection.ContentContext(identifier: "doer.doh.stream", isFinal: false)
    }

    static let connectSuccessResponse = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    private static func streamTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = false
        return NWParameters(tls: nil, tcp: tcp)
    }

    private static func tlsTCPParameters(serverName: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let tls = NWProtocolTLS.Options()
        serverName.withCString { pointer in
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, pointer)
        }
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func shouldMITM(_ host: String) -> Bool {
        !MitmCertificateAuthority.isCloudflareChallengeHost(host)
    }

    private static func hexPrefix(_ data: Data, limit: Int = 16) -> String {
        data.prefix(limit)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }

    private static func endpointHost(from address: String) -> NWEndpoint.Host {
        if let ipv4 = IPv4Address(address) {
            return .ipv4(ipv4)
        }
        if let ipv6 = IPv6Address(address) {
            return .ipv6(ipv6)
        }
        return .name(address, nil)
    }

    /// Prefer IPv4 when both families are present. IPv6 answers often stall
    /// on networks that advertise AAAA but cannot actually route it.
    static func preferredUpstreamAddresses(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        let unique = addresses.filter { seen.insert($0).inserted }
        let ipv4 = unique.filter { !$0.contains(":") }
        if !ipv4.isEmpty { return ipv4 }
        return unique.filter { $0.contains(":") }
    }

    private func rotatedAddresses(for host: String, addresses: [String]) -> [String] {
        guard !addresses.isEmpty else { return [] }
        let offset = hostAttemptOffsets[host, default: 0]
        hostAttemptOffsets[host] = offset + 1
        let start = offset % addresses.count
        return Array(addresses[start...]) + Array(addresses[..<start])
    }

    private func close(_ connection: NWConnection?) {
        guard let connection else { return }
        connections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }
}

nonisolated private final class TunnelDiagnostics: @unchecked Sendable {
    private var didLogClientHello = false

    func logClientHelloIfNeeded(_ data: Data) {
        guard !didLogClientHello else { return }
        didLogClientHello = true

        let isTLSHandshake = data.first == 0x16
        let hasLinuxDoSNI = data.range(of: Data("linux.do".utf8)) != nil
        DohDebugLog.record(
            "Client TLS first bytes: \(hexPrefix(data)); tlsHandshake=\(isTLSHandshake); sni_linux_do=\(hasLinuxDoSNI)"
        )
    }

    private func hexPrefix(_ data: Data, limit: Int = 16) -> String {
        data.prefix(limit)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }
}

enum LocalConnectProxyError: Error {
    case invalidPort
    case listenerFailed(Error)
    case startTimedOut
}
