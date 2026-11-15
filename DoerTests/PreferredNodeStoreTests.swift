import XCTest

@testable import Doer

final class PreferredNodeStoreTests: XCTestCase {
    private let suiteName = "doer.tests.preferred-node"
    private var defaults: UserDefaults!
    private var store: PreferredNodeStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = PreferredNodeStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeNode(ip: String = "104.21.58.192") -> PreferredNode {
        PreferredNode(
            ip: ip,
            family: ip.contains(":") ? .v6 : .v4,
            latencyMs: 42,
            selectedAt: Date(),
            source: .vendor
        )
    }

    // MARK: - 覆盖域名

    func testCoveredHostMatching() {
        XCTAssertTrue(PreferredNodeStore.isCoveredHost("linux.do"))
        XCTAssertTrue(PreferredNodeStore.isCoveredHost("LINUX.DO"))
        XCTAssertTrue(PreferredNodeStore.isCoveredHost("  linux.do  "))
        XCTAssertTrue(PreferredNodeStore.isCoveredHost("www.linux.do"))
        XCTAssertTrue(PreferredNodeStore.isCoveredHost("cdn.linux.do"))

        XCTAssertFalse(PreferredNodeStore.isCoveredHost("linux.do.evil.com"))
        XCTAssertFalse(PreferredNodeStore.isCoveredHost("evil-linux.do"))
        XCTAssertFalse(PreferredNodeStore.isCoveredHost("linux.do.cn"))
        XCTAssertFalse(PreferredNodeStore.isCoveredHost(""))
        XCTAssertFalse(PreferredNodeStore.isCoveredHost("example.com"))
    }

    // MARK: - 钉选

    func testPinnedAddressOnlyForCoveredHosts() {
        store.node = makeNode()
        XCTAssertEqual(store.pinnedAddress(forHost: "linux.do"), "104.21.58.192")
        XCTAssertEqual(store.pinnedAddress(forHost: "www.linux.do"), "104.21.58.192")
        XCTAssertNil(store.pinnedAddress(forHost: "example.com"))
    }

    func testPinnedAddressNilWithoutWinner() {
        XCTAssertNil(store.pinnedAddress(forHost: "linux.do"))
    }

    func testNodePersistsAcrossInstances() {
        store.node = makeNode(ip: "2606:4700::1")
        let reloaded = PreferredNodeStore(defaults: defaults)
        XCTAssertEqual(reloaded.node?.ip, "2606:4700::1")
        XCTAssertEqual(reloaded.node?.family, .v6)
    }

    /// 赢家随钥匙一起落盘：之后连 linux.do 就不必再解析它的 HTTPS 记录。
    func testEchConfigPersistsWithWinner() {
        var node = makeNode()
        node.echConfig = Data([0x00, 0x03, 0x01, 0x01, 0x01])
        store.node = node

        let reloaded = PreferredNodeStore(defaults: defaults)
        XCTAssertEqual(reloaded.node?.echConfig, Data([0x00, 0x03, 0x01, 0x01, 0x01]))
    }

    func testNodeWithoutEchConfigDecodes() {
        store.node = makeNode()
        XCTAssertNil(PreferredNodeStore(defaults: defaults).node?.echConfig)
    }

    func testClearRemovesPersistedWinner() {
        store.node = makeNode()
        store.clear()
        XCTAssertNil(store.node)
        XCTAssertNil(PreferredNodeStore(defaults: defaults).node)
    }

    // MARK: - 连败降级

    func testWinnerDemotedAfterThreeConsecutiveFailures() {
        store.node = makeNode()
        var demoted = 0
        store.onWinnerDemoted = { demoted += 1 }

        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)
        XCTAssertNotNil(store.node)
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)
        XCTAssertNotNil(store.node)
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)

        XCTAssertNil(store.node, "连败 3 次应解除钉住")
        XCTAssertEqual(demoted, 1)
    }

    func testSuccessResetsFailureStreak() {
        store.node = makeNode()
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: true)
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)
        store.reportOutcome(host: "linux.do", ip: "104.21.58.192", success: false)
        XCTAssertNotNil(store.node, "成功一次后计数应清零")
    }

    func testOutcomeForOtherIPIsIgnored() {
        store.node = makeNode()
        for _ in 0 ..< 5 {
            store.reportOutcome(host: "linux.do", ip: "1.2.3.4", success: false)
        }
        XCTAssertNotNil(store.node)
    }

    func testOutcomeForUncoveredHostIsIgnored() {
        store.node = makeNode()
        for _ in 0 ..< 5 {
            store.reportOutcome(host: "example.com", ip: "104.21.58.192", success: false)
        }
        XCTAssertNotNil(store.node)
    }
}
