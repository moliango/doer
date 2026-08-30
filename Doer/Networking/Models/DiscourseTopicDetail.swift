import Foundation

struct DiscoursePostResponse: Decodable {
    let post: DiscourseTopicDetail.Post
}

struct DiscourseTopicDetail: Decodable {
    enum NotificationLevel: Int, CaseIterable {
        case muted = 0
        case regular = 1
        case tracking = 2
        case watching = 3
    }

    let id: Int
    let title: String
    let fancyTitle: String?
    let postsCount: Int
    let replyCount: Int
    let views: Int
    let categoryId: Int?
    let createdAt: String
    let tags: [Tag]
    var postStream: PostStream
    let validReactions: [String]
    let bookmarked: Bool
    let bookmarkId: Int?
    let userBadges: UserBadges?
    var sharedIssueVisible: Bool
    var canCreateSharedIssue: Bool
    var sharedIssueCount: Int
    var userCreatedSharedIssue: Bool
    var notificationLevel: NotificationLevel
    let canEdit: Bool
    /// Server last-read floor; used to resume / jump-to-unread (Phase 1).
    let lastReadPostNumber: Int?
    /// Suggested / related topics shown at the end of a thread (FluxDo parity).
    let suggestedTopics: [SuggestedTopic]
    let relatedTopics: [SuggestedTopic]
    enum CodingKeys: String, CodingKey {
        case id, title, tags, bookmarked, views
        case fancyTitle = "fancy_title"
        case postsCount = "posts_count"
        case replyCount = "reply_count"
        case categoryId = "category_id"
        case createdAt = "created_at"
        case postStream = "post_stream"
        case validReactions = "valid_reactions"
        case bookmarkId = "bookmark_id"
        case userBadges = "user_badges"
        case sharedIssueVisible = "shared_issue_visible"
        case canCreateSharedIssue = "can_create_shared_issue"
        case sharedIssueCount = "shared_issue_count"
        case userCreatedSharedIssue = "user_created_shared_issue"
        case lastReadPostNumber = "last_read_post_number"
        case suggestedTopics = "suggested_topics"
        case relatedTopics = "related_topics"
        case details
    }

    struct SuggestedTopic: Decodable, Equatable {
        struct Poster: Decodable, Equatable {
            let username: String?
            let name: String?
            let avatarTemplate: String?

            enum CodingKeys: String, CodingKey {
                case username, name, user
                case avatarTemplate = "avatar_template"
            }

            private struct UserPayload: Decodable {
                let username: String?
                let name: String?
                let avatarTemplate: String?

                enum CodingKeys: String, CodingKey {
                    case username, name
                    case avatarTemplate = "avatar_template"
                }
            }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let nested = (try? container.decodeIfPresent(UserPayload.self, forKey: .user)) ?? nil
                let outerUsername = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? nil
                let outerName = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? nil
                let outerAvatar = (try? container.decodeIfPresent(String.self, forKey: .avatarTemplate)) ?? nil
                username = outerUsername ?? nested?.username
                name = outerName ?? nested?.name
                avatarTemplate = outerAvatar ?? nested?.avatarTemplate
            }
        }

        let id: Int
        let title: String
        let fancyTitle: String?
        let postsCount: Int?
        let replyCount: Int?
        let createdAt: String?
        let lastPostedAt: String?
        let categoryId: Int?
        let categoryName: String?
        let tags: [String]
        let posters: [Poster]

        enum CodingKeys: String, CodingKey {
            case id, title, tags, posters, category, topic
            case fancyTitle = "fancy_title"
            case postsCount = "posts_count"
            case replyCount = "reply_count"
            case createdAt = "created_at"
            case lastPostedAt = "last_posted_at"
            case categoryId = "category_id"
            case categoryName = "category_name"
            case tagNames = "tag_names"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = (try? container.decode(String.self, forKey: .title)) ?? ""
            fancyTitle = try? container.decodeIfPresent(String.self, forKey: .fancyTitle)
            postsCount = container.decodeLossyInt(forKey: .postsCount)
            replyCount = container.decodeLossyInt(forKey: .replyCount)
            createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
            lastPostedAt = try? container.decodeIfPresent(String.self, forKey: .lastPostedAt)
            let decodedCategoryName = try? container.decodeIfPresent(String.self, forKey: .categoryName)
            let decodedCategory = (try? container.decodeIfPresent(CategoryPayload.self, forKey: .category)) ?? nil
            let nestedTopic = (try? container.decodeIfPresent(TopicPayload.self, forKey: .topic)) ?? nil
            categoryId = container.decodeLossyInt(forKey: .categoryId)
                ?? nestedTopic?.categoryId
                ?? decodedCategory?.id
            categoryName = decodedCategoryName ?? decodedCategory?.name ?? nestedTopic?.categoryName

            let directTags = Self.decodeTagNames(from: container)
            tags = directTags.isEmpty ? (nestedTopic?.tags ?? []) : directTags
            posters = (try? container.decodeIfPresent([Poster].self, forKey: .posters))
                ?? nestedTopic?.posters
                ?? []
        }

        private struct CategoryPayload: Decodable {
            let id: Int?
            let name: String?
        }

        private struct TopicPayload: Decodable {
            let tags: [String]
            let posters: [Poster]
            let categoryName: String?
            let categoryId: Int?

            enum CodingKeys: String, CodingKey {
                case tags, posters, category
                case categoryName = "category_name"
                case tagNames = "tag_names"
                case categoryId = "category_id"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tags = SuggestedTopic.decodeTagNames(from: container)
                posters = (try? container.decodeIfPresent([Poster].self, forKey: .posters)) ?? []
                let category = (try? container.decodeIfPresent(CategoryPayload.self, forKey: .category)) ?? nil
                let directName = try? container.decodeIfPresent(String.self, forKey: .categoryName)
                categoryName = directName ?? category?.name
                categoryId = container.decodeLossyInt(forKey: .categoryId) ?? category?.id
            }
        }

        private static func decodeTagNames<T: CodingKey>(from container: KeyedDecodingContainer<T>) -> [String] {
            if let names = try? container.decodeIfPresent([String].self, forKey: T(stringValue: "tag_names")!),
               !names.isEmpty {
                return names.filter { !$0.isEmpty }
            }
            if let names = try? container.decodeIfPresent([String].self, forKey: T(stringValue: "tags")!),
               !names.isEmpty {
                return names.filter { !$0.isEmpty }
            }
            if let objects = try? container.decodeIfPresent([TopicTag].self, forKey: T(stringValue: "tags")!),
               !objects.isEmpty {
                return objects.compactMap(\.displayName)
            }
            return []
        }

        private struct TopicTag: Decodable {
            let name: String?
            let text: String?
            let id: String?

            enum CodingKeys: String, CodingKey { case name, text, id }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try? container.decodeIfPresent(String.self, forKey: .name)
                text = try? container.decodeIfPresent(String.self, forKey: .text)
                id = (try? container.decodeIfPresent(String.self, forKey: .id))
                    ?? (container.decodeLossyInt(forKey: .id).map(String.init))
            }

            var displayName: String? { name ?? text ?? id }
        }

        var displayTitle: String {
            let fancy = fancyTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fancy.isEmpty ? title : fancy
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        fancyTitle = try? container.decodeIfPresent(String.self, forKey: .fancyTitle)
        postsCount = try container.decode(Int.self, forKey: .postsCount)
        replyCount = try container.decode(Int.self, forKey: .replyCount)
        views = container.decodeLossyInt(forKey: .views) ?? 0
        categoryId = try? container.decodeIfPresent(Int.self, forKey: .categoryId)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        tags = (try? container.decodeIfPresent([Tag].self, forKey: .tags)) ?? []
        postStream = try container.decode(PostStream.self, forKey: .postStream)
        validReactions = (try? container.decodeIfPresent([String].self, forKey: .validReactions)) ?? []
        bookmarked = (try? container.decodeIfPresent(Bool.self, forKey: .bookmarked)) ?? false
        bookmarkId = try? container.decodeIfPresent(Int.self, forKey: .bookmarkId)
        userBadges = try? container.decodeIfPresent(UserBadges.self, forKey: .userBadges)
        sharedIssueVisible = (try? container.decodeIfPresent(Bool.self, forKey: .sharedIssueVisible)) ?? false
        canCreateSharedIssue = (try? container.decodeIfPresent(Bool.self, forKey: .canCreateSharedIssue)) ?? false
        sharedIssueCount = container.decodeLossyInt(forKey: .sharedIssueCount) ?? 0
        userCreatedSharedIssue = (try? container.decodeIfPresent(Bool.self, forKey: .userCreatedSharedIssue)) ?? false
        lastReadPostNumber = container.decodeLossyInt(forKey: .lastReadPostNumber)
        let suggested = (try? container.decodeIfPresent([SuggestedTopic].self, forKey: .suggestedTopics)) ?? []
        let related = (try? container.decodeIfPresent([SuggestedTopic].self, forKey: .relatedTopics)) ?? []
        suggestedTopics = suggested
        relatedTopics = related
        let details = try? container.decodeIfPresent(Details.self, forKey: .details)
        notificationLevel = NotificationLevel(rawValue: details?.notificationLevel ?? 1) ?? .regular
        canEdit = details?.canEdit ?? false
        canAssign = details?.canAssign ?? false
        assignedToUsername = details?.assignedToUser?.username
            ?? details?.assignedToUser?.name
        injectGrantedBadges()
    }

    private struct Details: Decodable {
        let notificationLevel: Int
        let canEdit: Bool
        let canAssign: Bool
        let assignedToUser: AssignedUser?

        struct AssignedUser: Decodable {
            let username: String?
            let name: String?
            let avatarTemplate: String?

            enum CodingKeys: String, CodingKey {
                case username, name
                case avatarTemplate = "avatar_template"
            }
        }

        enum CodingKeys: String, CodingKey {
            case notificationLevel = "notification_level"
            case canEdit = "can_edit"
            case canAssign = "can_assign"
            case assignedToUser = "assigned_to_user"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            notificationLevel = container.decodeLossyInt(forKey: .notificationLevel) ?? 1
            canEdit = (try? container.decodeIfPresent(Bool.self, forKey: .canEdit)) ?? false
            canAssign = (try? container.decodeIfPresent(Bool.self, forKey: .canAssign)) ?? false
            assignedToUser = try? container.decodeIfPresent(AssignedUser.self, forKey: .assignedToUser)
        }
    }

    /// discourse-assign snapshot from topic details.
    private(set) var canAssign: Bool = false
    private(set) var assignedToUsername: String?

    private mutating func injectGrantedBadges() {
        guard let userBadges,
              !userBadges.badgesById.isEmpty,
              !userBadges.badgeIdsByUserId.isEmpty
        else { return }

        for index in postStream.posts.indices {
            guard let userId = postStream.posts[index].userId,
                  let badgeIds = userBadges.badgeIdsByUserId[userId],
                  !badgeIds.isEmpty
            else { continue }

            let injectedBadges = badgeIds.compactMap { userBadges.badgesById[$0] }
            guard !injectedBadges.isEmpty else { continue }
            postStream.posts[index].badgesGranted = injectedBadges
        }
    }

    struct PostStream: Decodable {
        var posts: [Post]
        let stream: [Int]?
    }

    struct Tag: Decodable {
        let id: Int?
        let name: String
        let slug: String

        enum CodingKeys: String, CodingKey {
            case id, name, slug
        }

        init(id: Int? = nil, name: String, slug: String? = nil) {
            self.id = id
            self.name = name
            self.slug = slug?.isEmpty == false ? slug! : name
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let value = try? single.decode(String.self) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                self.init(name: trimmed)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decodedName = (try? container.decodeIfPresent(String.self, forKey: .name))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let decodedSlug = (try? container.decodeIfPresent(String.self, forKey: .slug))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let resolvedName = decodedName.isEmpty ? decodedSlug : decodedName
            self.init(
                id: container.decodeLossyInt(forKey: .id),
                name: resolvedName,
                slug: decodedSlug.isEmpty ? resolvedName : decodedSlug
            )
        }
        /// Discourse `/tag/:name` uses the tag name, not a separate latin slug.
        var routeName: String { name.isEmpty ? slug : name }
    }

    struct ReplyToUser: Decodable {
        let username: String
        let avatarTemplate: String?

        enum CodingKeys: String, CodingKey {
            case username
            case avatarTemplate = "avatar_template"
        }
    }

    struct UserStatus: Decodable {
        let emoji: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case emoji, description
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            emoji = try? container.decodeNonEmptyStringIfPresent(forKey: .emoji)
            description = try? container.decodeNonEmptyStringIfPresent(forKey: .description)
        }
    }

    struct GrantedBadge: Decodable, Hashable {
        let id: Int
        let name: String
        let icon: String?
        let imageUrl: String?
        let slug: String
        let badgeTypeId: Int

        enum CodingKeys: String, CodingKey {
            case badge
            case id, name, icon, slug
            case imageUrl = "image_url"
            case badgeTypeId = "badge_type_id"
        }

        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: CodingKeys.self)
            if let nested = try? root.nestedContainer(keyedBy: CodingKeys.self, forKey: .badge) {
                id = nested.decodeLossyInt(forKey: .id) ?? 0
                name = (try? nested.decodeNonEmptyStringIfPresent(forKey: .name)) ?? ""
                icon = try? nested.decodeNonEmptyStringIfPresent(forKey: .icon)
                imageUrl = try? nested.decodeNonEmptyStringIfPresent(forKey: .imageUrl)
                slug = (try? nested.decodeNonEmptyStringIfPresent(forKey: .slug)) ?? ""
                badgeTypeId = nested.decodeLossyInt(forKey: .badgeTypeId) ?? 0
                return
            }

            id = root.decodeLossyInt(forKey: .id) ?? 0
            name = (try? root.decodeNonEmptyStringIfPresent(forKey: .name)) ?? ""
            icon = try? root.decodeNonEmptyStringIfPresent(forKey: .icon)
            imageUrl = try? root.decodeNonEmptyStringIfPresent(forKey: .imageUrl)
            slug = (try? root.decodeNonEmptyStringIfPresent(forKey: .slug)) ?? ""
            badgeTypeId = root.decodeLossyInt(forKey: .badgeTypeId) ?? 0
        }
    }

    struct UserBadges: Decodable {
        let badgesById: [Int: GrantedBadge]
        let badgeIdsByUserId: [Int: [Int]]

        enum CodingKeys: String, CodingKey {
            case badges, users
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            badgesById = Self.decodeBadges(from: container)
            badgeIdsByUserId = Self.decodeUsers(from: container)
        }

        private static func decodeBadges(from container: KeyedDecodingContainer<CodingKeys>) -> [Int: GrantedBadge] {
            if let map = try? container.decode([String: GrantedBadge].self, forKey: .badges) {
                var result: [Int: GrantedBadge] = [:]
                for (key, badge) in map {
                    guard let id = Int(key) else { continue }
                    result[id] = badge
                }
                return result
            }
            if let list = try? container.decode([GrantedBadge].self, forKey: .badges) {
                var result: [Int: GrantedBadge] = [:]
                for badge in list {
                    result[badge.id] = badge
                }
                return result
            }
            return [:]
        }

        private static func decodeUsers(from container: KeyedDecodingContainer<CodingKeys>) -> [Int: [Int]] {
            if let map = try? container.decode([String: BadgeUser].self, forKey: .users) {
                var result: [Int: [Int]] = [:]
                for (key, user) in map {
                    guard let id = Int(key), !user.badgeIds.isEmpty else { continue }
                    result[id] = user.badgeIds
                }
                return result
            }
            if let list = try? container.decode([BadgeUser].self, forKey: .users) {
                var result: [Int: [Int]] = [:]
                for user in list {
                    guard let id = user.id, !user.badgeIds.isEmpty else { continue }
                    result[id] = user.badgeIds
                }
                return result
            }
            return [:]
        }

        private struct BadgeUser: Decodable {
            let id: Int?
            let badgeIds: [Int]

            enum CodingKeys: String, CodingKey {
                case id
                case badgeIds = "badge_ids"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = container.decodeLossyInt(forKey: .id)
                badgeIds = ((try? container.decodeIfPresent([LossyIntValue].self, forKey: .badgeIds)) ?? [])
                    .compactMap(\.value)
            }
        }
    }

    struct Reaction: Decodable {
        let id: String
        let type: String
        let count: Int

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case type
            case count
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = ((try? container.decodeIfPresent(String.self, forKey: .id))
                ?? (try? container.decodeIfPresent(String.self, forKey: .name))
                ?? "")
            type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "emoji"
            count = container.decodeLossyInt(forKey: .count) ?? 0
        }
    }

    struct LinkCount: Decodable, Hashable {
        let url: String
        let title: String?
        let clicks: Int
        let internalLink: Bool
        let reflection: Bool

        enum CodingKeys: String, CodingKey {
            case url, title, clicks, reflection
            case internalLink = "internal"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
            title = (try? container.decodeIfPresent(String.self, forKey: .title))
                .flatMap { $0.isEmpty ? nil : $0 }
            clicks = container.decodeLossyInt(forKey: .clicks) ?? 0
            internalLink = (try? container.decodeIfPresent(Bool.self, forKey: .internalLink)) ?? false
            reflection = (try? container.decodeIfPresent(Bool.self, forKey: .reflection)) ?? false
        }
    }

    struct BoostUser: Decodable, Hashable {
        let id: Int
        let username: String
        let name: String?
        let avatarTemplate: String?

        enum CodingKeys: String, CodingKey {
            case id, username, name
            case avatarTemplate = "avatar_template"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.decodeLossyInt(forKey: .id) ?? 0
            username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
            name = (try? container.decodeIfPresent(String.self, forKey: .name))
                .flatMap { $0.isEmpty ? nil : $0 }
            avatarTemplate = (try? container.decodeIfPresent(String.self, forKey: .avatarTemplate))
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        init(id: Int, username: String, name: String?, avatarTemplate: String?) {
            self.id = id
            self.username = username
            self.name = name
            self.avatarTemplate = avatarTemplate
        }
    }

    struct Boost: Decodable, Identifiable, Hashable {
        let id: Int
        let cooked: String
        let user: BoostUser
        let canDelete: Bool
        let canFlag: Bool
        let userFlagStatus: Int?
        let availableFlags: [String]?

        enum CodingKeys: String, CodingKey {
            case id, cooked, user
            case canDelete = "can_delete"
            case canFlag = "can_flag"
            case userFlagStatus = "user_flag_status"
            case availableFlags = "available_flags"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.decodeLossyInt(forKey: .id) ?? 0
            cooked = (try? container.decodeIfPresent(String.self, forKey: .cooked)) ?? ""
            user = (try? container.decodeIfPresent(BoostUser.self, forKey: .user))
                ?? BoostUser(id: 0, username: "", name: nil, avatarTemplate: nil)
            canDelete = (try? container.decodeIfPresent(Bool.self, forKey: .canDelete)) ?? false
            canFlag = (try? container.decodeIfPresent(Bool.self, forKey: .canFlag)) ?? false
            userFlagStatus = container.decodeLossyInt(forKey: .userFlagStatus)
            availableFlags = try? container.decodeIfPresent([String].self, forKey: .availableFlags)
        }

        init(
            id: Int,
            cooked: String,
            user: BoostUser,
            canDelete: Bool,
            canFlag: Bool,
            userFlagStatus: Int? = nil,
            availableFlags: [String]? = nil
        ) {
            self.id = id
            self.cooked = cooked
            self.user = user
            self.canDelete = canDelete
            self.canFlag = canFlag
            self.userFlagStatus = userFlagStatus
            self.availableFlags = availableFlags
        }

        func replacingActionState(
            canDelete: Bool? = nil,
            canFlag: Bool? = nil,
            userFlagStatus: Int? = nil,
            availableFlags: [String]? = nil
        ) -> Boost {
            Boost(
                id: id,
                cooked: cooked,
                user: user,
                canDelete: canDelete ?? self.canDelete,
                canFlag: canFlag ?? self.canFlag,
                userFlagStatus: userFlagStatus ?? self.userFlagStatus,
                availableFlags: availableFlags ?? self.availableFlags
            )
        }
    }

    struct Post: Decodable, Identifiable {
        let id: Int
        let name: String?
        let username: String
        let avatarTemplate: String?
        let createdAt: String
        var cooked: String
        let raw: String?
        let canEdit: Bool
        let yours: Bool
        let postNumber: Int
        let replyCount: Int
        let replyToPostNumber: Int?
        let replyToUser: ReplyToUser?
        let actionCode: String?
        let userTitle: String?
        let flairUrl: String?
        let flairBgColor: String?
        let flairColor: String?
        let flairName: String?
        let primaryGroupName: String?
        let userId: Int?
        let userStatus: UserStatus?
        var badgesGranted: [GrantedBadge]
        let moderator: Bool
        let admin: Bool
        let groupModerator: Bool
        var bookmarked: Bool
        var bookmarkId: Int?
        var reactions: [Reaction]
        var reactionUsersCount: Int
        var currentUserReaction: Reaction?
        var currentUserUsedMainReaction: Bool
        let linkCounts: [LinkCount]
        let polls: [DiscoursePollVoteResponse.Poll]
        let pollsVotes: [String: [String]]
        var boosts: [Boost]
        var canBoost: Bool
        let whisper: Bool
        let version: Int
        let userSignature: String?
        let wiki: Bool
        /// discourse-post-voting plugin fields (Q&A topics).
        var postVotingVoteCount: Int
        var postVotingUserVotedDirection: String?
        let postVotingHasVotes: Bool
        /// discourse-solved plugin: this post is the accepted answer.
        let acceptedAnswer: Bool
        let canAcceptAnswer: Bool
        let canUnacceptAnswer: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, username, cooked, raw, yours
            case canEdit = "can_edit"
            case avatarTemplate = "avatar_template"
            case createdAt = "created_at"
            case postNumber = "post_number"
            case replyCount = "reply_count"
            case replyToPostNumber = "reply_to_post_number"
            case replyToUser = "reply_to_user"
            case actionCode = "action_code"
            case userTitle = "user_title"
            case flairUrl = "flair_url"
            case flairBgColor = "flair_bg_color"
            case flairColor = "flair_color"
            case flairName = "flair_name"
            case primaryGroupName = "primary_group_name"
            case userId = "user_id"
            case userStatus = "user_status"
            case badgesGranted = "badges_granted"
            case moderator, admin
            case groupModerator = "group_moderator"
            case bookmarked
            case bookmarkId = "bookmark_id"
            case reactions
            case reactionUsersCount = "reaction_users_count"
            case currentUserReaction = "current_user_reaction"
            case currentUserUsedMainReaction = "current_user_used_main_reaction"
            case linkCounts = "link_counts"
            case polls
            case pollsVotes = "polls_votes"
            case boosts
            case canBoost = "can_boost"
            case whisper
            case version
            case userSignature = "user_signature"
            case wiki
            case postVotingVoteCount = "post_voting_vote_count"
            case postVotingUserVotedDirection = "post_voting_user_voted_direction"
            case postVotingHasVotes = "post_voting_has_votes"
            case acceptedAnswer = "accepted_answer"
            case canAcceptAnswer = "can_accept_answer"
            case canUnacceptAnswer = "can_unaccept_answer"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            username = try container.decode(String.self, forKey: .username)
            name = (try? container.decodeIfPresent(String.self, forKey: .name))
                .flatMap { $0.isEmpty ? nil : $0 } ?? username
            avatarTemplate = try container.decodeIfPresent(String.self, forKey: .avatarTemplate)
            createdAt = try container.decode(String.self, forKey: .createdAt)
            cooked = try container.decode(String.self, forKey: .cooked)
            raw = try? container.decodeIfPresent(String.self, forKey: .raw)
            canEdit = (try? container.decodeIfPresent(Bool.self, forKey: .canEdit)) ?? false
            yours = (try? container.decodeIfPresent(Bool.self, forKey: .yours)) ?? false
            postNumber = try container.decode(Int.self, forKey: .postNumber)
            replyCount = try container.decode(Int.self, forKey: .replyCount)
            replyToPostNumber = try? container.decodeIfPresent(Int.self, forKey: .replyToPostNumber)
            replyToUser = try? container.decodeIfPresent(ReplyToUser.self, forKey: .replyToUser)
            actionCode = try? container.decodeIfPresent(String.self, forKey: .actionCode)
            userTitle = try? container.decodeNonEmptyStringIfPresent(forKey: .userTitle)
            flairUrl = try? container.decodeNonEmptyStringIfPresent(forKey: .flairUrl)
            flairBgColor = try? container.decodeNonEmptyStringIfPresent(forKey: .flairBgColor)
            flairColor = try? container.decodeNonEmptyStringIfPresent(forKey: .flairColor)
            flairName = try? container.decodeNonEmptyStringIfPresent(forKey: .flairName)
            primaryGroupName = try? container.decodeNonEmptyStringIfPresent(forKey: .primaryGroupName)
            userId = container.decodeLossyInt(forKey: .userId)
            userStatus = try? container.decodeIfPresent(UserStatus.self, forKey: .userStatus)
            badgesGranted = (try? container.decodeIfPresent([GrantedBadge].self, forKey: .badgesGranted)) ?? []
            moderator = (try? container.decodeIfPresent(Bool.self, forKey: .moderator)) ?? false
            admin = (try? container.decodeIfPresent(Bool.self, forKey: .admin)) ?? false
            groupModerator = (try? container.decodeIfPresent(Bool.self, forKey: .groupModerator)) ?? false
            bookmarked = (try? container.decodeIfPresent(Bool.self, forKey: .bookmarked)) ?? false
            bookmarkId = try? container.decodeIfPresent(Int.self, forKey: .bookmarkId)
            reactions = (try? container.decodeIfPresent([Reaction].self, forKey: .reactions)) ?? []
            reactionUsersCount = (try? container.decodeIfPresent(Int.self, forKey: .reactionUsersCount)) ?? 0
            currentUserReaction = try? container.decodeIfPresent(Reaction.self, forKey: .currentUserReaction)
            currentUserUsedMainReaction = (try? container.decodeIfPresent(Bool.self, forKey: .currentUserUsedMainReaction)) ?? false
            linkCounts = (try? container.decodeIfPresent([LinkCount].self, forKey: .linkCounts)) ?? []
            polls = (try? container.decodeIfPresent([DiscoursePollVoteResponse.Poll].self, forKey: .polls)) ?? []
            pollsVotes = (try? container.decodeIfPresent(LossyPollVotesValue.self, forKey: .pollsVotes)?.value) ?? [:]
            boosts = (try? container.decodeIfPresent([Boost].self, forKey: .boosts)) ?? []
            canBoost = (try? container.decodeIfPresent(Bool.self, forKey: .canBoost)) ?? false
            whisper = (try? container.decodeIfPresent(Bool.self, forKey: .whisper)) ?? false
            version = container.decodeLossyInt(forKey: .version) ?? 1
            userSignature = try? container.decodeNonEmptyStringIfPresent(forKey: .userSignature)
            wiki = (try? container.decodeIfPresent(Bool.self, forKey: .wiki)) ?? false
            postVotingVoteCount = container.decodeLossyInt(forKey: .postVotingVoteCount) ?? 0
            postVotingUserVotedDirection = try? container.decodeNonEmptyStringIfPresent(forKey: .postVotingUserVotedDirection)
            postVotingHasVotes = (try? container.decodeIfPresent(Bool.self, forKey: .postVotingHasVotes))
                ?? (postVotingVoteCount != 0 || postVotingUserVotedDirection != nil)
            acceptedAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .acceptedAnswer)) ?? false
            canAcceptAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .canAcceptAnswer)) ?? false
            canUnacceptAnswer = (try? container.decodeIfPresent(Bool.self, forKey: .canUnacceptAnswer)) ?? false
        }

        var showEditsIndicator: Bool { version > 1 || wiki }
        var editsCount: Int { version > 1 ? version - 1 : 0 }
        var isPostVotingAnswer: Bool { postVotingHasVotes || postVotingVoteCount != 0 || postNumber > 1 }
    }
}

extension KeyedDecodingContainer {
    func decodeNonEmptyStringIfPresent(forKey key: Key) throws -> String? {
        let value = try decodeIfPresent(String.self, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct DiscourseTopicPostsResponse: Decodable {
    var postStream: PostStreamPosts
    let userBadges: DiscourseTopicDetail.UserBadges?

    enum CodingKeys: String, CodingKey {
        case postStream = "post_stream"
        case userBadges = "user_badges"
    }

    struct PostStreamPosts: Decodable {
        var posts: [DiscourseTopicDetail.Post]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        postStream = try container.decode(PostStreamPosts.self, forKey: .postStream)
        userBadges = try? container.decodeIfPresent(DiscourseTopicDetail.UserBadges.self, forKey: .userBadges)
        injectGrantedBadges()
    }

    private mutating func injectGrantedBadges() {
        guard let userBadges,
              !userBadges.badgesById.isEmpty,
              !userBadges.badgeIdsByUserId.isEmpty
        else { return }

        for index in postStream.posts.indices {
            guard let userId = postStream.posts[index].userId,
                  let badgeIds = userBadges.badgeIdsByUserId[userId],
                  !badgeIds.isEmpty
            else { continue }

            let injectedBadges = badgeIds.compactMap { userBadges.badgesById[$0] }
            guard !injectedBadges.isEmpty else { continue }
            postStream.posts[index].badgesGranted = injectedBadges
        }
    }
}

struct DiscoursePollVoteResponse: Decodable {
    struct Poll: Decodable {
        let name: String?
        let status: String?
        let type: String?
        let votersCount: Int?
        let minSelections: Int?
        let maxSelections: Int?
        let resultsMode: String?
        let isPublic: Bool?
        let options: [Option]

        var hasResultPayload: Bool {
            votersCount != nil || !options.isEmpty
        }

        init(
            name: String?,
            status: String?,
            type: String?,
            votersCount: Int?,
            minSelections: Int?,
            maxSelections: Int?,
            resultsMode: String?,
            isPublic: Bool?,
            options: [Option]
        ) {
            self.name = name
            self.status = status
            self.type = type
            self.votersCount = votersCount
            self.minSelections = minSelections
            self.maxSelections = maxSelections
            self.resultsMode = resultsMode
            self.isPublic = isPublic
            self.options = options
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
            name = container.decodeLossyString(forKeys: ["name", "poll_name", "pollName"])
            status = container.decodeLossyString(forKeys: ["status", "poll_status", "pollStatus"])
            type = container.decodeLossyString(forKeys: ["type", "poll_type", "pollType"])
            votersCount = container.decodeLossyInt(forKeys: [
                "voters",
                "voters_count",
                "votersCount",
                "voter_count",
                "voterCount",
                "total",
                "total_votes",
                "totalVotes",
                "total_voters",
                "totalVoters",
                "votes"
            ])
            minSelections = container.decodeLossyInt(forKeys: ["min", "poll_min", "minSelections", "min_selections"])
            maxSelections = container.decodeLossyInt(forKeys: ["max", "poll_max", "maxSelections", "max_selections"])
            resultsMode = container.decodeLossyString(forKeys: ["results", "poll_results", "resultsMode", "results_mode"])
            isPublic = container.decodeLossyBool(forKeys: ["public", "isPublic", "is_public", "poll_public"])
            options = Self.decodeOptions(from: container)
        }

        func named(_ fallbackName: String) -> Poll {
            Poll(
                name: name ?? fallbackName,
                status: status,
                type: type,
                votersCount: votersCount,
                minSelections: minSelections,
                maxSelections: maxSelections,
                resultsMode: resultsMode,
                isPublic: isPublic,
                options: options
            )
        }

        private static func decodeOptions(from container: KeyedDecodingContainer<FlexibleCodingKey>) -> [Option] {
            for keyName in [
                "options",
                "choices",
                "poll_options",
                "pollOptions",
                "option_votes",
                "optionVotes",
                "vote_counts",
                "voteCounts",
                "votes"
            ] {
                let key = FlexibleCodingKey(stringValue: keyName)
                if let options = try? container.decode([Option].self, forKey: key) {
                    return options.filter(\.hasResultPayload)
                }
                if let options = try? container.decode([String: Option].self, forKey: key) {
                    return options.map { optionId, option in
                        option.identified(by: optionId)
                    }
                    .filter(\.hasResultPayload)
                    .sorted { ($0.id ?? "") < ($1.id ?? "") }
                }
                if let votes = try? container.decode([String: LossyIntValue].self, forKey: key) {
                    return votes.map { optionId, value in
                        Option(
                            id: optionId,
                            text: nil,
                            voteCount: value.value,
                            percentageText: nil,
                            isSelected: nil
                        )
                    }
                    .filter(\.hasResultPayload)
                    .sorted { ($0.id ?? "") < ($1.id ?? "") }
                }
            }
            return []
        }
    }

    struct Option: Decodable {
        let id: String?
        let text: String?
        let voteCount: Int?
        let percentageText: String?
        let isSelected: Bool?

        var hasResultPayload: Bool {
            id != nil || voteCount != nil || percentageText != nil || isSelected != nil
        }

        init(
            id: String?,
            text: String?,
            voteCount: Int?,
            percentageText: String?,
            isSelected: Bool?
        ) {
            self.id = id
            self.text = text
            self.voteCount = voteCount
            self.percentageText = percentageText
            self.isSelected = isSelected
        }

        init(from decoder: Decoder) throws {
            if let intValue = try? LossyIntValue(from: decoder), let value = intValue.value {
                id = nil
                text = nil
                voteCount = value
                percentageText = nil
                isSelected = nil
                return
            }

            let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
            id = container.decodeLossyString(forKeys: ["id", "option_id", "optionId", "poll_option_id", "pollOptionId"])
            text = container.decodeLossyString(forKeys: ["html", "text", "title", "label", "name"])
            voteCount = container.decodeLossyInt(forKeys: ["votes", "vote_count", "voteCount", "count", "voters"])
            isSelected = container.decodeLossyBool(forKeys: ["selected", "isSelected", "is_selected", "chosen", "voted"])

            if let text = container.decodeLossyString(forKeys: ["percentage", "percent", "percentText", "percentageText", "percentage_text", "percent_text"]) {
                percentageText = Self.normalizedPercentageText(text)
            } else if let value = container.decodeLossyDouble(forKeys: ["percentage", "percent", "percentText", "percentageText", "percentage_text", "percent_text"]) {
                percentageText = Self.percentageText(from: value)
            } else {
                percentageText = nil
            }
        }

        func identified(by fallbackId: String) -> Option {
            Option(
                id: id ?? fallbackId,
                text: text,
                voteCount: voteCount,
                percentageText: percentageText,
                isSelected: isSelected
            )
        }

        private static func normalizedPercentageText(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("%") {
                return trimmed
            }
            guard let value = Double(trimmed) else {
                return trimmed
            }
            return percentageText(from: value)
        }

        private static func percentageText(from value: Double) -> String {
            let percent = value > 0 && value < 1 ? value * 100 : value
            let rounded = (percent * 10).rounded() / 10
            if rounded.rounded() == rounded {
                return "\(Int(rounded))%"
            }
            return "\(rounded)%"
        }
    }

    let polls: [Poll]
    private static let pollEnvelopeKeys = ["poll", "polls", "result", "results", "data", "poll_result", "pollResult"]

    init(polls: [Poll] = []) {
        self.polls = polls
    }

    init(from decoder: Decoder) throws {
        var decodedPolls: [Poll] = []

        if let container = try? decoder.container(keyedBy: FlexibleCodingKey.self) {
            for key in Self.pollEnvelopeKeys {
                decodedPolls.append(contentsOf: Self.decodePolls(from: container, forKey: key))
            }
        }

        if let rootPoll = try? Poll(from: decoder), rootPoll.hasResultPayload {
            decodedPolls.append(rootPoll)
        }

        var seenNames: Set<String> = []
        polls = decodedPolls.filter { poll in
            guard poll.hasResultPayload else { return false }
            guard let name = poll.name, !name.isEmpty else { return true }
            return seenNames.insert(name).inserted
        }
    }

    func poll(named name: String?) -> Poll? {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedName, !normalizedName.isEmpty,
           let match = polls.first(where: { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName }) {
            return match
        }
        return polls.count == 1 ? polls[0] : nil
    }

    private static func decodePolls(from container: KeyedDecodingContainer<FlexibleCodingKey>, forKey keyName: String) -> [Poll] {
        let key = FlexibleCodingKey(stringValue: keyName)
        if let poll = try? container.decode(Poll.self, forKey: key), poll.hasResultPayload {
            return [poll]
        }
        if let polls = try? container.decode([Poll].self, forKey: key) {
            return polls.filter(\.hasResultPayload)
        }
        if let polls = try? container.decode([String: Poll].self, forKey: key) {
            return polls.map { name, poll in
                poll.named(name)
            }
            .filter(\.hasResultPayload)
        }
        if let nestedContainer = try? container.nestedContainer(keyedBy: FlexibleCodingKey.self, forKey: key) {
            var polls: [Poll] = []
            for nestedKey in pollEnvelopeKeys where nestedKey != keyName {
                polls.append(contentsOf: decodePolls(from: nestedContainer, forKey: nestedKey))
            }
            return polls
        }
        return []
    }
}

private struct FlexibleCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init(intValue: Int) {
        stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private struct LossyIntValue: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = Int(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            value = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
    }
}

private struct LossyStringValue: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringValue = try? container.decode(String.self) {
            let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            value = trimmed.isEmpty ? nil : trimmed
        } else if let intValue = try? container.decode(Int.self) {
            value = "\(intValue)"
        } else if let doubleValue = try? container.decode(Double.self) {
            value = "\(doubleValue)"
        } else {
            value = nil
        }
    }
}

private struct LossyPollVotesValue: Decodable {
    let value: [String: [String]]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        var votes: [String: [String]] = [:]
        for key in container.allKeys {
            if let values = try? container.decode([LossyStringValue].self, forKey: key) {
                let optionIds = values.compactMap(\.value)
                if !optionIds.isEmpty {
                    votes[key.stringValue] = optionIds
                }
            } else if let value = try? container.decode(LossyStringValue.self, forKey: key),
                      let optionId = value.value {
                votes[key.stringValue] = [optionId]
            }
        }
        value = votes
    }
}

private extension KeyedDecodingContainer where Key == FlexibleCodingKey {
    func decodeLossyString(forKeys keys: [String]) -> String? {
        for key in keys {
            let codingKey = FlexibleCodingKey(stringValue: key)
            if let value = try? decodeIfPresent(String.self, forKey: codingKey) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = try? decodeIfPresent(Int.self, forKey: codingKey) {
                return "\(value)"
            }
            if let value = try? decodeIfPresent(Double.self, forKey: codingKey) {
                return "\(value)"
            }
        }
        return nil
    }

    func decodeLossyInt(forKeys keys: [String]) -> Int? {
        for key in keys {
            let codingKey = FlexibleCodingKey(stringValue: key)
            if let value = try? decodeIfPresent(Int.self, forKey: codingKey) {
                return value
            }
            if let value = try? decodeIfPresent(Double.self, forKey: codingKey) {
                return Int(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: codingKey),
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }
        return nil
    }

    func decodeLossyDouble(forKeys keys: [String]) -> Double? {
        for key in keys {
            let codingKey = FlexibleCodingKey(stringValue: key)
            if let value = try? decodeIfPresent(Double.self, forKey: codingKey) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: codingKey) {
                return Double(value)
            }
            if let value = try? decodeIfPresent(String.self, forKey: codingKey),
               let doubleValue = Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")) {
                return doubleValue
            }
        }
        return nil
    }

    func decodeLossyBool(forKeys keys: [String]) -> Bool? {
        for key in keys {
            let codingKey = FlexibleCodingKey(stringValue: key)
            if let value = try? decodeIfPresent(Bool.self, forKey: codingKey) {
                return value
            }
            if let value = try? decodeIfPresent(Int.self, forKey: codingKey) {
                return value != 0
            }
            if let value = try? decodeIfPresent(String.self, forKey: codingKey) {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["true", "1", "yes", "y"].contains(normalized) {
                    return true
                }
                if ["false", "0", "no", "n"].contains(normalized) {
                    return false
                }
            }
        }
        return nil
    }
}
