import UIKit
import ObjectiveC
import CoreText

// MARK: - Bottom Bar
extension AppSettings {

    enum ForumDynamicTabItem: String, CaseIterable {
        case history
        case search
        case notifications
        case messages
        case bookmarks
        case chat

        var title: String {
            switch self {
            case .history: return String(localized: "tab.history")
            case .search: return String(localized: "search.title")
            case .notifications: return String(localized: "tab.notifications")
            case .messages: return String(localized: "tab.messages")
            case .bookmarks: return String(localized: "me.bookmarks")
            case .chat: return String(localized: "chat.title", defaultValue: "站内聊天")
            }
        }

        var subtitle: String {
            switch self {
            case .history:
                return String(
                    localized: "settings.bottom_bar.history.subtitle",
                    defaultValue: "查看已读和看过的话题"
                )
            case .search:
                return String(
                    localized: "settings.bottom_bar.search.subtitle",
                    defaultValue: "搜索帖子和回复"
                )
            case .notifications:
                return String(
                    localized: "settings.bottom_bar.notifications.subtitle",
                    defaultValue: "查看回复、点赞和系统通知"
                )
            case .messages:
                return String(
                    localized: "settings.bottom_bar.messages.subtitle",
                    defaultValue: "查看论坛私信"
                )
            case .bookmarks:
                return String(
                    localized: "settings.bottom_bar.bookmarks.subtitle",
                    defaultValue: "查看已收藏内容"
                )
            case .chat:
                return String(
                    localized: "settings.bottom_bar.chat.subtitle",
                    defaultValue: "频道与私聊"
                )
            }
        }

        var symbolName: String {
            switch self {
            case .history: return "clock.arrow.circlepath"
            case .search: return "magnifyingglass"
            case .notifications: return "bell"
            case .messages: return "envelope"
            case .bookmarks: return "bookmark"
            case .chat: return "bubble.left.and.bubble.right"
            }
        }

        nonisolated static func storedValue(_ rawValue: String) -> ForumDynamicTabItem? {
            if rawValue == "categories" {
                return .history
            }
            return ForumDynamicTabItem(rawValue: rawValue)
        }
    }

    static let minimumConfiguredForumDynamicTabItems = 0
    static let maximumConfiguredForumDynamicTabItems = 5
    static let maximumVisibleForumDynamicTabItems = 3
    static let defaultForumDynamicTabItems: [ForumDynamicTabItem] = [
        .history,
        .notifications,
        .chat,
    ]

    static func pluginForumTabItemID(pluginID: String, contributionID: String) -> String {
        "plugin:\(pluginID):\(contributionID)"
    }

    var bottomBarAutoHideEnabled: Bool {
        get { bool(forKey: "bottomBarAutoHideEnabled", defaultValue: true) }
        set {
            defaults.set(newValue, forKey: "bottomBarAutoHideEnabled")
            notifyChanged()
        }
    }

    var forumDynamicTabItems: [ForumDynamicTabItem] {
        get {
            Self.sanitizedForumDynamicTabItems(
                forumConfiguredTabItemIDs.compactMap(ForumDynamicTabItem.storedValue)
            )
        }
        set {
            forumConfiguredTabItemIDs = Self.sanitizedForumDynamicTabItems(newValue).map(\.rawValue)
        }
    }

    var forumConfiguredTabItemIDs: [String] {
        get {
            let stored = defaults.stringArray(forKey: "forumDynamicTabItemIds")
                ?? Self.defaultForumDynamicTabItems.map(\.rawValue)
            return Self.sanitizedForumTabItemIDs(stored)
        }
        set {
            defaults.set(Self.sanitizedForumTabItemIDs(newValue), forKey: "forumDynamicTabItemIds")
            notifyChanged()
        }
    }

    var forumVisibleConfiguredTabItemIDs: [String] {
        Array(forumConfiguredTabItemIDs.prefix(Self.maximumVisibleForumDynamicTabItems))
    }

    var forumVisibleDynamicTabItems: [ForumDynamicTabItem] {
        Array(forumDynamicTabItems.prefix(Self.maximumVisibleForumDynamicTabItems))
    }

    func resetForumDynamicTabItems() {
        forumConfiguredTabItemIDs = Self.defaultForumDynamicTabItems.map(\.rawValue)
    }

    static func sanitizedForumDynamicTabItems(_ items: [ForumDynamicTabItem]) -> [ForumDynamicTabItem] {
        var seen = Set<ForumDynamicTabItem>()
        let uniqueItems = items.filter { seen.insert($0).inserted }
        let limitedItems = Array(uniqueItems.prefix(maximumConfiguredForumDynamicTabItems))
        if limitedItems.count >= minimumConfiguredForumDynamicTabItems {
            return limitedItems
        }
        return Array(defaultForumDynamicTabItems.prefix(minimumConfiguredForumDynamicTabItems))
    }

    static func sanitizedForumTabItemIDs(_ itemIDs: [String]) -> [String] {
        var seen = Set<String>()
        let normalized = itemIDs.compactMap { rawValue -> String? in
            if let systemItem = ForumDynamicTabItem.storedValue(rawValue) {
                return systemItem.rawValue
            }
            guard rawValue.hasPrefix("plugin:"), rawValue.split(separator: ":").count >= 3 else {
                return nil
            }
            return rawValue
        }
        return Array(normalized.filter { seen.insert($0).inserted }.prefix(maximumConfiguredForumDynamicTabItems))
    }
}
