import Network
import XCTest
@testable import Doer

final class EncryptedDnsServiceTests: XCTestCase {
    func testAliDNSSpecUsesBootstrapIPs() throws {
        let spec = try XCTUnwrap(
            EncryptedDnsService.spec(
                urlString: "https://dns.alidns.com/dns-query",
                providerRaw: AppSettings.DoHProvider.alidns.rawValue
            )
        )
        XCTAssertEqual(spec.url.absoluteString, "https://dns.alidns.com/dns-query")
        XCTAssertEqual(spec.bootstrapIPs, ["223.5.5.5", "223.6.6.6"])
        XCTAssertEqual(EncryptedDnsService.bootstrapEndpoints(spec.bootstrapIPs).count, 2)
    }

    func testCustomIPURLBootstrapsFromHost() throws {
        let spec = try XCTUnwrap(
            EncryptedDnsService.spec(
                urlString: "https://223.5.5.5/dns-query",
                providerRaw: AppSettings.DoHProvider.custom.rawValue
            )
        )
        XCTAssertEqual(spec.bootstrapIPs, ["223.5.5.5"])
    }

    func testOrderedBootstrapIPsPreferLiveIPv4() {
        XCTAssertEqual(
            EncryptedDnsService.orderedBootstrapIPs(
                [
                    "162.159.36.1",
                    "2606:4700:5c::a29f:2e07",
                    "162.159.36.20",
                    "162.159.36.1",
                ],
                preferIPv6: false
            ),
            ["162.159.36.1", "162.159.36.20"]
        )
    }

    func testLockedBootstrapIPsCannotDropInferred() {
        let url = "https://i4cm5lqxfu.cloudflare-gateway.com/dns-query"
        let locked = AppSettings.lockedBootstrapIPs(for: url, extras: ["1.1.1.1"])
        XCTAssertTrue(locked.contains("162.159.36.1"))
        XCTAssertTrue(locked.contains("1.1.1.1"))
    }

    func testClashFakeIPIsNotUsableBootstrap() {
        XCTAssertTrue(EncryptedDnsService.isTunnelFakeIP("198.18.10.184"))
        XCTAssertTrue(EncryptedDnsService.isTunnelFakeIP("198.19.0.1"))
        XCTAssertFalse(EncryptedDnsService.isTunnelFakeIP("104.21.16.56"))
        XCTAssertEqual(
            EncryptedDnsService.usableBootstrapIPs([
                "198.18.10.184",
                "119.29.29.29",
                "104.21.16.56",
            ]),
            ["119.29.29.29", "104.21.16.56"]
        )
        XCTAssertTrue(
            EncryptedDnsService.shouldSkipEncryptedDNS(
                systemIPs: ["198.18.10.184"],
                forumIPs: []
            )
        )
        XCTAssertTrue(
            EncryptedDnsService.shouldSkipEncryptedDNS(
                systemIPs: ["104.21.16.56"],
                forumIPs: ["198.18.0.1"]
            )
        )
        XCTAssertFalse(
            EncryptedDnsService.shouldSkipEncryptedDNS(
                systemIPs: ["104.21.16.56", "172.67.210.33"],
                forumIPs: ["172.66.166.61"]
            )
        )
    }

    func testRejectsNonHTTPSURL() {
        XCTAssertNil(
            EncryptedDnsService.spec(
                urlString: "http://dns.alidns.com/dns-query",
                providerRaw: AppSettings.DoHProvider.alidns.rawValue
            )
        )
        XCTAssertNil(
            EncryptedDnsService.spec(
                urlString: "",
                providerRaw: AppSettings.DoHProvider.custom.rawValue
            )
        )
    }
}
