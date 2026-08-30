import Foundation

/// Client-side topic username filter (FluxDo `username_filters` display parity).
/// Does not force-keep floor 1 unless the filtered user is the OP.
enum TopicUsernameFilterPolicy {
    static func normalized(_ username: String?) -> String? {
        let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    static func usernamesMatch(_ a: String?, _ b: String?) -> Bool {
        switch (normalized(a), normalized(b)) {
        case (nil, nil):
            return true
        case let (left?, right?):
            return left.caseInsensitiveCompare(right) == .orderedSame
        default:
            return false
        }
    }

    static func isFilteringOP(filterUsername: String?, opUsername: String?) -> Bool {
        guard let filter = normalized(filterUsername), let op = normalized(opUsername) else {
            return false
        }
        return usernamesMatch(filter, op)
    }

    static func postMatches(username: String, filterUsername: String?) -> Bool {
        guard let filter = normalized(filterUsername) else { return true }
        return usernamesMatch(username, filter)
    }

    /// Same user again clears; a different user replaces; nil clears.
    static func toggling(current: String?, requested: String) -> String? {
        guard let next = normalized(requested) else { return current }
        if usernamesMatch(current, next) {
            return nil
        }
        return next
    }

    /// Discourse `username_filters` always keeps floor 1. Ignore the opening post
    /// when deciding whether the filtered TopicView actually applied.
    static func usernameFilterTookEffectExcludingOpeningPost(
        posts: [(postNumber: Int, username: String)],
        filterUsername: String?
    ) -> Bool {
        guard let filter = normalized(filterUsername) else { return true }
        let hasOtherAuthors = posts.contains { post in
            post.postNumber != 1 && !usernamesMatch(post.username, filter)
        }
        return !hasOtherAuthors
    }

    /// After a `username_filters` TopicView, clearing the filter (or switching to
    /// another exclusive mode) must fetch without the query. Nested `/n/topic` is a
    /// different stream, so defer that unfiltered reload until nested is off.
    static func shouldFetchUnfilteredTopicView(
        hadUsernameFilter: Bool,
        showingNested: Bool
    ) -> Bool {
        hadUsernameFilter && !showingNested
    }
}

/// In-topic find result cursor. Empty lists yield `nil`; otherwise indices wrap.
enum TopicFindNavigation {
    static func clampedIndex(_ index: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min(max(index, 0), count - 1)
    }

    static func nextIndex(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return (current + 1) % count
    }

    static func previousIndex(current: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return (current - 1 + count) % count
    }
}

struct TopicFindHit: Equatable {
    let postId: Int
    let postNumber: Int
}
