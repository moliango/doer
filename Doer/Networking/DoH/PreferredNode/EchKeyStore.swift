import DohProxy
import Foundation

/// 一把可用的 ECH 钥匙（序列化的 `ECHConfigList`）。
nonisolated struct EchKey: Codable, Equatable, Sendable {
    nonisolated enum Source: String, Codable, Sendable {
        /// 落盘复用
        case persisted
        /// 服务端拒绝 ECH 时当场给的 retry_configs
        case retryConfigs
        /// 公共 DoH 的 HTTPS 记录
        case httpsRecord
        /// atlas 节点表
        case atlas
    }

    var bytes: Data
    var source: Source
    var adoptedAt: Date
}

/// ECH 钥匙池。
///
/// Cloudflare 的 ECH 是**共享钥匙**（public_name 是 `cloudflare-ech.com`），任何开了 ECH 的
/// CF zone 返回的都是同一把。所以可以从非 linux.do 的域名取钥匙 —— 公共 DNS 因此不必知道
/// 我们要连 linux.do。钥匙落盘后，冷启动也不必再打一次 DoH。
///
/// 对齐 cfluxdo `select.rs`：`ECH_KEYS_MAX = 3`、`ECH_KEY_MAX_AGE_SECS = 48h`，
/// 收养时去重并置顶。
nonisolated final class EchKeyStore: @unchecked Sendable {
    static let shared = EchKeyStore()

    static let maxKeys = 3
    static let maxAge: TimeInterval = 48 * 3600

    private static let storageKey = "preferredNode.echKeys.v1"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var stored: [EchKey]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stored = Self.load(from: defaults)
    }

    /// 未过 48h 老化的钥匙，新的在前。
    var liveKeys: [EchKey] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        return stored.filter { now.timeIntervalSince($0.adoptedAt) < Self.maxAge }
    }

    /// 池里最优先的一把。
    var primary: Data? {
        liveKeys.first?.bytes
    }

    /// 收养一把钥匙并置顶（去重、截断到 3 把）。返回是否真的发生了变化。
    @discardableResult
    func adopt(_ bytes: Data, source: EchKey.Source) -> Bool {
        // retry_configs 与 atlas 的 ech 都可能是裸 config，统一补长度前缀。
        let normalized = BoringSSLECH.configList(from: bytes)
        // 空的 ECHConfigList（只剩 2 字节长度前缀）没有意义，别让它占住池位。
        guard normalized.count > 2 else { return false }

        lock.lock()
        if stored.first?.bytes == normalized {
            lock.unlock()
            return false
        }
        stored.removeAll { $0.bytes == normalized }
        stored.insert(EchKey(bytes: normalized, source: source, adoptedAt: Date()), at: 0)
        if stored.count > Self.maxKeys {
            stored.removeLast(stored.count - Self.maxKeys)
        }
        let snapshot = stored
        lock.unlock()

        persist(snapshot)
        DohDebugLog.record(
            "收养 ECH 钥匙 \(normalized.count) 字节（\(source.rawValue)），池内 \(snapshot.count) 把",
            subsystem: "优选"
        )
        return true
    }

    func clear() {
        lock.lock()
        stored.removeAll()
        lock.unlock()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func persist(_ keys: [EchKey]) {
        guard let data = try? JSONEncoder().encode(keys) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [EchKey] {
        guard let data = defaults.data(forKey: storageKey),
              let keys = try? JSONDecoder().decode([EchKey].self, from: data)
        else { return [] }
        return keys
    }
}
