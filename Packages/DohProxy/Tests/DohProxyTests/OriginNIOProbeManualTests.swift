import Foundation
import XCTest
@testable import DohProxy

/// 手动网络测试：用真实的 CF 边缘复现优选探针的 `OriginNIOClient` 写路径。
///
/// 默认跳过（会打真网络）。要跑：
/// ```
/// DOER_NIO_PROBE=1 swift test --filter OriginNIOProbeManualTests
/// DOER_NIO_PROBE=1 DOER_NIO_WRITE_DELAY=0 swift test --filter ...   # 握手前就写
/// ```
final class OriginNIOProbeManualTests: XCTestCase {

    func testProbeGetsHTTPResponse() throws {
        guard ProcessInfo.processInfo.environment["DOER_NIO_PROBE"] == "1" else {
            throw XCTSkip("手动网络测试，设 DOER_NIO_PROBE=1 才跑")
        }
        let delay = Double(ProcessInfo.processInfo.environment["DOER_NIO_WRITE_DELAY"] ?? "0.3") ?? 0.3
        let ip = ProcessInfo.processInfo.environment["DOER_NIO_PROBE_IP"] ?? "104.20.28.74"

        let key = try echKey(domain: "cloudflare-ech.com")
        print("[probe] ECH key \(key.count) bytes")

        let fd = try connect(ip: ip, port: 443)
        defer { Darwin.close(fd) }

        let lock = NSLock()
        var plaintext = Data()
        var appSent = 0
        var wireReceived = 0
        let gotResponse = expectation(description: "HTTP 响应")

        let client = try OriginNIOClient(
            sni: "linux.do",
            applicationProtocols: ["http/1.1"],
            echConfig: key
        )
        print("[probe] echInjected=\(client.echInjected)")

        let socketWrite: (Data, @escaping () -> Void) -> Void = { data, done in
            lock.lock()
            appSent += data.count
            lock.unlock()
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < data.count {
                    let written = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
                    if written <= 0 { break }
                    offset += written
                }
            }
            done()
        }

        client.start(
            socketRead: { deliver in
                DispatchQueue.global().async {
                    var buffer = [UInt8](repeating: 0, count: 16_384)
                    let count = Darwin.recv(fd, &buffer, buffer.count, 0)
                    lock.lock()
                    if count > 0 { wireReceived += count }
                    lock.unlock()
                    deliver(count > 0 ? Data(buffer[0 ..< count]) : nil)
                }
            },
            socketWrite: socketWrite,
            appRead: { plain in
                lock.lock()
                plaintext.append(plain)
                let snapshot = plaintext
                let total = appSent
                lock.unlock()
                print("[probe] 明文 +\(plain.count)B（累计 \(snapshot.count)B，已发 \(total)B）")
                if snapshot.range(of: Data("HTTP/1.1 200".utf8)) != nil {
                    gotResponse.fulfill()
                }
            },
            completion: { ok in print("[probe] completion \(ok)") },
            onHandshake: { ok in
                print("[probe] handshake \(ok) echAccepted=\(client.echAccepted) err=\(client.lastError ?? "-")")
            }
        )

        let request = Data(
            "GET /cdn-cgi/trace HTTP/1.1\r\nHost: linux.do\r\nUser-Agent: okhttp/4.12.0\r\nAccept: */*\r\nConnection: close\r\n\r\n".utf8
        )
        print("[probe] 请求 \(request.count)B，\(delay)s 后写入")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            client.writeApplication(request, socketWrite: socketWrite)
        }

        let result = XCTWaiter().wait(for: [gotResponse], timeout: 10)
        lock.lock()
        let received = plaintext
        let wire = wireReceived
        lock.unlock()
        print("[probe] 线路收到 \(wire)B，明文 \(received.count)B")
        XCTAssertEqual(result, .completed, "10s 内没拿到 HTTP 200，明文首段：\(String(data: received.prefix(200), encoding: .isoLatin1) ?? "<空>")")
    }

    // MARK: - 工具

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

    private func connect(ip: String, port: UInt16) throws -> Int32 {
        var storage = sockaddr_in()
        storage.sin_family = sa_family_t(AF_INET)
        storage.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &storage.sin_addr) == 1 else {
            throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad ip \(ip)"])
        }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "probe", code: 2) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "connect \(ip):\(port) failed"])
        }
        return fd
    }
}
