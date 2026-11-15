import Foundation

public struct DohHostRecord: Equatable, Sendable {
    public var host: String
    public var addresses: [String]
    public var preferredIP: String?
    public var echConfig: Data?
    public var echNegative: Bool
    public var ttl: TimeInterval
    public var expiresAt: Date
}

public struct DohCacheStats: Equatable, Sendable {
    public var hostEntries: Int
    public var echAvailable: Int
    public var echNegative: Int
}

public final class DohBootstrapResolver: @unchecked Sendable {
    public static let stickyTTL: TimeInterval = 600
    public static let penaltyTTL: TimeInterval = 120
    public static let maxCacheEntries = 1000
    /// TTL 刚过时先拿旧答案、后台刷新，别让建连等一轮三次查询。
    public static let staleServingWindow: TimeInterval = 120
    /// 解析失败后的短负缓存，挡住同一秒里涌进来的重试。
    public static let negativeTTL: TimeInterval = 3

    private let queue = DispatchQueue(label: "doer.doh.bootstrap-resolver")
    private var config: DohProxyConfig
    private var cache: [String: DohHostRecord] = [:]
    private var inflight: [String: [(Result<DohHostRecord, Error>) -> Void]] = [:]
    private var stickyUntil: [String: (ip: String, expires: Date)] = [:]
    private var penalties: [String: [String: Date]] = [:]
    private var failures: [String: (until: Date, error: Error)] = [:]

    public init(config: DohProxyConfig) {
        self.config = config
    }

    public func updateConfig(_ config: DohProxyConfig) {
        queue.async {
            if self.config.signature != config.signature {
                self.cache.removeAll()
                self.stickyUntil.removeAll()
                self.penalties.removeAll()
                self.failures.removeAll()
            }
            self.config = config
        }
    }

    public func resolve(host rawHost: String, completion: @escaping (Result<DohHostRecord, Error>) -> Void) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        queue.async {
            let now = Date()
            if let cached = self.cache[host] {
                if cached.expiresAt > now {
                    completion(.success(self.applyingStickyAndPenalties(cached)))
                    return
                }
                // 过期不久：旧答案照发，后台刷新。代理每条 CONNECT 都会问一次，
                // 让建连去等一轮 A/AAAA/HTTPS 查询不值当。
                if now.timeIntervalSince(cached.expiresAt) < Self.staleServingWindow {
                    completion(.success(self.applyingStickyAndPenalties(cached)))
                    // 刷新失败后有 3 秒负缓存，别让每条 CONNECT 都去撞一次。
                    let backingOff = self.failures[host].map { $0.until > now } ?? false
                    if self.inflight[host] == nil, !backingOff {
                        self.inflight[host] = []
                        self.load(host: host)
                    }
                    return
                }
            }
            if self.inflight[host] != nil {
                self.inflight[host, default: []].append(completion)
                return
            }
            if let failure = self.failures[host], failure.until > now {
                completion(.failure(failure.error))
                return
            }
            self.inflight[host] = [completion]
            self.load(host: host)
        }
    }

    public func lookupEchConfig(host: String, completion: @escaping (Result<DohEchLookupResult, Error>) -> Void) {
        resolve(host: host) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let record):
                completion(.success(DohEchLookupResult(
                    host: record.host,
                    echConfig: record.echConfig,
                    negative: record.echNegative
                )))
            }
        }
    }

    public func recordHostSuccess(host rawHost: String, ip: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        queue.async {
            self.stickyUntil[host] = (ip, Date().addingTimeInterval(Self.stickyTTL))
            if var record = self.cache[host] {
                record.preferredIP = ip
                self.cache[host] = record
            }
        }
    }

    public func recordHostFailure(host rawHost: String, ip: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        queue.async {
            var map = self.penalties[host] ?? [:]
            let now = Date()
            map[ip] = now.addingTimeInterval(Self.penaltyTTL)
            self.penalties[host] = map
            // 长会话里主机名只增不减，顺手清掉过期惩罚项。
            if self.penalties.count > 256 {
                self.penalties = self.penalties.compactMapValues { entries in
                    let alive = entries.filter { $0.value > now }
                    return alive.isEmpty ? nil : alive
                }
            }
        }
    }

    public func clearCache() {
        queue.async {
            self.cache.removeAll()
            self.stickyUntil.removeAll()
            self.penalties.removeAll()
            self.failures.removeAll()
        }
    }

    public func cacheStats() -> DohCacheStats {
        queue.sync {
            let now = Date()
            let live = cache.values.filter { $0.expiresAt > now }
            return DohCacheStats(
                hostEntries: live.count,
                echAvailable: live.filter { $0.echConfig != nil }.count,
                echNegative: live.filter(\.echNegative).count
            )
        }
    }

    public func cacheRecords() -> [DohHostRecord] {
        queue.sync {
            let now = Date()
            return cache.values.filter { $0.expiresAt > now }.sorted { $0.host < $1.host }
        }
    }

    private func load(host: String) {
        guard let dns = DohEndpoint(
            url: config.serverURL,
            bootstrapIPs: config.bootstrapIPs,
            preferIPv6: config.preferIPv6
        ), dns.isReady else {
            finish(host: host, result: .failure(DohProxyError.bootstrapUnavailable(config.serverURL)))
            return
        }
        let echURL = config.effectiveEchServerURL
        let echBootstrap = DohServerCatalog.builtIn(url: echURL)?.bootstrapIPs ?? config.bootstrapIPs
        guard let ech = DohEndpoint(
            url: echURL,
            bootstrapIPs: echBootstrap,
            preferIPv6: config.preferIPv6
        ), ech.isReady else {
            finish(host: host, result: .failure(DohProxyError.bootstrapUnavailable(echURL)))
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var addresses: [String] = []
        var ttls: [Int] = []
        var httpsRData: [Data] = []
        var errors: [Error] = []

        func addQuery(endpoint: DohEndpoint, type: UInt16) {
            guard let query = DohDNSMessage.makeQuery(host: host, type: type) else {
                lock.lock()
                errors.append(DohProxyError.queryFailed(host))
                lock.unlock()
                return
            }
            group.enter()
            var didLeave = false
            DohBootstrapTransport.query(endpoint: endpoint, dnsQuery: query, queue: queue) { result in
                lock.lock()
                switch result {
                case .failure(let error):
                    errors.append(error)
                case .success(let body):
                    do {
                        let resources = try DohDNSMessage.parseResources(body, expectedType: type)
                        ttls.append(contentsOf: resources.map(\.ttl))
                        switch type {
                        case DohDNSMessage.typeA:
                            addresses.append(contentsOf: resources.compactMap { DohDNSMessage.ipv4String(from: $0.rdata) })
                        case DohDNSMessage.typeAAAA:
                            addresses.append(contentsOf: resources.compactMap { DohDNSMessage.ipv6String(from: $0.rdata) })
                        case DohDNSMessage.typeHTTPS:
                            httpsRData.append(contentsOf: resources.map(\.rdata))
                        default:
                            break
                        }
                    } catch {
                        errors.append(error)
                    }
                }
                let shouldLeave = !didLeave
                didLeave = true
                lock.unlock()
                if shouldLeave {
                    group.leave()
                }
            }
        }

        addQuery(endpoint: dns, type: DohDNSMessage.typeA)
        addQuery(endpoint: dns, type: DohDNSMessage.typeAAAA)
        addQuery(endpoint: ech, type: DohDNSMessage.typeHTTPS)

        group.notify(queue: queue) {
            let unique = Self.unique(addresses)
            let echResult = DohEchClient().result(host: host, httpsAnswers: httpsRData)
            if unique.isEmpty, echResult.echConfig == nil {
                self.finish(host: host, result: .failure(errors.first ?? DohProxyError.emptyAnswer(host)))
                return
            }
            let ttl = DohDNSMessage.clampTTL(ttls.min() ?? 300)
            let record = DohHostRecord(
                host: host,
                addresses: unique,
                preferredIP: nil,
                echConfig: echResult.echConfig,
                echNegative: echResult.negative,
                ttl: ttl,
                expiresAt: Date().addingTimeInterval(ttl)
            )
            self.store(record)
            self.finish(host: host, result: .success(self.applyingStickyAndPenalties(record)))
        }
    }

    private func store(_ record: DohHostRecord) {
        if cache.count >= Self.maxCacheEntries {
            let now = Date()
            let expired = cache.filter { $0.value.expiresAt <= now }.map(\.key)
            expired.forEach { cache.removeValue(forKey: $0) }
            if cache.count >= Self.maxCacheEntries, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
                cache.removeValue(forKey: oldest.key)
            }
        }
        cache[record.host] = record
    }

    private func applyingStickyAndPenalties(_ record: DohHostRecord) -> DohHostRecord {
        var next = record
        let now = Date()
        if let sticky = stickyUntil[record.host], sticky.expires > now {
            next.preferredIP = sticky.ip
        }
        let dead = (penalties[record.host] ?? [:]).compactMap { ip, until in until > now ? ip : nil }
        if !dead.isEmpty {
            let filtered = next.addresses.filter { !dead.contains($0) }
            if !filtered.isEmpty {
                next.addresses = filtered
            }
        }
        if let preferred = next.preferredIP, next.addresses.contains(preferred) {
            next.addresses = [preferred] + next.addresses.filter { $0 != preferred }
        }
        return next
    }

    private func finish(host: String, result: Result<DohHostRecord, Error>) {
        switch result {
        case .success:
            failures.removeValue(forKey: host)
        case .failure(let error):
            failures[host] = (Date().addingTimeInterval(Self.negativeTTL), error)
        }
        let completions = inflight.removeValue(forKey: host) ?? []
        completions.forEach { $0(result) }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
