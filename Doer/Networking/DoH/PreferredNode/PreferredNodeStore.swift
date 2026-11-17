import Foundation

/// 优选赢家：linux.do 及其子域统一走这一个边缘 IP、同一地址族。
///
/// 不变式：CF 的 `cf_clearance` 绑定出口 IP，双栈网络下 v4 与 v6 是两个出口。
/// 子域换 IP 会让在 linux.do 上铸出的 clearance 直接失效（稳定 403）。
nonisolated struct PreferredNode: Codable, Equatable, Sendable {
    nonisolated enum Family: String, Codable, Sendable {
        case v4
        case v6

        var prefersIPv6: Bool { self == .v6 }
    }

    nonisolated enum Source: String, Codable, Sendable {
        case sticky
        case atlas
        case vendor
        case random
    }

    var ip: String
    var family: Family
    var latencyMs: Int
    var selectedAt: Date
    var source: Source
    /// 竞速时用的 ECH 钥匙。连赢家时直接用它，就不必再去解析 linux.do 的 HTTPS 记录。
    var echConfig: Data? = nil
}

/// 赢家落盘与钉选。`LocalConnectProxy` 在建连时实时读它，所以换节点不需要重建会话。
nonisolated final class PreferredNodeStore: @unchecked Sendable {
    static let shared = PreferredNodeStore()

    private static let storageKey = "preferredNode.v1"
    /// 连败计数窗口：窗口外的失败不累计。
    private static let demoteWindow: TimeInterval = 60
    private static let demoteFailStreak = 3

    /// 赢家连续失败到阈值时回调（Selector 借此降级重赛）。
    var onWinnerDemoted: (() -> Void)?

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var stored: PreferredNode?
    private var failStreak = 0
    private var lastFailureAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = Self.load(from: defaults)
    }

    var node: PreferredNode? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            failStreak = 0
            lastFailureAt = nil
            lock.unlock()
            persist(newValue)
        }
    }

    /// 被覆盖的域名在存在赢家时一律先连赢家，不看各自的粘性 IP。
    func pinnedAddress(forHost host: String) -> String? {
        guard Self.isCoveredHost(host) else { return nil }
        lock.lock()
        let ip = stored?.ip
        lock.unlock()
        guard let ip else { return nil }
        // 赢家是上一个网络选出来的：换到只有 v4 的蜂窝时钉着一个 v6 地址，
        // 每次 CONNECT 都要先白等 8 秒超时才回退解析。
        guard Self.isRoutable(ip) else { return nil }
        return ip
    }

    /// CF 自家域名（验证页、Turnstile、CDN）不是 linux.do 子域，但同样落在 CF 边缘上：
    /// 任何 CF 边缘 IP 都服务所有 CF zone，所以 DoH 解析不出来时连赢家 IP + 正确 SNI 仍然可用。
    /// **只在解析失败时用**，不参与 linux.do 的钉选语义（`cf_clearance` 仍按 `isCoveredHost` 绑定）。
    func cloudflareEdgeAddress() -> String? {
        lock.lock()
        let ip = stored?.ip
        lock.unlock()
        guard let ip, Self.isRoutable(ip) else { return nil }
        return ip
    }

    private static func isRoutable(_ ip: String) -> Bool {
        let family = CloudflareRanges.localFamilySupport()
        return ip.contains(":") ? family.v6 : family.v4
    }

    /// linux.do 与其子域必须连同一个边缘 IP、走同一个地址族。
    static func isCoveredHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "linux.do" || normalized.hasSuffix(".linux.do")
    }

    /// 建连结果回报：赢家在窗口内连败到阈值即解除钉住，交给 Selector 降级重赛。
    func reportOutcome(host: String, ip: String, success: Bool) {
        guard Self.isCoveredHost(host) else { return }
        lock.lock()
        guard let current = stored, current.ip == ip else {
            lock.unlock()
            return
        }
        if success {
            failStreak = 0
            lastFailureAt = nil
            lock.unlock()
            return
        }
        let now = Date()
        if let last = lastFailureAt, now.timeIntervalSince(last) > Self.demoteWindow {
            failStreak = 0
        }
        failStreak += 1
        lastFailureAt = now
        let demoted = failStreak >= Self.demoteFailStreak
        if demoted {
            stored = nil
            failStreak = 0
            lastFailureAt = nil
        }
        lock.unlock()

        guard demoted else { return }
        persist(nil)
        DohDebugLog.record(
            "赢家连败 \(Self.demoteFailStreak) 次，解除钉住 \(ip)",
            subsystem: "优选"
        )
        onWinnerDemoted?()
    }

    /// 换网后校验一次赢家。
    ///
    /// - 地址族在新网络里不可路由：直接解除钉住，不然每次 CONNECT 都白等 8 秒。
    /// - 还能路由：保留（免得 linux.do 立刻没网），但把连败计数顶到阈值前一次，
    ///   新网络上它还没被验证过，第一次失败就该降级重赛，而不是连败三次。
    func handlePathChange() {
        lock.lock()
        let ip = stored?.ip
        let drop = ip.map { !Self.isRoutable($0) } ?? false
        if drop {
            stored = nil
            failStreak = 0
        } else {
            failStreak = max(0, Self.demoteFailStreak - 1)
        }
        lastFailureAt = nil
        lock.unlock()

        guard let ip else { return }
        if drop {
            persist(nil)
            DohDebugLog.record("换网后赢家 \(ip) 地址族不可路由，解除钉住", subsystem: "优选")
        } else {
            DohDebugLog.record("换网：赢家 \(ip) 保留，下一次连败即降级", subsystem: "优选")
        }
    }

    func clear() {
        node = nil
    }

    // MARK: - 持久化

    private func persist(_ value: PreferredNode?) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> PreferredNode? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PreferredNode.self, from: data)
    }
}
