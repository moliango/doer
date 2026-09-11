import XCTest
@testable import DohProxy

final class DohDNSMessageTests: XCTestCase {
    func testClampTTLMatchesFluxDo() {
        XCTAssertEqual(DohDNSMessage.clampTTL(10), 60)
        XCTAssertEqual(DohDNSMessage.clampTTL(300), 300)
        XCTAssertEqual(DohDNSMessage.clampTTL(10_000), 1800)
        XCTAssertEqual(DohDNSMessage.clampTTL(0), 300)
    }

    func testMakeQueryEncodesTypeHTTPS() throws {
        let query = try XCTUnwrap(DohDNSMessage.makeQuery(host: "example.com", type: DohDNSMessage.typeHTTPS))
        XCTAssertGreaterThan(query.count, 12)
        XCTAssertEqual(query[query.count - 4], 0)
        XCTAssertEqual(query[query.count - 3], 65)
        XCTAssertEqual(query[query.count - 2], 0)
        XCTAssertEqual(query[query.count - 1], 1)
    }

    func testParseARecord() throws {
        var message = Data()
        message.append(contentsOf: [0x00, 0x01, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        message.append(contentsOf: [7])
        message.append(contentsOf: Array("example".utf8))
        message.append(contentsOf: [3])
        message.append(contentsOf: Array("com".utf8))
        message.append(0)
        message.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        message.append(contentsOf: [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 1, 2, 3, 4])
        let records = try DohDNSMessage.parseResources(message, expectedType: DohDNSMessage.typeA)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(DohDNSMessage.ipv4String(from: records[0].rdata), "1.2.3.4")
        XCTAssertEqual(records[0].ttl, 300)
    }

    func testEndpointRequiresBootstrapOrIPHost() {
        XCTAssertEqual(
            DohEndpoint(url: "https://doh.example.invalid/dns-query", bootstrapIPs: [], preferIPv6: false)?.isReady,
            false
        )
        XCTAssertEqual(
            DohEndpoint(url: "https://1.1.1.1/dns-query", bootstrapIPs: [], preferIPv6: false)?.bootstrapIPs,
            ["1.1.1.1"]
        )
        XCTAssertEqual(
            DohEndpoint(
                url: DohServerCatalog.dnsPod.url,
                bootstrapIPs: DohServerCatalog.dnsPod.bootstrapIPs,
                preferIPv6: false
            )?.bootstrapIPs.first,
            "1.12.12.12"
        )
    }

    func testPreferIPv6OrdersBootstrap() {
        let endpoint = DohEndpoint(
            url: DohServerCatalog.cloudflare.url,
            bootstrapIPs: DohServerCatalog.cloudflare.bootstrapIPs,
            preferIPv6: true
        )
        XCTAssertEqual(endpoint?.bootstrapIPs.first?.contains(":"), true)
    }
}
