import DohProxy
import Foundation

/// 「自动」DoH 选服：并发探测内置服务器，取**最快且应答合法**的那个。
///
/// 用户不需要知道自己在用哪台 DNS：设置里选「自动」之后，这里负责挑，
/// 挑出来的结果存进 `dohAutoSelectedURL`，`AppSettings.dohProxyConfig` 直接读它。
///
/// 设计要点：
/// - 冷启动**不等探测**：没有历史结果时配置层落回 DNSPod，探测在后台跑完再热切换。
/// - 探测复用 `DohBootstrapTransport.query`（已有 0.3s 错峰 + 最多 3 个 IP 竞速），
///   所以被墙的 bootstrap IP 不会让一个候选拖满超时。
/// - 一轮只认第一个返回**含 Cloudflare 网段 A 记录**的候选：国内解析器会把 linux.do
///   解析成假地址，那种应答必须淘汰，否则自动模式会主动选一台投毒的服务器。
/// - 3 秒没有可用结果就放弃，保持现状。
nonisolated enum DoHServerAutoSelector {

    enum Trigger: String {
        /// 启动 / 配置变更后。
        case launch
        /// Wi‑Fi ↔ 蜂窝切换等路径变化。
        case networkChange
        /// 当前 DoH 连续查询失败，已退回系统 DNS。
        case watchdog
        /// 回前台时的周期重选。
        case periodic
        /// 用户在设置里点了「自动」。
        case manual

        /// 是否受 6 小时节流限制。
        var respectsRefreshInterval: Bool {
            switch self {
            case .launch, .periodic: return true
            case .networkChange, .watchdog, .manual: return false
            }
        }
    }

    /// 同一网络下的重选间隔。
    static let refreshInterval: TimeInterval = 6 * 3600
    /// 一轮探测的总预算。超过就放弃，保留当前服务器。
    private static let scanTimeout: TimeInterval = 3
    /// 探测用的目标域名，与日常解析一致，不额外制造特征。
    private static let probeHost = "linux.do"

    private static let lock = NSLock()
    private static var isScanning = false
    private static var generation = 0
    private static let queue = DispatchQueue(
        label: "doer.doh.auto-select",
        attributes: .concurrent
    )
    /// 超时兜底单独排队：探测线程可能被 `getaddrinfo` 同步阻塞，超时不跟着挨饿。
    private static let timerQueue = DispatchQueue(label: "doer.doh.auto-select.timer")

    /// 参与自动选服的候选：内置且自带 bootstrap 的服务器。
    ///
    /// 没有 bootstrap 的预设（Canadian Shield）和用户自定义服务器不参与——
    /// 前者本来就要求系统 DNS 才连得上，后者是用户显式选择的结果。
    static var candidates: [AppSettings.DoHProvider] {
        AppSettings.DoHProvider.builtInDisplayOrder.filter { !$0.bootstrapIPs.isEmpty }
    }

    static func rescan(trigger: Trigger, completion: ((String?) -> Void)? = nil) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "dohEnabled"),
              AppSettings.dohAutoSelectEnabled(from: defaults)
        else {
            completion?(nil)
            return
        }
        if trigger.respectsRefreshInterval, !isDueForRefresh(defaults: defaults) {
            completion?(nil)
            return
        }

        lock.lock()
        if isScanning {
            // 触发条件本身幂等，扫描中再来一次直接丢弃，不排队。
            lock.unlock()
            completion?(nil)
            return
        }
        isScanning = true
        generation += 1
        let round = generation
        lock.unlock()

        // 扫描必须在后台跑：候选里的 DoH host 不是 IP 时，`DohBootstrapTransport.query`
        // 会同步做一次 `getaddrinfo`。触发点之一是启动时的主线程 `configureFromSettings()`，
        // 放在主线程会直接把冷启动卡住几秒。
        queue.async {
            runScan(trigger: trigger, round: round, completion: completion)
        }
    }

    private static func runScan(trigger: Trigger, round: Int, completion: ((String?) -> Void)?) {
        let defaults = UserDefaults.standard
        // 排队这几毫秒里用户可能已经关掉 DoH 或切回手动：一个请求都不发（R1.7）。
        guard defaults.bool(forKey: "dohEnabled"),
              AppSettings.dohAutoSelectEnabled(from: defaults)
        else {
            resetScanFlag(round: round)
            completion?(nil)
            return
        }

        let startedAt = Date()
        let preferIPv6 = defaults.bool(forKey: "dohPreferIPv6")
        let currentURL = AppSettings.effectiveDoHServer(from: defaults).url
        DohDebugLog.record(
            "自动选服开始（\(trigger.rawValue)），候选 \(candidates.count) 台，当前 \(hostOf(currentURL))",
            subsystem: "DoH"
        )

        let probeLock = NSLock()
        var settled = false
        var arrived = [String]()

        func finish(winner: AppSettings.DoHProvider?) {
            probeLock.lock()
            if settled {
                probeLock.unlock()
                return
            }
            settled = true
            // 在这里取快照：扫描期间失败回调仍可能在别的线程 append，
            // 锁外读 `arrived` 会构成数据竞争。
            let pending = arrived
            probeLock.unlock()

            resetScanFlag(round: round)

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            guard let winner else {
                let detail = pending.isEmpty
                    ? "全部候选未在 \(Int(scanTimeout))s 内给出应答"
                    : "候选应答均不可用：\(pending.joined(separator: ", "))"
                DohDebugLog.record("自动选服失败（\(elapsedMs)ms）：\(detail)", subsystem: "DoH")
                completion?(nil)
                return
            }
            apply(
                winner: winner,
                currentURL: currentURL,
                trigger: trigger,
                elapsedMs: elapsedMs,
                completion: completion
            )
        }

        timerQueue.asyncAfter(deadline: .now() + scanTimeout) {
            finish(winner: nil)
        }

        for provider in candidates {
            guard let endpoint = DohEndpoint(
                url: provider.url,
                bootstrapIPs: provider.bootstrapIPs,
                preferIPv6: preferIPv6
            ), endpoint.isReady,
                let query = DohDNSMessage.makeQuery(host: probeHost, type: DohDNSMessage.typeA)
            else {
                continue
            }
            // 每个候选各占一个并发 worker：串行发起时，前面候选的同步系统解析
            // 会把后面的候选挤到 3 秒预算之外。
            queue.async {
                DohBootstrapTransport.query(
                    endpoint: endpoint,
                    dnsQuery: query,
                    queue: queue,
                    quiet: true
                ) { result in
                    switch result {
                    case .success(let body):
                        // HTTP 200 只说明服务器答了。还要确认答里带的是**真的** linux.do
                        // 地址：linux.do 在 Cloudflare 上，国内解析器对它会回 Facebook 段的
                        // 假地址（实测 157.240.6.35 / 2a03:2880:…:face:b00c）。这种服务器
                        // "能解析但解析错"，选进来比不换更糟——那正是开了 DoH 反而没网的成因。
                        let records = (try? DohDNSMessage.parseResources(
                            body,
                            expectedType: DohDNSMessage.typeA
                        )) ?? []
                        let addresses = records.compactMap {
                            DohDNSMessage.ipv4String(from: $0.rdata)
                        }
                        guard !addresses.isEmpty else {
                            probeLock.lock()
                            arrived.append("\(provider.title)(空应答)")
                            probeLock.unlock()
                            return
                        }
                        guard addresses.contains(where: CloudflareRanges.isCloudflare) else {
                            probeLock.lock()
                            arrived.append(
                                "\(provider.title)(投毒 \(addresses.prefix(2).joined(separator: "/")))"
                            )
                            probeLock.unlock()
                            return
                        }
                        finish(winner: provider)
                    case .failure(let error):
                        probeLock.lock()
                        arrived.append("\(provider.title)(\(Self.shortReason(error)))")
                        probeLock.unlock()
                    }
                }
            }
        }
    }

    /// 只有当前这一轮才有资格清标记，避免旧一轮的收尾把新一轮的 `isScanning` 抹掉。
    private static func resetScanFlag(round: Int) {
        lock.lock()
        if round == generation { isScanning = false }
        lock.unlock()
    }

    // MARK: - 落地

    private static func apply(
        winner: AppSettings.DoHProvider,
        currentURL: String,
        trigger: Trigger,
        elapsedMs: Int,
        completion: ((String?) -> Void)?
    ) {
        // 扫描的这几秒里用户可能已经关掉 DoH 或改回手动服务器：
        // 那样既不该写结果，也不该把服务器装回去（R1.7）。
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "dohEnabled"),
              AppSettings.dohAutoSelectEnabled(from: defaults)
        else {
            DohDebugLog.record("自动选服结果丢弃：DoH 已关闭或已切回手动", subsystem: "DoH")
            completion?(nil)
            return
        }
        let winnerURL = DohServerCatalog.normalize(winner.url)
        let changed = winnerURL != DohServerCatalog.normalize(currentURL)
        // 直接写 UserDefaults：这一层是 nonisolated 的，不能碰主线程隔离的
        // `AppSettings.shared`。通知由下一次主线程刷新补上。
        defaults.set(winnerURL, forKey: "dohAutoSelectedURL")
        defaults.set(Date().timeIntervalSince1970, forKey: "dohAutoSelectedAt")
        DohDebugLog.record(
            "自动选服\(changed ? "切换" : "确认")到 \(winner.title)"
                + "（\(trigger.rawValue)，\(elapsedMs)ms）",
            subsystem: "DoH"
        )
        completion?(winnerURL)
        DispatchQueue.main.async {
            AppSettings.shared.notifyChanged()
            guard changed else { return }
            // 换服务器后 Encrypted DNS 的 spec 也变了，走现有 reapply 路径：
            // 那里会重新探活、代次守卫、按需清缓存，不绕过任何安全检查。
            LightweightDohProxyService.shared.configureFromSettings()
        }
    }

    // MARK: - 节流

    private static func isDueForRefresh(defaults: UserDefaults) -> Bool {
        guard let last = defaults.object(forKey: "dohAutoSelectedAt") as? Double else { return true }
        return Date().timeIntervalSince1970 - last >= refreshInterval
    }

    private static func hostOf(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private static func shortReason(_ error: Error) -> String {
        if let proxyError = error as? DohProxyError {
            switch proxyError {
            case .bootstrapUnavailable: return "无 bootstrap"
            case .queryFailed: return "查询失败"
            case .malformedDNSResponse: return "应答损坏"
            default: return "失败"
            }
        }
        let text = error.localizedDescription
        return text.count > 24 ? String(text.prefix(24)) + "…" : text
    }
}
