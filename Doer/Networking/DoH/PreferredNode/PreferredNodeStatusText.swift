import Foundation

/// 设置页展示用的优选状态文案。
@MainActor
enum PreferredNodeStatusText {
    static var isEnabled: Bool {
        let settings = AppSettings.shared
        return settings.dohEnabled
            && settings.preferredNodeEnabled
            && settings.preferredNodeMode != .off
    }

    static var isRunning: Bool {
        PreferredNodeSelector.shared.status.isRunning
    }

    static func subtitle() -> String {
        guard isEnabled else {
            return String(
                localized: "settings.network.preferred_node.disabled",
                defaultValue: "已关闭（需先开启 DoH）"
            )
        }
        switch PreferredNodeSelector.shared.status {
        case .gathering:
            return String(
                localized: "settings.network.preferred_node.gathering",
                defaultValue: "正在收集候选…"
            )
        case .racing(let done, let total):
            return String(
                format: String(
                    localized: "settings.network.preferred_node.racing",
                    defaultValue: "竞速中 %1$d/%2$d"
                ),
                done,
                total
            )
        case .failed(let message):
            if let node = PreferredNodeStore.shared.node {
                return describe(node) + " · " + String(
                    format: String(
                        localized: "settings.network.preferred_node.last_failed",
                        defaultValue: "上次失败：%1$@"
                    ),
                    message
                )
            }
            return String(
                format: String(
                    localized: "settings.network.preferred_node.failed",
                    defaultValue: "未选出节点：%1$@"
                ),
                message
            )
        case .idle, .success:
            guard let node = PreferredNodeStore.shared.node else {
                return String(
                    localized: "settings.network.preferred_node.none",
                    defaultValue: "还没选过节点"
                )
            }
            return describe(node)
        }
    }

    private static func describe(_ node: PreferredNode) -> String {
        "\(node.ip) · \(node.latencyMs)ms · \(node.family.rawValue) · \(sourceTitle(node.source))"
    }

    private static func sourceTitle(_ source: PreferredNode.Source) -> String {
        switch source {
        case .sticky:
            return String(
                localized: "settings.network.preferred_node.source.sticky",
                defaultValue: "沿用"
            )
        case .atlas:
            return "atlas"
        case .vendor:
            return String(
                localized: "settings.network.preferred_node.source.vendor",
                defaultValue: "大厂域名"
            )
        case .random:
            return String(
                localized: "settings.network.preferred_node.source.random",
                defaultValue: "随机抽样"
            )
        }
    }
}
