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
}

struct MeStatsConfiguration: Codable, Equatable {
    var orderedMetrics: [MeStatType]
    var layout: MeStatsLayout
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
