import Foundation

struct DiscourseGroupShowResponse: Decodable {
    let group: DiscourseGroup
}

struct DiscourseGroupListResponse: Decodable {
    let groups: [DiscourseGroup]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([DiscourseGroup].self, forKey: .groups) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case groups
    }
}

struct DiscourseGroup: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fullName: String?
    let title: String?
    let userCount: Int
    let bioExcerpt: String?
    let flairURL: String?
    let flairBgColor: String?
    let flairColor: String?
    let automatic: Bool
    let publicAdmission: Bool
    let bioRaw: String?
    let isGroupUser: Bool
    let isGroupOwner: Bool
    let mentionable: Bool
    let messageable: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, title, automatic, mentionable, messageable
        case fullName = "full_name"
        case userCount = "user_count"
        case bioExcerpt = "bio_excerpt"
        case bioRaw = "bio_raw"
        case flairURL = "flair_url"
        case flairBgColor = "flair_bg_color"
        case flairColor = "flair_color"
        case publicAdmission = "public_admission"
        case isGroupUser = "is_group_user"
        case isGroupOwner = "is_group_owner"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        userCount = try container.decodeIfPresent(Int.self, forKey: .userCount) ?? 0
        bioExcerpt = try container.decodeIfPresent(String.self, forKey: .bioExcerpt)
        flairURL = try container.decodeIfPresent(String.self, forKey: .flairURL)
        flairBgColor = try container.decodeIfPresent(String.self, forKey: .flairBgColor)
        flairColor = try container.decodeIfPresent(String.self, forKey: .flairColor)
        automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        publicAdmission = try container.decodeIfPresent(Bool.self, forKey: .publicAdmission) ?? false
        bioRaw = try container.decodeIfPresent(String.self, forKey: .bioRaw)
        isGroupUser = try container.decodeIfPresent(Bool.self, forKey: .isGroupUser) ?? false
        isGroupOwner = try container.decodeIfPresent(Bool.self, forKey: .isGroupOwner) ?? false
        mentionable = try container.decodeIfPresent(Bool.self, forKey: .mentionable) ?? false
        messageable = try container.decodeIfPresent(Bool.self, forKey: .messageable) ?? false
    }

    /// Plain bio for the group page. `bio_raw` keeps line breaks; the excerpt is a fallback.
    var bioText: String {
        let raw = (bioRaw ?? bioExcerpt ?? "")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw
    }

    var displayName: String {
        let full = fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !full.isEmpty { return full }
        let titled = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !titled.isEmpty { return titled }
        return name
    }

    func flairAbsoluteURL(baseURL: String) -> URL? {
        guard let flairURL, !flairURL.isEmpty else { return nil }
        if flairURL.hasPrefix("http://") || flairURL.hasPrefix("https://") {
            return URL(string: flairURL)
        }
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = flairURL.hasPrefix("/") ? flairURL : "/\(flairURL)"
        return URL(string: root + path)
    }
}

struct DiscourseGroupMembersResponse: Decodable {
    let members: [DiscourseGroupMember]
    let total: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = try container.decodeIfPresent([DiscourseGroupMember].self, forKey: .members) ?? []
        let meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
        total = meta?.total ?? members.count
    }

    private struct Meta: Decodable {
        let total: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case members, meta
    }
}

struct DiscourseGroupMember: Decodable, Identifiable, Hashable {
    let id: Int
    let username: String
    let name: String?
    let avatarTemplate: String?
    let lastSeenAt: String?
    let lastPostedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case avatarTemplate = "avatar_template"
        case lastSeenAt = "last_seen_at"
        case lastPostedAt = "last_posted_at"
    }

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? username : trimmed
    }
}
