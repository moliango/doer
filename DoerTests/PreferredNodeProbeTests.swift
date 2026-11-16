import DohProxy
import Network
import XCTest
@testable import Doer

/// 手动网络测试：在**模拟器/真机的 `NWConnection`** 上跑一遍优选探针的完整往返。
///
/// 为什么单独有这个测试：`Packages/DohProxy` 里的同类测试跑在 macOS 上、用 BSD socket，
/// 绕过了 `NWConnection`。而探针出问题的恰恰是 `NWConnection` 那一层（队列语义、
/// 读循环重挂），所以必须在 iOS 运行时里验证。
///
/// 会打真网络，只在显式指定时跑：
/// ```
/// xcodebuild test -workspace Doer.xcworkspace -scheme Doer \
///   -destination 'platform=iOS Simulator,name=doerdebug' \
///   -only-testing:DoerTests/PreferredNodeProbeTests
/// ```
final class PreferredNodeProbeTests: XCTestCase {

    /// icook.tw 的一个 CF 边缘；Mac 上用 curl 实测 200。
    private let targetIP = "104.20.28.74"

    func testProbeGetsHTTP200WithECH() throws {
        let key = try echKey(domain: "cloudflare-ech.com")
        XCTAssertFalse(key.isEmpty, "没取到 ECH 钥匙，后面的结论不成立")
        print("[probe] ECH key \(key.count) bytes")

        let client = PreferredNodeHTTPSClient(
            echConfig: key,
            timeouts: PreferredNodeHTTPSClient.Timeouts(tcp: 4, tls: 6, http: 6)
        )
        let done = expectation(description: "HTTP 往返")
        var outcome: Result<PreferredNodeHTTPReply, PreferredNodeHTTPFailure>?

        client.request(ip: targetIP, host: "linux.do", path: "/cdn-cgi/trace") { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 20)

        switch outcome {
        case .success(let reply):
            print("[probe] status=\(reply.status) ech Accepted=\(reply.echAccepted) 耗时=\(reply.latencyMs)ms")
            XCTAssertEqual(reply.status, 200, "拿到了响应但状态码不对")
            XCTAssertTrue(reply.echAccepted, "ECH 没被接受，走的可能是明文 SNI")
        case .failure(let failure):
            XCTFail("探针失败：\(failure)")
        case nil:
            XCTFail("20s 内没有回调")
        }
    }

    /// 对照组：**不用 ECH**，连一个没被墙的 CF 域名。
    /// 它通过 → `NWConnection` + `OriginNIOClient` 的读写路径没问题，问题在 ECH；
    /// 它也不通 → 问题在我们的发送/接收胶水层。
    func testProbeWithoutECHToUnblockedCFHost() throws {
        let client = PreferredNodeHTTPSClient(
            echConfig: nil,
            timeouts: PreferredNodeHTTPSClient.Timeouts(tcp: 4, tls: 6, http: 6)
        )
        let done = expectation(description: "对照组往返")
        var outcome: Result<PreferredNodeHTTPReply, PreferredNodeHTTPFailure>?
        client.request(ip: "104.18.20.69", host: "www.visa.com.hk", path: "/cdn-cgi/trace") { result in
            outcome = result
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        switch outcome {
        case .success(let reply):
            print("[plain-ech-off] status=\(reply.status) 耗时=\(reply.latencyMs)ms")
            XCTAssertEqual(reply.status, 200, "拿到响应了但状态码不对")
        case .failure(let failure):
            XCTFail("对照组失败：\(failure)")
        case nil:
            XCTFail("对照组 20s 内没有回调")
        }
    }

    private func echKey(domain: String) throws -> Data {
        let endpoint = try XCTUnwrap(
            DohEndpoint(url: "https://223.5.5.5/dns-query", bootstrapIPs: ["223.5.5.5"], preferIPv6: false)
        )
        let query = try XCTUnwrap(DohDNSMessage.makeQuery(host: domain, type: DohHttpsRecord.qtype))
        let semaphore = DispatchSemaphore(value: 0)
        var key: Data?
        DohBootstrapTransport.query(
            endpoint: endpoint,
            dnsQuery: query,
            queue: DispatchQueue(label: "probe.ech"),
            quiet: false
        ) { result in
            if case .success(let body) = result,
               let resources = try? DohDNSMessage.parseResources(body, expectedType: DohHttpsRecord.qtype)
            {
                key = DohHttpsRecord.firstECHConfig(from: resources.map(\.rdata))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return try XCTUnwrap(key, "没取到 \(domain) 的 ECH 钥匙")
    }
}
