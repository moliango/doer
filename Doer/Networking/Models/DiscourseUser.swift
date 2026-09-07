import Foundation
import UIKit

struct DiscourseCurrentUserResponse: Decodable {
    let currentUser: DiscourseCurrentUser?

    enum CodingKeys: String, CodingKey {
        case currentUser = "current_user"
    }
}

struct DiscourseCurrentUser: Codable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let unreadNotifications: Int?
    let unreadHighPriorityNotifications: Int?
    let allUnreadNotificationsCount: Int?
    let seenNotificationId: Int?
    let notificationChannelPosition: Int?

    var effectiveUnreadNotificationCount: Int {
        if let allUnreadNotificationsCount {
            return max(allUnreadNotificationsCount, 0)
        }
        return max((unreadNotifications ?? 0) + (unreadHighPriorityNotifications ?? 0), 0)
    }

    var hasOfficialUnreadNotificationCount: Bool {
        allUnreadNotificationsCount != nil
            || unreadNotifications != nil
            || unreadHighPriorityNotifications != nil
    }

    init(
        id: Int,
        username: String,
        name: String?,
        avatarTemplate: String?,
        unreadNotifications: Int? = nil,
        unreadHighPriorityNotifications: Int? = nil,
        allUnreadNotificationsCount: Int? = nil,
        seenNotificationId: Int? = nil,
        notificationChannelPosition: Int? = nil
    ) {
        self.id = id
        self.username = username
        self.name = name
        self.avatarTemplate = avatarTemplate
        self.unreadNotifications = unreadNotifications
        self.unreadHighPriorityNotifications = unreadHighPriorityNotifications
        self.allUnreadNotificationsCount = allUnreadNotificationsCount
        self.seenNotificationId = seenNotificationId
        self.notificationChannelPosition = notificationChannelPosition
    }

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case avatarTemplate = "avatar_template"
        case unreadNotifications = "unread_notifications"
        case unreadHighPriorityNotifications = "unread_high_priority_notifications"
        case allUnreadNotificationsCount = "all_unread_notifications_count"
        case seenNotificationId = "seen_notification_id"
        case notificationChannelPosition = "notification_channel_position"
    }
}

struct DiscourseUserProfileResponse: Decodable {
    let user: DiscourseUserProfile
}

struct DiscourseUserProfile: Codable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let title: String?
    let trustLevel: Int?
    let badgeCount: Int?
    let profileViewCount: Int?
    let timeRead: Int?
    let createdAt: String?
    let lastPostedAt: String?
    let bioExcerpt: String?
    let bioCooked: String?
    let bioRaw: String?
    let location: String?
    let website: String?
    let websiteName: String?
    let profileBackgroundURL: String?
    let cardBackgroundURL: String?
    let followingCount: Int?
    let followerCount: Int?
    let gamificationScore: Int?
    let flairName: String?
    let flairUrl: String?
    let flairBackgroundColor: String?
    let flairColor: String?
    let lastSeenAt: String?
    let recentTimeRead: Int?
    let topicPostCount: Int?
    let canFollow: Bool?
    let isFollowed: Bool?
    let canSendPrivateMessages: Bool?
    let canSendPrivateMessageToUser: Bool?
    let muted: Bool?
    let ignored: Bool?
    let canMuteUser: Bool?
    let canIgnoreUser: Bool?
    let suspendReason: String?
    let suspendedTill: String?
    let silenceReason: String?
    let silencedTill: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name, title
        case avatarTemplate = "avatar_template"
        case trustLevel = "trust_level"
        case badgeCount = "badge_count"
        case profileViewCount = "profile_view_count"
        case timeRead = "time_read"
        case createdAt = "created_at"
        case lastPostedAt = "last_posted_at"
        case bioExcerpt = "bio_excerpt"
        case bioCooked = "bio_cooked"
        case bioRaw = "bio_raw"
        case location
        case website
        case websiteName = "website_name"
        case profileBackgroundURL = "profile_background_upload_url"
        case cardBackgroundURL = "card_background_upload_url"
        case followingCount = "total_following"
        case followerCount = "total_followers"
        case gamificationScore = "gamification_score"
        case flairName = "flair_name"
        case flairUrl = "flair_url"
        case flairBackgroundColor = "flair_bg_color"
        case flairColor = "flair_color"
        case lastSeenAt = "last_seen_at"
        case recentTimeRead = "recent_time_read"
        case topicPostCount = "topic_post_count"
        case canFollow = "can_follow"
        case isFollowed = "is_followed"
        case canSendPrivateMessages = "can_send_private_messages"
        case canSendPrivateMessageToUser = "can_send_private_message_to_user"
        case muted, ignored
        case canMuteUser = "can_mute_user"
        case canIgnoreUser = "can_ignore_user"
        case suspendReason = "suspend_reason"
        case suspendedTill = "suspended_till"
        case silenceReason = "silence_reason"
        case silencedTill = "silenced_till"
    }
}

struct DiscourseUserBadgesResponse: Decodable {
    let userBadges: [DiscourseUserBadge]

    enum CodingKeys: String, CodingKey {
        case badges
        case userBadges = "user_badges"
        case topics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let badges = try container.decodeIfPresent([DiscourseBadge].self, forKey: .badges) ?? []
        let badgeMap = Dictionary(uniqueKeysWithValues: badges.map { ($0.id, $0) })

        let topics = try container.decodeIfPresent([BadgeTopic].self, forKey: .topics) ?? []
        let topicMap = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.title) })

        let rawBadges = try container.decodeIfPresent([RawUserBadge].self, forKey: .userBadges) ?? []
        userBadges = rawBadges.map { raw in
            DiscourseUserBadge(
                id: raw.id,
                badgeId: raw.badgeId,
                userId: 0,
                grantedAt: raw.grantedAt,
                topicId: raw.topicId,
                topicTitle: raw.topicTitle ?? raw.topicId.flatMap { topicMap[$0] },
                postNumber: nil,
                count: raw.count,
                badge: raw.badge ?? badgeMap[raw.badgeId]
            )
        }
    }

    private struct BadgeTopic: Decodable {
        let id: Int
        let title: String
    }

    private struct RawUserBadge: Decodable {
        let id: Int
        let badgeId: Int
        let grantedAt: String?
        let topicId: Int?
        let topicTitle: String?
        let count: Int
        let badge: DiscourseBadge?

        enum CodingKeys: String, CodingKey {
            case id
            case badgeId = "badge_id"
            case grantedAt = "granted_at"
            case topicId = "topic_id"
            case topicTitle = "topic_title"
            case count
            case badge
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(Int.self, forKey: .id)) ?? 0
            badgeId = (try? container.decode(Int.self, forKey: .badgeId)) ?? 0
            grantedAt = try container.decodeIfPresent(String.self, forKey: .grantedAt)
            topicId = try container.decodeIfPresent(Int.self, forKey: .topicId)
            topicTitle = try container.decodeIfPresent(String.self, forKey: .topicTitle)
            count = (try? container.decode(Int.self, forKey: .count)) ?? 1
            badge = try container.decodeIfPresent(DiscourseBadge.self, forKey: .badge)
        }
    }
}

struct DiscourseBadge: Codable, Hashable {
    let id: Int
    let name: String
    let description: String?
    let badgeTypeId: Int
    let imageURL: String?
    let icon: String?
    let slug: String?
    let grantCount: Int
    let longDescription: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, slug
        case badgeTypeId = "badge_type_id"
        case imageURL = "image_url"
        case grantCount = "grant_count"
        case longDescription = "long_description"
    }

    init(
        id: Int,
        name: String,
        description: String? = nil,
        badgeTypeId: Int,
        imageURL: String? = nil,
        icon: String? = nil,
        slug: String? = nil,
        grantCount: Int = 0,
        longDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.badgeTypeId = badgeTypeId
        self.imageURL = imageURL
        self.icon = icon
        self.slug = slug
        self.grantCount = grantCount
        self.longDescription = longDescription
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(Int.self, forKey: .id)) ?? 0
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        badgeTypeId = (try? container.decode(Int.self, forKey: .badgeTypeId)) ?? 3
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        grantCount = (try? container.decode(Int.self, forKey: .grantCount)) ?? 0
        longDescription = try container.decodeIfPresent(String.self, forKey: .longDescription)
    }

    var type: BadgeType {
        BadgeType(rawValue: badgeTypeId) ?? .bronze
    }


    enum BadgeType: Int, Hashable {
        case gold = 1
        case silver = 2
        case bronze = 3

        var title: String {
            switch self {
            case .gold: return String(localized: "badges.gold")
            case .silver: return String(localized: "badges.silver")
            case .bronze: return String(localized: "badges.bronze")
            }
        }

        /// FluxDo-style premium medal chrome (light / dark).
        var color: UIColor {
            switch self {
            case .gold:
                return UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 1.0, green: 0.843, blue: 0.0, alpha: 1) // #FFD700
                        : UIColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 1) // #F59E0B
                }
            case .silver:
                return UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1) // #E0E0E0
                        : UIColor(red: 0.471, green: 0.565, blue: 0.612, alpha: 1) // #78909C
                }
            case .bronze:
                return UIColor { traits in
                    traits.userInterfaceStyle == .dark
                        ? UIColor(red: 1.0, green: 0.671, blue: 0.569, alpha: 1) // #FFAB91
                        : UIColor(red: 0.631, green: 0.533, blue: 0.498, alpha: 1) // #A1887F
                }
            }
        }
    }
}

struct DiscourseUserBadge: Identifiable, Hashable {
    let id: Int
    let badgeId: Int
    let userId: Int
    let grantedAt: String?
    let topicId: Int?
    let topicTitle: String?
    let postNumber: Int?
    let count: Int
    let badge: DiscourseBadge?
}

struct DiscourseBadgeUser: Decodable, Hashable, Identifiable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let admin: Bool?
    let moderator: Bool?

    enum CodingKeys: String, CodingKey {
        case id, username, name, admin, moderator
        case avatarTemplate = "avatar_template"
    }
}

struct DiscourseBadgeDetailResponse: Decodable {
    let badge: DiscourseBadge
    let userBadges: [DiscourseUserBadge]
    let users: [DiscourseBadgeUser]
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case badge
        case badges
        case users
        case topics
        case userBadges = "user_badges"
        case userBadgeInfo = "user_badge_info"
    }

    private struct UserBadgeInfo: Decodable {
        let userBadges: [RawGrant]?
        let grantCount: Int?

        enum CodingKeys: String, CodingKey {
            case userBadges = "user_badges"
            case grantCount = "grant_count"
        }
    }

    private struct RawGrant: Decodable {
        let id: Int
        let badgeId: Int
        let userId: Int
        let grantedAt: String?
        let topicId: Int?
        let topicTitle: String?
        let postNumber: Int?
        let count: Int
        let badge: DiscourseBadge?

        enum CodingKeys: String, CodingKey {
            case id
            case badgeId = "badge_id"
            case userId = "user_id"
            case grantedAt = "granted_at"
            case topicId = "topic_id"
            case topicTitle = "topic_title"
            case postNumber = "post_number"
            case count
            case badge
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? container.decode(Int.self, forKey: .id)) ?? 0
            badgeId = (try? container.decode(Int.self, forKey: .badgeId)) ?? 0
            userId = (try? container.decode(Int.self, forKey: .userId)) ?? 0
            grantedAt = try container.decodeIfPresent(String.self, forKey: .grantedAt)
            topicId = try container.decodeIfPresent(Int.self, forKey: .topicId)
            topicTitle = try container.decodeIfPresent(String.self, forKey: .topicTitle)
            postNumber = try container.decodeIfPresent(Int.self, forKey: .postNumber)
            count = (try? container.decode(Int.self, forKey: .count)) ?? 1
            badge = try container.decodeIfPresent(DiscourseBadge.self, forKey: .badge)
        }
    }

    private struct TopicStub: Decodable {
        let id: Int
        let title: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let badges = (try? container.decode([DiscourseBadge].self, forKey: .badges)) ?? []
        let badgeMap = Dictionary(uniqueKeysWithValues: badges.map { ($0.id, $0) })
        users = (try? container.decode([DiscourseBadgeUser].self, forKey: .users)) ?? []

        let topics = (try? container.decode([TopicStub].self, forKey: .topics)) ?? []
        let topicMap = Dictionary(uniqueKeysWithValues: topics.map { ($0.id, $0.title) })

        let rawGrants: [RawGrant]
        let infoCount: Int?
        if let info = try? container.decode(UserBadgeInfo.self, forKey: .userBadgeInfo) {
            rawGrants = info.userBadges ?? []
            infoCount = info.grantCount
        } else {
            rawGrants = (try? container.decode([RawGrant].self, forKey: .userBadges)) ?? []
            infoCount = nil
        }

        userBadges = rawGrants.map { raw in
            DiscourseUserBadge(
                id: raw.id,
                badgeId: raw.badgeId,
                userId: raw.userId,
                grantedAt: raw.grantedAt,
                topicId: raw.topicId,
                topicTitle: raw.topicTitle ?? raw.topicId.flatMap { topicMap[$0] },
                postNumber: raw.postNumber,
                count: raw.count,
                badge: raw.badge ?? badgeMap[raw.badgeId]
            )
        }

        if let decoded = try? container.decode(DiscourseBadge.self, forKey: .badge) {
            badge = decoded
        } else if let first = userBadges.first?.badge {
            badge = first
        } else if let first = badges.first {
            badge = first
        } else {
            badge = DiscourseBadge(id: 0, name: String(localized: "badges.unknown"), badgeTypeId: 3)
        }

        totalCount = infoCount ?? badge.grantCount
    }
}

struct DiscoursePendingInvitesResponse: Decodable {
    let invites: [DiscourseInviteLink]

    enum CodingKeys: String, CodingKey {
        case invites
        case pendingInvites = "pending_invites"
        case invited
        case pending
    }

    init(from decoder: Decoder) throws {
        if let array = try? [DiscourseInviteLink].init(from: decoder) {
            invites = array
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let decoded = try? container.decode([DiscourseInviteLink].self, forKey: .invites) {
            invites = decoded
        } else if let decoded = try? container.decode([DiscourseInviteLink].self, forKey: .pendingInvites) {
            invites = decoded
        } else if let decoded = try? container.decode([DiscourseInviteLink].self, forKey: .invited) {
            invites = decoded
        } else if let decoded = try? container.decode([DiscourseInviteLink].self, forKey: .pending) {
            invites = decoded
        } else {
            invites = []
        }
    }
}

struct DiscourseInviteLink: Decodable, Identifiable {
    let id: Int
    let inviteKey: String?
    let inviteLink: String?
    let description: String?
    let createdAt: String?
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case invite
        case inviteKey = "invite_key"
        case inviteLink = "invite_link"
        case inviteURL = "invite_url"
        case url
        case link
        case description
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try container.decodeIfPresent(NestedInvite.self, forKey: .invite)

        let decodedInviteKey = try? container.decode(String.self, forKey: .inviteKey)
        let decodedInviteLink = try? container.decode(String.self, forKey: .inviteLink)
        let decodedInviteURL = try? container.decode(String.self, forKey: .inviteURL)
        let decodedURL = try? container.decode(String.self, forKey: .url)
        let decodedLink = try? container.decode(String.self, forKey: .link)
        let decodedDescription = try? container.decode(String.self, forKey: .description)
        let decodedCreatedAt = try? container.decode(String.self, forKey: .createdAt)
        let decodedExpiresAt = try? container.decode(String.self, forKey: .expiresAt)
        let decodedId = try? container.decode(Int.self, forKey: .id)

        inviteKey = decodedInviteKey ?? nested?.inviteKey
        inviteLink = decodedInviteLink ?? decodedInviteURL ?? decodedURL ?? decodedLink ?? nested?.inviteLink
        description = decodedDescription ?? nested?.description
        createdAt = decodedCreatedAt ?? nested?.createdAt
        expiresAt = decodedExpiresAt ?? nested?.expiresAt
        id = decodedId ?? nested?.id ?? Self.stableId(inviteKey ?? inviteLink ?? description ?? "")
    }

    func effectiveURLString(baseURL: String) -> String? {
        if let inviteLink, !inviteLink.isEmpty {
            return inviteLink
        }
        if let inviteKey, !inviteKey.isEmpty {
            let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return "\(trimmedBase)/invites/\(inviteKey)"
        }
        return nil
    }

    private struct NestedInvite: Decodable {
        let id: Int?
        let inviteKey: String?
        let inviteLink: String?
        let description: String?
        let createdAt: String?
        let expiresAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case inviteKey = "invite_key"
            case inviteLink = "invite_link"
            case description
            case createdAt = "created_at"
            case expiresAt = "expires_at"
        }
    }

    private static func stableId(_ value: String) -> Int {
        let hash = value.unicodeScalars.reduce(UInt64(5381)) { (($0 << 5) &+ $0) &+ UInt64($1.value) }
        return Int(hash % UInt64(Int.max))
    }
}

// MARK: - Composer @-mention user search

struct DiscourseUserSearchResponse: Decodable {
    let users: [DiscourseMentionUser]
    let groups: [DiscourseMentionGroup]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        users = (try? container.decodeIfPresent([DiscourseMentionUser].self, forKey: .users)) ?? []
        groups = (try? container.decodeIfPresent([DiscourseMentionGroup].self, forKey: .groups)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case users, groups
    }
}

struct DiscourseMentionGroup: Decodable, Hashable, Identifiable {
    var id: String { name.lowercased() }
    let name: String
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        fullName = try? container.decodeIfPresent(String.self, forKey: .fullName)
    }

    init(name: String, fullName: String? = nil) {
        self.name = name
        self.fullName = fullName
    }

    var displayName: String {
        let trimmed = fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }
}

struct DiscourseMentionUser: Decodable, Hashable, Identifiable {
    var id: String { username.lowercased() }
    let username: String
    let name: String?
    let avatarTemplate: String?

    enum CodingKeys: String, CodingKey {
        case username, name
        case avatarTemplate = "avatar_template"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = (try? container.decodeIfPresent(String.self, forKey: .username)) ?? ""
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        avatarTemplate = try? container.decodeIfPresent(String.self, forKey: .avatarTemplate)
    }

    init(username: String, name: String?, avatarTemplate: String?) {
        self.username = username
        self.name = name
        self.avatarTemplate = avatarTemplate
    }
}
