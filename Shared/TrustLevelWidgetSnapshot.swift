import Foundation

enum TrustLevelWidgetIDs {
    static let appGroup = "group.com.naine.doer"
    static let snapshotKey = "trustLevel.widget.snapshot"
    static let widgetKind = "DoerTrustLevelWidget"
    static let deepLink = "doer://trust"
}

struct TrustLevelWidgetItem: Codable, Equatable {
    var label: String
    var current: Int
    var target: Int
    var isMet: Bool
    var isReverse: Bool

    var remaining: Int {
        if isReverse { return max(current - target, 0) }
        return max(target - current, 0)
    }

    var fractionComplete: Double {
        if isMet { return 1 }
        if isReverse {
            guard target > 0 else { return current <= 0 ? 1 : 0 }
            return min(max(1 - Double(current) / Double(target), 0), 1)
        }
        guard target > 0 else { return 0 }
        return min(max(Double(current) / Double(target), 0), 1)
    }

    var formattedCurrent: String { Self.formattedCount(current) }
    var formattedTarget: String { Self.formattedCount(target) }
    var formattedRemaining: String { Self.formattedCount(remaining) }

    static func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct TrustLevelWidgetSnapshot: Codable, Equatable {
    var title: String
    var badgeText: String
    var subtitle: String
    var items: [TrustLevelWidgetItem]
    var updatedAt: Date
    var trustLevel: Int?

    var headlineItem: TrustLevelWidgetItem? {
        items.first { $0.label.contains("帖") || $0.label.lowercased().contains("post") || $0.label.contains("读") }
            ?? items.first { !$0.isMet }
            ?? items.first
    }

    var levelBadgeText: String {
        if let trustLevel { return "TL\(trustLevel)" }
        return badgeText
    }

    var secondaryItems: [TrustLevelWidgetItem] {
        guard let headline = headlineItem else { return Array(items.prefix(3)) }
        return items.filter { $0.label != headline.label }
    }

    var formattedUpdatedAt: String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: updatedAt)
    }
}

enum TrustLevelWidgetSnapshotStore {
    static func load(defaults: UserDefaults? = UserDefaults(suiteName: TrustLevelWidgetIDs.appGroup)) -> TrustLevelWidgetSnapshot? {
        guard let data = defaults?.data(forKey: TrustLevelWidgetIDs.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(TrustLevelWidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: TrustLevelWidgetSnapshot, defaults: UserDefaults? = UserDefaults(suiteName: TrustLevelWidgetIDs.appGroup)) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: TrustLevelWidgetIDs.snapshotKey)
    }
}
