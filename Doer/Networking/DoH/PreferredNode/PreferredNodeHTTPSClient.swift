import DohProxy
import Foundation
import Network

nonisolated enum PreferredNodeHTTPFailure: Error, Equatable, Sendable {
    case tcpConnect
    case tcpTimeout
    case tlsTimeout
    case tls(String)
    /// 服务端拒绝了 ECH。带 retry_configs 时可以当场换钥匙重试。
    case echRejected(retryConfigs: Data?)
    case httpTimeout
    case http(String)

    var description: String {
        switch self {
        case .tcpConnect: return "tcp connect failed"
        case .tcpTimeout: return "tcp timeout"
        case .tlsTimeout: return "tls timeout"
        case .tls(let detail): return "tls: \(detail)"
        case .echRejected(let retryConfigs):
            return "ech rejected (\(retryConfigs.map { "retry_configs \($0.count) bytes" } ?? "no retry_configs"))"
        case .httpTimeout: return "http timeout"
        case .http(let detail): return "http: \(detail)"
        }
    }
}

nonisolated struct PreferredNodeHTTPReply: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data
    /// 从 TCP 发起到拿到状态行的墙钟时间（毫秒）
    var latencyMs: Int
    var echAccepted: Bool

    var retryAfterSeconds: Int? {
        headers["retry-after"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(Int.init)
    }
}

/// 经指定 IP + ECH 发一个 HTTP/1.1 请求的小客户端。
///
/// 链路：TCP → TLS 1.3 + ECH（内层 SNI 为 `host`）→ 一个 HTTP/1.1 请求。
/// `/cdn-cgi/trace` 探测与 atlas 拉表共用这条链路（对应 Rust `probe::tls_connect` + `h1_request`）。
///
/// 这里绝不打印 ECH 钥匙字节、请求头和正文。
nonisolated final class PreferredNodeHTTPSClient: @unchecked Sendable {

    /// 三段超时：TCP 建连、TLS 握手、HTTP 往返。
    struct Timeouts: Sendable {
        var tcp: TimeInterval = 2
        var tls: TimeInterval = 3
        var http: TimeInterval = 2

        static let `default` = Timeouts()
    }

    /// 探测与小请求共用的 User-Agent：安卓上最常见的 HTTP 库。
    static let userAgent = "okhttp/4.12.0"

    private static let queue = DispatchQueue(
        label: "doer.preferred-node.http",
        attributes: .concurrent
    )

    private let timeouts: Timeouts
    private let echConfig: Data?

    init(echConfig: Data?, timeouts: Timeouts = .default) {
        self.echConfig = echConfig
        self.timeouts = timeouts
    }

    func request(
        ip: String,
        host: String,
        path: String,
        headers: [(String, String)] = [],
        maxBody: Int = 4096,
        completion: @escaping (Result<PreferredNodeHTTPReply, PreferredNodeHTTPFailure>) -> Void
    ) {
        guard let port = NWEndpoint.Port(rawValue: 443) else { return }
        let start = Date()
        let lock = NSLock()
        var finished = false
        var echAccepted = false

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        if #available(iOS 16.0, *) {
            parameters.preferNoProxies = true
        }

        let connection = NWConnection(host: Self.endpointHost(from: ip), port: port, using: parameters)
        var buffer = Data()

        func finish(_ result: Result<PreferredNodeHTTPReply, PreferredNodeHTTPFailure>) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            lock.unlock()
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }

        func fail(_ failure: PreferredNodeHTTPFailure) {
            finish(.failure(failure))
        }

        /// 状态行 + 头，以及正文起始偏移。
        func parseHeaderBlock(_ data: Data) -> (status: Int, headers: [String: String], bodyOffset: Int)? {
            let separator = Data([13, 10, 13, 10])
            guard let range = data.range(of: separator) else { return nil }
            guard let text = String(data: data[data.startIndex ..< range.lowerBound], encoding: .ascii) else {
                return nil
            }
            let lines = text.components(separatedBy: "\r\n")
            guard let statusLine = lines.first else { return nil }
            let parts = statusLine.split(separator: " ")
            guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = String(line[line.startIndex ..< colon])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let value = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                headers[name] = value
            }
            return (status, headers, data.distance(from: data.startIndex, to: range.upperBound))
        }

        func latencyMs() -> Int {
            Int((Date().timeIntervalSince(start) * 1000).rounded())
        }

        func consume(_ data: Data) {
            buffer.append(data)
            guard let block = parseHeaderBlock(buffer) else {
                if buffer.count > maxBody { fail(.http("oversized header block")) }
                return
            }
            lock.lock()
            let accepted = echAccepted
            lock.unlock()

            if block.status != 200 {
                finish(.success(PreferredNodeHTTPReply(
                    status: block.status,
                    headers: block.headers,
                    body: Data(),
                    latencyMs: latencyMs(),
                    echAccepted: accepted
                )))
                return
            }

            let body: Data
            do {
                guard let extracted = try DohBootstrapTransport.httpBody(from: buffer, requireComplete: false) else {
                    // 正文尚未收全；超出上限就按已收到的部分收尾。
                    if buffer.count - block.bodyOffset >= maxBody {
                        fail(.http("oversized body"))
                    }
                    return
                }
                body = extracted
            } catch {
                fail(.http(String(describing: error)))
                return
            }
            finish(.success(PreferredNodeHTTPReply(
                status: block.status,
                headers: block.headers,
                body: body,
                latencyMs: latencyMs(),
                echAccepted: accepted
            )))
        }

        let tcpTimeout = DispatchWorkItem { fail(.tcpTimeout) }
        Self.queue.asyncAfter(deadline: .now() + timeouts.tcp, execute: tcpTimeout)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                tcpTimeout.cancel()
                guard !finished else { return }
                do {
                    let client = try OriginNIOClient(
                        sni: host,
                        applicationProtocols: ["http/1.1"],
                        echConfig: self.echConfig
                    )
                    let tlsTimeout = DispatchWorkItem { fail(.tlsTimeout) }
                    let httpTimeout = DispatchWorkItem { fail(.httpTimeout) }
                    Self.queue.asyncAfter(deadline: .now() + self.timeouts.tls, execute: tlsTimeout)

                    client.start(
                        socketRead: { deliver in
                            func receive() {
                                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                                    if let data, !data.isEmpty {
                                        deliver(data)
                                        return
                                    }
                                    if error != nil || isComplete {
                                        deliver(nil)
                                        return
                                    }
                                    receive()
                                }
                            }
                            receive()
                        },
                        socketWrite: { data, done in
                            connection.send(
                                content: data,
                                contentContext: NWConnection.ContentContext(
                                    identifier: "doer.preferred-node.http",
                                    isFinal: false
                                ),
                                isComplete: false,
                                completion: .contentProcessed { _ in done() }
                            )
                        },
                        appRead: { plaintext in
                            consume(plaintext)
                        },
                        completion: { _ in },
                        onHandshake: { ok in
                            tlsTimeout.cancel()
                            lock.lock()
                            echAccepted = client.echAccepted
                            lock.unlock()
                            guard ok else {
                                // 服务端拒绝 ECH 时会给出 retry_configs，调用方可以当场换钥匙重试。
                                if let retryConfigs = client.echRetryConfigs {
                                    fail(.echRejected(retryConfigs: retryConfigs))
                                } else {
                                    fail(.tls(client.lastError ?? "handshake failed"))
                                }
                                return
                            }
                            Self.queue.asyncAfter(deadline: .now() + self.timeouts.http, execute: httpTimeout)
                        }
                    )

                    client.writeApplication(Self.requestData(host: host, path: path, headers: headers)) { _, _ in }
                } catch {
                    fail(.tls(String(describing: error)))
                }
            case .failed:
                fail(.tcpConnect)
            case .cancelled:
                fail(.tcpConnect)
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
    }

    private static func requestData(host: String, path: String, headers: [(String, String)]) -> Data {
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)",
            "User-Agent: \(userAgent)",
            "Accept: */*",
            "Connection: close",
        ]
        lines.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
        lines.append("")
        lines.append("")
        return Data(lines.joined(separator: "\r\n").utf8)
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
}
