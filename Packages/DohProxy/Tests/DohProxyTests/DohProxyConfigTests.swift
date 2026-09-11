import XCTest
@testable import DohProxy

final class DohProxyConfigTests: XCTestCase {
    func testDefaultServerIsDNSPod() {
        XCTAssertEqual(DohServerCatalog.defaultServer.url, "https://doh.pub/dns-query")
        XCTAssertEqual(DohServerCatalog.builtIn.first?.url, DohServerCatalog.dnsPod.url)
    }

    func testFluxDoServerListOrder() {
        XCTAssertEqual(
            DohServerCatalog.builtIn.map(\.url),
            [
                "https://doh.pub/dns-query",
                "https://dns.pub/dns-query",
                "https://cloudflare-dns.com/dns-query",
                "https://private.canadianshield.cira.ca/dns-query",
                "https://dns.alidns.com/dns-query",
                "https://dns.quad9.net/dns-query",
                "https://dns.google/dns-query",
            ]
        )
    }

    func testCloudflareGatewayInfersBootstrap() {
        let ips = DohServerCatalog.inferredBootstrapIPs(
            for: "https://i4cm5lqxfu.cloudflare-gateway.com/dns-query"
        )
        XCTAssertEqual(ips, ["162.159.36.1", "162.159.46.1"])
        XCTAssertFalse(ips.contains("1.1.1.1"))
        let config = DohProxyConfig(
            enabled: true,
            serverURL: "https://i4cm5lqxfu.cloudflare-gateway.com/dns-query",
            bootstrapIPs: ips
        )
        XCTAssertTrue(config.bootstrapReady)
    }

    func testCustomURLWithoutBootstrapFailsReadyCheck() {
        let config = DohProxyConfig(
            enabled: true,
            serverURL: "https://doh.example.invalid/dns-query",
            bootstrapIPs: []
        )
        XCTAssertFalse(config.bootstrapReady)
    }

    func testIPHostCustomURLIsBootstrapReady() {
        let config = DohProxyConfig(
            enabled: true,
            serverURL: "https://1.1.1.1/dns-query",
            bootstrapIPs: []
        )
        XCTAssertTrue(config.bootstrapReady)
    }

    func testGatewayDefaultMatchesFluxDo() {
        let config = DohProxyConfig(
            enabled: true,
            serverURL: DohServerCatalog.dnsPod.url,
            bootstrapIPs: DohServerCatalog.dnsPod.bootstrapIPs
        )
        XCTAssertTrue(config.gatewayEnabled)
        XCTAssertTrue(config.isGatewayMode)
        XCTAssertFalse(config.h2Mitm)
        XCTAssertEqual(config.effectiveEchServerURL, config.serverURL)
    }

    func testSignatureChangesWithECHServerAndGateway() {
        let base = DohProxyConfig(
            enabled: true,
            serverURL: DohServerCatalog.dnsPod.url,
            bootstrapIPs: DohServerCatalog.dnsPod.bootstrapIPs
        )
        let ech = DohProxyConfig(
            enabled: true,
            serverURL: DohServerCatalog.dnsPod.url,
            bootstrapIPs: DohServerCatalog.dnsPod.bootstrapIPs,
            echServerURL: DohServerCatalog.cloudflare.url
        )
        let noGateway = DohProxyConfig(
            enabled: true,
            serverURL: DohServerCatalog.dnsPod.url,
            bootstrapIPs: DohServerCatalog.dnsPod.bootstrapIPs,
            gatewayEnabled: false
        )
        XCTAssertNotEqual(base.signature, ech.signature)
        XCTAssertNotEqual(base.signature, noGateway.signature)
    }
}
