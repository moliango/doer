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

    func testMergedBootstrapIPsKeepLockedAheadOfSystem() {
        XCTAssertEqual(
            EncryptedDnsService.mergedBootstrapIPs(
                locked: ["1.12.12.12", "120.53.53.53"],
                system: ["1.1.1.1", "1.12.12.12"]
            ),
            ["1.12.12.12", "120.53.53.53", "1.1.1.1"]
        )
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

    func testNormalizedSpecKeepsCatalogIPsAndDropsEmpty() throws {
        let spec = try XCTUnwrap(
            EncryptedDnsService.spec(
                urlString: "https://doh.pub/dns-query",
                providerRaw: AppSettings.DoHProvider.dnspod.rawValue
            )
        )
        let normalized = try XCTUnwrap(EncryptedDnsService.normalizedSpec(spec))
        XCTAssertEqual(normalized.bootstrapIPs, ["1.12.12.12", "120.53.53.53"])
        XCTAssertNil(
            EncryptedDnsService.normalizedSpec(
                EncryptedDnsService.ResolverSpec(
                    url: spec.url,
                    bootstrapIPs: []
                )
            )
        )
    }

    func testEncryptedDNSDropsForeignCatalogIPsAndIPv6() throws {
        let spec = EncryptedDnsService.ResolverSpec(
            url: try XCTUnwrap(URL(string: "https://ld.ddd.oaifree.com/query-dns")),
            bootstrapIPs: ["119.29.29.29", "223.5.5.5", "104.21.16.56"]
        )
        let ips = try XCTUnwrap(
            EncryptedDnsService.specForEncryptedDNS(
                spec,
                systemIPs: ["104.21.16.56", "2606:4700:3037::ac43:d221"]
            )
        ).bootstrapIPs
        XCTAssertEqual(ips, ["104.21.16.56"])
    }

    func testEncryptedDNSKeepsMatchingProviderIPs() throws {
        let spec = try XCTUnwrap(
            EncryptedDnsService.spec(
                urlString: "https://dns.alidns.com/dns-query",
                providerRaw: AppSettings.DoHProvider.alidns.rawValue
            )
        )
        let ips = try XCTUnwrap(
            EncryptedDnsService.specForEncryptedDNS(spec, systemIPs: [])
        ).bootstrapIPs
        XCTAssertEqual(ips, ["223.5.5.5", "223.6.6.6"])
    }
}
