import Foundation
import Network

/// 带 keep-alive 复用的最小 HTTP/1.1 客户端（只发 POST，只收一条响应）。
///
/// 解析一次域名要打三个查询（A / AAAA / HTTPS），此前每条查询都新开一条
/// TCP + TLS（`Connection: close`），冷启动就是三次握手。这里按
/// (bootstrap IP, SNI, 端口) 复用连接：同一次解析的后两个查询直接跑在已经
/// 握好手的连接上，TTL 到期重解析也不用再握手。
///
/// 全部状态只在这条串行队列上，调用方给的 `queue` 只用来回投 completion。
final class DohHTTPClient {
    static let shared = DohHTTPClient()

    struct ConnectionKey: Hashable {
        let ip: String
        let host: String
        let port: UInt16
    }

    /// 空闲连接上限。CF / 公共 DoH 一般只需要一两条，留点余量给多端点场景。
    private static let maxIdleConnections = 8
    /// 空闲这么久就关掉，别让 iOS 的无线电为一条没用的连接保活。
    private static let idleTimeout: TimeInterval = 20
    /// 单条连接上的单次请求超时。
    private static let requestTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "doer.doh.http-client")
    private var idle: [ConnectionKey: (connection: NWConnection, lastUsed: Date)] = [:]
    private var cleanupScheduled = false

    private init() {}

    /// 关闭所有空闲连接（换服务器、清缓存时用）。
    func closeIdleConnections() {
        queue.async { [self] in
            let connections = idle.values.map(\.connection)
            idle.removeAll()
            connections.forEach { $0.cancel() }
        }
    }

    /// 经 `ip` 向 `host` 发一个 POST，TLS SNI 是 `host`。
    ///
    /// `completion` 在调用方 `callbackQueue` 上回调。连接复用失败（对端已关、
    /// 帧读不完整）会自动换一条新连接重试一次。
    func post(
        ip: String,
        host: String,
        port: UInt16,
        path: String,
        body: Data,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let key = ConnectionKey(ip: ip, host: host, port: port)
        let request = Self.makeRequest(host: host, path: path, body: body)

        queue.async { [self] in
            let reused = idle.removeValue(forKey: key)?.connection
            perform(
                key: key,
                existing: reused,
                host: host,
                port: port,
                request: request,
                callbackQueue: callbackQueue,
                completion: completion
            )
        }
    }

    // MARK: - 单次往返

    private func perform(
        key: ConnectionKey,
        existing: NWConnection?,
        host: String,
        port: UInt16,
        request: Data,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let connection: NWConnection
        let reused: Bool
        if let existing {
            if existing.state == .ready {
                connection = existing
                reused = true
            } else {
                // 池里的连接已经断了（服务端回收、空闲超时），换新的。
                existing.stateUpdateHandler = nil
                existing.cancel()
                guard let fresh = makeConnection(ip: key.ip, host: host, port: port) else {
                    callbackQueue.async { completion(.failure(DohProxyError.bootstrapUnavailable(host))) }
                    return
                }
                connection = fresh
                reused = false
            }
        } else {
            guard let fresh = makeConnection(ip: key.ip, host: host, port: port) else {
                callbackQueue.async { completion(.failure(DohProxyError.bootstrapUnavailable(host))) }
                return
            }
            connection = fresh
            reused = false
        }
        var finished = false
        var buffer = Data()
        var timeout: DispatchWorkItem!

        func deliver(_ result: Result<Data, Error>, keepConnection: Bool) {
            guard !finished else { return }
            finished = true
            timeout?.cancel()
            if keepConnection {
                store(key: key, connection: connection)
            } else {
                connection.cancel()
            }
            callbackQueue.async { completion(result) }
        }

        timeout = DispatchWorkItem {
            deliver(.failure(DohProxyError.queryFailed("timeout \(key.ip)")), keepConnection: false)
        }

        /// 复用连接时对端可能已经悄悄关掉了（空闲超时、服务端回收）。
        /// 这种情况一条新连接就能解决，不要把它算成这次解析的失败。
        func failOrRetry(_ error: Error) {
            guard !finished else { return }
            if reused {
                finished = true
                timeout.cancel()
                connection.cancel()
                perform(
                    key: key,
                    existing: nil,
                    host: host,
                    port: port,
                    request: request,
                    callbackQueue: callbackQueue,
                    completion: completion
                )
                return
            }
            deliver(.failure(error), keepConnection: false)
        }

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    do {
                        if let message = try DohHTTPWire.parseMessage(buffer) {
                            let keepAlive = message.consumed == buffer.count
                                && !message.closeConnection
                            deliver(.success(message.body), keepConnection: keepAlive)
                            return
                        }
                    } catch {
                        failOrRetry(error)
                        return
                    }
                }
                if let error {
                    failOrRetry(error)
                    return
                }
                if isComplete {
                    failOrRetry(DohProxyError.queryFailed("closed \(key.ip)"))
                    return
                }
                receiveMore()
            }
        }

        let send = {
            connection.send(
                content: request,
                contentContext: NWConnection.ContentContext(identifier: "doer.doh.bootstrap", isFinal: false),
                isComplete: false,
                completion: .contentProcessed { error in
                    if let error {
                        failOrRetry(error)
                        return
                    }
                    receiveMore()
                }
            )
        }

        if reused {
            send()
        } else {
            var didSend = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didSend else { return }
                    didSend = true
                    send()
                case .waiting:
                    // 路由暂时不可达时交给超时处理：错峰并发已经让别的地址
                    // 同时在试，这里不必立刻判负。
                    break
                case .failed(let error):
                    failOrRetry(error)
                case .cancelled:
                    failOrRetry(DohProxyError.queryFailed("cancelled \(key.ip)"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        queue.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
    }

    // MARK: - 连接与池

    private func makeConnection(ip: String, host: String, port: UInt16) -> NWConnection? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let tls = NWProtocolTLS.Options()
        host.withCString { pointer in
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, pointer)
        }
        // 锁死 HTTP/1.1：Cloudflare 的 h2 在部分出口上会直接卡住。
        "http/1.1".withCString { pointer in
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, pointer)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        return NWConnection(host: Self.endpointHost(ip), port: endpointPort, using: parameters)
    }

    private func store(key: ConnectionKey, connection: NWConnection) {
        // 这次请求的回调已经用完了，别让连接上的状态回调再引用它。
        connection.stateUpdateHandler = nil
        // 同一个 key 并发两条请求时会各握一条连接，先到的留着，后到的关掉。
        if let existing = idle[key]?.connection, existing !== connection {
            existing.cancel()
        }
        idle[key] = (connection, Date())
        if idle.count > Self.maxIdleConnections {
            // 丢掉最早空闲的那条。
            if let oldest = idle.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                idle.removeValue(forKey: oldest)?.connection.cancel()
            }
        }
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        guard !cleanupScheduled else { return }
        cleanupScheduled = true
        queue.asyncAfter(deadline: .now() + Self.idleTimeout) { [self] in
            cleanupScheduled = false
            let now = Date()
            let stale = idle.filter { now.timeIntervalSince($0.value.lastUsed) >= Self.idleTimeout }
            idle = idle.filter { now.timeIntervalSince($0.value.lastUsed) < Self.idleTimeout }
            stale.values.forEach { $0.connection.cancel() }
            if !idle.isEmpty { scheduleCleanup() }
        }
    }

    private static func makeRequest(host: String, path: String, body: Data) -> Data {
        let header = [
            "POST \(path) HTTP/1.1",
            "Host: \(host)",
            "Accept: application/dns-message",
            "Content-Type: application/dns-message",
            "Content-Length: \(body.count)",
            "Connection: keep-alive",
            "",
            "",
        ].joined(separator: "\r\n")
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    static func endpointHost(_ address: String) -> NWEndpoint.Host {
        if let ipv4 = IPv4Address(address) {
            return .ipv4(ipv4)
        }
        if let ipv6 = IPv6Address(address) {
            return .ipv6(ipv6)
        }
        return .name(address, nil)
    }
}
