import XCTest

@testable import Doer

/// 用例移植自 cfluxdo `core/doh_proxy/src/probe.rs` 的 `trace_host_line_must_match_exactly`。
final class CloudflareNodeProbeTests: XCTestCase {

    func testTraceHostLineMustMatchExactly() {
        let body = Data("fl=1f2\nh=linux.do\nip=203.0.113.9\nts=1.0\n".utf8)
        XCTAssertTrue(CloudflareNodeProbe.traceMatches(body, expect: "linux.do"))
        XCTAssertFalse(CloudflareNodeProbe.traceMatches(Data("h=linux.do.evil\n".utf8), expect: "linux.do"))
        XCTAssertFalse(CloudflareNodeProbe.traceMatches(Data("h=evil.linux.do\n".utf8), expect: "linux.do"))
        XCTAssertFalse(CloudflareNodeProbe.traceMatches(Data("fl=1\nip=1.2.3.4\n".utf8), expect: "linux.do"))
        XCTAssertTrue(CloudflareNodeProbe.traceMatches(Data("h=linux.do\r\n".utf8), expect: "linux.do"))
    }

    func testTraceHostLineToleratesTrailingWhitespace() {
        XCTAssertTrue(CloudflareNodeProbe.traceMatches(Data("h=linux.do   \n".utf8), expect: "linux.do"))
        XCTAssertTrue(CloudflareNodeProbe.traceMatches(Data("h=linux.do".utf8), expect: "linux.do"))
    }

    func testTraceRequiresWholeLineMatch() {
        XCTAssertFalse(CloudflareNodeProbe.traceMatches(Data("x h=linux.do\n".utf8), expect: "linux.do"))
        XCTAssertFalse(CloudflareNodeProbe.traceMatches(Data("".utf8), expect: "linux.do"))
    }

    func testTracePathAndProbeHost() {
        XCTAssertEqual(CloudflareNodeProbe.tracePath, "/cdn-cgi/trace")
        XCTAssertEqual(PreferredNodeSelector.probeHost, "linux.do")
    }

    // MARK: - retry_configs

    func testRetryConfigsOnlyOnEchRejection() {
        let retry = Data([0x00, 0x03, 0x01, 0x01, 0x01])
        XCTAssertEqual(
            PreferredNodeProbeOutcome.Failure.echRejected(retryConfigs: retry).retryConfigs,
            retry
        )
        XCTAssertNil(PreferredNodeProbeOutcome.Failure.echRejected(retryConfigs: nil).retryConfigs)
        XCTAssertNil(PreferredNodeProbeOutcome.Failure.tls("boom").retryConfigs)
        XCTAssertNil(PreferredNodeProbeOutcome.Failure.tcpConnect.retryConfigs)
        XCTAssertNil(PreferredNodeProbeOutcome.Failure.bodyMismatch.retryConfigs)
    }

    func testEchRejectionDescriptionMentionsKeySize() {
        let retry = Data(repeating: 0, count: 42)
        XCTAssertTrue(
            PreferredNodeProbeOutcome.Failure.echRejected(retryConfigs: retry).description
                .contains("42")
        )
        XCTAssertTrue(
            PreferredNodeProbeOutcome.Failure.echRejected(retryConfigs: nil).description
                .contains("no retry_configs")
        )
    }

    /// 钥匙来源必须是别的 CF zone，不能是 linux.do 本身。
    func testHttpsKeyDomainsNeverIncludeTargetSite() {
        XCTAssertFalse(PreferredNodeSelector.httpsKeyDomains.contains("linux.do"))
        XCTAssertTrue(PreferredNodeSelector.httpsKeyDomains.contains("icook.tw"))
    }
}
