import XCTest
@testable import Doer

final class StickerMarketFilterTests: XCTestCase {
    private func group(id: String, name: String, topic: String) -> StickerGroup {
        StickerGroup(id: id, name: name, icon: "", topic: topic, order: 0, emojiCount: 1, isArchived: false)
    }

    func testCategoryAllKeepsEveryPack() {
        let groups = [
            group(id: "1", name: "ACfun", topic: "other"),
            group(id: "2", name: "新年主题包", topic: "bilibili"),
        ]
        XCTAssertEqual(
            StickerMarketFilterPolicy.filtered(groups: groups, categoryId: "all", query: "").map(\.id),
            ["1", "2"]
        )
    }

    func testCategoryFiltersByTopic() {
        let groups = [
            group(id: "1", name: "ACfun", topic: "other"),
            group(id: "2", name: "新年主题包", topic: "bilibili"),
            group(id: "3", name: "bilibili 2", topic: "bilibili"),
        ]
        XCTAssertEqual(
            StickerMarketFilterPolicy.filtered(groups: groups, categoryId: "bilibili", query: "").map(\.id),
            ["2", "3"]
        )
    }

    func testSearchMatchesNameCaseInsensitively() {
        let groups = [
            group(id: "1", name: "ACfun", topic: "other"),
            group(id: "2", name: "新年主题包", topic: "bilibili"),
        ]
        XCTAssertEqual(
            StickerMarketFilterPolicy.filtered(groups: groups, categoryId: "all", query: "ac").map(\.id),
            ["1"]
        )
        XCTAssertEqual(
            StickerMarketFilterPolicy.filtered(groups: groups, categoryId: "all", query: "新年").map(\.id),
            ["2"]
        )
    }

    func testSearchAndCategoryCombine() {
        let groups = [
            group(id: "1", name: "猫", topic: "neko"),
            group(id: "2", name: "猫猫", topic: "bilibili"),
            group(id: "3", name: "狗", topic: "neko"),
        ]
        XCTAssertEqual(
            StickerMarketFilterPolicy.filtered(groups: groups, categoryId: "neko", query: "猫").map(\.id),
            ["1"]
        )
    }

    func testIndexDecodesTopics() throws {
        let json = """
        {"totalPages":1,"pageSize":48,"totalGroups":2,"topics":[{"id":"all","label":"全部","totalGroups":2,"totalPages":1},{"id":"bilibili","label":"bilibili","totalGroups":1,"totalPages":1}]}
        """.data(using: .utf8)!
        let index = try JSONDecoder().decode(StickerMarketIndex.self, from: json)
        XCTAssertEqual(index.displayTopics.map(\.id), ["all", "bilibili"])
    }

    func testGroupDecodesTopic() throws {
        let json = """
        {"id":"g1","name":"包","icon":"https://x","topic":"telegram","order":3,"emojiCount":12,"isArchived":false}
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(StickerGroup.self, from: json)
        XCTAssertEqual(group.topic, "telegram")
        XCTAssertEqual(group.emojiCount, 12)
    }

    func testSubscribePersistsDetailLocally() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sticker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "sticker-test-\(UUID().uuidString)")!
        let store = StickerMarketStore(defaults: defaults, storageDirectory: directory)
        let detail = StickerGroupDetail(
            id: "g1",
            name: "包",
            icon: "",
            emojis: [StickerItem(id: "e1", name: "a", url: "https://x/a.webp", width: 32, height: 32, groupId: "g1")]
        )
        store.subscribe("g1")
        XCTAssertEqual(store.subscribedGroupIds(), ["g1"])

        let data = try JSONEncoder().encode(detail)
        try data.write(to: directory.appendingPathComponent("subscribed-details.json"))
        XCTAssertEqual(store.loadPersistedDetails().map(\.id), ["g1"])
        XCTAssertEqual(store.loadPersistedDetails().first?.emojis.count, 1)

        store.unsubscribe("g1")
        XCTAssertTrue(store.subscribedGroupIds().isEmpty)
        XCTAssertTrue(store.loadPersistedDetails().isEmpty)
    }
}
