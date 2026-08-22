import XCTest
@testable import DohProxy

final class DohParityTests: XCTestCase {
    func testH2ALPNLocksHTTP1WhenDisabled() {
        XCTAssertEqual(H2MitmALPN.protocols(h2Enabled: false), ["http/1.1"])
        XCTAssertTrue(H2MitmALPN.locksHTTP1(H2MitmALPN.protocols(h2Enabled: false)))
        XCTAssertEqual(H2MitmALPN.protocols(h2Enabled: true), ["h2", "http/1.1"])
        XCTAssertFalse(H2MitmALPN.locksHTTP1(H2MitmALPN.protocols(h2Enabled: true)))
    }

    func testHTTPConnectHandshake() {
        let data = UpstreamHandshake.httpConnect(host: "linux.do", port: 443, username: "u", password: "p")
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("CONNECT linux.do:443 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Proxy-Authorization: Basic "))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testSocks5ConnectDomain() {
        let data = UpstreamHandshake.socks5Connect(host: "linux.do", port: 443)
        XCTAssertEqual(data[0], 0x05)
        XCTAssertEqual(data[3], 0x03)
        XCTAssertEqual(data[4], 8)
        XCTAssertEqual(String(data: data.subdata(in: 5 ..< 13), encoding: .utf8), "linux.do")
        XCTAssertEqual(data[13], 0x01)
        XCTAssertEqual(data[14], 0xBB)
    }

    func testShadowsocksKeyLengths() {
        XCTAssertEqual(UpstreamHandshake.shadowsocksKeyLength(cipher: "aes-128-gcm"), 16)
        XCTAssertEqual(UpstreamHandshake.shadowsocksKeyLength(cipher: "aes-256-gcm"), 32)
        XCTAssertEqual(UpstreamHandshake.shadowsocksKeyLength(cipher: "chacha20-ietf-poly1305"), 32)
        XCTAssertEqual(UpstreamHandshake.shadowsocksKeyLength(cipher: "2022-blake3-aes-256-gcm"), 32)
        XCTAssertEqual(UpstreamHandshake.shadowsocksKeyLength(cipher: "unknown"), 0)
    }

    func testGatewayRewritesAbsoluteForm() throws {
        let raw = Data("GET http://127.0.0.1:8080/t/1.json HTTP/1.1\r\nHost: linux.do\r\nAccept: */*\r\n\r\n".utf8)
        let parsed = try XCTUnwrap(try DohGatewayHTTPRequest.parse(raw))
        XCTAssertEqual(parsed.host, "linux.do")
        XCTAssertEqual(parsed.port, 443)
        let text = String(data: parsed.originForm, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("GET /t/1.json HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: linux.do"))
        XCTAssertFalse(text.contains("127.0.0.1"))
    }
}
