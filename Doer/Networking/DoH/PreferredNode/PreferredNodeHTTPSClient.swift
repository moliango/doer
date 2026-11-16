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
        // `NWConnection.start(queue:)` 要求**串行**队列。以前 30 个探针共用一条
        // `.concurrent` 队列，回调会在不同线程上并发跑，Network.framework 的
        // "不重入 / 有序投递" 保证失效——表现就是字节发出去了却永远读不到回包。
        // 每条探测独占一条串行队列，代价可以忽略。
        let workQueue = DispatchQueue(label: "doer.preferred-node.probe")
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
        /// 诊断用：这一次探测到底发出去多少、收回来多少。
        /// `http 超时` 分不出"请求根本没发出去"和"发出去了但没回"，这两个数字能。
        var sentBytes = 0
        var receivedBytes = 0
        /// 握手完成之后才发出去的应用数据，以及解密后的明文字节数。
        var appBytesSent = 0
        var plaintextBytes = 0
        var plaintextHead = ""
        var handshakeDone = false

        /// 三段超时都登记在这里，成功时统一取消。
        /// 不取消的话，已经拿到响应的探测会在 2 秒后再跑一次 `fail(.httpTimeout)`，
        /// 日志里就出现「赢家同时也是超时失败」这种自相矛盾的记录。
        var pendingTimeouts: [DispatchWorkItem] = []

        func finish(_ result: Result<PreferredNodeHTTPReply, PreferredNodeHTTPFailure>) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            let timeouts = pendingTimeouts
            pendingTimeouts = []
            lock.unlock()
            timeouts.forEach { $0.cancel() }
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion(result)
        }

        func fail(_ failure: PreferredNodeHTTPFailure) {
            lock.lock()
            let alreadyDone = finished
            lock.unlock()
            guard !alreadyDone else { return }
            if case .httpTimeout = failure {
                lock.lock()
                let sent = sentBytes
                let received = receivedBytes
                let appSent = appBytesSent
                let plain = plaintextBytes
                let head = plaintextHead
                lock.unlock()
                DohDebugLog.record(
                    "探测 \(ip)：TLS 已通但 \(Int(timeouts.http))s 内没有完整响应"
                        + "（发出 \(sent)B/应用 \(appSent)B，收回 \(received)B/明文 \(plain)B）"
                        + (head.isEmpty ? "" : "，首段「\(head)」"),
                    subsystem: "优选"
                )
            }
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

        func schedule(_ item: DispatchWorkItem, after seconds: TimeInterval) {
            lock.lock()
            let done = finished
            if !done { pendingTimeouts.append(item) }
            lock.unlock()
            guard !done else { return }
            workQueue.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        schedule(DispatchWorkItem { fail(.tcpTimeout) }, after: timeouts.tcp)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard !finished else { return }
                do {
                    let client = try OriginNIOClient(
                        sni: host,
                        applicationProtocols: ["http/1.1"],
                        echConfig: self.echConfig
                    )
                    let tlsTimeout = DispatchWorkItem { fail(.tlsTimeout) }
                    let httpTimeout = DispatchWorkItem { fail(.httpTimeout) }
                    schedule(tlsTimeout, after: self.timeouts.tls)

                    // 写路径必须**同一个**闭包传给 `start` 和 `writeApplication`：
                    // 握手已经完成时 `writeApplication` 会直接调用它把密文发出去，
                    // 传个空闭包就等于把请求扔掉——表现为"TLS 通了但 HTTP 一直超时"。
                    let socketWrite: (Data, @escaping () -> Void) -> Void = { data, done in
                        lock.lock()
                        sentBytes += data.count
                        if handshakeDone { appBytesSent += data.count }
                        lock.unlock()
                        connection.send(
                            content: data,
                            // 用默认消息上下文并把这一条标成完整：自定义 content context
                            // 配 `isComplete: false` 时，Network.framework 可能把数据留在
                            // 本地缓冲等后续片段，连接又一直开着，于是永远发不出去。
                            contentContext: .defaultMessage,
                            isComplete: true,
                            completion: .contentProcessed { _ in }
                        )
                        // `done` 必须立刻调，不能挂在 `.contentProcessed` 上：
                        // `OriginNIOClient` 的读循环是在 `socketWrite` 的 done 回调里
                        // 才挂下一次 `receive` 的，发送完成回调不来（真机上就遇到过），
                        // 读就永远停在那里——表现是"请求发出去了、响应一个字节都收不到"。
                        done()
                    }
                    let requestData = Self.requestData(host: host, path: path, headers: headers)

                    client.start(
                        socketRead: { deliver in
                            func receive() {
                                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                                    if let data, !data.isEmpty {
                                        lock.lock()
                                        receivedBytes += data.count
                                        lock.unlock()
                                        deliver(data)
                                        return
                                    }
                                    if error != nil || isComplete {
                                        // 连接被对端关掉时 `pumpSocket` 不会再挂下一次读，
                                        // 不在这里报错就只能干等 http 超时，日志里完全看不出
                                        // "服务端/中间盒 RST 了"还是"根本没回"。
                                        lock.lock()
                                        let handshook = handshakeDone
                                        lock.unlock()
                                        if handshook {
                                            let reason = error.map {
                                                "连接被关闭：\($0.localizedDescription)"
                                            } ?? "连接被对端关闭（握手后无响应）"
                                            fail(.http(reason))
                                        }
                                        deliver(nil)
                                        return
                                    }
                                    receive()
                                }
                            }
                            receive()
                        },
                        socketWrite: socketWrite,
                        appRead: { plaintext in
                            lock.lock()
                            plaintextBytes += plaintext.count
                            if plaintextHead.isEmpty {
                                plaintextHead = String(data: plaintext.prefix(120), encoding: .isoLatin1)?
                                    .replacingOccurrences(of: "\r\n", with: "⏎")
                                    ?? ""
                            }
                            lock.unlock()
                            consume(plaintext)
                        },
                        completion: { _ in },
                        onHandshake: { ok in
                            tlsTimeout.cancel()
                            lock.lock()
                            echAccepted = client.echAccepted
                            handshakeDone = true
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
                            schedule(httpTimeout, after: self.timeouts.http)
                            // 请求在**握手完成之后**才写：这样一定走 `writeApplication` 的直写分支，
                            // 不依赖 `pendingApplication` 那条"等下一次 ingest 才补发"的路径。
                            // 再 `async` 一下，让它排在本次 `flushOutbound`（发客户端 Finished）之后，
                            // 免得明文抢在握手最后一条记录前面上线路。
                            workQueue.async {
                                client.writeApplication(requestData, socketWrite: socketWrite)
                            }
                        }
                    )
                } catch {
                    fail(.tls(String(describing: error)))
                }
            case .failed:
                fail(.tcpConnect)
            case .cancelled:
                fail(.tcpConnect)
            case .waiting(let error):
                // 被 RST 时 NWConnection 走的是 `.waiting`，不是 `.failed`。
                // 以前这里被 `default` 吞掉，只能干等到 http 超时 ——
                // 日志里"TLS 通了但没有响应"其实多半就是被重置了。
                lock.lock()
                let handshook = handshakeDone
                lock.unlock()
                if handshook {
                    fail(.http("连接被重置：\(error)"))
                } else {
                    fail(.tcpConnect)
                }
            default:
                break
            }
        }
        connection.start(queue: workQueue)
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
