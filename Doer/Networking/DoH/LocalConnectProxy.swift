import DohProxy
import Foundation
import Network

nonisolated final class LocalConnectProxy: @unchecked Sendable {
    private let queue = DispatchQueue(label: "doer.doh.connect-proxy")
    private let stateLock = NSLock()
    private let resolver: DohResolver
    private let config: DohProxyConfig
    private let requestedPort: UInt16
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var mitmBridges: [ObjectIdentifier: MitmTLSBridge] = [:]
    private var originClients: [ObjectIdentifier: OriginNIOClient] = [:]
    private var ssSessions: [ObjectIdentifier: ShadowsocksAEADSession] = [:]
    private var hostAttemptOffsets: [String: Int] = [:]
    private var gatewayOriginInflight = 0
    private var gatewayOriginWaiters: [() -> Void] = []
    private let gatewayOriginLimit = 2
    private var streamContexts: [ObjectIdentifier: NWConnection.ContentContext] = [:]
    var onTLSHandshakeReset: ((String) -> Void)?
    var onListening: ((UInt16) -> Void)?
    var onFailed: ((Error) -> Void)?

    init(resolver: DohResolver, config: DohProxyConfig, port: UInt16 = 0) {
        self.resolver = resolver
        self.config = config
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
        mitmBridges.removeAll()
        originClients.removeAll()
        ssSessions.removeAll()
        streamContexts.removeAll()
        gatewayOriginWaiters.removeAll()
        gatewayOriginInflight = 0
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
                if let gateway = try DohGatewayHTTPRequest.parse(nextBuffer) {
                    DohDebugLog.record("Gateway HTTP \(gateway.host):\(gateway.port)")
                    openGateway(gateway, client: client)
                    return
                }
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
                    if let ech = answer.echConfig, !ech.isEmpty {
                        DohDebugLog.record("ECH config for \(host) (\(ech.count) bytes)")
                    }
                    DohDebugLog.record("Resolved \(host) -> \(addresses.joined(separator: ", "))")
                    guard !addresses.isEmpty else {
                        self.reject(client, reason: "empty resolved address", socks: readyReply == Socks5Handshake.connectOK)
                        return
                    }
                    if !useMITM {
                        DohDebugLog.record("CONNECT pass-through \(host) via DoH IP \(addresses[0])")
                    }
                    self.connectUpstream(
                        addresses: addresses,
                        port: upstreamPort,
                        addressIndex: 0,
                        client: client,
                        bufferedClientData: bufferedClientData,
                        hostname: host,
                        readyReply: readyReply,
                        useMITM: useMITM,
                        echConfig: answer.echConfig
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
        useMITM: Bool = false,
        echConfig: Data? = nil
    ) {
        if addressIndex == 0, let hop = config.upstream, hop.isValid {
            connectViaConfiguredUpstream(
                hop,
                client: client,
                bufferedClientData: bufferedClientData,
                hostname: hostname,
                readyReply: readyReply,
                useMITM: useMITM,
                echConfig: echConfig
            )
            return
        }
        if addressIndex == 0, let hop = config.upstream, !hop.host.isEmpty {
            reject(client, reason: "invalid upstream")
            return
        }
        guard addressIndex < addresses.count else {
            reject(client, reason: "all upstream addresses failed")
            return
        }

        let target = addresses[addressIndex]
        let host = Self.endpointHost(from: target)
        let parameters = Self.streamTCPParameters()
        let upstream = NWConnection(host: host, port: port, using: parameters)
        let upstreamId = ObjectIdentifier(upstream)
        let gate = HandshakeGate()
        connections[upstreamId] = upstream
        let timeout = DispatchWorkItem { [weak upstream] in
            guard let upstream else { return }
            DohDebugLog.record("Upstream timeout \(target):\(port.rawValue)")
            upstream.cancel()
        }
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        upstream.stateUpdateHandler = { [weak self, weak upstream, weak client] state in
            guard let self, let upstream else { return }
            switch state {
            case .waiting(let error):
                DohDebugLog.record("Upstream waiting \(target): \(error)")
            case .ready:
                gate.settle {
                    timeout.cancel()
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
                            useMITM: useMITM,
                            echConfig: echConfig
                        )
                    }
                }
            case .failed, .cancelled:
                timeout.cancel()
                self.connections.removeValue(forKey: ObjectIdentifier(upstream))
                gate.settle {
                    guard let client else { return }
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
                        useMITM: useMITM,
                        echConfig: echConfig
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
        useMITM: Bool,
        echConfig: Data? = nil,
        originNeedsTLS: Bool? = nil
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
                self.startMITM(
                    client: client,
                    upstream: upstream,
                    hostname: hostname,
                    leftover: bufferedClientData,
                    originNeedsTLS: originNeedsTLS ?? true,
                    echConfig: echConfig
                )
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
        leftover: Data,
        originNeedsTLS: Bool = false,
        echConfig: Data? = nil
    ) {
        guard let material = MitmCertificateAuthority.shared.derMaterial(for: hostname) else {
            DohDebugLog.record("MITM identity missing for \(hostname)")
            reject(client, reason: "mitm identity", socks: false)
            close(upstream)
            return
        }
        let bridge = MitmTLSBridge(client: client, upstream: upstream)
        if let ss = ssSessions[ObjectIdentifier(upstream)] {
            bridge.wrapUpstreamWrite = { ss.encrypt($0) }
            bridge.wrapUpstreamRead = { ss.decrypt($0) }
        }
        mitmBridges[ObjectIdentifier(client)] = bridge
        if !leftover.isEmpty {
            bridge.preload(leftover)
        }
        DohDebugLog.record("MITM CONNECT \(hostname)")
        let alpn = H2MitmALPN.protocols(h2Enabled: config.h2Mitm)
        bridge.start(
            certificateDER: material.certificate,
            rsaPrivateKeyDER: material.rsaPrivateKey,
            alpn: alpn,
            originNeedsTLS: originNeedsTLS,
            sni: hostname,
            echConfig: echConfig,
            completion: { [weak self, weak client, weak upstream] ok in
                guard let self, !ok else { return }
                self.queue.async {
                    if let client {
                        self.mitmBridges.removeValue(forKey: ObjectIdentifier(client))
                        self.close(client)
                    }
                    self.close(upstream)
                }
            }
        )
    }

    private func startByteTunnel(
        client: NWConnection?,
        upstream: NWConnection,
        bufferedClientData: Data,
        addresses: [String],
        addressIndex: Int,
        hostname: String,
        readyReply: Data,
        requestAlreadySent: Bool = false
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

        if requestAlreadySent {
            DohDebugLog.record("Gateway pipes \(hostname)")
            beginPipes(Data())
            return
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

        beginPipes(Data())
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
                if isUpstream, !sawUpstreamData {
                    DohDebugLog.record("Gateway origin first bytes \(data.count) from \(relay.hostname)")
                }
                var payload = data
                if isUpstream, let ss = self.ssSessions[ObjectIdentifier(source)] {
                    payload = ss.decrypt(data)
                    if payload.isEmpty {
                        self.pipe(
                            from: source,
                            to: target,
                            sourceRole: sourceRole,
                            diagnostics: diagnostics,
                            relay: relay,
                            sawUpstreamData: sawUpstreamData
                        )
                        return
                    }
                }
                self.sendStreaming(target, content: payload) { [weak self, weak source, weak target] sendError in
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
        let payload: Data
        if let ss = ssSessions[ObjectIdentifier(connection)] {
            payload = ss.encrypt(content)
        } else {
            payload = content
        }
        connection.send(
            content: payload,
            contentContext: streamingContext(for: connection),
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

    /// Reuse one non-final context per connection. A new context per send
    /// leaves each chunk incomplete; `defaultMessage` is final and can FIN
    /// the socket after the CONNECT 200.
    private func streamingContext(for connection: NWConnection) -> NWConnection.ContentContext {
        let id = ObjectIdentifier(connection)
        if let existing = streamContexts[id] {
            return existing
        }
        let context = NWConnection.ContentContext(identifier: "doer.doh.stream", isFinal: false)
        streamContexts[id] = context
        return context
    }

    static let connectSuccessResponse = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)

    private static func streamTCPParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if #available(iOS 16.0, *) {
            parameters.preferNoProxies = true
        }
        return parameters
    }

    private func connectViaConfiguredUpstream(
        _ hop: DohUpstreamConfig,
        client: NWConnection,
        bufferedClientData: Data,
        hostname: String,
        readyReply: Data,
        useMITM: Bool,
        echConfig: Data? = nil,
        gatewayRequest: DohGatewayHTTPRequest? = nil
    ) {
        resolver.resolve(host: hop.host) { [weak self, weak client] result in
            guard let self, let client else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    DohDebugLog.record("Upstream resolve failed \(hop.host): \(error)")
                    self.reject(client, reason: "upstream resolve failed")
                case .success(let answer):
                    guard let ip = Self.preferredUpstreamAddresses(answer.addresses).first,
                          let port = NWEndpoint.Port(rawValue: UInt16(clamping: hop.port))
                    else {
                        self.reject(client, reason: "upstream empty address")
                        return
                    }
                    let hopConnection = NWConnection(
                        host: Self.endpointHost(from: ip),
                        port: port,
                        using: Self.streamTCPParameters()
                    )
                    self.connections[ObjectIdentifier(hopConnection)] = hopConnection
                    hopConnection.stateUpdateHandler = { [weak self, weak client, weak hopConnection] state in
                        guard let self, let client, let hopConnection else { return }
                        guard case .ready = state else { return }
                        let handshake: Data
                        switch hop.protocolKind {
                        case .http:
                            handshake = UpstreamHandshake.httpConnect(
                                host: hostname,
                                port: 443,
                                username: hop.username,
                                password: hop.password
                            )
                        case .socks5:
                            handshake = UpstreamHandshake.socks5Greeting(userpass: hop.username != nil)
                        case .shadowsocks:
                            guard let cipher = ShadowsocksAEAD.Cipher(name: hop.cipher) else {
                                self.reject(client, reason: "unsupported shadowsocks cipher")
                                return
                            }
                            let session = ShadowsocksAEADSession(
                                password: hop.password ?? "",
                                cipher: cipher
                            )
                            self.sendStreaming(
                                hopConnection,
                                content: session.openingPrefix(host: hostname, port: 443)
                            ) { error in
                                if error != nil {
                                    self.reject(client, reason: "shadowsocks prefix")
                                    return
                                }
                                self.ssSessions[ObjectIdentifier(hopConnection)] = session
                                self.finishUpstreamHop(
                                    hopConnection,
                                    client: client,
                                    bufferedClientData: bufferedClientData,
                                    hostname: hostname,
                                    readyReply: readyReply,
                                    useMITM: useMITM,
                                    echConfig: echConfig,
                                    gatewayRequest: gatewayRequest
                                )
                            }
                            return
                        }
                        self.sendStreaming(hopConnection, content: handshake) { error in
                            if error != nil {
                                self.reject(client, reason: "upstream handshake send")
                                return
                            }
                            hopConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                                self.queue.async {
                                    guard let data, !data.isEmpty else {
                                        self.reject(client, reason: "upstream handshake empty")
                                        return
                                    }
                                    if hop.protocolKind == .socks5 {
                                        let userpass = hop.username != nil
                                        if userpass {
                                            let auth = UpstreamHandshake.socks5UserPass(
                                                username: hop.username ?? "",
                                                password: hop.password ?? ""
                                            )
                                            self.sendStreaming(hopConnection, content: auth) { _ in
                                                let connect = UpstreamHandshake.socks5Connect(host: hostname, port: 443)
                                                self.sendStreaming(hopConnection, content: connect) { _ in
                                                    self.finishUpstreamHop(
                                                        hopConnection,
                                                        client: client,
                                                        bufferedClientData: bufferedClientData,
                                                        hostname: hostname,
                                                        readyReply: readyReply,
                                                        useMITM: useMITM,
                                                        echConfig: echConfig,
                                                        gatewayRequest: gatewayRequest
                                                    )
                                                }
                                            }
                                            return
                                        }
                                        let connect = UpstreamHandshake.socks5Connect(host: hostname, port: 443)
                                        self.sendStreaming(hopConnection, content: connect) { _ in
                                            self.finishUpstreamHop(
                                                hopConnection,
                                                client: client,
                                                bufferedClientData: bufferedClientData,
                                                hostname: hostname,
                                                readyReply: readyReply,
                                                useMITM: useMITM,
                                                echConfig: echConfig,
                                                gatewayRequest: gatewayRequest
                                            )
                                        }
                                        return
                                    }
                                    let text = String(data: data, encoding: .utf8) ?? ""
                                    guard text.contains(" 200 ") else {
                                        self.reject(client, reason: "upstream CONNECT failed")
                                        return
                                    }
                                    self.finishUpstreamHop(
                                        hopConnection,
                                        client: client,
                                        bufferedClientData: bufferedClientData,
                                        hostname: hostname,
                                        readyReply: readyReply,
                                        useMITM: useMITM,
                                        echConfig: echConfig,
                                        gatewayRequest: gatewayRequest
                                    )
                                }
                            }
                        }
                    }
                    hopConnection.start(queue: self.queue)
                }
            }
        }
    }

    private func finishUpstreamHop(
        _ hopConnection: NWConnection,
        client: NWConnection,
        bufferedClientData: Data,
        hostname: String,
        readyReply: Data,
        useMITM: Bool,
        echConfig: Data? = nil,
        gatewayRequest: DohGatewayHTTPRequest? = nil
    ) {
        if let gatewayRequest {
            startGatewayOrigin(
                client: client,
                upstream: hopConnection,
                request: gatewayRequest,
                echConfig: echConfig,
                originAddress: hostname
            )
            return
        }
        sendConnectSuccess(
            to: client,
            upstream: hopConnection,
            bufferedClientData: bufferedClientData,
            addresses: [],
            addressIndex: 0,
            hostname: hostname,
            readyReply: readyReply,
            useMITM: useMITM,
            echConfig: echConfig
        )
    }

    private func startGatewayOrigin(
        client: NWConnection,
        upstream: NWConnection,
        request: DohGatewayHTTPRequest,
        echConfig: Data?,
        originAddress: String
    ) {
        do {
            let alpn = H2MitmALPN.protocols(h2Enabled: config.h2Mitm)
            let origin = try OriginNIOClient(
                sni: request.host,
                applicationProtocols: alpn,
                echConfig: echConfig
            )
            originClients[ObjectIdentifier(client)] = origin
            DohDebugLog.record("Gateway origin TLS NIOSSL \(request.host) \(originAddress)")
            startGatewayNIOOrigin(origin, client: client, upstream: upstream, request: request)
        } catch {
            DohDebugLog.record("Gateway origin TLS failed: \(error)")
            reject(client, reason: "gateway tls")
            close(upstream)
        }
    }

    private func startGatewayNIOOrigin(
        _ origin: OriginNIOClient,
        client: NWConnection,
        upstream: NWConnection,
        request: DohGatewayHTTPRequest
    ) {
            var loggedHello = false
            origin.start(
                socketRead: { [weak self, weak upstream] deliver in
                    guard let self, let upstream else { return }
                    func receive() {
                        upstream.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                            guard let data else {
                                deliver(nil)
                                return
                            }
                            if let ss = self.ssSessions[ObjectIdentifier(upstream)] {
                                let payload = ss.decrypt(data)
                                if payload.isEmpty {
                                    receive()
                                    return
                                }
                                deliver(payload)
                            } else {
                                deliver(data)
                            }
                        }
                    }
                    receive()
                },
                socketWrite: { [weak self, weak upstream] data, done in
                    guard let self, let upstream else {
                        done()
                        return
                    }
                    if !loggedHello {
                        loggedHello = true
                        DohDebugLog.record("Gateway origin ClientHello \(data.count) bytes to \(request.host)")
                    }
                    self.sendStreaming(upstream, content: data) { _ in
                        done()
                    }
                },
                appRead: { [weak self, weak client] plaintext in
                    guard let self, let client else { return }
                    self.sendStreaming(client, content: plaintext) { _ in }
                },
                completion: { [weak self, weak client, weak upstream] ok in
                    guard let self, !ok else { return }
                    self.queue.async {
                        self.close(client)
                        self.close(upstream)
                    }
                }
            )
            origin.writeApplication(request.originForm) { [weak self, weak upstream] payload, done in
                guard let self, let upstream else {
                    done()
                    return
                }
                self.sendStreaming(upstream, content: payload) { _ in
                    done()
                }
            }
            pipeGatewayClient(client, origin: origin)
    }

    private func enqueueGatewayOrigin(_ work: @escaping () -> Void) {
        if gatewayOriginInflight >= gatewayOriginLimit {
            gatewayOriginWaiters.append(work)
            return
        }
        gatewayOriginInflight += 1
        work()
    }

    private func completeGatewayOrigin() {
        if let next = gatewayOriginWaiters.first {
            gatewayOriginWaiters.removeFirst()
            next()
            return
        }
        gatewayOriginInflight = max(0, gatewayOriginInflight - 1)
    }

    /// TLS to the hostname via Network.framework. Connecting to a Cloudflare
    /// anycast IP with a clear SNI ClientHello is reset (POSIX 54).
    private func startOriginSystemTLS(
        host: String,
        port: UInt16,
        attempt: Int = 0,
        onReady: @escaping (NWConnection) -> Void,
        onFail: @escaping (Error?) -> Void
    ) {
        startOriginConnection(
            host: host,
            port: port,
            useTLS: true,
            attempt: attempt,
            onReady: onReady,
            onFail: onFail
        )
    }

    private func startOriginConnection(
        host: String,
        port: UInt16,
        useTLS: Bool,
        attempt: Int = 0,
        onReady: @escaping (NWConnection) -> Void,
        onFail: @escaping (Error?) -> Void
    ) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            onFail(nil)
            return
        }
        let label = useTLS ? "system TLS" : "pass-through TCP"
        DohDebugLog.record("Gateway origin \(label) \(host) attempt=\(attempt)")
        let parameters = useTLS ? tlsTCPParameters(serverName: host) : Self.streamTCPParameters()
        let upstream = NWConnection(
            host: .name(host, nil),
            port: nwPort,
            using: parameters
        )
        connections[ObjectIdentifier(upstream)] = upstream
        let gate = HandshakeGate()
        let timeout = DispatchWorkItem { [weak self, weak upstream] in
            guard let self, let upstream else { return }
            gate.settle {
                DohDebugLog.record("Gateway origin \(label) timeout \(host)")
                self.close(upstream)
                if attempt < 1 {
                    self.startOriginConnection(
                        host: host,
                        port: port,
                        useTLS: useTLS,
                        attempt: attempt + 1,
                        onReady: onReady,
                        onFail: onFail
                    )
                } else {
                    onFail(nil)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        upstream.stateUpdateHandler = { [weak self, weak upstream] state in
            guard let self, let upstream else { return }
            switch state {
            case .waiting(let error):
                DohDebugLog.record("Gateway origin \(label) waiting \(host): \(error)")
            case .ready:
                gate.settle {
                    timeout.cancel()
                    DohDebugLog.record("Gateway origin \(label) ready \(host)")
                    onReady(upstream)
                }
            case .failed(let error):
                gate.settle {
                    timeout.cancel()
                    DohDebugLog.record("Gateway origin \(label) failed \(host): \(error)")
                    self.close(upstream)
                    if attempt < 1 {
                        self.startOriginConnection(
                            host: host,
                            port: port,
                            useTLS: useTLS,
                            attempt: attempt + 1,
                            onReady: onReady,
                            onFail: onFail
                        )
                    } else {
                        onFail(error)
                    }
                }
            case .cancelled:
                gate.settle {
                    timeout.cancel()
                    onFail(nil)
                }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func tlsTCPParameters(serverName: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let tls = NWProtocolTLS.Options()
        serverName.withCString { pointer in
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, pointer)
        }
        for proto in H2MitmALPN.protocols(h2Enabled: config.h2Mitm) {
            proto.withCString { pointer in
                sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, pointer)
            }
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if #available(iOS 16.0, *) {
            parameters.preferNoProxies = true
        }
        return parameters
    }

    private func pipeGatewayClient(_ client: NWConnection, origin: OriginNIOClient) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            if let data, !data.isEmpty {
                origin.writeApplication(data) { _, _ in }
                self.pipeGatewayClient(client, origin: origin)
                return
            }
            if error != nil || isComplete { return }
            self.pipeGatewayClient(client, origin: origin)
        }
    }

    private func openGateway(_ request: DohGatewayHTTPRequest, client: NWConnection) {
        resolver.resolve(host: request.host) { [weak self, weak client] result in
            guard let self, let client else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    DohDebugLog.record("Gateway resolve failed \(request.host): \(error)")
                    self.reject(client, reason: "resolve failed")
                case .success(let answer):
                    let addresses = Self.preferredUpstreamAddresses(answer.addresses)
                    guard let first = addresses.first else {
                        self.reject(client, reason: "empty resolved address")
                        return
                    }
                    DohDebugLog.record("Gateway resolved \(request.host) -> \(addresses.joined(separator: ", "))")
                    if let ech = answer.echConfig, !ech.isEmpty {
                        DohDebugLog.record(
                            "Gateway ECH config \(ech.count) bytes unused until inject works"
                        )
                    }
                    if let hop = self.config.upstream, hop.isValid {
                        self.connectViaConfiguredUpstream(
                            hop,
                            client: client,
                            bufferedClientData: request.originForm,
                            hostname: request.host,
                            readyReply: Data(),
                            useMITM: false,
                            echConfig: answer.echConfig,
                            gatewayRequest: request
                        )
                        return
                    }
                    self.enqueueGatewayOrigin {
                        self.startOriginSystemTLS(host: request.host, port: request.port) { tlsConn in
                            self.completeGatewayOrigin()
                            DohDebugLog.record(
                                "Gateway origin HTTP send \(request.originForm.count) bytes \(request.host)"
                            )
                            self.sendStreaming(tlsConn, content: request.originForm) { error in
                                if error != nil {
                                    DohDebugLog.record(
                                        "Gateway origin HTTP send failed: \(String(describing: error))"
                                    )
                                    self.close(client)
                                    self.close(tlsConn)
                                    return
                                }
                                self.startByteTunnel(
                                    client: client,
                                    upstream: tlsConn,
                                    bufferedClientData: Data(),
                                    addresses: [first],
                                    addressIndex: 0,
                                    hostname: request.host,
                                    readyReply: Data(),
                                    requestAlreadySent: true
                                )
                            }
                        } onFail: { error in
                            self.completeGatewayOrigin()
                            DohDebugLog.record(
                                "Gateway origin system TLS gave up \(request.host): \(String(describing: error))"
                            )
                            self.reject(client, reason: "gateway tls")
                        }
                    }
                }
            }
        }
    }

    /// Origin ECH inject is not available on device yet. Until it is, CONNECT
    /// pass-through lets URLSession speak real HTTPS (h2) so Cloudflare does
    /// not 403 `cf-mitigated: challenge` on HTTP/1.1 Gateway hops.
    static var originECHReady = false

    static func shouldMITM(_ host: String) -> Bool {
        guard originECHReady else { return false }
        return !MitmCertificateAuthority.isCloudflareChallengeHost(host)
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
        let id = ObjectIdentifier(connection)
        connections.removeValue(forKey: id)
        ssSessions.removeValue(forKey: id)
        originClients.removeValue(forKey: id)
        mitmBridges.removeValue(forKey: id)
        streamContexts.removeValue(forKey: id)
        connection.cancel()
    }
}

private final class HandshakeGate {
    private var settled = false

    func settle(_ body: () -> Void) {
        guard !settled else { return }
        settled = true
        body()
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
