import DohProxy
import Network
import XCTest
@testable import Doer

/// 手动网络测试：验证 **DoH 查询本体**（`DohBootstrapTransport` → `DohHTTPClient` → `NWConnection`）能真正发出请求并拿到答案。
///
/// 为什么需要它：`DohHTTPClient` 以前用自定义 `ContentContext(isFinal: false)` + `isComplete: false`
/// 发送 POST，数据被 Network.framework 留在本地缓冲，查询一律超时，随后回落系统 DNS ——
/// 于是 linux.do 拿到的是投毒地址、HTTPS 记录里也没有 ECH 钥匙，整条 ECH 链路被"静默降级"。
///
/// 会打真网络，只在显式指定时跑：
/// ```
/// xcodebuild test -workspace Doer.xcworkspace -scheme Doer \
///   -destination 'platform=iOS Simulator,name=doerdebug' \
///   -only-testing:DoerTests/DohBootstrapQueryTests
/// ```
final class DohBootstrapQueryTests: XCTestCase {

    /// IP 字面量端点：证书带 IP SAN，查询本身不经系统 DNS。
    private func endpoint() throws -> DohEndpoint {
        try XCTUnwrap(
            DohEndpoint(url: "https://223.5.5.5/dns-query", bootstrapIPs: ["223.5.5.5"], preferIPv6: false)
        )
    }

    func testARecordQueryCompletes() throws {
        let addresses = try query(host: "linux.do", type: DohDNSMessage.typeA)
        print("[bootstrap] linux.do A -> \(addresses.count) 条")
        XCTAssertFalse(addresses.isEmpty, "DoH A 查询没拿到任何地址（多半又是发不出去超时）")
    }

    func testHTTPSRecordCarriesECHKey() throws {
        let query = try XCTUnwrap(DohDNSMessage.makeQuery(host: "cloudflare-ech.com", type: DohHttpsRecord.qtype))
        let semaphore = DispatchSemaphore(value: 0)
        var key: Data?
        var failure: Error?
        DohBootstrapTransport.query(
            endpoint: try endpoint(),
            dnsQuery: query,
            queue: DispatchQueue(label: "bootstrap.https"),
            quiet: false
        ) { result in
            switch result {
            case .success(let body):
                let resources = (try? DohDNSMessage.parseResources(body, expectedType: DohHttpsRecord.qtype)) ?? []
                key = DohHttpsRecord.firstECHConfig(from: resources.map(\.rdata))
            case .failure(let error):
                failure = error
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 12)

        XCTAssertNil(failure, "DoH HTTPS 查询失败：\(String(describing: failure))")
        let config = try XCTUnwrap(key, "HTTPS 记录里没有 ECH 钥匙")
        print("[bootstrap] ECH 钥匙 \(config.count) 字节")
        XCTAssertGreaterThan(config.count, 8)
    }

    private func query(host: String, type: UInt16) throws -> [String] {
        let dnsQuery = try XCTUnwrap(DohDNSMessage.makeQuery(host: host, type: type))
        let semaphore = DispatchSemaphore(value: 0)
        var addresses: [String] = []
        var failure: Error?
        DohBootstrapTransport.query(
            endpoint: try endpoint(),
            dnsQuery: dnsQuery,
            queue: DispatchQueue(label: "bootstrap.a"),
            quiet: false
        ) { result in
            switch result {
            case .success(let body):
                if let resources = try? DohDNSMessage.parseResources(body, expectedType: type) {
                    addresses = resources.compactMap {
                        DohDNSMessage.ipv4String(from: $0.rdata)
                            ?? DohDNSMessage.ipv6String(from: $0.rdata)
                    }
                }
            case .failure(let error):
                failure = error
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 12)
        XCTAssertNil(failure, "DoH 查询失败：\(String(describing: failure))")
        return addresses
    }
}
