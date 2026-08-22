import XCTest
@testable import Doer

final class LocalConnectProxyTests: XCTestCase {
    func testConnectSuccessResponseIsStreamingHTTP11() throws {
        let text = try XCTUnwrap(String(data: LocalConnectProxy.connectSuccessResponse, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 Connection Established\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(text.contains("Proxy-Agent"))
        XCTAssertFalse(text.contains("Content-Length"))
        XCTAssertFalse(text.contains("Transfer-Encoding"))
    }

    func testPreferredUpstreamAddressesSkipIPv6WhenIPv4Exists() {
        XCTAssertEqual(
            LocalConnectProxy.preferredUpstreamAddresses([
                "2606:4700:10::6814:10ea",
                "104.20.16.234",
                "172.66.166.61",
                "104.20.16.234",
            ]),
            ["104.20.16.234", "172.66.166.61"]
        )
    }

    func testCONNECTProxyDictionaryUsesHTTPSKeys() {
        let dict = LightweightDohProxyService.proxyDictionary(port: 1080)
        XCTAssertEqual(dict["HTTPSEnable"] as? NSNumber, 1)
        XCTAssertEqual(dict["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(dict["HTTPSPort"] as? NSNumber, 1080)
        XCTAssertEqual(dict["ExceptionsList"] as? [String], ["127.0.0.1", "localhost", "::1"])
    }

    func testMITMSkipsCloudflareChallengeHost() {
        XCTAssertTrue(LocalConnectProxy.shouldMITM("linux.do"))
        XCTAssertTrue(LocalConnectProxy.shouldMITM("example.com"))
        XCTAssertFalse(LocalConnectProxy.shouldMITM("challenges.cloudflare.com"))
    }

    func testSocks5GreetingAndDomainConnect() throws {
        let greeting = Data([0x05, 0x01, 0x00])
        let rest = try XCTUnwrap(try Socks5Handshake.consumeGreeting(greeting))
        XCTAssertTrue(rest.isEmpty)

        var request = Data([0x05, 0x01, 0x00, 0x03, 8])
        request.append(contentsOf: "linux.do".utf8)
        request.append(contentsOf: [0x01, 0xBB])
        request.append(contentsOf: [0x16, 0x03])
        let parsed = try XCTUnwrap(try Socks5Handshake.consumeConnect(request))
        XCTAssertEqual(parsed.host, "linux.do")
        XCTAssertEqual(parsed.port, 443)
        XCTAssertEqual(parsed.remainder, Data([0x16, 0x03]))
    }

    func testPreferredUpstreamAddressesKeepIPv6WhenNoIPv4() {
        XCTAssertEqual(
            LocalConnectProxy.preferredUpstreamAddresses([
                "2606:4700:10::6814:10ea",
                "2606:4700:10::ac42:a63d",
            ]),
            ["2606:4700:10::6814:10ea", "2606:4700:10::ac42:a63d"]
        )
    }
}
