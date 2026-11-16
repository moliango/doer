import XCTest
@testable import DohProxy

final class DohBootstrapTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DohBootstrapTransport.clearSystemAddressCache()
    }

    override func tearDown() {
        DohBootstrapTransport.clearSystemAddressCache()
        DohBootstrapTransport.skipSystemAddressLookup = false
        super.tearDown()
    }

    /// Encrypted DNS 开着时不能再做 `getaddrinfo`，只能吃缓存；灌进去的 IP
    /// 必须能被读到，否则传输层就只剩配置里那个可能连不上的 bootstrap。
    func testSeededSystemAddressesAreReadableFromCache() {
        XCTAssertTrue(DohBootstrapTransport.cachedSystemAddresses(for: "edge.example.com").isEmpty)

        DohBootstrapTransport.seedSystemAddresses(["156.239.232.72", "203.168.131.145"], for: "edge.example.com")

        XCTAssertEqual(
            DohBootstrapTransport.cachedSystemAddresses(for: "edge.example.com"),
            ["156.239.232.72", "203.168.131.145"]
        )
        // 主机名大小写不该影响命中。
        XCTAssertEqual(
            DohBootstrapTransport.cachedSystemAddresses(for: "EDGE.Example.COM"),
            ["156.239.232.72", "203.168.131.145"]
        )
    }

    func testClearingTheCacheDropsSeededAddresses() {
        DohBootstrapTransport.seedSystemAddresses(["1.1.1.1"], for: "edge.example.com")
        DohBootstrapTransport.clearSystemAddressCache()
        XCTAssertTrue(DohBootstrapTransport.cachedSystemAddresses(for: "edge.example.com").isEmpty)
    }

    func testEmptySeedIsIgnored() {
        DohBootstrapTransport.seedSystemAddresses(["1.1.1.1"], for: "edge.example.com")
        DohBootstrapTransport.seedSystemAddresses([], for: "edge.example.com")
        XCTAssertEqual(
            DohBootstrapTransport.cachedSystemAddresses(for: "edge.example.com"),
            ["1.1.1.1"]
        )
    }
}
