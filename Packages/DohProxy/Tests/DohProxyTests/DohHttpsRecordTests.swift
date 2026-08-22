import XCTest
@testable import DohProxy

final class DohHttpsRecordTests: XCTestCase {
    func testParsesECHSvcParam() throws {
        var rdata = Data()
        rdata.append(contentsOf: [0x00, 0x01]) // priority 1
        rdata.append(0x00) // root target
        rdata.append(contentsOf: [0x00, 0x05, 0x00, 0x04, 0x01, 0x02, 0x03, 0x04])
        let parsed = try DohHttpsRecord.parseResourceData(rdata)
        XCTAssertEqual(parsed.priority, 1)
        XCTAssertEqual(parsed.echConfig, Data([1, 2, 3, 4]))
    }

    func testMissingECHIsNegativeCache() {
        var rdata = Data()
        rdata.append(contentsOf: [0x00, 0x01, 0x00])
        let result = DohEchClient().result(host: "example.com", httpsAnswers: [rdata])
        XCTAssertTrue(result.negative)
        XCTAssertFalse(result.isAvailable)
    }

    func testFirstECHConfigWins() {
        var without = Data()
        without.append(contentsOf: [0x00, 0x01, 0x00])
        var withECH = Data()
        withECH.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x05, 0x00, 0x02, 0xAA, 0xBB])
        let result = DohEchClient().result(host: "cloudflare.com", httpsAnswers: [without, withECH])
        XCTAssertEqual(result.echConfig, Data([0xAA, 0xBB]))
        XCTAssertFalse(result.negative)
    }
}
