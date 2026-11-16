import XCTest
@testable import Doer

/// 「自动」选服的配置层：默认值推断、生效服务器、与手动选择的互斥。
///
/// 选服探测本身要打网络，不在单测里跑；这里覆盖的是"探测失败也不会把配置搞坏"——
/// 自动模式永远能解析出一份可用的服务器。
@MainActor
final class DoHServerAutoSelectTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "DoHServerAutoSelectTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    func testNeverConfiguredUserStartsInAutoMode() {
        XCTAssertTrue(AppSettings.dohAutoSelectEnabled(from: defaults))
    }

    func testUserWhoPickedAServerKeepsTheirChoice() {
        defaults.set(AppSettings.DoHProvider.google.rawValue, forKey: "dohProvider")

        XCTAssertFalse(AppSettings.dohAutoSelectEnabled(from: defaults))
        XCTAssertEqual(
            AppSettings.effectiveDoHServer(from: defaults).url,
            AppSettings.DoHProvider.google.url
        )
    }

    func testAutoModeFallsBackToDNSPodBeforeAnyScan() {
        defaults.set(true, forKey: "dohAutoSelectEnabled")

        let effective = AppSettings.effectiveDoHServer(from: defaults)

        XCTAssertEqual(effective.url, AppSettings.DoHProvider.dnspod.url)
        XCTAssertEqual(Set(effective.bootstrap), Set(AppSettings.DoHProvider.dnspod.bootstrapIPs))
    }

    func testAutoModeUsesPersistedWinner() {
        defaults.set(true, forKey: "dohAutoSelectEnabled")
        defaults.set(AppSettings.DoHProvider.cloudflare.url, forKey: "dohAutoSelectedURL")

        let effective = AppSettings.effectiveDoHServer(from: defaults)

        XCTAssertEqual(effective.url, AppSettings.DoHProvider.cloudflare.url)
        XCTAssertEqual(Set(effective.bootstrap), Set(AppSettings.DoHProvider.cloudflare.bootstrapIPs))
    }

    func testFailedScanKeepsPreviousSelectionAndNeverYieldsEmptyServer() {
        defaults.set(true, forKey: "dohAutoSelectEnabled")
        defaults.set(AppSettings.DoHProvider.tencent.url, forKey: "dohAutoSelectedURL")
        // 探测失败时只会更新时间戳，不会写空值。
        defaults.set(Date().timeIntervalSince1970, forKey: "dohAutoSelectedAt")

        XCTAssertEqual(
            AppSettings.effectiveDoHServer(from: defaults).url,
            AppSettings.DoHProvider.tencent.url
        )

        // 即使结果被写成空串（探测失败/数据被破坏），也必须落回一份可用 spec，
        // 不能留下空 URL 把整个进程的解析搞坏。
        defaults.set("", forKey: "dohAutoSelectedURL")
        let fallback = AppSettings.effectiveDoHServer(from: defaults)
        XCTAssertEqual(fallback.url, AppSettings.DoHProvider.dnspod.url)
        XCTAssertFalse(fallback.bootstrap.isEmpty)
    }

    func testChoosingASpecificServerTurnsAutoOffPermanently() {
        defaults.set(true, forKey: "dohAutoSelectEnabled")

        // 设置页点具体服务器最终落到这两个键；这里按同样的写入顺序模拟。
        defaults.set(false, forKey: "dohAutoSelectEnabled")
        defaults.set(true, forKey: "dohServerManuallySelected")
        defaults.set(AppSettings.DoHProvider.quad9.rawValue, forKey: "dohProvider")

        XCTAssertFalse(AppSettings.dohAutoSelectEnabled(from: defaults))
        XCTAssertEqual(
            AppSettings.effectiveDoHServer(from: defaults).url,
            AppSettings.DoHProvider.quad9.url
        )
    }

    func testAutoCandidatesExcludeServersWithoutBootstrap() {
        let candidates = DoHServerAutoSelector.candidates

        XCTAssertTrue(candidates.contains(.dnspod))
        XCTAssertTrue(candidates.contains(.cloudflare))
        XCTAssertFalse(candidates.contains(.canadianShield))
        XCTAssertFalse(candidates.contains(.custom))
        XCTAssertTrue(candidates.allSatisfy { !$0.bootstrapIPs.isEmpty })
    }
}
