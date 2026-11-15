import XCTest

@testable import Doer

final class DohConnectionModeTests: XCTestCase {
    private let suiteName = "doer.tests.doh-connection-mode"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - 默认值

    func testDefaultConnectionModeIsEncryptedDNS() {
        XCTAssertEqual(AppSettings.dohConnectionMode(from: defaults), .encryptedDNS)
    }

    func testUnknownRawValueFallsBackToEncryptedDNS() {
        defaults.set(99, forKey: "dohConnectionMode")
        XCTAssertEqual(AppSettings.dohConnectionMode(from: defaults), .encryptedDNS)
    }

    // MARK: - 连接方式 → originECHReady

    func testShouldEnableOriginECH() {
        XCTAssertTrue(LightweightDohProxyService.DohProxyLiveness.shouldEnableOriginECH(
            enabled: true, mode: .localECH, runtimeEscaped: false
        ))
        XCTAssertFalse(LightweightDohProxyService.DohProxyLiveness.shouldEnableOriginECH(
            enabled: true, mode: .localECH, runtimeEscaped: true
        ), "运行时回退过就不该自动切回来")
        XCTAssertFalse(LightweightDohProxyService.DohProxyLiveness.shouldEnableOriginECH(
            enabled: true, mode: .encryptedDNS, runtimeEscaped: false
        ))
        XCTAssertFalse(LightweightDohProxyService.DohProxyLiveness.shouldEnableOriginECH(
            enabled: false, mode: .localECH, runtimeEscaped: false
        ))
    }

    // MARK: - 配置派生

    func testLocalECHForcesH2() {
        defaults.set(true, forKey: "dohEnabled")
        defaults.set(AppSettings.DohConnectionMode.localECH.rawValue, forKey: "dohConnectionMode")
        defaults.set(false, forKey: "dohH2Mitm")

        let config = AppSettings.dohProxyConfig(from: defaults)
        XCTAssertTrue(config.h2Mitm, "本地 ECH 必须开 h2，否则 CF 会拿 HTTP/1.1 回 403 challenge")
    }

    func testLocalECHDropsGatewayWhenWebViewCanUseCONNECT() {
        defaults.set(true, forKey: "dohEnabled")
        defaults.set(AppSettings.DohConnectionMode.localECH.rawValue, forKey: "dohConnectionMode")
        defaults.set(true, forKey: "dohGatewayEnabled")

        let config = AppSettings.dohProxyConfig(from: defaults)
        if LocalConnectProxy.supportsWebViewCONNECTProxy {
            XCTAssertFalse(config.gatewayEnabled, "iOS 17+ 的 WebView 也能挂 CONNECT，不需要 gateway hop")
        } else {
            XCTAssertTrue(config.gatewayEnabled, "iOS 16 的 WebView 只能靠 gateway")
        }
    }

    func testEncryptedDNSKeepsUserGatewayAndH2Choices() {
        defaults.set(true, forKey: "dohEnabled")
        defaults.set(true, forKey: "dohGatewayEnabled")
        defaults.set(false, forKey: "dohH2Mitm")

        let config = AppSettings.dohProxyConfig(from: defaults)
        XCTAssertTrue(config.gatewayEnabled)
        XCTAssertFalse(config.h2Mitm)

        defaults.set(false, forKey: "dohGatewayEnabled")
        defaults.set(true, forKey: "dohH2Mitm")
        let flipped = AppSettings.dohProxyConfig(from: defaults)
        XCTAssertFalse(flipped.gatewayEnabled)
        XCTAssertTrue(flipped.h2Mitm)
    }

    func testConnectionModeChangesSignatureSoProxyReapplies() {
        defaults.set(true, forKey: "dohEnabled")
        defaults.set(AppSettings.DohConnectionMode.encryptedDNS.rawValue, forKey: "dohConnectionMode")
        let before = AppSettings.dohProxyConfig(from: defaults).signature

        defaults.set(AppSettings.DohConnectionMode.localECH.rawValue, forKey: "dohConnectionMode")
        let after = AppSettings.dohProxyConfig(from: defaults).signature

        XCTAssertNotEqual(before, after, "换连接方式必须让 signature 变化，否则代理不会重建")
    }

    // MARK: - 模式文案

    func testConnectionModeCasesAreStable() {
        XCTAssertEqual(AppSettings.DohConnectionMode.encryptedDNS.rawValue, 0)
        XCTAssertEqual(AppSettings.DohConnectionMode.localECH.rawValue, 1)
        XCTAssertEqual(AppSettings.DohConnectionMode.allCases.count, 2)
    }
}
