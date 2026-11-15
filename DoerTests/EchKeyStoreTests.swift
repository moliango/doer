import XCTest

@testable import Doer

final class EchKeyStoreTests: XCTestCase {
    private let suiteName = "doer.tests.ech-key-store"
    private var defaults: UserDefaults!
    private var store: EchKeyStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = EchKeyStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func key(_ byte: UInt8, count: Int = 5) -> Data {
        Data(repeating: byte, count: count)
    }

    /// 裸 config 会被补上 2 字节长度前缀。
    private func normalized(_ byte: UInt8, count: Int = 5) -> Data {
        var list = Data([0, UInt8(count)])
        list.append(Data(repeating: byte, count: count))
        return list
    }

    // MARK: - 常量

    func testConstantsMatchCfluxdo() {
        XCTAssertEqual(EchKeyStore.maxKeys, 3)
        XCTAssertEqual(EchKeyStore.maxAge, 48 * 3600)
    }

    // MARK: - 收养

    func testAdoptNormalizesAndBecomesPrimary() {
        XCTAssertTrue(store.adopt(key(1), source: .httpsRecord))
        XCTAssertEqual(store.primary, normalized(1))
        XCTAssertEqual(store.liveKeys.count, 1)
        XCTAssertEqual(store.liveKeys.first?.source, .httpsRecord)
    }

    func testAdoptSameKeyIsNoOp() {
        XCTAssertTrue(store.adopt(key(1), source: .httpsRecord))
        XCTAssertFalse(store.adopt(key(1), source: .atlas), "同一把钥匙不重复入池")
        XCTAssertEqual(store.liveKeys.count, 1)
        XCTAssertEqual(store.liveKeys.first?.source, .httpsRecord, "来源不应被覆盖")
    }

    func testAdoptMovesExistingKeyToFront() {
        store.adopt(key(1), source: .httpsRecord)
        store.adopt(key(2), source: .atlas)
        XCTAssertEqual(store.liveKeys.map(\.bytes), [normalized(2), normalized(1)])

        store.adopt(key(1), source: .retryConfigs)
        XCTAssertEqual(store.liveKeys.map(\.bytes), [normalized(1), normalized(2)])
        XCTAssertEqual(store.liveKeys.first?.source, .retryConfigs)
    }

    func testAdoptCapsPoolAtThree() {
        for byte in UInt8(1) ... UInt8(4) {
            store.adopt(key(byte), source: .atlas)
        }
        XCTAssertEqual(store.liveKeys.count, 3)
        XCTAssertEqual(
            store.liveKeys.map(\.bytes),
            [normalized(4), normalized(3), normalized(2)],
            "最旧的应被挤出"
        )
    }

    func testAdoptRejectsEmptyKey() {
        XCTAssertFalse(store.adopt(Data(), source: .atlas))
        XCTAssertTrue(store.liveKeys.isEmpty)
    }

    func testAlreadyPrefixedKeyIsNotDoubleWrapped() {
        let prefixed = normalized(7)
        store.adopt(prefixed, source: .retryConfigs)
        XCTAssertEqual(store.primary, prefixed)
    }

    // MARK: - 落盘

    func testKeysPersistAcrossInstances() {
        store.adopt(key(1), source: .httpsRecord)
        store.adopt(key(2), source: .retryConfigs)

        let reloaded = EchKeyStore(defaults: defaults)
        XCTAssertEqual(reloaded.liveKeys.map(\.bytes), [normalized(2), normalized(1)])
        XCTAssertEqual(reloaded.liveKeys.map(\.source), [.retryConfigs, .httpsRecord])
    }

    func testClearRemovesPersistedKeys() {
        store.adopt(key(1), source: .atlas)
        store.clear()
        XCTAssertTrue(store.liveKeys.isEmpty)
        XCTAssertTrue(EchKeyStore(defaults: defaults).liveKeys.isEmpty)
    }

    // MARK: - 48h 老化

    func testKeysOlderThan48HoursAreNotLive() {
        let stale = EchKey(
            bytes: normalized(1),
            source: .persisted,
            adoptedAt: Date().addingTimeInterval(-(EchKeyStore.maxAge + 60))
        )
        let fresh = EchKey(bytes: normalized(2), source: .persisted, adoptedAt: Date())
        let data = try? JSONEncoder().encode([stale, fresh])
        defaults.set(data, forKey: "preferredNode.echKeys.v1")

        let reloaded = EchKeyStore(defaults: defaults)
        XCTAssertEqual(reloaded.liveKeys.map(\.bytes), [normalized(2)])
    }

    func testAllStaleKeysYieldNoPrimary() {
        let stale = EchKey(
            bytes: normalized(1),
            source: .persisted,
            adoptedAt: Date().addingTimeInterval(-(EchKeyStore.maxAge + 60))
        )
        defaults.set(
            try? JSONEncoder().encode([stale]),
            forKey: "preferredNode.echKeys.v1"
        )
        XCTAssertNil(EchKeyStore(defaults: defaults).primary)
    }
}
