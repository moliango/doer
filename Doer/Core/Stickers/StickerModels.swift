import Foundation

struct StickerMarketTopic: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    let totalGroups: Int
    let totalPages: Int

    enum CodingKeys: String, CodingKey {
        case id, label, totalGroups, totalPages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        label = (try? container.decode(String.self, forKey: .label)) ?? id
        totalGroups = (try? container.decode(Int.self, forKey: .totalGroups)) ?? 0
        totalPages = (try? container.decode(Int.self, forKey: .totalPages)) ?? 0
    }

    init(id: String, label: String, totalGroups: Int, totalPages: Int) {
        self.id = id
        self.label = label
        self.totalGroups = totalGroups
        self.totalPages = totalPages
    }

    var isAll: Bool { id == "all" || id.isEmpty }
}

struct StickerMarketIndex: Codable, Equatable {
    let totalPages: Int
    let pageSize: Int
    let totalGroups: Int
    let topics: [StickerMarketTopic]

    enum CodingKeys: String, CodingKey {
        case totalPages, pageSize, totalGroups, topics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalPages = (try? container.decode(Int.self, forKey: .totalPages)) ?? 0
        pageSize = (try? container.decode(Int.self, forKey: .pageSize)) ?? 0
        totalGroups = (try? container.decode(Int.self, forKey: .totalGroups)) ?? 0
        topics = (try? container.decode([StickerMarketTopic].self, forKey: .topics)) ?? []
    }

    init(totalPages: Int, pageSize: Int, totalGroups: Int, topics: [StickerMarketTopic] = []) {
        self.totalPages = totalPages
        self.pageSize = pageSize
        self.totalGroups = totalGroups
        self.topics = topics
    }

    var displayTopics: [StickerMarketTopic] {
        let usable = topics.filter { !$0.id.isEmpty && ($0.isAll || $0.totalGroups > 0) }
        if usable.contains(where: \.isAll) {
            return usable
        }
        return [StickerMarketTopic(id: "all", label: "全部", totalGroups: totalGroups, totalPages: totalPages)] + usable
    }
}

struct StickerGroup: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let icon: String
    let topic: String
    let order: Int
    let emojiCount: Int
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, icon, topic, order, emojiCount, isArchived
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        icon = (try? container.decode(String.self, forKey: .icon)) ?? ""
        topic = (try? container.decode(String.self, forKey: .topic)) ?? ""
        order = (try? container.decode(Int.self, forKey: .order)) ?? 0
        emojiCount = (try? container.decode(Int.self, forKey: .emojiCount)) ?? 0
        isArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
    }

    init(
        id: String,
        name: String,
        icon: String,
        topic: String = "",
        order: Int,
        emojiCount: Int,
        isArchived: Bool
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.topic = topic
        self.order = order
        self.emojiCount = emojiCount
        self.isArchived = isArchived
    }
}

enum StickerMarketFilterPolicy {
    static let allCategoryId = "all"

    static func matches(group: StickerGroup, categoryId: String?, query: String) -> Bool {
        if let categoryId, !categoryId.isEmpty, categoryId != allCategoryId {
            let topic = group.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard topic.compare(categoryId, options: .caseInsensitive) == .orderedSame else {
                return false
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return group.name.localizedCaseInsensitiveContains(needle)
            || group.id.localizedCaseInsensitiveContains(needle)
            || group.topic.localizedCaseInsensitiveContains(needle)
    }

    static func filtered(
        groups: [StickerGroup],
        categoryId: String?,
        query: String
    ) -> [StickerGroup] {
        groups.filter { matches(group: $0, categoryId: categoryId, query: query) }
    }
}

struct StickerItem: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let url: String
    let width: Int
    let height: Int
    let groupId: String

    enum CodingKeys: String, CodingKey {
        case id, name, url, width, height, groupId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        width = (try? container.decode(Int.self, forKey: .width)) ?? 0
        height = (try? container.decode(Int.self, forKey: .height)) ?? 0
        groupId = (try? container.decode(String.self, forKey: .groupId)) ?? ""
    }

    init(id: String, name: String, url: String, width: Int, height: Int, groupId: String) {
        self.id = id
        self.name = name
        self.url = url
        self.width = width
        self.height = height
        self.groupId = groupId
    }

    /// FluxDO-compatible Discourse markdown image insertion.
    var markdown: String {
        "![\(name)|\(width)x\(height),30%](\(url))"
    }
}

struct StickerGroupDetail: Codable, Equatable {
    let id: String
    let name: String
    let icon: String
    let emojis: [StickerItem]

    enum CodingKeys: String, CodingKey {
        case id, name, icon, emojis
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        icon = (try? container.decode(String.self, forKey: .icon)) ?? ""
        emojis = (try? container.decode([StickerItem].self, forKey: .emojis)) ?? []
    }

    init(id: String, name: String, icon: String, emojis: [StickerItem]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.emojis = emojis
    }
}

private struct StickerGroupsPage: Codable {
    let groups: [StickerGroup]
}
