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
    /// `NWListener` 最近一次上报的状态是否为 `.ready`。`.waiting` 时内核的
    /// listen socket 可能还在（于是回环 connect 照样成功），但 App 已经不再
    /// accept，光靠 connect 探活会漏判，必须连状态一起看。
    private var listenerIsReady = false
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stallWatchdogs: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var mitmBridges: [ObjectIdentifier: MitmTLSBridge] = [:]
    private var originClients: [ObjectIdentifier: OriginNIOClient] = [:]
    private var ssSessions: [ObjectIdentifier: ShadowsocksAEADSession] = [:]
    private var hostAttemptOffsets: [String: Int] = [:]
    private var gatewayOriginInflight = 0
    private var gatewayOriginWaiters: [() -> Void] = []
    private let gatewayOriginLimit = 2
    /// 隧道建立后上游进 `.waiting` 的容忍时间：换网、接口消失时状态可能就这么挂着，
    /// 两边既收不到数据也收不到错误。
    private static let stallWatchdogSeconds: TimeInterval = 6
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

    /// 回环监听器是否真的还在 accept。
    ///
    /// App 回前台后 `NWListener` 可能被系统挂起：状态停在 `.waiting`（甚至不再
    /// 回调 `stateUpdateHandler`），`listener` / `boundPort` 也都还在，于是
    /// `isRunning` 一直判活，而 URLSession 连 127.0.0.1 直接拿 310（HTTPS proxy
    /// 连接失败）。`boundPort` 区分不出这种情况，所以要两个条件同时成立：
    /// 最近一次状态是 `.ready`（App 仍在 accept），并且自己真连一下——
    /// 回环 connect 正常是微秒级，返回 0 说明监听队列还在接受连接。
    func isAcceptingConnections() -> Bool {
        stateLock.lock()
        let port = boundPort
        let ready = listenerIsReady
        stateLock.unlock()
        guard let port, port != 0 else { return false }
        guard ready else {
            DohDebugLog.record("Local CONNECT health check failed: 127.0.0.1:\(port) listener not ready")
            return false
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let code = errno
            DohDebugLog.record("Local CONNECT health check socket failed: 127.0.0.1:\(port) errno=\(code)")
            return false
        }
        // `close` 在本类里有同名方法（NWConnection 版），这里必须显式走 Darwin。
        defer { Darwin.close(fd) }

        // 非阻塞 + poll：回环 connect 正常是微秒级，但没有监听者时也可能因为
        // accept 队列满而丢 SYN，阻塞版要等系统级重传超时（几十秒）。这个方法
        // 跑在 `startQueue` 上，卡住会把整条 DoH 启动链路一起拖死。
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, size)
            }
        }
        if result == 0 { return true }
        let connectError = errno
        guard connectError == EINPROGRESS || connectError == EALREADY else {
            DohDebugLog.record("Local CONNECT health check failed: 127.0.0.1:\(port) errno=\(connectError)")
            return false
        }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, 250) > 0 else {
            DohDebugLog.record("Local CONNECT health check timed out: 127.0.0.1:\(port)")
            return false
        }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
            DohDebugLog.record("Local CONNECT health check failed: 127.0.0.1:\(port) errno=\(socketError)")
            return false
        }
        return true
    }

    /// 换 Wi‑Fi / 蜂窝：旧接口上的 socket 全部作废。
    ///
    /// 不主动收掉的话，URLSession 会继续复用它连到回环代理的那些连接——上游其实
    /// 已经停在 `.waiting`，请求只能干等到自己的超时，表现就是「换网后一直转圈」。
    /// 全部在 `queue` 上同步做，晚于此刻建立的连接不会被误杀。
    func noteNetworkPathChanged(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let stale = Array(self.connections.values)
            self.connections.removeAll()
            self.mitmBridges.removeAll()
            self.originClients.removeAll()
            self.ssSessions.removeAll()
            self.hostAttemptOffsets.removeAll()
            self.gatewayOriginWaiters.removeAll()
            self.gatewayOriginInflight = 0
            self.stallWatchdogs.values.forEach { $0.cancel() }
            self.stallWatchdogs.removeAll()
            stale.forEach { $0.cancel() }
            DohDebugLog.record("换网（\(reason)）收掉 \(stale.count) 条旧连接")
        }
    }

    private func armStallWatchdog(_ connection: NWConnection, label: String) {
        let id = ObjectIdentifier(connection)
        guard stallWatchdogs[id] == nil else { return }
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.stallWatchdogs.removeValue(forKey: id)
            DohDebugLog.record("隧道停滞 \(label)：\(Self.stallWatchdogSeconds) 秒没恢复，收掉重连")
            connection.cancel()
        }
        stallWatchdogs[id] = work
        queue.asyncAfter(deadline: .now() + Self.stallWatchdogSeconds, execute: work)
    }

    private func cancelStallWatchdog(_ connection: NWConnection?) {
        guard let connection else { return }
        stallWatchdogs.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }

    /// Starts the loopback listener without blocking the caller.
    /// Waiting here from the main thread deadlocks: NWListener callbacks can
    /// hop to MainActor while launch is still inside `didFinishLaunching`.
    func start() throws {
        MitmNIOPipe.log = { DohDebugLog.record($0, subsystem: "MITM") }
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
                self.listenerIsReady = true
                self.stateLock.unlock()
                DohDebugLog.record("Local CONNECT proxy ready on 127.0.0.1:\(port)")
                self.onListening?(port)
            case .waiting(let error):
                // `.waiting` 有可能自己回到 `.ready`，所以这里只记日志、不清
                // `boundPort`：清了会引起无谓重建。但要把 `listenerIsReady`
                // 打掉——内核的 listen socket 可能还在，客户端能连上却没人
                // accept，必须让 `isAcceptingConnections()` 判失败并重建。
                self.stateLock.lock()
                self.listenerIsReady = false
                self.stateLock.unlock()
                DohDebugLog.record("Local CONNECT proxy waiting: \(error)")
            case .failed(let error):
                DohDebugLog.record("Local CONNECT proxy failed: \(error)")
                self.stateLock.lock()
                self.boundPort = nil
                self.listenerIsReady = false
                self.stateLock.unlock()
                self.onFailed?(LocalConnectProxyError.listenerFailed(error))
            case .cancelled:
                self.stateLock.lock()
                self.boundPort = nil
                self.listenerIsReady = false
                self.stateLock.unlock()
            default:
                break
            }
        }
        stateLock.lock()
        self.listener = listener
        self.listenerIsReady = false
        stateLock.unlock()
        listener.start(queue: queue)
    }

    func stop() {
        // `listener`/`boundPort` are lock-guarded, but the tunnel dictionaries are
        // only ever touched on `queue` (`handleClient` / `close` / `pipe`). Tear
        // them down there as well, otherwise a connection arriving mid-stop races
        // those dictionaries. The listener itself is cancelled synchronously so
        // `isRunning` flips immediately.
        stateLock.lock()
        let currentListener = listener
        listener = nil
        boundPort = nil
        listenerIsReady = false
        stateLock.unlock()
        currentListener?.cancel()

        queue.async { [self] in
            let active = connections.values
            connections.removeAll()
            mitmBridges.removeAll()
            originClients.removeAll()
            ssSessions.removeAll()
            gatewayOriginWaiters.removeAll()
            gatewayOriginInflight = 0
            active.forEach { $0.cancel() }
        }
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

        // 优选赢家：直接连，连 linux.do 的 DNS 都不查。
        //
        // 本地 ECH 模式下必须带 ECH——那条路的目的就是藏 SNI，没有 ECH 等于放弃它。
        // Encrypted DNS 模式的 SNI 本来就是明文，有赢家直连就够；否则 ECH 抓取一失败
        // 这条捷径就静默失效，退回等 DNS，正好是"赢了优选却还在依赖 DoH"的成因。
        if let pinned = PreferredNodeStore.shared.pinnedAddress(forHost: host) {
            let ech = PreferredNodeStore.shared.node?.echConfig
            let hasECH = !(ech?.isEmpty ?? true)
            if hasECH || !Self.originECHReady {
                // Encrypted DNS 走的是 pass-through，ECH 钥匙根本不会被注入，
                // 日志里别把它写成「已注入」。
                let modeNote = useMITM
                    ? (hasECH ? "ECH 已注入" : "ECH 未启用")
                    : "Encrypted DNS"
                DohDebugLog.record(
                    "优选直连 \(host) -> \(pinned)（不查 DNS，\(modeNote)）",
                    subsystem: "优选"
                )
                connectUpstream(
                    addresses: [pinned],
                    port: upstreamPort,
                    addressIndex: 0,
                    client: client,
                    bufferedClientData: bufferedClientData,
                    hostname: host,
                    readyReply: readyReply,
                    useMITM: useMITM,
                    echConfig: hasECH ? ech : nil,
                    onExhausted: { [weak self] in
                        guard let self else { return }
                        // 捷径失败不能把这次 CONNECT 判死：回到正常解析，
                        // 让 DoH 给出的地址（含赢家本身）继续试。
                        DohDebugLog.record("优选直连失败，回退解析 \(host)", subsystem: "优选")
                        self.resolveAndConnect(
                            host: host,
                            upstreamPort: upstreamPort,
                            client: client,
                            bufferedClientData: bufferedClientData,
                            readyReply: readyReply
                        )
                    }
                )
                return
            }
        }

        resolveAndConnect(
            host: host,
            upstreamPort: upstreamPort,
            client: client,
            bufferedClientData: bufferedClientData,
            readyReply: readyReply
        )
    }

    /// 目标 host 属于验证页依赖、且确定托管在 CF 上的域名，并且当前存在一个
    /// 本机地址族可路由的优选赢家时，返回该赢家 IP。
    /// - Parameter excluding: 本次已经试过的地址。赢家已经试过就不再返回，
    ///   否则 TLS 重试路径会对着同一个 IP 反复重连。
    private func cloudflareEdgeFallbackAddress(
        for host: String,
        excluding addresses: [String] = []
    ) -> String? {
        guard Self.isCloudflareHostedRegardlessOfDNS(host),
              let edge = PreferredNodeStore.shared.cloudflareEdgeAddress(),
              !addresses.contains(edge)
        else { return nil }
        return edge
    }

    /// DoH 解析不出来时，用优选赢家 IP 直连 CF 域名。
    /// 返回 false 表示这个 host 不适用兜底（或没有可用赢家），调用方照原样 reject。
    @discardableResult
    private func connectViaCloudflareEdge(
        host: String,
        upstreamPort: NWEndpoint.Port,
        client: NWConnection,
        bufferedClientData: Data,
        readyReply: Data,
        useMITM: Bool,
        replayHello: Data? = nil,
        excluding: [String] = [],
        onExhausted: (() -> Void)? = nil
    ) -> Bool {
        guard let edge = cloudflareEdgeFallbackAddress(for: host, excluding: excluding) else {
            return false
        }
        DohDebugLog.record(
            "Resolve unavailable for \(host); using Cloudflare edge \(edge)",
            subsystem: "优选"
        )
        connectUpstream(
            addresses: [edge],
            port: upstreamPort,
            addressIndex: 0,
            client: client,
            bufferedClientData: bufferedClientData,
            hostname: host,
            readyReply: readyReply,
            replayHello: replayHello,
            useMITM: useMITM,
            // 赢家随身的 ECH 钥匙是 linux.do 的，别的 host 不能用它，否则握手必失败。
            echConfig: nil,
            // 兜底自身不再兜底：地址只有赢家一个，失败就 reject，避免递归。
            onExhausted: onExhausted
        )
        return true
    }

    /// 正常解析路径：DoH 解析 →（有赢家就排第一）→ 依次连接。
    private func resolveAndConnect(
        host: String,
        upstreamPort: NWEndpoint.Port,
        client: NWConnection,
        bufferedClientData: Data,
        readyReply: Data
    ) {
        let useMITM = Self.shouldMITM(host)
        // CF 自家域名（验证页 / Turnstile / CDN）直接走赢家，**不等 DoH**：
        // 它们都在同一张 CF anycast 上，而 DoH 一旦不可用，每次解析都要白等 8 秒
        // （负缓存只有 3 秒），一帖几张图排在网关队列后面就是几十秒白屏。
        // 赢家连不上再回到 DoH。
        if Self.isCloudflareHostedRegardlessOfDNS(host),
           let edge = PreferredNodeStore.shared.cloudflareEdgeAddress() {
            DohDebugLog.record(
                "Cloudflare host \(host): using edge \(edge) without DNS",
                subsystem: "优选"
            )
            connectUpstream(
                addresses: [edge],
                port: upstreamPort,
                addressIndex: 0,
                client: client,
                bufferedClientData: bufferedClientData,
                hostname: host,
                readyReply: readyReply,
                useMITM: useMITM,
                echConfig: nil,
                onExhausted: { [weak self, weak client] in
                    guard let self, let client else { return }
                    DohDebugLog.record("Cloudflare edge failed for \(host); falling back to DoH")
                    self.resolveAndConnectViaDoH(
                        host: host,
                        upstreamPort: upstreamPort,
                        client: client,
                        bufferedClientData: bufferedClientData,
                        readyReply: readyReply,
                        useMITM: useMITM,
                        allowEdgeFallback: false
                    )
                }
            )
            return
        }
        resolveAndConnectViaDoH(
            host: host,
            upstreamPort: upstreamPort,
            client: client,
            bufferedClientData: bufferedClientData,
            readyReply: readyReply,
            useMITM: useMITM,
            allowEdgeFallback: true
        )
    }

    /// DoH 解析路径。`allowEdgeFallback` 为 false 表示已经试过赢家才来到这里，
    /// 不要再退回去，避免两边来回递归。
    private func resolveAndConnectViaDoH(
        host: String,
        upstreamPort: NWEndpoint.Port,
        client: NWConnection,
        bufferedClientData: Data,
        readyReply: Data,
        useMITM: Bool,
        allowEdgeFallback: Bool
    ) {
        resolver.resolve(host: host) { [weak self, weak client] result in
            guard let self, let client else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    DohDebugLog.record("Resolve failed for \(host): \(error.localizedDescription)")
                    if allowEdgeFallback,
                       self.connectViaCloudflareEdge(
                        host: host,
                        upstreamPort: upstreamPort,
                        client: client,
                        bufferedClientData: bufferedClientData,
                        readyReply: readyReply,
                        useMITM: useMITM
                    ) {
                        return
                    }
                    self.reject(client, reason: "resolve failed", socks: readyReply == Socks5Handshake.connectOK)
                case .success(let answer):
                    let resolved = Self.preferredUpstreamAddresses(answer.addresses)
                    let addresses: [String]
                    if let pinned = PreferredNodeStore.shared.pinnedAddress(forHost: host) {
                        // 优选赢家先连，但 DoH 解析出来的地址仍排在后面当回退：
                        // 只给一个地址时赢家一挂，这个页面就直接打不开了。
                        let rest = resolved.filter { $0 != pinned }
                        addresses = [pinned] + self.rotatedAddresses(for: host, addresses: rest)
                        DohDebugLog.record(
                            "优选钉住 \(host) -> \(pinned)（回退 \(rest.count) 个）",
                            subsystem: "优选"
                        )
                    } else {
                        addresses = self.rotatedAddresses(for: host, addresses: resolved)
                    }
                    if let ech = answer.echConfig, !ech.isEmpty {
                        DohDebugLog.record("ECH config for \(host) (\(ech.count) bytes)")
                    }
                    DohDebugLog.record("Resolved \(host) -> \(addresses.joined(separator: ", "))")
                    guard !addresses.isEmpty else {
                        // 应答全被过滤掉（投毒 / 假地址）和解析失败一样致命：
                        // 验证页依赖的 CF 域名还有赢家可用，先试赢家，不行再 reject。
                        if allowEdgeFallback,
                           self.connectViaCloudflareEdge(
                            host: host,
                            upstreamPort: upstreamPort,
                            client: client,
                            bufferedClientData: bufferedClientData,
                            readyReply: readyReply,
                            useMITM: useMITM
                        ) {
                            return
                        }
                        self.reject(client, reason: "empty resolved address", socks: readyReply == Socks5Handshake.connectOK)
                        return
                    }
                    if !useMITM {
                        DohDebugLog.record("CONNECT pass-through \(host) via DoH IP \(addresses[0])")
                    }
                    // 解析成功但地址全连不上时也退到 CF 边缘：DNS 给出的地址可能整批被墙，
                    // 而赢家是竞速验证过能用的。`addresses` 里已有赢家就不重复兜底。
                    var edgeFallback: (() -> Void)? = nil
                    if allowEdgeFallback,
                       Self.isCloudflareHostedRegardlessOfDNS(host),
                       let edge = PreferredNodeStore.shared.cloudflareEdgeAddress(),
                       !addresses.contains(edge) {
                        edgeFallback = { [weak self, weak client] in
                            guard let self, let client else { return }
                            guard self.connectViaCloudflareEdge(
                                host: host,
                                upstreamPort: upstreamPort,
                                client: client,
                                bufferedClientData: bufferedClientData,
                                readyReply: readyReply,
                                useMITM: useMITM,
                                excluding: addresses
                            ) else {
                                // 赢家可能在构造兜底之后被降级/清除（连败、换网）。
                                // 这时兜底拿不到地址，必须显式 reject：`onExhausted`
                                // 已经吃掉了原生的 reject 分支，这里再不动就让
                                // 客户端挂在一条永远不会重试的连接上。
                                self.reject(
                                    client,
                                    reason: "all upstream addresses failed",
                                    socks: readyReply == Socks5Handshake.connectOK
                                )
                                return
                            }
                        }
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
                        echConfig: answer.echConfig,
                        onExhausted: edgeFallback
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
        echConfig: Data? = nil,
        /// 地址全部失败时的兜底。传了就代替 `reject`，用于"优选直连失败退回解析"。
        onExhausted: (() -> Void)? = nil
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
            if let onExhausted {
                onExhausted()
                return
            }
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
        let resolver = self.resolver
        let timeout = DispatchWorkItem { [weak upstream] in
            guard let upstream else { return }
            DohDebugLog.record("Upstream timeout \(target):\(port.rawValue)")
            PreferredNodeStore.shared.reportOutcome(host: hostname, ip: target, success: false)
            resolver.recordHostFailure(host: hostname, ip: target)
            upstream.cancel()
        }
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)

        /// 放弃当前地址并换下一个。
        ///
        /// `.failed/.cancelled` 与 `.waiting` 的不可达错误共用。`gate.settle`
        /// 保证换地址只发生一次：握手已结算（`.ready` 之后掉线）时这里只做
        /// 幂等清理——`gate.settle` 的 body 不会再跑，隧道层自己收尾。
        /// 先 `cancel` 掉旧连接，避免 `.waiting` 之后自己恢复成 `.ready`
        /// 留下一条没人管的上游。
        let abandonAndRetry: (String) -> Void = { [weak self, weak upstream, weak client] logLine in
            guard let self, let upstream else { return }
            timeout.cancel()
            self.cancelStallWatchdog(upstream)
            self.connections.removeValue(forKey: upstreamId)
            // 先摘回调再 cancel：否则 `.cancelled` 会再进一遍。虽然 `gate.settle`
            // 只结算一次、字典清理也幂等，但重入没有收益，日志里也会多一条
            // 「failed」掩盖真正的失败原因。
            upstream.stateUpdateHandler = nil
            upstream.cancel()
            gate.settle {
                guard let client else { return }
                DohDebugLog.record(logLine)
                PreferredNodeStore.shared.reportOutcome(host: hostname, ip: target, success: false)
                self.resolver.recordHostFailure(host: hostname, ip: target)
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
                    echConfig: echConfig,
                    onExhausted: onExhausted
                )
            }
        }

        upstream.stateUpdateHandler = { [weak self, weak upstream, weak client] state in
            guard let self, let upstream else { return }
            switch state {
            case .waiting(let error):
                if Self.isUnreachableNetworkError(error) {
                    abandonAndRetry(
                        "Upstream unreachable \(target):\(port.rawValue) \(error), trying next"
                    )
                    return
                }
                DohDebugLog.record("Upstream waiting \(target): \(error)")
                if gate.hasSettled {
                    self.armStallWatchdog(upstream, label: "\(target):\(port.rawValue)")
                }
            case .ready:
                self.cancelStallWatchdog(upstream)
                gate.settle {
                    timeout.cancel()
                    DohDebugLog.record("Upstream connected \(target):\(port.rawValue)")
                    // 这里不报成功：TCP 通了只说明三次握手没问题，Cloudflare 的
                    // 坏边缘恰恰是「TCP 通、TLS 被 RST」。成功信号留到上游真的
                    // 回了字节（`pipe`）或 MITM 完成，否则每次 reset 之后的
                    // 重连都会先把 `failStreak` 清零，赢家永远降不了级。
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
                abandonAndRetry("Upstream failed \(target):\(port.rawValue), trying next")
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
                    echConfig: echConfig,
                    originAddress: addresses.indices.contains(addressIndex) ? addresses[addressIndex] : nil
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
        echConfig: Data? = nil,
        originAddress: String? = nil
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
            },
            onOriginHandshake: { [weak self] ok in
                // MITM 的上游字节由 bridge 消费，不进 `pipe`，所以成功信号
                // 只能挂在源站 TLS/ECH 握手上：握手过了才说明这台边缘可用。
                guard let self, let originAddress else { return }
                self.queue.async {
                    if ok {
                        self.resolver.recordHostSuccess(host: hostname, ip: originAddress)
                        PreferredNodeStore.shared.reportOutcome(
                            host: hostname,
                            ip: originAddress,
                            success: true
                        )
                    } else {
                        self.resolver.recordHostFailure(host: hostname, ip: originAddress)
                        PreferredNodeStore.shared.reportOutcome(
                            host: hostname,
                            ip: originAddress,
                            success: false
                        )
                    }
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
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak source, weak target] data, _, isComplete, error in
            guard let self, let source, let target else { return }
            if let data, !data.isEmpty {
                diagnostics?.logClientHelloIfNeeded(data)
                let isUpstream = sourceRole == "upstream"
                if isUpstream, !sawUpstreamData {
                    // 上游吐了字节，才说明这台边缘真的能用（TLS 握手过了）。
                    // 成功信号必须在这里报，不能在 TCP `.ready`，否则「TCP 通、
                    // TLS 被 RST」的坏边缘每次重连都先清零连败计数。
                    if relay.addressIndex < relay.addresses.count {
                        let live = relay.addresses[relay.addressIndex]
                        self.resolver.recordHostSuccess(host: relay.hostname, ip: live)
                        PreferredNodeStore.shared.reportOutcome(
                            host: relay.hostname,
                            ip: live,
                            success: true
                        )
                    }
                    DohDebugLog.record("Upstream first bytes \(data.count) from \(relay.hostname)")
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
                    // TLS 被 RST：TCP 明明连上了，坏掉的是这台边缘。
                    // 只报给 `recordHostSuccess` 会在 `connectUpstream.ready`
                    // 里提前抵消掉，所以这里必须显式记失败，否则优选赢家永远
                    // 降不了级（惩罚/粘性一直按「TCP 通了」算成功）。
                    if relay.addressIndex < relay.addresses.count {
                        let dead = relay.addresses[relay.addressIndex]
                        self.resolver.recordHostFailure(host: relay.hostname, ip: dead)
                        PreferredNodeStore.shared.reportOutcome(
                            host: relay.hostname,
                            ip: dead,
                            success: false
                        )
                    }
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
            // DoH 给出的地址 TCP 都通了、TLS 却全被 RST：这是"边缘坏了"，不是
            // "域名不存在"。验证页依赖的 CF 域名还有竞速验证过的赢家可用，先试它。
            // CF 自有域名是 pass-through（`shouldMITM` 为 false），不带 linux.do 的 ECH 钥匙。
            if !sawUpstreamData,
               let tlsPort = NWEndpoint.Port(rawValue: 443),
               connectViaCloudflareEdge(
                   host: hostname,
                   upstreamPort: tlsPort,
                   client: client,
                   bufferedClientData: hello,
                   readyReply: readyReply,
                   useMITM: false,
                   replayHello: hello,
                   excluding: addresses
               ) {
                return
            }
            DohDebugLog.record("All DoH IPs RST TLS for \(hostname)")
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
        // `.defaultMessage` + `isComplete: true` 是 `send(content:completion:)` 的默认参数，
        // 也是 TCP 上推一段字节的标准写法，不会 FIN 连接（FIN 要用 `.finalMessage`）。
        // 以前这里用一条自定义的非 final ContentContext 配 `isComplete: false`，结果每个
        // 分片都被 Network.framework 留在本地缓冲：CONNECT 200 发不回去，客户端请求也
        // 推不到源站，整条 DoH 代理看着握手成功却一个字节都不通。
        connection.send(
            content: payload,
            contentContext: .defaultMessage,
            isComplete: true,
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
            ) { [weak self, weak client] ok in
                guard !ok, let self, let client else { return }
                self.reject(client, reason: "gateway tls")
            }
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
        originAddress: String,
        onHandshake: @escaping (Bool) -> Void = { _ in }
    ) {
        do {
            // Gateway rewrite is HTTP/1.1 origin-form. Do not offer h2.
            let origin = try OriginNIOClient(
                sni: request.host,
                applicationProtocols: H2MitmALPN.protocols(h2Enabled: false),
                echConfig: echConfig
            )
            let needsPipe = originClients[ObjectIdentifier(client)] == nil
            originClients[ObjectIdentifier(client)] = origin
            DohDebugLog.record(
                "Gateway origin TLS NIOSSL \(request.host) \(originAddress) echInjected=\(origin.echInjected) echBytes=\(echConfig?.count ?? 0)"
            )
            startGatewayNIOOrigin(
                origin,
                client: client,
                upstream: upstream,
                request: request,
                originAddress: originAddress,
                pipeClient: needsPipe,
                onHandshake: onHandshake
            )
        } catch {
            DohDebugLog.record("Gateway origin TLS failed: \(error)")
            close(upstream)
            onHandshake(false)
        }
    }

    private func startGatewayNIOOrigin(
        _ origin: OriginNIOClient,
        client: NWConnection,
        upstream: NWConnection,
        request: DohGatewayHTTPRequest,
        originAddress: String,
        pipeClient: Bool,
        onHandshake: @escaping (Bool) -> Void
    ) {
            var loggedHello = false
            var loggedInbound = false
            var handshakeSettled = false
            let settleHandshake: (Bool) -> Void = { [weak self, weak origin] ok in
                guard let self, !handshakeSettled else { return }
                handshakeSettled = true
                if ok {
                    DohDebugLog.record(
                        "Gateway origin TLS ready \(request.host) \(originAddress) echAccepted=\(origin?.echAccepted == true)"
                    )
                } else {
                    // 服务端拒绝 ECH：当场收养它给的新钥匙，下一轮不用等 DNS 刷新。
                    if let retry = origin?.echRetryConfigs {
                        EchKeyStore.shared.adopt(retry, source: .retryConfigs)
                        DohDebugLog.record(
                            "Gateway origin ECH 被拒，收养服务端新钥匙 \(retry.count) 字节",
                            subsystem: "优选"
                        )
                    }
                    DohDebugLog.record(
                        "Gateway origin TLS failed \(request.host) \(originAddress): \(origin?.lastError ?? "unknown")"
                    )
                }
                onHandshake(ok)
            }
            let timeout = DispatchWorkItem { [weak self, weak upstream] in
                guard let self, let upstream else { return }
                DohDebugLog.record("Gateway origin TLS timeout \(request.host) \(originAddress)")
                self.close(upstream)
                settleHandshake(false)
            }
            queue.asyncAfter(deadline: .now() + 8, execute: timeout)
            origin.start(
                socketRead: { [weak self, weak upstream] deliver in
                    guard let self, let upstream else { return }
                    func receive() {
                        upstream.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                            if let data, !data.isEmpty {
                                if !loggedInbound {
                                    loggedInbound = true
                                    DohDebugLog.record(
                                        "Gateway origin inbound \(data.count) bytes from \(originAddress) first=\(Self.hexPrefix(data))"
                                    )
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
                                return
                            }
                            if let error {
                                DohDebugLog.record(
                                    "Gateway origin TCP read error \(originAddress): \(error)"
                                )
                                deliver(nil)
                                return
                            }
                            if isComplete {
                                deliver(nil)
                                return
                            }
                            receive()
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
                        let clearSNI = data.range(of: Data(request.host.utf8)) != nil
                        DohDebugLog.record(
                            "Gateway origin ClientHello \(data.count) bytes to \(request.host) sni_clear=\(clearSNI) echInjected=\(origin.echInjected)"
                        )
                    }
                    self.sendStreaming(upstream, content: data) { sendError in
                        if let sendError {
                            DohDebugLog.record(
                                "Gateway origin TCP write error \(originAddress): \(sendError)"
                            )
                        }
                        done()
                    }
                },
                appRead: { [weak self, weak client] plaintext in
                    guard let self, let client else { return }
                    self.sendStreaming(client, content: plaintext) { _ in }
                },
                completion: { _ in },
                onHandshake: { [weak self] ok in
                    timeout.cancel()
                    self?.queue.async {
                        settleHandshake(ok)
                    }
                },
                // 源站那头断了：让 `upstream.stateUpdateHandler` 走 cancelled/failed
                // 分支去换下一个地址，而不是把客户端挂在一个已经死掉的响应上。
                onSocketClosed: { [weak self, weak upstream] in
                    guard let self, let upstream else { return }
                    self.queue.async {
                        DohDebugLog.record("Gateway origin 关闭 \(request.host) \(originAddress)")
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
            if pipeClient {
                pipeGatewayClient(client)
            }
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

    /// 网关路径用优选赢家直连验证页依赖的 CF 域名。
    /// 调用方已确认 host 适用且赢家存在；这里只负责记日志并入队。
    private func enqueueGatewayAtCloudflareEdge(
        _ edge: String,
        request: DohGatewayHTTPRequest,
        client: NWConnection
    ) {
        DohDebugLog.record(
            "Resolve unavailable for \(request.host); using Cloudflare edge \(edge)",
            subsystem: "优选"
        )
        enqueueGatewayOrigin {
            // 赢家自己失败时不再兜底，直接走 reject。
            self.connectGatewayOriginTCP(
                addresses: [edge],
                index: 0,
                request: request,
                client: client,
                echConfig: nil,
                allowEdgeFallback: false
            )
        }
    }

    /// Raw TCP to the DoH-resolved origin IP, then NIO TLS with ECH.
    /// Network.framework TLS to the hostname sends a clear `SNI=linux.do` and is RST.
    private func connectGatewayOriginTCP(
        addresses: [String],
        index: Int,
        request: DohGatewayHTTPRequest,
        client: NWConnection,
        echConfig: Data?,
        /// 地址全部失败时是否允许退到优选赢家。赢家自己失败时传 false，防止递归。
        allowEdgeFallback: Bool = true,
        /// 地址全部失败时的接管者（例如「赢家直连失败 → 回到 DoH 解析」）。
        /// 调用方负责收尾（归还网关并发槽 / reject）。
        onExhausted: (() -> Void)? = nil
    ) {
        guard index < addresses.count,
              let port = NWEndpoint.Port(rawValue: request.port)
        else {
            if let onExhausted {
                onExhausted()
                return
            }
            // 解析成功但地址全连不上，和解析失败一样：验证页依赖的 CF 域名还有
            // 竞速验证过的赢家可用，先试它，再决定 reject。
            if allowEdgeFallback,
               let edge = cloudflareEdgeFallbackAddress(for: request.host, excluding: addresses) {
                DohDebugLog.record(
                    "Resolve unavailable for \(request.host); using Cloudflare edge \(edge)",
                    subsystem: "优选"
                )
                // 不调 `completeGatewayOrigin()`：仍是同一笔请求，继续占用并发配额。
                connectGatewayOriginTCP(
                    addresses: [edge],
                    index: 0,
                    request: request,
                    client: client,
                    echConfig: nil,
                    allowEdgeFallback: false
                )
                return
            }
            completeGatewayOrigin()
            DohDebugLog.record("Gateway origin TCP gave up \(request.host)")
            reject(client, reason: "gateway tls")
            return
        }

        let target = addresses[index]
        DohDebugLog.record("Gateway origin TCP \(target):\(port.rawValue) \(request.host)")
        let upstream = NWConnection(
            host: Self.endpointHost(from: target),
            port: port,
            using: Self.streamTCPParameters()
        )
        connections[ObjectIdentifier(upstream)] = upstream
        let gate = HandshakeGate()
        let timeout = DispatchWorkItem { [weak upstream] in
            guard let upstream else { return }
            DohDebugLog.record("Gateway origin TCP timeout \(target)")
            PreferredNodeStore.shared.reportOutcome(host: request.host, ip: target, success: false)
            upstream.cancel()
        }
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        upstream.stateUpdateHandler = { [weak self, weak upstream, weak client] state in
            guard let self, let upstream else { return }
            switch state {
            case .waiting(let error):
                guard Self.isUnreachableNetworkError(error) else {
                    DohDebugLog.record("Gateway origin TCP waiting \(target): \(error)")
                    if gate.hasSettled {
                        self.armStallWatchdog(upstream, label: "\(target):\(port.rawValue)")
                    }
                    return
                }
                // 网关模式同样会遇到 IPv6-only 域名：这张网卡连 IPv6 地址立刻
                // ENETDOWN，等看门狗只是白等，直接换下一个地址。
                DohDebugLog.record(
                    "Gateway origin TCP unreachable \(target):\(port.rawValue) \(error), trying next"
                )
                timeout.cancel()
                self.cancelStallWatchdog(upstream)
                self.connections.removeValue(forKey: ObjectIdentifier(upstream))
                PreferredNodeStore.shared.reportOutcome(host: request.host, ip: target, success: false)
                // 必须先摘掉回调再 cancel：`.cancelled` 分支把「gate 已结算」
                // 解释成「握手后的响应丢了，客户端不能干等」。而这里换地址时
                // gate 会先结算一次，迟到的 `.cancelled` 若还走那条路，就会把
                // 正在重试的客户端当场关掉，换地址等于没做。
                upstream.stateUpdateHandler = nil
                upstream.cancel()
                if gate.hasSettled {
                    // 握手已过：这条响应不会再回来了，客户端不能干等。
                    self.close(client)
                    return
                }
                gate.settle {
                    guard let client else {
                        self.completeGatewayOrigin()
                        return
                    }
                    self.connectGatewayOriginTCP(
                        addresses: addresses,
                        index: index + 1,
                        request: request,
                        client: client,
                        echConfig: echConfig,
                        allowEdgeFallback: allowEdgeFallback,
                        onExhausted: onExhausted
                    )
                }
            case .ready:
                self.cancelStallWatchdog(upstream)
                gate.settle {
                    timeout.cancel()
                    DohDebugLog.record("Gateway origin TCP ready \(target)")
                    guard let client else {
                        self.completeGatewayOrigin()
                        self.close(upstream)
                        return
                    }
                    self.startGatewayOrigin(
                        client: client,
                        upstream: upstream,
                        request: request,
                        echConfig: echConfig,
                        originAddress: target
                    ) { ok in
                        if ok {
                            // 网关到源站的 TLS/ECH 握手成功，这台边缘才算可用。
                            self.resolver.recordHostSuccess(host: request.host, ip: target)
                            PreferredNodeStore.shared.reportOutcome(
                                host: request.host,
                                ip: target,
                                success: true
                            )
                            self.completeGatewayOrigin()
                            return
                        }
                        // TCP 通了但网关 TLS/ECH 失败：这台边缘同样不可用。
                        PreferredNodeStore.shared.reportOutcome(host: request.host, ip: target, success: false)
                        self.resolver.recordHostFailure(host: request.host, ip: target)
                        self.close(upstream)
                        self.connectGatewayOriginTCP(
                            addresses: addresses,
                            index: index + 1,
                            request: request,
                            client: client,
                            echConfig: echConfig,
                            allowEdgeFallback: allowEdgeFallback,
                            onExhausted: onExhausted
                        )
                    }
                }
            case .failed(let error):
                timeout.cancel()
                self.cancelStallWatchdog(upstream)
                self.connections.removeValue(forKey: ObjectIdentifier(upstream))
                DohDebugLog.record("Gateway origin TCP error \(target): \(error)")
                PreferredNodeStore.shared.reportOutcome(host: request.host, ip: target, success: false)
                if gate.hasSettled {
                    // 握手/请求已经过完，这条响应不会再回来了。网关模式下客户端不会
                    // 自己失败，只会干等到自己的请求超时（图片 15 秒），必须一起收掉。
                    self.close(client)
                    return
                }
                gate.settle {
                    guard let client else {
                        self.completeGatewayOrigin()
                        return
                    }
                    self.connectGatewayOriginTCP(
                        addresses: addresses,
                        index: index + 1,
                        request: request,
                        client: client,
                        echConfig: echConfig,
                        allowEdgeFallback: allowEdgeFallback,
                        onExhausted: onExhausted
                    )
                }
            case .cancelled:
                timeout.cancel()
                self.cancelStallWatchdog(upstream)
                self.connections.removeValue(forKey: ObjectIdentifier(upstream))
                if gate.hasSettled {
                    // 同上：上游事后被收掉（watchdog / 换网 / 边缘回收），
                    // 客户端也必须看到连接断开，否则它会一直等到自身超时。
                    self.close(client)
                    return
                }
                gate.settle {
                    DohDebugLog.record("Gateway origin TCP failed \(target), trying next")
                    PreferredNodeStore.shared.reportOutcome(host: request.host, ip: target, success: false)
                    guard let client else {
                        self.completeGatewayOrigin()
                        return
                    }
                    self.connectGatewayOriginTCP(
                        addresses: addresses,
                        index: index + 1,
                        request: request,
                        client: client,
                        echConfig: echConfig,
                        allowEdgeFallback: allowEdgeFallback,
                        onExhausted: onExhausted
                    )
                }
            default:
                break
            }
        }
        upstream.start(queue: queue)
    }

    private func pipeGatewayClient(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            guard let origin = self.originClients[ObjectIdentifier(client)] else { return }
            if let data, !data.isEmpty {
                origin.writeApplication(data) { _, _ in }
                self.pipeGatewayClient(client)
                return
            }
            if error != nil || isComplete { return }
            self.pipeGatewayClient(client)
        }
    }

    private func openGateway(_ request: DohGatewayHTTPRequest, client: NWConnection) {
        let request = resolvedGatewayRequest(request)

        // 优选赢家 + 随赢家落盘的 ECH 钥匙：直接连，连 linux.do 的 DNS 都不查。
        let hasUpstream = config.upstream?.isValid == true
        if !hasUpstream,
           let pinned = PreferredNodeStore.shared.pinnedAddress(forHost: request.host),
           let ech = PreferredNodeStore.shared.node?.echConfig, !ech.isEmpty {
            DohDebugLog.record("优选直连 \(request.host) -> \(pinned)（不查 DNS）", subsystem: "优选")
            enqueueGatewayOrigin {
                self.connectGatewayOriginTCP(
                    addresses: [pinned],
                    index: 0,
                    request: request,
                    client: client,
                    echConfig: ech
                )
            }
            return
        }

        // CF 自家域名（验证页 Turnstile / CDN 图）同样直接走赢家，不等 DoH：
        // 网关只有 2 个并发槽，一次解析超时是 8 秒，一帖几张图就是几十秒白屏。
        if !hasUpstream,
           Self.isCloudflareHostedRegardlessOfDNS(request.host),
           let edge = PreferredNodeStore.shared.cloudflareEdgeAddress() {
            DohDebugLog.record(
                "Cloudflare host \(request.host): using edge \(edge) without DNS",
                subsystem: "优选"
            )
            enqueueGatewayOrigin {
                self.connectGatewayOriginTCP(
                    addresses: [edge],
                    index: 0,
                    request: request,
                    client: client,
                    echConfig: nil,
                    allowEdgeFallback: false,
                    onExhausted: { [weak self, weak client] in
                        guard let self, let client else { return }
                        // 这一槽还没归还：先 complete 再重新入队，别让并发配额泄漏。
                        self.completeGatewayOrigin()
                        DohDebugLog.record(
                            "Cloudflare edge failed for \(request.host); falling back to DoH"
                        )
                        self.openGatewayViaDoH(
                            request,
                            client: client,
                            allowEdgeFallback: false
                        )
                    }
                )
            }
            return
        }

        openGatewayViaDoH(request, client: client, allowEdgeFallback: true)
    }

    /// 网关模式的 DoH 解析路径。`allowEdgeFallback` 为 false 表示已经试过赢家。
    private func openGatewayViaDoH(
        _ request: DohGatewayHTTPRequest,
        client: NWConnection,
        allowEdgeFallback: Bool
    ) {
        let hasUpstream = config.upstream?.isValid == true
        resolver.resolve(host: request.host) { [weak self, weak client] result in
            guard let self, let client else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    DohDebugLog.record("Gateway resolve failed \(request.host): \(error)")
                    // 验证页依赖的 CF 域名解析不出来时，优选赢家仍然可用（任何 CF 边缘
                    // 都服务所有 CF zone）；否则 Turnstile iframe 直接起不来。
                    // 配了 upstream 时不绕开它，照旧 reject。
                    if allowEdgeFallback, !hasUpstream,
                       let edge = self.cloudflareEdgeFallbackAddress(for: request.host) {
                        self.enqueueGatewayAtCloudflareEdge(edge, request: request, client: client)
                        return
                    }
                    self.reject(client, reason: "resolve failed")
                case .success(let answer):
                    let resolved = Self.preferredUpstreamAddresses(answer.addresses)
                    let addresses: [String]
                    if let pinned = PreferredNodeStore.shared.pinnedAddress(forHost: request.host) {
                        // 优选赢家先连（保证 CF 看到的出口 IP 不变），解析结果排在后面当回退。
                        let rest = resolved.filter { $0 != pinned }
                        addresses = [pinned] + rest
                        DohDebugLog.record(
                            "优选钉住 \(request.host) -> \(pinned)（回退 \(rest.count) 个）",
                            subsystem: "优选"
                        )
                    } else {
                        addresses = resolved
                    }
                    guard !addresses.isEmpty else {
                        // 应答全被过滤（投毒/假地址）时同样退到赢家，别让验证页 iframe 起不来。
                        if allowEdgeFallback, !hasUpstream,
                           let edge = self.cloudflareEdgeFallbackAddress(for: request.host) {
                            self.enqueueGatewayAtCloudflareEdge(edge, request: request, client: client)
                            return
                        }
                        self.reject(client, reason: "empty resolved address")
                        return
                    }
                    DohDebugLog.record("Gateway resolved \(request.host) -> \(addresses.joined(separator: ", "))")
                    if let ech = answer.echConfig, !ech.isEmpty {
                        DohDebugLog.record("Gateway ECH config \(ech.count) bytes")
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
                        self.connectGatewayOriginTCP(
                            addresses: addresses,
                            index: 0,
                            request: request,
                            client: client,
                            echConfig: answer.echConfig,
                            allowEdgeFallback: allowEdgeFallback
                        )
                    }
                }
            }
        }
    }

    /// WKWebView can only attach the CONNECT proxy via `proxyConfigurations` (iOS 17+).
    /// iOS 16 loads the CF challenge through Gateway loopback HTTP instead.
    static var supportsWebViewCONNECTProxy: Bool {
        if #available(iOS 17.0, *) { return true }
        return false
    }

    /// Kept for diagnostics. Encrypted DNS does not follow system A/AAAA for linux.do.
    static var systemNameResolutionBlockedLinuxDo = false

    static var usesWebViewHTTPTransport: Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return false
        }
        return UserDefaults.standard.bool(forKey: "dohEnabled")
            && !supportsWebViewCONNECTProxy
            && preferSafariWebViewHTTP
    }

    static func refreshSystemNameResolutionHealth() {
        // 只读缓存：这里只做健康判断，不能为了看一眼 DNS 就把调用线程（可能是
        // 主线程）卡在一次 `getaddrinfo` 上。
        let ips = DohBootstrapTransport.cachedSystemAddresses(for: "linux.do")
        systemNameResolutionBlockedLinuxDo = isPoisonedLinuxDoAddresses(ips)
        if systemNameResolutionBlockedLinuxDo {
            DohDebugLog.record(
                "system DNS linux.do poisoned \(ips.joined(separator: ",")); Encrypted DNS stays on"
            )
        } else if !ips.isEmpty {
            DohDebugLog.record("system DNS linux.do \(ips.prefix(4).joined(separator: ","))")
        }
    }

    static func abandonWebViewHTTPTransport(reason: String) {
        guard !supportsWebViewCONNECTProxy else { return }
        DohDebugLog.record("DoH iOS16 WebView HTTP retry reason=\(reason)")
    }

    static func enableSafariWebViewHTTPAfterChallenge() {
        guard !supportsWebViewCONNECTProxy else { return }
        preferSafariWebViewHTTP = false
        DohDebugLog.record("DoH stay on Encrypted DNS after Turnstile")
    }

    static func isPoisonedLinuxDoAddresses(_ ips: [String]) -> Bool {
        let trimmed = ips.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains(where: EncryptedDnsService.isTunnelFakeIP) { return true }
        if trimmed.contains(where: isFacebookOrGarbageAddress) { return true }
        if trimmed.contains(where: isCloudflareishAddress) { return false }
        return true
    }

    static func isFacebookOrGarbageAddress(_ ip: String) -> Bool {
        let value = ip.lowercased()
        if value.contains("face:b00c") { return true }
        if value.hasPrefix("2a03:2880:") { return true }
        if value.hasPrefix("31.13.") { return true }
        if value.hasPrefix("157.240.") { return true }
        if value.hasPrefix("69.171.") { return true }
        if value.hasPrefix("173.252.") { return true }
        return false
    }

    static func isCloudflareishAddress(_ ip: String) -> Bool {
        let value = ip.lowercased()
        if value.hasPrefix("2606:4700:") { return true }
        if value.hasPrefix("2803:f800:") { return true }
        if value.hasPrefix("2400:cb00:") { return true }
        if value.hasPrefix("2405:b500:") { return true }
        if value.hasPrefix("2405:8100:") { return true }
        if value.hasPrefix("2a06:98c1:") { return true }
        if value.hasPrefix("2c0f:f248:") { return true }
        guard let ipv4 = IPv4Address(value) else { return false }
        let bytes = [UInt8](ipv4.rawValue)
        guard bytes.count >= 2 else { return false }
        let a = Int(bytes[0])
        let b = Int(bytes[1])
        if a == 104, (16...31).contains(b) { return true }
        if a == 172, (64...71).contains(b) { return true }
        if a == 162, b == 158 { return true }
        if a == 188, b == 114 { return true }
        if a == 108, b == 162 { return true }
        if a == 141, b == 101 { return true }
        if a == 198, b == 41 { return true }
        if a == 197, b == 234 { return true }
        if a == 190, b == 93 { return true }
        if a == 173, b == 245 { return true }
        return false
    }

    /// Origin ECH / Gateway MITM. Off restores the v1.8.4 Encrypted DNS path:
    /// URLSession uses system TLS to DoH-resolved IPs, so existing `cf_clearance`
    /// works and linux.do does not need a Turnstile hop.
    ///
    /// 由「连接方式」设置在 `configureFromSettings` 里驱动；运行时回退后不再自动切回。
    static var originECHReady = false

    /// 运行时回退过（例如 WebView 过盾后）。为真时即使设置要求本地 ECH 也不切回来，
    /// 直到用户在设置里重新选一次连接方式。
    static var runtimeECHEscaped = false

    /// Hidden WKWebView JSON. Off: pass-through CONNECT RSTs linux.do TLS.
    static var preferSafariWebViewHTTP = false

    /// Forum host used when WKWebView talks HTTP to 127.0.0.1 without `Host`.
    static var gatewayOriginHost = "linux.do"

    static func isLoopbackGatewayHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1"
            || normalized == "localhost"
            || normalized == "::1"
    }

    private func resolvedGatewayRequest(_ request: DohGatewayHTTPRequest) -> DohGatewayHTTPRequest {
        guard Self.isLoopbackGatewayHost(request.host) else { return request }
        let origin = Self.gatewayOriginHost
        let rewritten = request.withOriginHost(origin)
        DohDebugLog.record("Gateway loopback Host \(request.host) -> \(origin)")
        return rewritten
    }

    /// 验证页离不开、而且确定托管在 Cloudflare 上的域名。
    /// 这些域名一旦解析失败，验证页的 Turnstile iframe 就起不来——宁可直连 CF 边缘也不能 reject。
    private static func isCloudflareHostedRegardlessOfDNS(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "challenges.cloudflare.com"
            || normalized.hasSuffix(".challenges.cloudflare.com") { return true }
        if normalized == "ldstatic.com" || normalized.hasSuffix(".ldstatic.com") { return true }
        return false
    }

    static func shouldMITM(_ host: String) -> Bool {
        guard originECHReady else { return false }
        // 只对需要「藏 SNI」的站点做 MITM，也就是 linux.do 及其子域。
        //
        // 之前是「除 challenges.cloudflare.com 以外全 MITM」，结果 CDN（cdn*.ldstatic.com）
        // 也被换成我们自签的叶子证书：`FluxDoMitmTrustManager` 只挂在 DiscourseAPI 的
        // Alamofire session 上，SDWebImage 的下载 session 没有它，图片全卡在证书校验，
        // 表现就是「CDN 不通」。这些域名没被墙，直通隧道让客户端自己验真证书即可。
        return PreferredNodeStore.isCoveredHost(host)
    }

    static var shouldSwitchToSystemTLSAfterWebViewClearance: Bool {
        originECHReady && !supportsWebViewCONNECTProxy
    }

    static func switchToSystemTLSAfterWebViewClearance() {
        guard originECHReady else { return }
        originECHReady = false
        runtimeECHEscaped = true
        preferSafariWebViewHTTP = false
        DohDebugLog.record("DoH restore Encrypted DNS after WebView CF pass")
        LightweightDohProxyService.shared.forceReapplyFromSettings()
    }

    private static func hexPrefix(_ data: Data, limit: Int = 16) -> String {
        data.prefix(limit)
            .map { String(format: "%02x", $0) }
            .joined(separator: " ")
    }

    /// 地址族在当前网卡上根本不可达（典型：域名只有 AAAA，Wi‑Fi 却只给了 IPv4，
    /// 连 `2606:...` 立刻 `ENETDOWN`）。这种 `.waiting` 不会自己好，等看门狗
    /// 只是白等 8 秒，必须立刻换下一个地址。
    private static func isUnreachableNetworkError(_ error: NWError) -> Bool {
        guard case .posix(let code) = error else { return false }
        switch code {
        case .EAFNOSUPPORT, .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH:
            return true
        default:
            return false
        }
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

    /// 轮转除首个以外的地址。
    ///
    /// 解析器已经把「上次连通过的粘性 IP / 未被惩罚的 IP」排在最前面，连它一起
    /// 轮转等于每次建连都换一个 Cloudflare 边缘，粘性就白记了（clearance 也跟
    /// 出口 IP 走）。首地址稳定，其余地址轮转用来分散负载、避开被投毒的那些。
    private func rotatedAddresses(for host: String, addresses: [String]) -> [String] {
        guard let preferred = addresses.first else { return [] }
        let rest = Array(addresses.dropFirst())
        guard !rest.isEmpty else { return addresses }
        let offset = hostAttemptOffsets[host, default: 0]
        hostAttemptOffsets[host] = offset + 1
        if hostAttemptOffsets.count > 512 { hostAttemptOffsets.removeAll() }
        let start = offset % rest.count
        return [preferred] + Array(rest[start...]) + Array(rest[..<start])
    }

    private func close(_ connection: NWConnection?) {
        guard let connection else { return }
        let id = ObjectIdentifier(connection)
        cancelStallWatchdog(connection)
        connections.removeValue(forKey: id)
        ssSessions.removeValue(forKey: id)
        originClients.removeValue(forKey: id)
        mitmBridges.removeValue(forKey: id)
        connection.cancel()
    }
}

private final class HandshakeGate {
    private var settled = false

    var hasSettled: Bool { settled }

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
