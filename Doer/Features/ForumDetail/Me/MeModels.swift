import UIKit
import Foundation

struct MeActionRow {
    let title: String
    let subtitle: String
    let symbolName: String
    let tintColor: UIColor
    let isEnabled: Bool
    var badgeCount: Int = 0
    let action: () -> Void
}

enum MeAccountFunction: String, CaseIterable, Codable, Hashable {
    case messages
    case chat
    case browser
    case aiModelService
    case badges
    case trustRequirements
    case inviteLinks
    case exportHistory
    case pendingPosts
    case notionSync
    case settings

    var title: String {
        switch self {
        case .messages:
            return String(localized: "messages.title")
        case .chat:
            return String(localized: "chat.title", defaultValue: "站内聊天")
        case .browser:
            return String(localized: "me.browser.home", defaultValue: "网页浏览")
        case .aiModelService:
            return String(localized: "ai.service.title", defaultValue: "AI 模型服务")
        case .badges:
            return String(localized: "me.badges")
        case .trustRequirements:
            return String(localized: "me.trust_requirements")
        case .inviteLinks:
            return String(localized: "me.invite_links")
        case .exportHistory:
            return String(localized: "topic.export.history", defaultValue: "导出历史")
        case .pendingPosts:
            return String(localized: "pending.title", defaultValue: "待审内容")
        case .notionSync:
            return String(localized: "notion.settings.title", defaultValue: "Notion 同步")
        case .settings:
            return String(localized: "me.settings")
        }
    }

    var symbolName: String {
        switch self {
        case .messages: return "envelope.fill"
        case .chat: return "bubble.left.and.bubble.right.fill"
        case .browser: return "safari.fill"
        case .aiModelService: return "cpu.fill"
        case .badges: return "medal.fill"
        case .trustRequirements: return "checkmark.shield.fill"
        case .inviteLinks: return "link.circle.fill"
        case .exportHistory: return "square.and.arrow.up.on.square.fill"
        case .pendingPosts: return "hourglass"
        case .notionSync: return "tray.and.arrow.up.fill"
        case .settings: return "gearshape.fill"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .messages: return .systemIndigo
        case .chat: return .systemPurple
        case .browser: return .systemCyan
        case .aiModelService: return .systemTeal
        case .badges: return .systemYellow
        case .trustRequirements: return .systemGreen
        case .inviteLinks: return .systemCyan
        case .exportHistory: return .systemGreen
        case .pendingPosts: return .systemOrange
        case .notionSync: return .systemGray
        case .settings: return .systemBlue
        }
    }

    var subtitle: String {
        switch self {
        case .messages:
            return String(localized: "me.action.messages.subtitle")
        case .chat:
            return String(localized: "me.action.chat.subtitle", defaultValue: "频道与私聊")
        case .browser:
            return String(localized: "me.action.browser.subtitle", defaultValue: "收藏、历史与内置浏览器")
        case .aiModelService:
            return String(localized: "me.action.ai.subtitle", defaultValue: "管理 AI 供应商与模型")
        case .badges:
            return String(localized: "me.action.badges.subtitle")
        case .trustRequirements:
            return String(localized: "me.action.trust.subtitle")
        case .inviteLinks:
            return String(localized: "me.action.invites.subtitle")
        case .exportHistory:
            return String(localized: "me.action.export_history.subtitle", defaultValue: "查看并再次分享话题导出文件")
        case .pendingPosts:
            return String(localized: "pending.subtitle", defaultValue: "查看送审中的主题与回复")
        case .notionSync:
            return String(localized: "notion.settings.subtitle", defaultValue: "配置 Token 并把话题同步到 Notion")
        case .settings:
            return String(localized: "me.action.settings.subtitle")
        }
    }
}

struct MeAccountFunctionConfiguration: Codable, Equatable {
    var orderedFunctions: [MeAccountFunction]
    var hiddenFunctions: [MeAccountFunction]
}

enum MeStatType: String, CaseIterable, Codable {
    case daysVisited
    case topicCount
    case postCount
    case likesReceived
    case likesGiven
    case timeRead
    case profileViews
    case badges

    var title: String {
        switch self {
        case .daysVisited: return String(localized: "me.stats.days")
        case .topicCount: return String(localized: "me.stats.topics")
        case .postCount: return String(localized: "me.stats.posts")
        case .likesReceived: return String(localized: "me.stats.likes")
        case .likesGiven: return String(localized: "me.stats.likes_given")
        case .timeRead: return String(localized: "me.stats.time_read")
        case .profileViews: return String(localized: "me.stats.profile_views")
        case .badges: return String(localized: "me.stats.badges")
        }
    }

    var symbolName: String {
        switch self {
        case .daysVisited: return "calendar"
        case .topicCount: return "text.bubble.fill"
        case .postCount: return "bubble.left.and.bubble.right.fill"
        case .likesReceived: return "heart.fill"
        case .likesGiven: return "hand.thumbsup.fill"
        case .timeRead: return "clock.fill"
        case .profileViews: return "eye.fill"
        case .badges: return "medal.fill"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .daysVisited: return .systemTeal
        case .topicCount: return .systemBlue
        case .postCount: return .systemIndigo
        case .likesReceived: return .systemPink
        case .likesGiven: return .systemPurple
        case .timeRead: return .systemGreen
        case .profileViews: return .systemOrange
        case .badges: return .systemYellow
        }
    }
}

enum MeStatsLayout: String, Codable, CaseIterable {
    case grid
    case horizontal

    var title: String {
        switch self {
        case .grid:
            return String(localized: "me.stats.layout.grid", defaultValue: "网格")
        case .horizontal:
            return String(localized: "me.stats.layout.horizontal", defaultValue: "横向")
        }
    }

    var subtitle: String {
        switch self {
        case .grid:
            return String(localized: "me.stats.layout.grid.subtitle", defaultValue: "每行四个，适合一眼扫完")
        case .horizontal:
            return String(localized: "me.stats.layout.horizontal.subtitle", defaultValue: "单行滑动，卡片更紧凑")
        }
    }

    var symbolName: String {
        switch self {
        case .grid: return "square.grid.2x2.fill"
        case .horizontal: return "rectangle.split.2x1.fill"
        }
    }
}

enum MeStatsLayoutGeometry {
    static let gridColumns = 4
    static let gridItemHeight: CGFloat = 84
    static let gridSpacing: CGFloat = 8
    static let horizontalItemHeight: CGFloat = 84
    static let horizontalSpacing: CGFloat = 12
    static let horizontalVisibleCount: CGFloat = 3
    static let horizontalPeek: CGFloat = 28
    static let horizontalItemWidth: CGFloat = 78

    static func gridRowCount(for itemCount: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        return Int(ceil(Double(itemCount) / Double(gridColumns)))
    }

    static func contentHeight(for itemCount: Int, layout: MeStatsLayout) -> CGFloat {
        switch layout {
        case .grid:
            let rows = max(gridRowCount(for: itemCount), 1)
            return CGFloat(rows) * gridItemHeight + CGFloat(max(rows - 1, 0)) * gridSpacing
        case .horizontal:
            return horizontalItemHeight
        }
    }

    /// Three full tiles plus a peek of the next, so horizontal never fills like a 4-up grid.
    static func horizontalItemWidth(in containerWidth: CGFloat) -> CGFloat {
        let width = max(containerWidth, 1)
        let spacers = horizontalSpacing * horizontalVisibleCount
        let available = width - horizontalPeek - spacers
        return max(64, floor(available / horizontalVisibleCount))
    }
}

struct MeStatsConfiguration: Codable, Equatable {
    var orderedMetrics: [MeStatType]
    var layout: MeStatsLayout

    var hiddenMetrics: [MeStatType] {
        let visible = Set(orderedMetrics)
        return MeStatType.allCases.filter { !visible.contains($0) }
    }

    mutating func hideMetric(_ metric: MeStatType, minimum: Int = 2) -> Bool {
        guard orderedMetrics.count > minimum,
              let index = orderedMetrics.firstIndex(of: metric) else { return false }
        orderedMetrics.remove(at: index)
        return true
    }

    mutating func showMetric(_ metric: MeStatType) {
        guard !orderedMetrics.contains(metric) else { return }
        orderedMetrics.append(metric)
    }

    mutating func moveMetric(at index: Int, by delta: Int) {
        moveMetric(from: index, to: index + delta)
    }

    mutating func moveMetric(from source: Int, to destination: Int) {
        guard orderedMetrics.indices.contains(source) else { return }
        let metric = orderedMetrics.remove(at: source)
        let index = min(max(destination, 0), orderedMetrics.count)
        orderedMetrics.insert(metric, at: index)
    }
}

struct MeStatItem {
    let type: MeStatType
    let valueText: String

    init(type: MeStatType, value: Int?) {
        self.type = type
        self.valueText = value.map { Self.formatNumber($0) } ?? "-"
    }

    init(type: MeStatType, valueText: String?) {
        self.type = type
        self.valueText = valueText ?? "-"
    }

    private static func formatNumber(_ value: Int) -> String {
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

final class MeStatsPreferences {
    private let legacyKey = "me.stats.selected"
    private let configurationKey = "me.stats.configuration"
    private let defaults: UserDefaults
    private let fallback: [MeStatType] = [.daysVisited, .postCount, .likesReceived, .topicCount]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: MeStatsConfiguration {
        get {
            if let data = defaults.data(forKey: configurationKey),
               let decoded = try? JSONDecoder().decode(MeStatsConfiguration.self, from: data),
               !decoded.orderedMetrics.isEmpty {
                return decoded
            }

            let legacy = defaults.stringArray(forKey: legacyKey)?.compactMap(MeStatType.init(rawValue:)) ?? []
            let migrated = MeStatsConfiguration(
                orderedMetrics: legacy.isEmpty ? fallback : legacy,
                layout: .grid
            )
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: configurationKey)
            }
            return migrated
        }
        set {
            guard !newValue.orderedMetrics.isEmpty,
                  let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: configurationKey)
            defaults.set(newValue.orderedMetrics.map(\.rawValue), forKey: legacyKey)
        }
    }

    var selectedStats: [MeStatType] {
        get { configuration.orderedMetrics }
        set {
            var updated = configuration
            updated.orderedMetrics = newValue
            configuration = updated
        }
    }

    func reset() {
        configuration = MeStatsConfiguration(orderedMetrics: fallback, layout: .grid)
    }
}

final class MeAccountFunctionPreferences {
    static let didChangeNotification = Notification.Name("MeAccountFunctionPreferences.didChange")

    private let configurationKey = "me.account_functions.configuration"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var configuration: MeAccountFunctionConfiguration {
        get {
            if let data = defaults.data(forKey: configurationKey),
               let decoded = try? JSONDecoder().decode(MeAccountFunctionConfiguration.self, from: data) {
                return sanitized(decoded)
            }
            return defaultConfiguration
        }
        set {
            let configuration = sanitized(newValue)
            guard let data = try? JSONEncoder().encode(configuration) else { return }
            defaults.set(data, forKey: configurationKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    var visibleFunctions: [MeAccountFunction] {
        let configuration = configuration
        let hidden = Set(configuration.hiddenFunctions)
        return configuration.orderedFunctions.filter { !hidden.contains($0) }
    }

    var hiddenFunctions: [MeAccountFunction] {
        let configuration = configuration
        let hidden = Set(configuration.hiddenFunctions)
        return configuration.orderedFunctions.filter { hidden.contains($0) }
    }

    func setVisibleFunctions(_ visibleFunctions: [MeAccountFunction]) {
        let current = configuration
        let visible = sanitizedFunctions(visibleFunctions)
        let visibleSet = Set(visible)
        let ordered = visible + current.orderedFunctions.filter { !visibleSet.contains($0) }
        configuration = MeAccountFunctionConfiguration(
            orderedFunctions: ordered,
            hiddenFunctions: ordered.filter { !visibleSet.contains($0) }
        )
    }

    func reset() {
        defaults.removeObject(forKey: configurationKey)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private var defaultConfiguration: MeAccountFunctionConfiguration {
        MeAccountFunctionConfiguration(
            orderedFunctions: MeAccountFunction.allCases,
            hiddenFunctions: []
        )
    }

    private func sanitized(_ configuration: MeAccountFunctionConfiguration) -> MeAccountFunctionConfiguration {
        let ordered = sanitizedFunctions(configuration.orderedFunctions)
        let orderedSet = Set(ordered)
        let missing = MeAccountFunction.allCases.filter { !orderedSet.contains($0) }
        let finalOrder = ordered + missing
        let hidden = sanitizedFunctions(configuration.hiddenFunctions).filter { finalOrder.contains($0) }
        return MeAccountFunctionConfiguration(
            orderedFunctions: finalOrder,
            hiddenFunctions: hidden
        )
    }

    private func sanitizedFunctions(_ functions: [MeAccountFunction]) -> [MeAccountFunction] {
        var seen = Set<MeAccountFunction>()
        return functions.filter { seen.insert($0).inserted }
    }
}
