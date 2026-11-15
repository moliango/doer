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
        defer { lock.unlock() }
        return stored?.ip
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
