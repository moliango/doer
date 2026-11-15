import XCTest
@testable import DohProxy

final class DohHTTPWireTests: XCTestCase {
    private func response(_ extra: String, body: String) -> Data {
        Data(("HTTP/1.1 200 OK\r\n" + extra + "\r\n\r\n").utf8) + Data(body.utf8)
    }

    func testContentLengthMessageIsFramed() throws {
        let data = response("Content-Length: 5\r\nContent-Type: application/dns-message", body: "hello")
        let message = try XCTUnwrap(DohHTTPWire.parseMessage(data))
        XCTAssertEqual(message.body, Data("hello".utf8))
        XCTAssertEqual(message.consumed, data.count)
        XCTAssertFalse(message.closeConnection)
    }

    func testIncompleteContentLengthReturnsNil() throws {
        let data = response("Content-Length: 10", body: "hello")
        XCTAssertNil(try DohHTTPWire.parseMessage(data))
    }

    func testConnectionCloseIsReported() throws {
        let data = response("Content-Length: 2\r\nConnection: close", body: "ok")
        let message = try XCTUnwrap(DohHTTPWire.parseMessage(data))
        XCTAssertTrue(message.closeConnection)
    }

    func testChunkedMessageIsFramed() throws {
        let data = response("Transfer-Encoding: chunked", body: "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n")
        let message = try XCTUnwrap(DohHTTPWire.parseMessage(data))
        XCTAssertEqual(message.body, Data("Wikipedia".utf8))
        XCTAssertEqual(message.consumed, data.count)
    }

    func testIncompleteChunkedReturnsNil() throws {
        let data = response("Transfer-Encoding: chunked", body: "4\r\nWiki\r\n")
        XCTAssertNil(try DohHTTPWire.parseMessage(data))
    }

    func testNonSuccessStatusThrows() {
        let data = Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertThrowsError(try DohHTTPWire.parseMessage(data))
    }

    func testMissingFramingReturnsNil() throws {
        // 没有 Content-Length / chunked 的响应只能等连接关闭，不能复用。
        let data = response("Content-Type: application/dns-message", body: "hello")
        XCTAssertNil(try DohHTTPWire.parseMessage(data))
    }
}
