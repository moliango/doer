import Darwin
import Foundation

/// 128 位 IPv6 表示。
///
/// `UInt128` 要 iOS 18+，而本项目最低支持 iOS 15，所以自己用高低两个 `UInt64` 拼。
nonisolated struct IPv6Bits: Equatable, Hashable, Sendable {
    var high: UInt64
    var low: UInt64

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    static let zero = IPv6Bits(high: 0, low: 0)

    /// 只保留前 `prefix` 位。
    func masked(_ prefix: UInt8) -> IPv6Bits {
        let bits = min(128, Int(prefix))
        if bits == 0 { return .zero }
        if bits >= 128 { return self }
        if bits <= 64 {
            let shift = UInt64(64 - bits)
            return IPv6Bits(high: (high >> shift) << shift, low: 0)
        }
        let shift = UInt64(128 - bits)
        return IPv6Bits(high: high, low: (low >> shift) << shift)
    }

    static func | (lhs: IPv6Bits, rhs: IPv6Bits) -> IPv6Bits {
        IPv6Bits(high: lhs.high | rhs.high, low: lhs.low | rhs.low)
    }

    /// 前 `prefix` 位之外的位掩码。
    static func hostMask(_ prefix: UInt8) -> UInt64 {
        let bits = min(64, Int(prefix))
        return bits == 0 ? UInt64.max : UInt64.max >> UInt64(bits)
    }

    var string: String {
        let groups: [UInt16] = [
            UInt16(truncatingIfNeeded: high >> 48),
            UInt16(truncatingIfNeeded: high >> 32),
            UInt16(truncatingIfNeeded: high >> 16),
            UInt16(truncatingIfNeeded: high),
            UInt16(truncatingIfNeeded: low >> 48),
            UInt16(truncatingIfNeeded: low >> 32),
            UInt16(truncatingIfNeeded: low >> 16),
            UInt16(truncatingIfNeeded: low),
        ]
        return groups.map { String(format: "%x", $0) }.joined(separator: ":")
    }
}

/// Cloudflare 公布的网段表、归属判断、投毒检查与随机抽样。
///
/// 网段来自 Cloudflare 官方列表（https://www.cloudflare.com/ips-v4 、 /ips-v6），属公开信息，可内置。
/// 移植自 cfluxdo `core/doh_proxy/src/cfnet.rs`。
nonisolated enum CloudflareRanges {

    // MARK: - 网段表

    private static func v4Bits(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt32 {
        (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d)
    }

    private static func v6Bits(_ a: UInt16, _ b: UInt16, _ c: UInt16, _ d: UInt16) -> IPv6Bits {
        IPv6Bits(
            high: (UInt64(a) << 48) | (UInt64(b) << 32) | (UInt64(c) << 16) | UInt64(d),
            low: 0
        )
    }

    /// Cloudflare 公布的 IPv4 网段：(网络号, 前缀长)
    static let v4: [(UInt32, UInt8)] = [
        (v4Bits(173, 245, 48, 0), 20),
        (v4Bits(103, 21, 244, 0), 22),
        (v4Bits(103, 22, 200, 0), 22),
        (v4Bits(103, 31, 4, 0), 22),
        (v4Bits(141, 101, 64, 0), 18),
        (v4Bits(108, 162, 192, 0), 18),
        (v4Bits(190, 93, 240, 0), 20),
        (v4Bits(188, 114, 96, 0), 20),
        (v4Bits(197, 234, 240, 0), 22),
        (v4Bits(198, 41, 128, 0), 17),
        (v4Bits(162, 158, 0, 0), 15),
        (v4Bits(104, 16, 0, 0), 13),
        (v4Bits(104, 24, 0, 0), 14),
        (v4Bits(172, 64, 0, 0), 13),
        (v4Bits(131, 0, 72, 0), 22),
    ]

    /// Cloudflare 公布的 IPv6 网段：(网络号, 前缀长)
    static let v6: [(IPv6Bits, UInt8)] = [
        (v6Bits(0x2400, 0xcb00, 0, 0), 32),
        (v6Bits(0x2606, 0x4700, 0, 0), 32),
        (v6Bits(0x2803, 0xf800, 0, 0), 32),
        (v6Bits(0x2405, 0xb500, 0, 0), 32),
        (v6Bits(0x2405, 0x8100, 0, 0), 32),
        (v6Bits(0x2a06, 0x98c0, 0, 0), 29),
        (v6Bits(0x2c0f, 0xf248, 0, 0), 32),
    ]

    /// 抽样时跳过的 IPv4 网段：104.16.0.0/15 是 Cloudflare 自家资产段，
    /// 实测不服务其他 zone，握手会被拒，白白浪费一次探测额度。
    static let skipV4: [(UInt32, UInt8)] = [(v4Bits(104, 16, 0, 0), 15)]

    // MARK: - 归属判断

    private static func v4Mask(_ prefix: UInt8) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << UInt32(32 - min(32, prefix))
    }

    private static func v4In(_ bits: UInt32, _ ranges: [(UInt32, UInt8)]) -> Bool {
        ranges.contains { network, prefix in bits & v4Mask(prefix) == network }
    }

    private static func v6In(_ bits: IPv6Bits, _ ranges: [(IPv6Bits, UInt8)]) -> Bool {
        ranges.contains { network, prefix in bits.masked(prefix) == network }
    }

    /// 地址是否落在 Cloudflare 公布的网段里。
    static func isCloudflare(_ ip: String) -> Bool {
        if let bits = ipv4Bits(ip) { return v4In(bits, v4) }
        if let bits = ipv6Bits(ip) { return v6In(bits, v6) }
        return false
    }

    /// 地址是否落在抽样跳过表里（只对 IPv4 有跳过表）。
    static func isSkipped(_ ip: String) -> Bool {
        guard let bits = ipv4Bits(ip) else { return false }
        return v4In(bits, skipV4)
    }

    /// 投毒检查：答案非空且全部落在 Cloudflare 网段。国内部分解析器会给 Cloudflare 域名
    /// 塞 Twitter/Facebook 段的假地址，这里一刀切。
    static func allCloudflare(_ ips: [String]) -> Bool {
        !ips.isEmpty && ips.allSatisfy(isCloudflare)
    }

    // MARK: - 解析 / 格式化

    static func ipv4Bits(_ ip: String) -> UInt32? {
        var address = in_addr()
        guard inet_pton(AF_INET, ip, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func ipv6Bits(_ ip: String) -> IPv6Bits? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, ip, &address) == 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: address) { raw in
            for (index, byte) in raw.enumerated() where index < 16 {
                bytes[index] = byte
            }
        }
        var high: UInt64 = 0
        for index in 0 ..< 8 { high = (high << 8) | UInt64(bytes[index]) }
        var low: UInt64 = 0
        for index in 8 ..< 16 { low = (low << 8) | UInt64(bytes[index]) }
        return IPv6Bits(high: high, low: low)
    }

    static func ipv4String(_ bits: UInt32) -> String {
        "\((bits >> 24) & 0xFF).\((bits >> 16) & 0xFF).\((bits >> 8) & 0xFF).\(bits & 0xFF)"
    }

    // MARK: - 抽样

    private static func randomBelow(_ bound: UInt64) -> UInt64 {
        guard bound > 0 else { return 0 }
        return UInt64.random(in: 0 ..< bound)
    }

    /// 按网段大小加权随机抽 `count` 个 IPv4：每个 /24 最多一个，主机位取 [1, 254]，
    /// 跳过 `skipV4`。抽不满（随机数源退化）就返回已有的。
    static func sampleIPv4(count: Int) -> [String] {
        guard count > 0 else { return [] }
        let weights: [UInt64] = v4.map { _, prefix in
            UInt64(1) << UInt64(24 - min(24, Int(prefix)))
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        var seen24 = Set<UInt32>()
        var out: [String] = []
        var attempts = 0
        // 拒绝采样有上限，避免 count 过大时死循环。
        while out.count < count, attempts < count * 16 {
            attempts += 1
            var pick = randomBelow(total)
            var index = 0
            // 边走边减：`pick` 到 break 时是落在该网段内的偏移。
            for (offset, weight) in weights.enumerated() {
                if pick < weight {
                    index = offset
                    break
                }
                pick -= weight
            }

            let subnet = v4[index].0 &+ (UInt32(pick) << 8)
            if seen24.contains(subnet) { continue }
            let bits = subnet | UInt32(1 + randomBelow(254))
            if v4In(bits, skipV4) { continue }
            seen24.insert(subnet)
            out.append(ipv4String(bits))
        }
        return out
    }

    /// 按网段大小加权随机抽 `count` 个 IPv6：每个 /64 最多一个，接口标识随机（非零）。
    static func sampleIPv6(count: Int) -> [String] {
        guard count > 0 else { return [] }
        let weights: [UInt64] = v6.map { _, prefix in
            UInt64(1) << UInt64(64 - min(64, Int(prefix)))
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }

        var seen64 = Set<UInt64>()
        var out: [String] = []
        var attempts = 0
        while out.count < count, attempts < count * 16 {
            attempts += 1
            var pick = randomBelow(total)
            var index = 0
            for (offset, weight) in weights.enumerated() {
                if pick < weight {
                    index = offset
                    break
                }
                pick -= weight
            }

            let (network, prefix) = v6[index]
            // 网络前缀之外的高位由随机 /64 序号填充（`high` 的低 64-prefix 位）。
            let subnetHigh = (network.high & ~IPv6Bits.hostMask(prefix)) | pick
            if seen64.contains(subnetHigh) { continue }
            var interfaceID = UInt64.random(in: 0 ... UInt64.max)
            if interfaceID == 0 { interfaceID = 1 }
            seen64.insert(subnetHigh)
            out.append(IPv6Bits(high: subnetHigh, low: interfaceID).string)
        }
        return out
    }

    // MARK: - 本机地址族

    struct FamilySupport: Equatable {
        var v4: Bool
        var v6: Bool

        static let none = FamilySupport(v4: false, v6: false)
        static let both = FamilySupport(v4: true, v6: true)

        var isEmpty: Bool { !v4 && !v6 }
    }

    /// 探测本机是否有 v4 / v6 出站路由：UDP socket 上 connect 只查路由表，不发任何包。
    static func localFamilySupport() -> FamilySupport {
        FamilySupport(
            v4: canRoute(remote: "1.1.1.1", family: AF_INET),
            v6: canRoute(remote: "2606:4700:4700::1111", family: AF_INET6)
        )
    }

    private static func canRoute(remote: String, family: Int32) -> Bool {
        let descriptor = socket(family, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(443).bigEndian
            guard inet_pton(AF_INET, remote, &address.sin_addr) == 1 else { return false }
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, size)
                }
            } == 0
        }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(443).bigEndian
        guard inet_pton(AF_INET6, remote, &address.sin6_addr) == 1 else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, size)
            }
        } == 0
    }
}
