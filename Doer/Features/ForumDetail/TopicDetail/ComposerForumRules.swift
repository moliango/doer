import Foundation

/// Category plugin rules used by composers: warden min length + reply-cost.
struct ComposerForumRules: Equatable {
    var minFirstPostLength: Int
    var minReplyLength: Int
    var replyCost: Int

    static let none = ComposerForumRules(minFirstPostLength: 0, minReplyLength: 0, replyCost: 0)

    static func resolve(category: DiscourseCategory?, parent: DiscourseCategory? = nil) -> ComposerForumRules {
        let child = rules(from: category)
        let inherited = rules(from: parent)
        return ComposerForumRules(
            minFirstPostLength: child.minFirstPostLength > 0 ? child.minFirstPostLength : inherited.minFirstPostLength,
            minReplyLength: child.minReplyLength > 0 ? child.minReplyLength : inherited.minReplyLength,
            replyCost: child.replyCost > 0 ? child.replyCost : inherited.replyCost
        )
    }

    static func resolve(baseURL: String, categoryId: Int?) -> ComposerForumRules {
        guard let categoryId else { return .none }
        let category = DiscourseTaxonomySessionStore.category(id: categoryId, for: baseURL)
            ?? LinuxDoCategoryCatalog.category(id: categoryId, baseURL: baseURL)
        let parentId = category?.parentCategoryId
        let parent = parentId.flatMap {
            DiscourseTaxonomySessionStore.category(id: $0, for: baseURL)
                ?? LinuxDoCategoryCatalog.category(id: $0, baseURL: baseURL)
        }
        return resolve(category: category, parent: parent)
    }

    private static func rules(from category: DiscourseCategory?) -> ComposerForumRules {
        guard let fields = category?.customFields else { return .none }
        let sharedMin = fields.int(forKeys: Self.sharedMinKeys) ?? 0
        let minFirst = fields.int(forKeys: Self.firstPostMinKeys) ?? sharedMin
        let minReply = fields.int(forKeys: Self.replyMinKeys) ?? sharedMin
        let cost = fields.int(forKeys: Self.replyCostKeys) ?? 0
        return ComposerForumRules(
            minFirstPostLength: minFirst,
            minReplyLength: minReply,
            replyCost: cost
        )
    }

    private static let sharedMinKeys = [
        "min_post_length",
        "min_word_count",
        "min_chars",
        "warden_min_post_length",
        "minimum_post_length",
    ]

    private static let firstPostMinKeys = [
        "min_first_post_length",
        "min_topic_length",
    ]

    private static let replyMinKeys = [
        "min_reply_length",
    ]

    private static let replyCostKeys = [
        "reply_cost",
        "discourse_reply_cost",
        "reply_score_cost",
    ]
}

struct ComposerLengthProgress: Equatable {
    let current: Int
    let minimum: Int

    var remaining: Int { max(minimum - current, 0) }
    var meetsMinimum: Bool { remaining == 0 }
    var shouldShowHint: Bool { minimum > 0 }
}

/// Discourse-like body length: collapse whitespace, then character count (CJK = 1).
enum ComposerWardenPolicy {
    static func visibleLength(of raw: String) -> Int {
        raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count
    }

    static func progress(raw: String, minimum: Int) -> ComposerLengthProgress {
        ComposerLengthProgress(current: visibleLength(of: raw), minimum: max(minimum, 0))
    }
}

enum ComposerReplyCostPolicy {
    static func shouldConfirm(cost: Int, isReply: Bool) -> Bool {
        isReply && cost > 0
    }
}

/// In-topic filter chip copy. Nested tree has its own chrome, so it is omitted.
enum TopicFilterHintPolicy {
    static func bannerTitle(
        showHint: Bool,
        isFilteringByOP: Bool,
        filterUsername: String?,
        isFilteringTopLevel: Bool
    ) -> String? {
        guard showHint else { return nil }
        if isFilteringByOP {
            return String(localized: "topic.filter_hint.op", defaultValue: "正在查看题主")
        }
        if let username = TopicUsernameFilterPolicy.normalized(filterUsername) {
            return String(
                format: String(localized: "topic.filter_hint.user %@", defaultValue: "正在查看 %@"),
                username
            )
        }
        if isFilteringTopLevel {
            return String(localized: "topic.filter_hint.top_level", defaultValue: "正在查看顶层回复")
        }
        return nil
    }
}
