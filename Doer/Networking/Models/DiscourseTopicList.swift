import Foundation

extension Notification.Name {
    static let topicReadProgressDidChange = Notification.Name("topicReadProgressDidChange")
}

nonisolated enum TopicReadProgressUserInfoKey {
    static let baseURL = "baseURL"
    static let topicId = "topicId"
    static let highestSeen = "highestSeen"
}

nonisolated struct DiscourseTopicList: Decodable {
    let users: [User]?
    let categories: [DiscourseCategory]?
    let topicList: TopicList

    enum CodingKeys: String, CodingKey {
        case users, categories
        case topicList = "topic_list"
    }

    struct User: Decodable {
        let id: Int
        let username: String
        let avatarTemplate: String?

        enum CodingKeys: String, CodingKey {
            case id, username
            case avatarTemplate = "avatar_template"
        }
    }

    struct Poster: Decodable {
        let userId: Int
        let extras: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case extras
        }
    }

    struct TopicList: Decodable {
        let topics: [Topic]
        let moreTopicsUrl: String?

        enum CodingKeys: String, CodingKey {
            case topics
            case moreTopicsUrl = "more_topics_url"
        }
    }

    struct Topic: Decodable, Identifiable {
        let id: Int
        let fancyTitle: String
        let title: String
        let postsCount: Int
        let replyCount: Int
        let views: Int
        let categoryId: Int?
        let createdAt: String
        let lastPostedAt: String?
        let pinned: Bool?
        /// User chose “unpin” — Discourse still may send `pinned: true`.
        let unpinned: Bool?
        let excerpt: String?
        let posters: [Poster]?
        let tags: [String]?
        let unseen: Bool
        let unreadPosts: Int
        let lastReadPostNumber: Int?
        let highestPostNumber: Int?

        var isUnreadForDisplay: Bool {
            unseen || unreadPosts > 0 || lastReadPostNumber == nil
        }

        enum CodingKeys: String, CodingKey {
            case id, title, views, pinned, unpinned, excerpt, posters, tags, unseen
            case fancyTitle = "fancy_title"
            case postsCount = "posts_count"
            case replyCount = "reply_count"
            case categoryId = "category_id"
            case createdAt = "created_at"
            case lastPostedAt = "last_posted_at"
            case unreadPosts = "unread_posts"
            case lastReadPostNumber = "last_read_post_number"
            case highestPostNumber = "highest_post_number"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            fancyTitle = try container.decode(String.self, forKey: .fancyTitle)
            title = try container.decode(String.self, forKey: .title)
            postsCount = try container.decode(Int.self, forKey: .postsCount)
            replyCount = try container.decode(Int.self, forKey: .replyCount)
            views = try container.decode(Int.self, forKey: .views)
            categoryId = try container.decodeIfPresent(Int.self, forKey: .categoryId)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            lastPostedAt = try container.decodeIfPresent(String.self, forKey: .lastPostedAt)
            pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
            unpinned = try container.decodeIfPresent(Bool.self, forKey: .unpinned)
            excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
            posters = try container.decodeIfPresent([Poster].self, forKey: .posters)
            tags = Self.decodeTags(from: container)
            unseen = try container.decodeIfPresent(Bool.self, forKey: .unseen) ?? false
            unreadPosts = try container.decodeIfPresent(Int.self, forKey: .unreadPosts) ?? 0
            lastReadPostNumber = try container.decodeIfPresent(Int.self, forKey: .lastReadPostNumber)
            highestPostNumber = try container.decodeIfPresent(Int.self, forKey: .highestPostNumber)
        }

        func updatingReadProgress(highestSeen: Int) -> Topic {
            Topic(
                id: id,
                fancyTitle: fancyTitle,
                title: title,
                postsCount: postsCount,
                replyCount: replyCount,
                views: views,
                categoryId: categoryId,
                createdAt: createdAt,
                lastPostedAt: lastPostedAt,
                pinned: pinned,
                unpinned: unpinned,
                excerpt: excerpt,
                posters: posters,
                tags: tags,
                unseen: false,
                unreadPosts: max((highestPostNumber ?? postsCount) - highestSeen, 0),
                lastReadPostNumber: max(lastReadPostNumber ?? 0, highestSeen),
                highestPostNumber: highestPostNumber
            )
        }

        /// Force a watermark (used by mark-unread; may lower last_read / raise unread).
        func forcingReadProgress(highestSeen: Int) -> Topic {
            let clamped = max(0, highestSeen)
            let highest = highestPostNumber ?? postsCount
            return Topic(
                id: id,
                fancyTitle: fancyTitle,
                title: title,
                postsCount: postsCount,
                replyCount: replyCount,
                views: views,
                categoryId: categoryId,
                createdAt: createdAt,
                lastPostedAt: lastPostedAt,
                pinned: pinned,
                unpinned: unpinned,
                excerpt: excerpt,
                posters: posters,
                tags: tags,
                unseen: clamped <= 0,
                unreadPosts: max(highest - clamped, 0),
                lastReadPostNumber: clamped > 0 ? clamped : nil,
                highestPostNumber: highestPostNumber
            )
        }

        private init(
            id: Int,
            fancyTitle: String,
            title: String,
            postsCount: Int,
            replyCount: Int,
            views: Int,
            categoryId: Int?,
            createdAt: String,
            lastPostedAt: String?,
            pinned: Bool?,
            unpinned: Bool?,
            excerpt: String?,
            posters: [Poster]?,
            tags: [String]?,
            unseen: Bool,
            unreadPosts: Int,
            lastReadPostNumber: Int?,
            highestPostNumber: Int?
        ) {
            self.id = id
            self.fancyTitle = fancyTitle
            self.title = title
            self.postsCount = postsCount
            self.replyCount = replyCount
            self.views = views
            self.categoryId = categoryId
            self.createdAt = createdAt
            self.lastPostedAt = lastPostedAt
            self.pinned = pinned
            self.unpinned = unpinned
            self.excerpt = excerpt
            self.posters = posters
            self.tags = tags
            self.unseen = unseen
            self.unreadPosts = unreadPosts
            self.lastReadPostNumber = lastReadPostNumber
            self.highestPostNumber = highestPostNumber
        }

        /// Compact list-row payload for related / suggested topics (no unread watermark).
        static func makeRecommendation(
            id: Int,
            title: String,
            fancyTitle: String?,
            postsCount: Int,
            replyCount: Int,
            categoryId: Int?,
            createdAt: String,
            lastPostedAt: String?,
            tags: [String]
        ) -> Topic {
            let fancy = fancyTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Topic(
                id: id,
                fancyTitle: fancy.isEmpty ? title : fancy,
                title: title,
                postsCount: postsCount,
                replyCount: replyCount,
                views: 0,
                categoryId: categoryId,
                createdAt: createdAt,
                lastPostedAt: lastPostedAt,
                pinned: nil,
                unpinned: nil,
                excerpt: nil,
                posters: nil,
                tags: tags,
                unseen: false,
                unreadPosts: 0,
                lastReadPostNumber: nil,
                highestPostNumber: postsCount
            )
        }

        private static func decodeTags(from container: KeyedDecodingContainer<CodingKeys>) -> [String]? {
            if let names = try? container.decodeIfPresent([String].self, forKey: .tags) {
                return names
            }
            if let tagObjects = try? container.decodeIfPresent([TopicTag].self, forKey: .tags) {
                return tagObjects.compactMap(\.displayName)
            }
            return nil
        }

        private struct TopicTag: Decodable {
            let name: String?
            let text: String?
            let id: String?

            enum CodingKeys: String, CodingKey {
                case name, text, id
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decodeIfPresent(String.self, forKey: .name)
                text = try container.decodeIfPresent(String.self, forKey: .text)
                if let stringId = try? container.decodeIfPresent(String.self, forKey: .id) {
                    id = stringId
                } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .id) {
                    id = String(intId)
                } else {
                    id = nil
                }
            }

            var displayName: String? {
                name ?? text ?? id
            }
        }
    }
}
