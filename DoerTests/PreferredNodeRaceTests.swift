import XCTest
@testable import Doer

/// 端到端：在 iOS 运行时里真跑一次优选，验证"收集候选 → 取钥匙 → 竞速 → 落地赢家"整条链路。
///
/// 会打真网络，只在显式指定时跑：
/// ```
/// xcodebuild test -workspace Doer.xcworkspace -scheme Doer \
///   -destination 'platform=iOS Simulator,name=doerdebug' \
///   -only-testing:DoerTests/PreferredNodeRaceTests
/// ```
@MainActor
final class PreferredNodeRaceTests: XCTestCase {

    func testManualReselectFindsAWinner() throws {
        let selector = PreferredNodeSelector.shared
        var winner: PreferredNode?

        // 测试宿主启动时会自动跑一次优选，manual 有 10s 冷却；
        // 冷却中被拒是立即回调 nil，所以重试几轮。
        for attempt in 0..<4 where winner == nil {
            if attempt > 0 { Thread.sleep(forTimeInterval: 12) }
            let done = expectation(description: "优选第 \(attempt + 1) 次")
            selector.reselect(trigger: .manual) { node in
                winner = node
                done.fulfill()
            }
            wait(for: [done], timeout: 120)
        }

        let node = try XCTUnwrap(winner, "这次优选没选出赢家（看 [优选] 日志里的失败摘要）")
        print("[race] 赢家 \(node.ip)（\(node.family.rawValue)，\(node.latencyMs)ms，\(node.source.rawValue)）")
        XCTAssertGreaterThan(node.latencyMs, 0)
        XCTAssertNotNil(PreferredNodeStore.shared.node, "赢家没有写进 store")
    }
}
