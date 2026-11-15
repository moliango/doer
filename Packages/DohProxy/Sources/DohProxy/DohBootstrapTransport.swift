import Darwin
import Foundation
import Network

/// DoH RFC 8484 POST over bootstrap IPs. TLS SNI is the DoH hostname.
/// ALPN is locked to HTTP/1.1 so Cloudflare cannot stall on h2.
public enum DohBootstrapTransport {
    public static var log: ((String) -> Void)?

    /// 相邻两个 bootstrap IP 的启动间隔。前一个 300ms 没连上就并行试下一个，
    /// 而不是死等满 5 秒超时——被墙 / 黑洞 IP 上这一条最省时间。
    private static let hedgeDelay: TimeInterval = 0.3
    /// 一轮查询的总预算。
    private static let raceTimeout: TimeInterval = 6
    /// 最多并行试几个地址，避免候选收集那种一次十几个端点的场景把连接数打爆。
    private static let maxHedgedAddresses = 3
    private static let systemAddressTTL: TimeInterval = 60

    private static let skipSystemLookupLock = NSLock()
    private static var skipSystemAddressLookupLocked = false

    /// When Apple Encrypted DNS is already required, `getaddrinfo` for the
    /// DoH hostname recurses through the same resolver and can stall ~30s.
    public static var skipSystemAddressLookup: Bool {
        get {
            skipSystemLookupLock.lock()
            defer { skipSystemLookupLock.unlock() }
            return skipSystemAddressLookupLocked
        }
        set {
            skipSystemLookupLock.lock()
            skipSystemAddressLookupLocked = newValue
            skipSystemLookupLock.unlock()
        }
    }

    /// Query one DoH endpoint over its bootstrap IPs.
    ///
    /// Public so app-layer code (Cloudflare preferred-node candidate gathering)
    /// can race several public resolvers without duplicating the TLS/HTTP plumbing.
    /// - Parameter quiet: suppress the per-IP `bootstrap connect/timeout` chatter.
    ///   Candidate gathering fans out over a dozen endpoints, and every unreachable
    ///   one walks its whole bootstrap list — that flood evicts the useful lines
    ///   from the 500-line in-app log.
    public static func query(
        endpoint: DohEndpoint,
        dnsQuery: Data,
        queue: DispatchQueue,
        quiet: Bool = false,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard endpoint.isReady else {
            completion(.failure(DohProxyError.bootstrapUnavailable(endpoint.url)))
            return
        }
        let logger: ((String) -> Void)? = quiet ? nil : log
        var addresses = endpoint.bootstrapIPs
        if !DohProxyConfig.looksLikeIPAddress(endpoint.host), !skipSystemAddressLookup {
            let resolved = systemAddresses(for: endpoint.host)
            if !resolved.isEmpty {
                logger?("DoH server \(endpoint.host) system DNS -> \(resolved.joined(separator: ", "))")
                var seen = Set<String>()
                let merged = (resolved + addresses).filter { seen.insert($0).inserted }
                let v4 = merged.filter { !$0.contains(":") }
                let v6 = merged.filter { $0.contains(":") }
                addresses = v4 + v6
            }
        }
        guard !addresses.isEmpty else {
            completion(.failure(DohProxyError.bootstrapUnavailable(endpoint.host)))
            return
        }
        race(
            addresses: Array(addresses.prefix(maxHedgedAddresses)),
            host: endpoint.host,
            port: endpoint.port,
            path: postPath(url: endpoint.url),
            dnsQuery: dnsQuery,
            queue: queue,
            logger: logger,
            completion: completion
        )
    }

    /// 错峰并发：第一个地址立刻开，之后每隔 `hedgeDelay` 再开一个，
    /// 谁先成功用谁。连接本身按 (IP, SNI) 复用，见 `DohHTTPClient`。
    private static func race(
        addresses: [String],
        host: String,
        port: UInt16,
        path: String,
        dnsQuery: Data,
        queue: DispatchQueue,
        logger: ((String) -> Void)?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let lock = NSLock()
        var settled = false
        var remaining = addresses.count
        var lastError: Error?

        func settle(_ result: Result<Data, Error>) {
            var deliver: Result<Data, Error>?
            lock.lock()
            if !settled {
                switch result {
                case .success:
                    settled = true
                    deliver = result
                case .failure(let error):
                    lastError = error
                    remaining -= 1
                    if remaining <= 0 {
                        settled = true
                        deliver = .failure(lastError ?? error)
                    }
                }
            }
            lock.unlock()
            guard let deliver else { return }
            queue.async { completion(deliver) }
        }

        for (index, ip) in addresses.enumerated() {
            queue.asyncAfter(deadline: .now() + Double(index) * hedgeDelay) {
                lock.lock()
                let alreadySettled = settled
                lock.unlock()
                guard !alreadySettled else { return }
                logger?("bootstrap connect \(ip) SNI=\(host)")
                DohHTTPClient.shared.post(
                    ip: ip,
                    host: host,
                    port: port,
                    path: path,
                    body: dnsQuery,
                    callbackQueue: queue
                ) { result in
                    switch result {
                    case .success(let body):
                        logger?("bootstrap ok \(ip) bytes=\(body.count)")
                        settle(.success(body))
                    case .failure(let error):
                        logger?("bootstrap failed \(ip): \(error.localizedDescription)")
                        settle(.failure(error))
                    }
                }
            }
        }

        queue.asyncAfter(deadline: .now() + raceTimeout) {
            settle(.failure(DohProxyError.queryFailed("timeout \(host):\(port)")))
        }
    }

    private static func postPath(url: String) -> String {
        let path = URL(string: url)?.path ?? ""
        return path.isEmpty ? "/dns-query" : path
    }

    /// Extract the HTTP/1.1 body from a raw response buffer.
    ///
    /// Public counterpart of the internal `DohHTTPWire.extractBody` so app-layer
    /// code can parse small plain HTTP/1.1 replies (e.g. `GET /cdn-cgi/trace`).
    /// Returns nil when `requireComplete` is false and the body is not yet framed.
    public static func httpBody(from data: Data, requireComplete: Bool) throws -> Data? {
        try DohHTTPWire.extractBody(from: data, requireComplete: requireComplete)
    }

    // MARK: - 系统解析

    private static let addressCacheLock = NSLock()
    private static var addressCache: [String: (addresses: [String], at: Date)] = [:]

    /// `getaddrinfo` 是同步阻塞调用，而解析一次域名要打三个查询；不缓存就会在
    /// 解析器的串行队列上连做三次。结果按主机名缓存一分钟。
    public static func systemAddresses(for host: String) -> [String] {
        let key = host.lowercased()
        addressCacheLock.lock()
        if let cached = addressCache[key], Date().timeIntervalSince(cached.at) < systemAddressTTL {
            let addresses = cached.addresses
            addressCacheLock.unlock()
            return addresses
        }
        addressCacheLock.unlock()

        let addresses = resolveSystemAddresses(for: host)
        addressCacheLock.lock()
        if addressCache.count > 32 { addressCache.removeAll() }
        addressCache[key] = (addresses, Date())
        addressCacheLock.unlock()
        return addresses
    }

    /// 关掉复用的 DoH 连接（换服务器 / 切网络后调用）。
    public static func closeIdleConnections() {
        DohHTTPClient.shared.closeIdleConnections()
    }

    /// 清掉系统解析缓存（换网络、切 DoH 服务器后调用）。
    public static func clearSystemAddressCache() {
        addressCacheLock.lock()
        addressCache.removeAll()
        addressCacheLock.unlock()
    }

    private static func resolveSystemAddresses(for host: String) -> [String] {
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
        DohHTTPClient.endpointHost(address)
    }
}
