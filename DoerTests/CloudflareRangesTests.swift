import XCTest

@testable import Doer

/// 用例逐条移植自 cfluxdo `core/doh_proxy/src/cfnet.rs` 的 `#[cfg(test)]`。
final class CloudflareRangesTests: XCTestCase {

    // MARK: - IPv4 网段边界

    func testCloudflareV4Boundaries() {
        for ip in ["104.16.0.0", "104.23.255.255", "104.24.0.0", "104.27.255.255"] {
            XCTAssertTrue(CloudflareRanges.isCloudflare(ip), "\(ip) 应在 CF 网段内")
        }
        XCTAssertFalse(CloudflareRanges.isCloudflare("104.28.0.0"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("172.64.0.1"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("172.71.255.255"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("172.72.0.0"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("162.159.0.1"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("198.41.128.1"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("198.41.127.255"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("8.8.8.8"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("1.1.1.1"))
    }

    // MARK: - IPv6 网段边界

    func testCloudflareV6Boundaries() {
        XCTAssertTrue(CloudflareRanges.isCloudflare("2606:4700::1"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("2606:4700:ffff:ffff:ffff:ffff:ffff:ffff"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("2606:4701::1"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("2a06:98c0::1"))
        XCTAssertTrue(CloudflareRanges.isCloudflare("2a06:98c7:ffff::1"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("2a06:98c8::1"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("2001:4860:4860::8888"))
    }

    func testMalformedAddressIsNotCloudflare() {
        XCTAssertFalse(CloudflareRanges.isCloudflare(""))
        XCTAssertFalse(CloudflareRanges.isCloudflare("not-an-ip"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("256.1.1.1"))
        XCTAssertFalse(CloudflareRanges.isCloudflare("104.21"))
    }

    // MARK: - 抽样跳过表

    func testSkipTableCoversOnly104_16Slash15() {
        XCTAssertTrue(CloudflareRanges.isSkipped("104.16.1.1"))
        XCTAssertTrue(CloudflareRanges.isSkipped("104.17.255.254"))
        XCTAssertFalse(CloudflareRanges.isSkipped("104.18.0.1"))
        XCTAssertFalse(CloudflareRanges.isSkipped("104.21.58.192"))
        XCTAssertFalse(CloudflareRanges.isSkipped("2606:4700::1"))
    }

    // MARK: - 投毒检查

    func testPoisonCheckRequiresNonEmptyAndAllCloudflare() {
        XCTAssertFalse(CloudflareRanges.allCloudflare([]))
        XCTAssertTrue(CloudflareRanges.allCloudflare(["104.21.58.192", "2606:4700::1"]))
        XCTAssertFalse(CloudflareRanges.allCloudflare(["104.21.58.192", "31.13.94.36"]))
    }

    // MARK: - 抽样

    func testV4SamplesAreDistinctCloudflareAndNotSkipped() {
        let ips = CloudflareRanges.sampleIPv4(count: 12)
        XCTAssertEqual(ips.count, 12)

        var subnets = Set<UInt32>()
        for ip in ips {
            XCTAssertTrue(CloudflareRanges.isCloudflare(ip), "\(ip) 不在 CF 网段")
            XCTAssertFalse(CloudflareRanges.isSkipped(ip), "\(ip) 在跳过表里")

            let parts = ip.split(separator: ".").compactMap { UInt8($0) }
            XCTAssertEqual(parts.count, 4)
            XCTAssertTrue((1 ... 254).contains(parts[3]), "\(ip) 主机位越界")

            let bits = CloudflareRanges.ipv4Bits(ip) ?? 0
            subnets.insert(bits & 0xFFFF_FF00)
        }
        XCTAssertEqual(subnets.count, 12, "每个 /24 最多一个")
    }

    func testV6SamplesAreDistinctCloudflareWithNonZeroInterfaceID() {
        let ips = CloudflareRanges.sampleIPv6(count: 4)
        XCTAssertEqual(ips.count, 4)

        var prefixes = Set<UInt64>()
        for ip in ips {
            XCTAssertTrue(CloudflareRanges.isCloudflare(ip), "\(ip) 不在 CF 网段")
            guard let bits = CloudflareRanges.ipv6Bits(ip) else {
                XCTFail("无法解析 \(ip)")
                continue
            }
            XCTAssertNotEqual(bits.low, 0, "\(ip) 接口标识不能为 0")
            prefixes.insert(bits.high)
        }
        XCTAssertEqual(prefixes.count, 4, "每个 /64 最多一个")
    }

    func testSampleCountZeroReturnsEmpty() {
        XCTAssertTrue(CloudflareRanges.sampleIPv4(count: 0).isEmpty)
        XCTAssertTrue(CloudflareRanges.sampleIPv6(count: 0).isEmpty)
    }

    // MARK: - 本机地址族

    func testLocalFamilySupportDoesNotPanic() {
        _ = CloudflareRanges.localFamilySupport()
    }

    // MARK: - IPv6Bits

    func testIPv6MaskingMatchesPublishedPrefix() {
        guard let bits = CloudflareRanges.ipv6Bits("2a06:98c7:ffff:ffff::1") else {
            XCTFail("解析失败")
            return
        }
        // 2a06:98c0::/29 是 v6 表里唯一一个非 /32 的网段
        XCTAssertEqual(bits.masked(29), CloudflareRanges.v6[5].0)
        XCTAssertEqual(CloudflareRanges.v6[5].1, 29)
    }

    func testIPv6StringRoundTrips() {
        for text in ["2606:4700:4700::1111", "2a06:98c0::1", "2400:cb00:1234:5678:9abc:def0:1234:5678"] {
            guard let bits = CloudflareRanges.ipv6Bits(text) else {
                XCTFail("解析失败 \(text)")
                continue
            }
            XCTAssertEqual(CloudflareRanges.ipv6Bits(bits.string), bits, "\(text) 往返不一致")
        }
    }
}
