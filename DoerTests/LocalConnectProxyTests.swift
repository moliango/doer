import Alamofire
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

    func testDoHReappliesWhenProxyDiedWithSameSignature() {
        XCTAssertTrue(
            LightweightDohProxyService.DohProxyLiveness.shouldReapply(
                enabled: true,
                signatureChanged: false,
                isLive: false
            )
        )
        XCTAssertFalse(
            LightweightDohProxyService.DohProxyLiveness.shouldReapply(
                enabled: true,
                signatureChanged: false,
                isLive: true
            )
        )
        XCTAssertTrue(
            LightweightDohProxyService.DohProxyLiveness.shouldReapply(
                enabled: true,
                signatureChanged: true,
                isLive: true
            )
        )
        XCTAssertFalse(
            LightweightDohProxyService.DohProxyLiveness.shouldReapply(
                enabled: false,
                signatureChanged: false,
                isLive: false
            )
        )
    }

    func testDoHProbeResultSubtitleIncludesLatencyAndIPs() {
        let ok = LightweightDohProxyService.ProbeResult(
            ok: true,
            latencyMs: 128,
            host: "linux.do",
            addresses: ["104.20.16.234", "172.66.166.61"],
            errorDescription: nil
        )
        XCTAssertEqual(ok.subtitle, "128 ms · linux.do → 104.20.16.234, 172.66.166.61")

        let failed = LightweightDohProxyService.ProbeResult(
            ok: false,
            latencyMs: 20,
            host: "linux.do",
            addresses: [],
            errorDescription: "timeout"
        )
        XCTAssertEqual(failed.subtitle, "timeout")
    }

    func testMITMSkipsCloudflareChallengeHost() {
        let previous = LocalConnectProxy.originECHReady
        LocalConnectProxy.originECHReady = false
        XCTAssertFalse(LocalConnectProxy.shouldMITM("linux.do"))
        LocalConnectProxy.originECHReady = true
        XCTAssertTrue(LocalConnectProxy.shouldMITM("linux.do"))
        XCTAssertTrue(LocalConnectProxy.shouldMITM("example.com"))
        XCTAssertFalse(LocalConnectProxy.shouldMITM("challenges.cloudflare.com"))
        LocalConnectProxy.originECHReady = previous
    }

    func testLoopbackGatewayHostDetection() {
        XCTAssertTrue(LocalConnectProxy.isLoopbackGatewayHost("127.0.0.1"))
        XCTAssertTrue(LocalConnectProxy.isLoopbackGatewayHost("localhost"))
        XCTAssertFalse(LocalConnectProxy.isLoopbackGatewayHost("linux.do"))
    }

    func testURLSessionSkipsCONNECTWhenOriginECHDisabled() {
        let previousECH = LocalConnectProxy.originECHReady
        let previousDoH = UserDefaults.standard.bool(forKey: "dohEnabled")
        LocalConnectProxy.originECHReady = false
        UserDefaults.standard.set(true, forKey: "dohEnabled")
        defer {
            LocalConnectProxy.originECHReady = previousECH
            UserDefaults.standard.set(previousDoH, forKey: "dohEnabled")
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPSEnable": 1]
        LightweightDohProxyService.shared.apply(to: config)
        XCTAssertNil(config.connectionProxyDictionary)
    }

    func testWebViewHTTPClientStaysDisabledInUnitTests() {
        XCTAssertFalse(LocalConnectProxy.usesWebViewHTTPTransport)
        LocalConnectProxy.originECHReady = false
        LocalConnectProxy.abandonWebViewHTTPTransport(reason: "test")
        XCTAssertFalse(LocalConnectProxy.originECHReady)
        LocalConnectProxy.enableSafariWebViewHTTPAfterChallenge()
        XCTAssertFalse(LocalConnectProxy.preferSafariWebViewHTTP)
        XCTAssertFalse(LocalConnectProxy.usesWebViewHTTPTransport)
    }

    func testPoisonedLinuxDoDNSIncludesFacebookAndNonCloudflare() {
        XCTAssertTrue(
            LocalConnectProxy.isPoisonedLinuxDoAddresses([
                "2a03:2880:f136:83:face:b00c:0:25de",
                "98.159.108.57",
            ])
        )
        XCTAssertTrue(LocalConnectProxy.isFacebookOrGarbageAddress("2a03:2880:f136:83:face:b00c:0:25de"))
        XCTAssertFalse(LocalConnectProxy.isCloudflareishAddress("98.159.108.57"))
        XCTAssertFalse(
            LocalConnectProxy.isPoisonedLinuxDoAddresses([
                "104.21.16.56",
                "172.67.210.33",
            ])
        )
        XCTAssertFalse(LocalConnectProxy.isPoisonedLinuxDoAddresses([]))
    }

    func testWebViewHTTPClientParsesJavaScriptNumberStatus() throws {
        let body = Data("{\"topic_list\":[]}".utf8)
        let payload: [String: Any] = [
            "status": 200.0,
            "url": "https://linux.do/latest.json",
            "headers": ["content-type": "application/json"],
            "bodyBase64": body.base64EncodedString(),
        ]
        let (data, response) = try WebViewHTTPClient.parseFetchResult(payload)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, body)
        XCTAssertEqual(response.url?.path, "/latest.json")
    }

    func testWebViewHTTPClientParsesNSNumberStatus() throws {
        let payload: [String: Any] = [
            "status": NSNumber(value: 403),
            "url": "https://linux.do/session/current.json",
            "headers": ["cf-mitigated": "challenge"],
            "bodyBase64": "",
        ]
        let (_, response) = try WebViewHTTPClient.parseFetchResult(payload)
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertEqual(response.value(forHTTPHeaderField: "cf-mitigated"), "challenge")
    }

    func testWebViewHTTPClientParsesJSONStringResult() throws {
        let json = """
        {"status":200,"url":"https://linux.do/session/current.json","headers":{"content-type":"application/json"},"bodyBase64":""}
        """
        let (_, response) = try WebViewHTTPClient.parseFetchResult(json)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.url?.path, "/session/current.json")
    }

    func testWebViewHTTPClientSurfacesJavaScriptErrorPayload() {
        XCTAssertThrowsError(
            try WebViewHTTPClient.parseFetchResult("{\"error\":\"Load failed\",\"name\":\"TypeError\"}")
        ) { error in
            XCTAssertEqual((error as NSError).localizedDescription, "Load failed")
        }
    }

    func testChallengePageIsNotLoadedOnGatewayLoopback() throws {
        let base = try XCTUnwrap(URL(string: "https://linux.do"))
        XCTAssertNil(CloudflareVerificationPolicy.gatewayBrowserURL(path: "/challenge", baseURL: base))
        XCTAssertEqual(
            CloudflareVerificationPolicy.verificationURL(baseURL: base, responseURL: nil).host,
            "linux.do"
        )
    }

    func testGatewayRewriteKeepsHostAndLoopback() throws {
        let original = URLRequest(url: try XCTUnwrap(URL(string: "https://linux.do/t/1.json?page=2")))
        let rewritten = try XCTUnwrap(DohGatewayRewrite.rewrite(original, port: 51997))
        XCTAssertEqual(rewritten.url?.scheme, "http")
        XCTAssertEqual(rewritten.url?.host, "127.0.0.1")
        XCTAssertEqual(rewritten.url?.port, 51997)
        XCTAssertEqual(rewritten.url?.path, "/t/1.json")
        XCTAssertEqual(rewritten.url?.query, "page=2")
        XCTAssertEqual(rewritten.value(forHTTPHeaderField: "Host"), "linux.do")
    }

    func testGatewayApplySkippedWhenOriginECHDisabled() throws {
        let previous = LocalConnectProxy.originECHReady
        LocalConnectProxy.originECHReady = false
        defer { LocalConnectProxy.originECHReady = previous }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://linux.do/session/current.json")))
        request = DohGatewayRewrite.applyIfNeeded(request)
        XCTAssertEqual(request.url?.host, "linux.do")
        XCTAssertEqual(request.url?.scheme, "https")
    }

    func testGatewayInterceptorNoopsWithoutRunningProxy() {
        let interceptor = DohGatewayInterceptor()
        var request = URLRequest(url: URL(string: "https://linux.do/t/1.json")!)
        request.setValue("keep-me", forHTTPHeaderField: "Cookie")
        let expectation = expectation(description: "adapt")
        interceptor.adapt(request, for: Session()) { result in
            let adapted = try? result.get()
            XCTAssertEqual(adapted?.url?.host, "linux.do")
            XCTAssertEqual(adapted?.value(forHTTPHeaderField: "Cookie"), "keep-me")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
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
