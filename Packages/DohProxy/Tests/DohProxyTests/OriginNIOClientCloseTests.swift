import Foundation
import XCTest
@testable import DohProxy

/// 上游 socket 关闭必须一路报出来。
///
/// 以前 `pumpSocket` 收到 nil 只调 `notifyHandshake(false)`，而握手早就通知过 `true`，
/// 那个调用是空操作 —— 客户端继续复用这条死隧道，请求全挂住且没有任何日志。
/// `socketRead` 是注入的闭包，这里不用打网络就能复现。
final class OriginNIOClientCloseTests: XCTestCase {

    func testOnSocketClosedFiresWhenSocketEnds() throws {
        let client = try OriginNIOClient(
            sni: "example.com",
            applicationProtocols: ["http/1.1"],
            echConfig: nil
        )
        let closed = expectation(description: "源站关闭回调")
        let done = expectation(description: "start 返回")
        done.assertForOverFulfill = false

        var socketRead: ((Data?) -> Void)?
        client.start(
            socketRead: { deliver in socketRead = deliver },
            socketWrite: { _, finish in finish() },
            appRead: { _ in },
            completion: { _ in done.fulfill() },
            onHandshake: { _ in },
            onSocketClosed: { closed.fulfill() }
        )

        let read = try XCTUnwrap(socketRead, "start 没有挂上读循环")
        // 对端关闭：读循环拿到的就是 nil
        read(nil)

        wait(for: [closed], timeout: 5)
        // 关闭只报一次，别让上层反复收连接。
        read(nil)
        wait(for: [done], timeout: 1)
    }
}
