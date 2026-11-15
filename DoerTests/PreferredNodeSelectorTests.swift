import XCTest

@testable import Doer

final class PreferredNodeSelectorTests: XCTestCase {

    private let v4Only = CloudflareRanges.FamilySupport(v4: true, v6: false)
    private let v6Only = CloudflareRanges.FamilySupport(v4: false, v6: true)
    private let both = CloudflareRanges.FamilySupport(v4: true, v6: true)

    // MARK: - 候选过滤

    func testAcceptsOnlyCloudflareInSupportedFamily() {
        XCTAssertTrue(PreferredNodeSelector.accepts("104.21.58.192", family: v4Only))
        XCTAssertTrue(PreferredNodeSelector.accepts("2606:4700::1", family: v6Only))
        XCTAssertTrue(PreferredNodeSelector.accepts("104.21.58.192", family: both))

        // 地址族不支持
        XCTAssertFalse(PreferredNodeSelector.accepts("2606:4700::1", family: v4Only))
        XCTAssertFalse(PreferredNodeSelector.accepts("104.21.58.192", family: v6Only))
    }

    func testAcceptsRejectsNonCloudflareAndSkipped() {
        XCTAssertFalse(PreferredNodeSelector.accepts("8.8.8.8", family: both))
        XCTAssertFalse(PreferredNodeSelector.accepts("31.13.94.36", family: both))
        XCTAssertFalse(PreferredNodeSelector.accepts("1.1.1.1", family: both))
        // 104.16.0.0/15 是 CF 自家资产段，不服务其他 zone
        XCTAssertFalse(PreferredNodeSelector.accepts("104.16.1.1", family: both))
        XCTAssertFalse(PreferredNodeSelector.accepts("not-an-ip", family: both))
    }

    // MARK: - 首选族排序

    func testOrderedByFamilyPutsPreferredFamilyFirst() {
        let candidates = ["2606:4700::1", "104.21.58.192", "2606:4700::2", "172.64.229.140"]
        XCTAssertEqual(
            PreferredNodeSelector.orderedByFamily(candidates, family: v4Only),
            ["104.21.58.192", "172.64.229.140", "2606:4700::1", "2606:4700::2"]
        )
        XCTAssertEqual(
            PreferredNodeSelector.orderedByFamily(candidates, family: v6Only),
            ["2606:4700::1", "2606:4700::2", "104.21.58.192", "172.64.229.140"]
        )
    }

    func testOrderedByFamilyKeepsRelativeOrderWithinFamily() {
        let candidates = ["104.21.58.192", "104.21.58.193", "104.21.58.194"]
        XCTAssertEqual(PreferredNodeSelector.orderedByFamily(candidates, family: v4Only), candidates)
    }

    // MARK: - 候选域名表

    func testVendorDomainsNeverIncludeTheTargetSite() {
        let domains = PreferredNodeSelector.vendorDomains + PreferredNodeSelector.communityDomains
        XCTAssertFalse(domains.contains("linux.do"), "公共 DNS 从不查询目标站本身")
        XCTAssertFalse(domains.isEmpty)
    }

    func testVendorAndCommunityDomainLists() {
        XCTAssertTrue(PreferredNodeSelector.vendorDomains.contains("openai.com"))
        XCTAssertTrue(PreferredNodeSelector.vendorDomains.contains("www.visa.com.hk"))
        XCTAssertEqual(PreferredNodeSelector.communityDomains.count, 4)
    }

    // MARK: - 解析器健康暂停

    func testShouldPauseResolverAfterTwoConsecutiveFailures() {
        XCTAssertFalse(PreferredNodeSelector.shouldPauseResolver(consecutiveFailures: 0))
        XCTAssertFalse(PreferredNodeSelector.shouldPauseResolver(consecutiveFailures: 1))
        XCTAssertTrue(PreferredNodeSelector.shouldPauseResolver(consecutiveFailures: 2))
        XCTAssertTrue(PreferredNodeSelector.shouldPauseResolver(consecutiveFailures: 9))
    }

    // MARK: - 失败归类

    func testFailureKeyClassifiesProbeFailures() {
        XCTAssertEqual(
            PreferredNodeSelector.failureKey(.tcpConnect),
            PreferredNodeSelector.failureKey(.tcpConnect)
        )
        XCTAssertEqual(PreferredNodeSelector.failureKey(.tcpTimeout), "tcp 超时")
        XCTAssertEqual(PreferredNodeSelector.failureKey(.tlsTimeout), "tls 超时")
        XCTAssertEqual(PreferredNodeSelector.failureKey(.bodyMismatch), "trace 不是 linux.do")
        XCTAssertEqual(PreferredNodeSelector.failureKey(.httpStatus(403)), "http 403")
        XCTAssertEqual(
            PreferredNodeSelector.failureKey(.echRejected(retryConfigs: nil)),
            "ech 被拒（无新钥匙）"
        )
        XCTAssertEqual(
            PreferredNodeSelector.failureKey(.echRejected(retryConfigs: Data([1, 2]))),
            "ech 被拒（有新钥匙）"
        )
    }

    func testFailureKeyGroupsTlsDetailsSeparately() {
        XCTAssertNotEqual(
            PreferredNodeSelector.failureKey(.tls("one")),
            PreferredNodeSelector.failureKey(.tls("two"))
        )
        XCTAssertTrue(PreferredNodeSelector.failureKey(.tls(String(repeating: "x", count: 200))).count < 60)
    }
}
