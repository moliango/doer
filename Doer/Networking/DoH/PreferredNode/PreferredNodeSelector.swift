import DohProxy
import Foundation

/// Cloudflare 本地优选：在 CF 共享池里自己找能连上 linux.do 的节点。
///
/// 1. **取候选**：上一轮赢家 → atlas 池 → 大厂 Cloudflare 域名（经公共 DoH 解析）→ CF 网段随机抽样。
///    答案不在 CF 网段的一律丢弃，防 DNS 投毒；公共 DNS 从不查询 linux.do 本身。
/// 2. **竞速**：对候选并发做 ECH 握手（内层 SNI = linux.do）并请求 `/cdn-cgi/trace`，
///    正文里 `h=linux.do` 才算通过，最快的记为赢家并落盘。
/// 3. **使用**：`PreferredNodeStore` 钉住赢家，linux.do 及所有子域统一走它、同一地址族。
///
/// 重测时机只有三个：切网、赢家连续失败、手动。没有定时重测，也没有后台任务。
/// 移植自 cfluxdo `core/doh_proxy/src/select.rs`。
nonisolated final class PreferredNodeSelector: @unchecked Sendable {
    static let shared = PreferredNodeSelector()

    enum Trigger: String, Sendable {
        case manual
        case networkChange
        case winnerFailure
    }

    enum Status: Equatable, Sendable {
        case idle
        case gathering
        case racing(done: Int, total: Int)
        case success(PreferredNode)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .gathering, .racing: return true
            default: return false
            }
        }
    }

    /// 探测的内层 SNI 与 Host。明文 SNI 在国内会被重置，只能走 ECH。
    static let probeHost = "linux.do"

    // 常量对齐 `select.rs:36-121`
    private static let concurrency = 8
    private static let graceInterval: TimeInterval = 0.4
    private static let raceTotal: TimeInterval = 4
    private static let gatherTimeout: TimeInterval = 4.5
    private static let maxCandidates = 32
    private static let vendorMaxPerDomain = 4
    private static let vendorMaxTotal = 10
    private static let communityMaxTotal = 4
    private static let randomV4Samples = 12
    private static let randomV6Samples = 4
    private static let publicDohConcurrency = 6
    private static let minRaceInterval: TimeInterval = 60
    private static let maxAutoRacesPerHour = 4
    private static let manualCooldown: TimeInterval = 10
    private static let failedRetry: TimeInterval = 300
    private static let netChangeDebounce: TimeInterval = 1.5
    private static let atlasMinFetchInterval: TimeInterval = 120
    private static let atlasBackoff: TimeInterval = 60
    private static let atlasBackoffMax: TimeInterval = 600
    /// 一轮竞速最多重跑几次（换钥匙 / 服务端给新钥匙）。
    private static let maxRacePasses = 4

    /// ECH 钥匙的备用来源：CF 共享钥匙，所以用别的 CF zone 就够了，
    /// **不必也不该去查 linux.do**（对齐 `select.rs:103`）。
    static let httpsKeyDomains = ["icook.tw", "skk.moe", "japan.com"]
    private static let httpsKeyDomainsToTry = 2

    /// 解析器连续失败到这个次数就暂停。
    private static let resolverFailureLimit = 2
    private static let resolverPauseDuration: TimeInterval = 600

    /// 经公共 DoH 解析的大厂 Cloudflare 域名（只查这些，从不查目标站本身）。
    static let vendorDomains = [
        "www.visa.com.hk",
        "www.visa.com.sg",
        "www.visa.com.tw",
        "openai.com",
        "www.shopify.com",
        "www.digitalocean.com",
        "www.udemy.com",
        "icook.tw",
        "japan.com",
    ]

    /// 社区优选域名，低优先附加。
    static let communityDomains = [
        "cf.090227.xyz",
        "skk.moe",
        "cloudflare.182682.xyz",
        "cf.877774.xyz",
    ]

    /// 内置公共 DoH 端点：全部用 `DohServerCatalog` 的「域名 + bootstrap IP」组合，
    /// SNI 仍是域名，完全不经系统 DNS。
    private static let publicResolvers: [DohServerDescriptor] = [
        DohServerCatalog.dnsPod,
        DohServerCatalog.tencent,
        DohServerCatalog.aliDNS,
        DohServerCatalog.cloudflare,
        DohServerCatalog.quad9,
        DohServerCatalog.google,
    ]

    /// 状态变化回调，在主线程触发。
    var onStatusChange: ((Status) -> Void)?

    private let queue = DispatchQueue(label: "doer.preferred-node.selector")
    /// `DohBootstrapTransport` 内部有未加锁的状态，必须给它串行队列。
    private let dohQueue = DispatchQueue(label: "doer.preferred-node.doh")
    private let store: PreferredNodeStore
    private let resolver: DohResolver
    private let atlasClient = AtlasRoutesClient()

    private let stateLock = NSLock()
    private var statusValue: Status = .idle
    private var isRacing = false
    private var lastRaceAt: Date?
    private var lastFailureAt: Date?
    private var autoRaceWindowStart: Date?
    private var autoRacesThisHour = 0
    private var atlasCache: AtlasRoutesTable?
    private var atlasFetchedAt: Date?
    private var atlasBackoffUntil: Date?
    private var netChangeWork: DispatchWorkItem?
    /// 解析器健康状态：连不上或一直给投毒答案的，暂停一段时间。
    /// 对齐 cfluxdo「连不上的端点由 DoH 健康状态自动暂停」。
    private var resolverFailures: [String: Int] = [:]
    private var resolverPausedUntil: [String: Date] = [:]

    init(
        store: PreferredNodeStore = .shared,
        resolver: DohResolver = DohResolver()
    ) {
        self.store = store
        self.resolver = resolver
        store.onWinnerDemoted = { [weak self] in
            self?.reselect(trigger: .winnerFailure)
        }
    }

    var status: Status {
        stateLock.lock()
        defer { stateLock.unlock() }
        return statusValue
    }

    /// 跟随主服务换 DoH 配置（换 provider / 自定义 URL / 上游）。
    /// 不更新就会一直朝启动时那个端点查候选和 ECH 钥匙。
    func updateConfig(_ config: DohProxyConfig) {
        resolver.updateConfig(config)
    }

    // MARK: - 入口

    /// 触发一次优选。`completion` 在主线程回调，`nil` 表示这次没选出赢家。
    func reselect(trigger: Trigger, completion: ((PreferredNode?) -> Void)? = nil) {
        if trigger == .networkChange {
            stateLock.lock()
            netChangeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.startRace(trigger: trigger, completion: completion)
            }
            netChangeWork = work
            stateLock.unlock()
            queue.asyncAfter(deadline: .now() + Self.netChangeDebounce, execute: work)
            return
        }
        queue.async { [weak self] in
            self?.startRace(trigger: trigger, completion: completion)
        }
    }

    /// 启动时接上赢家降级回调（幂等）。
    func start() {
        store.onWinnerDemoted = { [weak self] in
            self?.reselect(trigger: .winnerFailure)
        }
        if let node = store.node {
            setStatus(.success(node))
        }
    }

    // MARK: - 竞速编排

    private func startRace(trigger: Trigger, completion: ((PreferredNode?) -> Void)?) {
        // 已在 `queue` 上
        if let reason = rateLimitReason(trigger) {
            DohDebugLog.record("跳过竞速（\(trigger.rawValue)）：\(reason)", subsystem: "优选")
            finishRace(winner: nil, message: nil, completion: completion)
            return
        }
        stateLock.lock()
        if isRacing {
            stateLock.unlock()
            DohDebugLog.record("竞速进行中，忽略 \(trigger.rawValue)", subsystem: "优选")
            finishRace(winner: nil, message: nil, completion: completion)
            return
        }
        isRacing = true
        lastRaceAt = Date()
        if trigger != .manual {
            let now = Date()
            if let start = autoRaceWindowStart, now.timeIntervalSince(start) < 3600 {
                autoRacesThisHour += 1
            } else {
                autoRaceWindowStart = now
                autoRacesThisHour = 1
            }
        }
        stateLock.unlock()

        let mode = AppSettings.preferredNodeMode(from: .standard)
        setStatus(.gathering)
        DohDebugLog.record("开始优选（\(trigger.rawValue)，模式 \(mode.title)）", subsystem: "优选")

        let family = CloudflareRanges.localFamilySupport()
        guard !family.isEmpty else {
            finishRace(winner: nil, message: "本机没有可用的出站地址族", completion: completion)
            return
        }
        gatherCandidates(mode: mode, family: family) { [weak self] candidates, sources in
            guard let self else { return }
            guard !candidates.isEmpty else {
                self.finishRace(winner: nil, message: "没有候选节点", completion: completion)
                return
            }
            let keys = EchKeyStore.shared.liveKeys
            DohDebugLog.record(
                "候选 \(candidates.count) 个 · ECH 钥匙 \(keys.count) 把"
                    + (keys.isEmpty ? "（无钥匙，探针发的是明文 SNI）"
                                    : "（\(keys.map(\.source.rawValue).joined(separator: ","))）")
                    + " · 开始竞速",
                subsystem: "优选"
            )
            self.racePasses(
                candidates: candidates,
                sources: sources,
                family: family,
                keys: keys.map(\.bytes),
                pass: 0
            ) { winner in
                self.finishRace(
                    winner: winner,
                    message: winner == nil ? "全部候选都没通过" : nil,
                    completion: completion
                )
            }
        }
    }

    /// 一轮竞速；钥匙不匹配时最多重跑 `maxRacePasses` 轮。
    ///
    /// 重跑的两种情形：
    /// 1. 服务端拒绝 ECH 并给了 retry_configs —— 当场收养新钥匙（「不等 DNS 刷新」）。
    /// 2. 池里还有下一把钥匙 —— 换一把再试。
    ///
    /// 钥匙池为空时先补齐：非 linux.do 的 CF 域名 HTTPS 记录 → atlas 表里的 ech。
    /// **从不查询 linux.do 本身**，取不到就放弃优选（退回普通 DoH 解析）。
    private func racePasses(
        candidates: [String],
        sources: [String: PreferredNode.Source],
        family: CloudflareRanges.FamilySupport,
        keys: [Data],
        pass: Int,
        completion: @escaping (PreferredNode?) -> Void
    ) {
        guard pass < Self.maxRacePasses else {
            completion(nil)
            return
        }

        if keys.isEmpty, pass == 0 {
            fetchKeysFromHTTPSRecords { [weak self] fresh in
                guard let self else { return }
                guard !fresh.isEmpty else {
                    DohDebugLog.record("取不到 ECH 钥匙，跳过优选（不查 linux.do）", subsystem: "优选")
                    completion(nil)
                    return
                }
                self.racePasses(
                    candidates: candidates,
                    sources: sources,
                    family: family,
                    keys: fresh,
                    pass: pass,
                    completion: completion
                )
            }
            return
        }

        let key = keys.first
        if key == nil {
            DohDebugLog.record("无 ECH 钥匙，退回普通 TLS 探测", subsystem: "优选")
        }
        let probe = CloudflareNodeProbe(echConfig: key)
        race(candidates: candidates, sources: sources, family: family, probe: probe) { [weak self] winner, learned in
            guard let self else { return }
            if let winner {
                completion(winner)
                return
            }

            // 1. 服务端当场给了新钥匙
            var adopted = false
            for bytes in learned {
                if EchKeyStore.shared.adopt(bytes, source: .retryConfigs) { adopted = true }
            }
            if adopted {
                DohDebugLog.record("服务端换钥匙，立刻重赛", subsystem: "优选")
                self.racePasses(
                    candidates: candidates,
                    sources: sources,
                    family: family,
                    keys: EchKeyStore.shared.liveKeys.map(\.bytes),
                    pass: pass + 1,
                    completion: completion
                )
                return
            }

            // 2. 池里还有下一把
            if keys.count > 1 {
                self.racePasses(
                    candidates: candidates,
                    sources: sources,
                    family: family,
                    keys: Array(keys.dropFirst()),
                    pass: pass + 1,
                    completion: completion
                )
                return
            }

            // 3. 池里的钥匙全试过了，去 HTTPS 记录换一批
            if !keys.isEmpty, pass + 1 < Self.maxRacePasses {
                self.fetchKeysFromHTTPSRecords { fresh in
                    let usable = fresh.filter { !keys.contains($0) }
                    guard !usable.isEmpty else {
                        completion(nil)
                        return
                    }
                    self.racePasses(
                        candidates: candidates,
                        sources: sources,
                        family: family,
                        keys: usable,
                        pass: pass + 1,
                        completion: completion
                    )
                }
                return
            }
            completion(nil)
        }
    }

    /// 从非 linux.do 的 CF 域名 HTTPS 记录取钥匙（CF 共享钥匙，取到 `httpsKeyDomainsToTry` 把就停）。
    private func fetchKeysFromHTTPSRecords(completion: @escaping ([Data]) -> Void) {
        let domains = Self.httpsKeyDomains
        var found: [Data] = []

        func step(_ index: Int) {
            guard index < domains.count, found.count < Self.httpsKeyDomainsToTry else {
                completion(found)
                return
            }
            resolver.lookupEchConfig(host: domains[index]) { result in
                if let bytes = (try? result.get())?.echConfig, !bytes.isEmpty {
                    EchKeyStore.shared.adopt(bytes, source: .httpsRecord)
                    found.append(bytes)
                }
                step(index + 1)
            }
        }
        step(0)
    }

    private func finishRace(
        winner: PreferredNode?,
        message: String?,
        completion: ((PreferredNode?) -> Void)?
    ) {
        stateLock.lock()
        let wasRacing = isRacing
        isRacing = false
        if winner == nil, wasRacing {
            lastFailureAt = Date()
        }
        stateLock.unlock()

        if let winner {
            store.node = winner
            DohDebugLog.record(
                "赢家 \(winner.ip)（\(winner.family.rawValue)，\(winner.latencyMs)ms，\(winner.source.rawValue)）",
                subsystem: "优选"
            )
            setStatus(.success(winner))
        } else if let message {
            DohDebugLog.record("优选失败：\(message)", subsystem: "优选")
            setStatus(.failed(message))
        }

        guard let completion else { return }
        DispatchQueue.main.async { completion(winner) }
    }

    private func rateLimitReason(_ trigger: Trigger) -> String? {
        let now = Date()
        stateLock.lock()
        defer { stateLock.unlock() }
        switch trigger {
        case .manual:
            if let last = lastRaceAt, now.timeIntervalSince(last) < Self.manualCooldown {
                return "冷却中"
            }
            return nil
        case .winnerFailure:
            if let last = lastFailureAt, now.timeIntervalSince(last) < Self.failedRetry {
                return "距上次失败不足 \(Int(Self.failedRetry))s"
            }
            if let last = lastRaceAt, now.timeIntervalSince(last) < Self.minRaceInterval {
                return "距上次竞速不足 \(Int(Self.minRaceInterval))s"
            }
            return nil
        case .networkChange:
            if let last = lastRaceAt, now.timeIntervalSince(last) < Self.minRaceInterval {
                return "距上次竞速不足 \(Int(Self.minRaceInterval))s"
            }
            if let start = autoRaceWindowStart, now.timeIntervalSince(start) < 3600,
               autoRacesThisHour >= Self.maxAutoRacesPerHour {
                return "本小时自动竞速已达上限"
            }
            return nil
        }
    }

    private func setStatus(_ status: Status) {
        stateLock.lock()
        statusValue = status
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChange?(status)
        }
    }

    // MARK: - 候选收集

    private final class GatherState: @unchecked Sendable {
        let lock = NSLock()
        var ordered: [String] = []
        var seen = Set<String>()
        var sources: [String: PreferredNode.Source] = [:]
        var vendorCount = 0
        var communityCount = 0
        var finished = false
    }

    private func gatherCandidates(
        mode: AppSettings.PreferredNodeMode,
        family: CloudflareRanges.FamilySupport,
        completion: @escaping ([String], [String: PreferredNode.Source]) -> Void
    ) {
        let state = GatherState()

        func add(_ ips: [String], source: PreferredNode.Source) {
            state.lock.lock()
            for ip in ips where Self.accepts(ip, family: family) && state.seen.insert(ip).inserted {
                state.ordered.append(ip)
                state.sources[ip] = source
            }
            state.lock.unlock()
        }

        /// 大厂/社区域名走预算上限：每域最多 `perDomain` 个，整段总量受 `budget` 约束。
        func addBudgeted(_ ips: [String], perDomain: Int, community: Bool) {
            state.lock.lock()
            for ip in ips.prefix(perDomain) {
                guard Self.accepts(ip, family: family) else { continue }
                if community {
                    guard state.communityCount < Self.communityMaxTotal else { break }
                } else {
                    guard state.vendorCount < Self.vendorMaxTotal else { break }
                }
                guard state.seen.insert(ip).inserted else { continue }
                if community {
                    state.communityCount += 1
                } else {
                    state.vendorCount += 1
                }
                state.ordered.append(ip)
                state.sources[ip] = .vendor
            }
            state.lock.unlock()
        }

        func finish() {
            state.lock.lock()
            if state.finished {
                state.lock.unlock()
                return
            }
            state.finished = true
            let ordered = Array(state.ordered.prefix(Self.maxCandidates))
            let sources = state.sources
            state.lock.unlock()
            completion(ordered, sources)
        }

        // 1. 上一轮赢家
        if let node = store.node {
            add([node.ip], source: .sticky)
        }

        let useAtlas = mode == .localAndAtlas || mode == .atlasOnly
        let useLocal = mode == .localAndAtlas

        let group = DispatchGroup()

        // 2. atlas 池
        if useAtlas {
            group.enter()
            fetchAtlas(family: family) { ips in
                add(ips, source: .atlas)
                group.leave()
            }
        }

        // 3. 大厂域名 + 社区域名（并发经公共 DoH 解析，每域首个通过投毒检查的答案胜出）
        if useLocal {
            group.enter()
            let domains = Self.vendorDomains + Self.communityDomains
            let batches = stride(from: 0, to: domains.count, by: Self.publicDohConcurrency).map {
                Array(domains[$0 ..< min($0 + Self.publicDohConcurrency, domains.count)])
            }

            func runBatch(_ index: Int) {
                guard index < batches.count else {
                    group.leave()
                    return
                }
                let batchGroup = DispatchGroup()
                for domain in batches[index] {
                    batchGroup.enter()
                    resolveCloudflareDomain(domain, family: family) { ips in
                        if Self.communityDomains.contains(domain) {
                            addBudgeted(ips, perDomain: 1, community: true)
                        } else {
                            addBudgeted(ips, perDomain: Self.vendorMaxPerDomain, community: false)
                        }
                        batchGroup.leave()
                    }
                }
                batchGroup.notify(queue: dohQueue) { runBatch(index + 1) }
            }
            dohQueue.async { runBatch(0) }

            // 4. CF 网段随机抽样
            if family.v4 {
                add(CloudflareRanges.sampleIPv4(count: Self.randomV4Samples), source: .random)
            }
            if family.v6 {
                add(CloudflareRanges.sampleIPv6(count: Self.randomV6Samples), source: .random)
            }
        }

        group.notify(queue: queue) { finish() }
        queue.asyncAfter(deadline: .now() + Self.gatherTimeout) { finish() }
    }

    // MARK: - 解析器健康

    /// 连续失败到这个次数就该暂停这个解析器。
    static func shouldPauseResolver(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= resolverFailureLimit
    }

    private func resolverIsPaused(_ url: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let until = resolverPausedUntil[url] else { return false }
        return until > Date()
    }

    private func noteResolverResult(_ url: String, ok: Bool) {
        var paused = false
        var failures = 0
        stateLock.lock()
        if ok {
            resolverFailures[url] = 0
            resolverPausedUntil[url] = nil
        } else {
            failures = (resolverFailures[url] ?? 0) + 1
            resolverFailures[url] = failures
            if Self.shouldPauseResolver(consecutiveFailures: failures) {
                resolverPausedUntil[url] = Date().addingTimeInterval(Self.resolverPauseDuration)
                resolverFailures[url] = 0
                paused = true
            }
        }
        stateLock.unlock()

        guard paused else { return }
        DohDebugLog.record(
            "解析器 \(url) 连续失败 \(failures) 次，暂停 \(Int(Self.resolverPauseDuration / 60)) 分钟",
            subsystem: "优选"
        )
    }

    /// 并发向所有**健康**的公共 DoH 端点查询一个域名，首个通过投毒检查的答案胜出。
    ///
    /// 查询走 `quiet: true`：候选收集会铺开十几个端点，每个不可达的还要逐个试完
    /// bootstrap IP，那些 `bootstrap connect/timeout` 会把 500 行的日志冲干净。
    private func resolveCloudflareDomain(
        _ domain: String,
        family: CloudflareRanges.FamilySupport,
        completion: @escaping ([String]) -> Void
    ) {
        var types: [UInt16] = []
        if family.v4 { types.append(DohDNSMessage.typeA) }
        if family.v6 { types.append(DohDNSMessage.typeAAAA) }

        let active = Self.publicResolvers.filter { !resolverIsPaused($0.url) }
        guard !active.isEmpty else {
            completion([])
            return
        }

        let lock = NSLock()
        var settled = false
        var best: [String] = []
        var answered = 0
        var poisoned = 0
        /// 每个解析器这一轮还剩几条查询没回来。A/AAAA 各记一次失败会在一次网络
        /// 抖动里直接把它暂停掉（日志里就是「连续失败 2 次」），所以按解析器汇总。
        var pendingByResolver: [String: Int] = [:]
        var healthyResolvers = Set<String>()
        let group = DispatchGroup()

        for descriptor in active {
            guard let endpoint = DohEndpoint(
                url: descriptor.url,
                bootstrapIPs: descriptor.bootstrapIPs,
                preferIPv6: false
            ), endpoint.isReady else { continue }

            for type in types {
                guard let query = DohDNSMessage.makeQuery(host: domain, type: type) else { continue }
                lock.lock()
                pendingByResolver[descriptor.url, default: 0] += 1
                lock.unlock()
                group.enter()
                DohBootstrapTransport.query(
                    endpoint: endpoint,
                    dnsQuery: query,
                    queue: dohQueue,
                    quiet: true
                ) { result in
                    defer { group.leave() }
                    var ips: [String] = []
                    var poisonedAnswer = false
                    if case .success(let body) = result,
                       let resources = try? DohDNSMessage.parseResources(body, expectedType: type) {
                        ips = resources.compactMap { resource -> String? in
                            switch type {
                            case DohDNSMessage.typeA: return DohDNSMessage.ipv4String(from: resource.rdata)
                            case DohDNSMessage.typeAAAA: return DohDNSMessage.ipv6String(from: resource.rdata)
                            default: return nil
                            }
                        }
                        // 解析成功但答案不在 CF 网段 = 投毒，这个解析器同样不可信。
                        poisonedAnswer = !CloudflareRanges.allCloudflare(ips)
                    }
                    lock.lock()
                    if !ips.isEmpty, !poisonedAnswer {
                        healthyResolvers.insert(descriptor.url)
                        answered += 1
                        if !settled {
                            settled = true
                            best = ips
                        }
                    } else if poisonedAnswer {
                        poisoned += 1
                    }
                    let left = (pendingByResolver[descriptor.url] ?? 1) - 1
                    pendingByResolver[descriptor.url] = left
                    let healthy = healthyResolvers.contains(descriptor.url)
                    lock.unlock()
                    // 这一轮这个解析器还有查询在路上就先不判，等最后一条回来再说。
                    guard left <= 0 else { return }
                    self.noteResolverResult(descriptor.url, ok: healthy)
                }
            }
        }

        group.notify(queue: dohQueue) {
            lock.lock()
            let result = best
            let answers = answered
            let poisons = poisoned
            lock.unlock()
            if result.isEmpty {
                DohDebugLog.record(
                    "\(domain) 没拿到 CF 候选（\(active.count) 个健康解析器，成功 \(answers)，投毒 \(poisons)）",
                    subsystem: "优选"
                )
            }
            completion(result)
        }
    }

    // MARK: - atlas

    private func fetchAtlas(
        family: CloudflareRanges.FamilySupport,
        completion: @escaping ([String]) -> Void
    ) {
        let url = AppSettings.preferredNodeAtlasURL(from: .standard)
        stateLock.lock()
        let backoff = atlasBackoffUntil
        let cache = atlasCache
        let fetchedAt = atlasFetchedAt
        stateLock.unlock()

        let cached = cache?.candidates ?? []
        let now = Date()
        if let backoff, backoff > now {
            completion(cached)
            return
        }
        if let cache, let fetchedAt,
           now.timeIntervalSince(fetchedAt) < max(cache.ttl, Self.atlasMinFetchInterval) {
            completion(cache.candidates)
            return
        }
        guard let endpoint = AtlasRoutesClient.Endpoint(url: url) else {
            completion(cached)
            return
        }

        resolveCloudflareDomain(endpoint.host, family: family) { [weak self] bootstrap in
            guard let self else { return }
            var ips = Array(bootstrap.prefix(3))
            if let winner = self.store.node?.ip, !ips.contains(winner) {
                ips.append(winner)
            }
            guard !ips.isEmpty else {
                DohDebugLog.record("atlas 跳过：解析不到它的 IP", subsystem: "优选")
                completion(cached)
                return
            }
            self.atlasClient.fetch(endpoint: endpoint, bootstrapIPs: ips, family: family) { result in
                switch result {
                case .success(let table):
                    self.stateLock.lock()
                    self.atlasCache = table
                    self.atlasFetchedAt = Date()
                    self.atlasBackoffUntil = nil
                    self.stateLock.unlock()
                    // 表里带的钥匙先收养：少一次公共 DoH 查询，也不碰 linux.do。
                    if let ech = table.echConfig {
                        EchKeyStore.shared.adopt(ech, source: .atlas)
                    }
                    DohDebugLog.record(
                        "atlas 表 \(table.candidates.count) 个候选 ttl=\(Int(table.ttl))s"
                            + (table.echConfig == nil ? "" : " · 带 ECH 钥匙"),
                        subsystem: "优选"
                    )
                    completion(table.candidates)
                case .failure(let failure):
                    let backoff = Self.atlasBackoffSeconds(for: failure)
                    self.stateLock.lock()
                    self.atlasBackoffUntil = Date().addingTimeInterval(backoff)
                    self.stateLock.unlock()
                    DohDebugLog.record(
                        "atlas 拉取失败：\(failure.description)，退避 \(Int(backoff))s",
                        subsystem: "优选"
                    )
                    completion(cached)
                }
            }
        }
    }

    private static func atlasBackoffSeconds(for failure: AtlasRoutesError) -> TimeInterval {
        guard case .status(429, let retryAfter) = failure else { return atlasBackoff }
        let requested = TimeInterval(retryAfter ?? Int(atlasBackoff))
        return min(max(requested, atlasBackoff), atlasBackoffMax)
    }

    // MARK: - 竞速

    private func race(
        candidates: [String],
        sources: [String: PreferredNode.Source],
        family: CloudflareRanges.FamilySupport,
        probe: CloudflareNodeProbe,
        completion: @escaping (PreferredNode?, [Data]) -> Void
    ) {
        // 全部状态只在本 `queue` 上访问，因此不需要锁。
        var pending = Self.orderedByFamily(candidates, family: family)
        let total = pending.count
        var running = 0
        var done = 0
        var settled = false
        var graceArmed = false
        var winners: [PreferredNodeProbeOutcome] = []
        var learnedKeys: [Data] = []
        var failures: [String: Int] = [:]

        setStatus(.racing(done: 0, total: total))

        func settle() {
            guard !settled else { return }
            settled = true
            guard let best = winners.min(by: { $0.latencyMs < $1.latencyMs }) else {
                // 说清楚为什么全挂：是 TCP 不通、TLS 被重置，还是 ECH 被拒。
                let summary = failures
                    .sorted { $0.value > $1.value }
                    .prefix(4)
                    .map { "\($0.key)×\($0.value)" }
                    .joined(separator: " ")
                DohDebugLog.record(
                    "竞速全失败（\(total) 个候选）：\(summary.isEmpty ? "无结果" : summary)",
                    subsystem: "优选"
                )
                completion(nil, learnedKeys)
                return
            }
            completion(PreferredNode(
                ip: best.ip,
                family: best.ip.contains(":") ? .v6 : .v4,
                latencyMs: best.latencyMs,
                selectedAt: Date(),
                source: sources[best.ip] ?? .random,
                echConfig: probe.echConfig
            ), learnedKeys)
        }

        func pump() {
            while running < Self.concurrency, !pending.isEmpty, !settled {
                let ip = pending.removeFirst()
                running += 1
                probe.probe(ip: ip, sni: Self.probeHost) { outcome in
                    self.queue.async {
                        running -= 1
                        done += 1
                        if outcome.ok {
                            winners.append(outcome)
                        } else if let failure = outcome.failure {
                            failures[Self.failureKey(failure), default: 0] += 1
                            if let retry = failure.retryConfigs, !learnedKeys.contains(retry) {
                                learnedKeys.append(retry)
                            }
                        }
                        if !winners.isEmpty, !graceArmed {
                            graceArmed = true
                            self.queue.asyncAfter(deadline: .now() + Self.graceInterval) { settle() }
                        }
                        self.setStatus(.racing(done: done, total: total))
                        if pending.isEmpty, running == 0 {
                            settle()
                        } else {
                            pump()
                        }
                    }
                }
            }
        }

        pump()
        queue.asyncAfter(deadline: .now() + Self.raceTotal) { settle() }
    }

    // MARK: - 地址族

    /// 把探测失败归类，便于在日志里看清主因（去掉会变化的具体文案）。
    static func failureKey(_ failure: PreferredNodeProbeOutcome.Failure) -> String {
        switch failure {
        case .tcpConnect: return "tcp 不通"
        case .tcpTimeout: return "tcp 超时"
        case .tlsTimeout: return "tls 超时"
        case .tls(let detail): return "tls: \(detail.prefix(48))"
        case .echRejected(let retryConfigs):
            return retryConfigs == nil ? "ech 被拒（无新钥匙）" : "ech 被拒（有新钥匙）"
        case .httpTimeout: return "http 超时"
        case .httpStatus(let status): return "http \(status)"
        case .bodyMismatch: return "trace 不是 linux.do"
        case .http(let detail): return "http: \(detail.prefix(48))"
        }
    }

    static func accepts(_ ip: String, family: CloudflareRanges.FamilySupport) -> Bool {
        guard CloudflareRanges.isCloudflare(ip), !CloudflareRanges.isSkipped(ip) else { return false }
        return ip.contains(":") ? family.v6 : family.v4
    }

    /// 候选一律先排首选族。
    static func orderedByFamily(
        _ ips: [String],
        family: CloudflareRanges.FamilySupport
    ) -> [String] {
        let v6 = ips.filter { $0.contains(":") }
        let v4 = ips.filter { !$0.contains(":") }
        return family.v4 ? v4 + v6 : v6 + v4
    }
}
