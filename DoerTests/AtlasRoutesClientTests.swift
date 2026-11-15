import XCTest

@testable import Doer

/// 用例移植自 cfluxdo `core/doh_proxy/src/select.rs` 的
/// `atlas_routes_parsing_filters_non_cloudflare_and_takes_key`。
final class AtlasRoutesClientTests: XCTestCase {

    private let sampleBody = Data("""
    {
      "ttl": 600,
      "routes": [
        {"name": "linux.do", "v4": ["104.21.58.192", "31.13.94.36"], "v6": ["2606:4700::1"], "ech": "AAMBAQE="},
        {"name": "other.example", "v4": ["172.64.229.140", "104.16.1.1"]}
      ]
    }
    """.utf8)

    func testParseFiltersNonCloudflareAndSkipsOwnAssets() {
        let table = AtlasRoutesClient.parse(sampleBody, family: .init(v4: true, v6: false))
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.ttl, 600)
        // 31.13.94.36 是投毒答案；104.16.1.1 在抽样跳过表里；v6 关掉时丢弃 v6。
        XCTAssertEqual(table?.candidates, ["104.21.58.192", "172.64.229.140"])
    }

    func testParseKeepsV6WhenFamilyAllowsIt() {
        let table = AtlasRoutesClient.parse(sampleBody, family: .init(v4: true, v6: true))
        XCTAssertEqual(table?.candidates, ["104.21.58.192", "2606:4700::1", "172.64.229.140"])
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(AtlasRoutesClient.parse(Data("nope".utf8), family: .both))
        // 合法 JSON 但没有 routes：按 Rust 语义返回空表，而不是 nil
        let empty = AtlasRoutesClient.parse(Data("{}".utf8), family: .both)
        XCTAssertNotNil(empty)
        XCTAssertTrue(empty?.candidates.isEmpty == true)
    }

    func testParseDeduplicatesCandidates() {
        let body = Data("""
        {"routes": [
          {"name": "a", "v4": ["104.21.58.192"], "v6": []},
          {"name": "b", "v4": ["104.21.58.192"], "v6": []}
        ]}
        """.utf8)
        let table = AtlasRoutesClient.parse(body, family: .init(v4: true, v6: false))
        XCTAssertEqual(table?.candidates, ["104.21.58.192"])
        XCTAssertEqual(table?.ttl, 0)
    }

    func testParseCapsCandidatesAtTen() {
        let ips = (1 ... 30).map { "104.21.58.\($0)" }
        let list = ips.map { "\"\($0)\"" }.joined(separator: ",")
        let body = Data("{\"routes\": [{\"name\": \"a\", \"v4\": [\(list)], \"v6\": []}]}".utf8)
        let table = AtlasRoutesClient.parse(body, family: .init(v4: true, v6: false))
        XCTAssertEqual(table?.candidates.count, 10)
    }

    func testEndpointParsesHostAndPath() {
        XCTAssertEqual(
            AtlasRoutesClient.Endpoint(url: "https://atlas.1molchuan.top/v1/routes")?.host,
            "atlas.1molchuan.top"
        )
        XCTAssertEqual(
            AtlasRoutesClient.Endpoint(url: "https://atlas.1molchuan.top/v1/routes")?.path,
            "/v1/routes"
        )
        XCTAssertEqual(
            AtlasRoutesClient.Endpoint(url: "https://atlas.1molchuan.top")?.path,
            "/v1/routes"
        )
        XCTAssertNil(AtlasRoutesClient.Endpoint(url: "not a url"))
    }

    func testDefaultURLIsTheCommunityTable() {
        XCTAssertEqual(AtlasRoutesClient.defaultURL, "https://atlas.1molchuan.top/v1/routes")
    }

    // MARK: - ECH 钥匙

    func testParseTakesEchFromTargetRoute() {
        let table = AtlasRoutesClient.parse(sampleBody, family: .init(v4: true, v6: false))
        XCTAssertEqual(table?.echConfig, Data([0x00, 0x03, 0x01, 0x01, 0x01]))
    }

    func testParsePrefersTargetRouteEchOverEarlierRoute() {
        let body = Data("""
        {"routes": [
          {"name": "other.example", "v4": ["104.21.58.192"], "v6": [], "ech": "AgM="},
          {"name": "linux.do", "v4": ["104.21.58.193"], "v6": [], "ech": "AAMBAQE="}
        ]}
        """.utf8)
        let table = AtlasRoutesClient.parse(body, family: .init(v4: true, v6: false))
        XCTAssertEqual(table?.echConfig, Data([0x00, 0x03, 0x01, 0x01, 0x01]))
    }

    func testParseWithoutEchYieldsNilKey() {
        let body = Data("""
        {"routes": [{"name": "a", "v4": ["104.21.58.192"], "v6": []}]}
        """.utf8)
        let table = AtlasRoutesClient.parse(body, family: .init(v4: true, v6: false))
        XCTAssertNil(table?.echConfig)
    }

    func testDecodeBase64LenientHandlesURLSafeAndUnpadded() {
        XCTAssertEqual(AtlasRoutesClient.decodeBase64Lenient("AAMBAQE="), Data([0x00, 0x03, 0x01, 0x01, 0x01]))
        XCTAssertEqual(AtlasRoutesClient.decodeBase64Lenient("AAMBAQE"), Data([0x00, 0x03, 0x01, 0x01, 0x01]))
        XCTAssertEqual(AtlasRoutesClient.decodeBase64Lenient("  AAMBAQE=  "), Data([0x00, 0x03, 0x01, 0x01, 0x01]))
        // URL-safe 变体
        XCTAssertEqual(
            AtlasRoutesClient.decodeBase64Lenient("__-_"),
            AtlasRoutesClient.decodeBase64Lenient("//+/")
        )
        XCTAssertNil(AtlasRoutesClient.decodeBase64Lenient(""))
        XCTAssertNil(AtlasRoutesClient.decodeBase64Lenient("   "))
    }
}
