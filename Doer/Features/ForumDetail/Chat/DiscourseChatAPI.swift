import Alamofire
import Foundation
import UIKit

// MARK: - Models

struct DiscourseChatChannel: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String?
    let slug: String?
    let lastMessageSentAt: String?
    let currentUserMembership: Membership?
    let iconUploadURL: String?
    /// Nested upload object used by some Discourse chat serializers.
    let iconUpload: IconUpload?
    /// Site-configured channel emoji (`:speech_balloon:` or a unicode glyph).
    let emoji: String?
    let chatableType: String?
    let chatable: Chatable?

    struct Membership: Decodable, Equatable {
        let following: Bool?
        let unreadCount: Int?
        let lastReadMessageId: Int?

        enum CodingKeys: String, CodingKey {
            case following
            case unreadCount = "unread_count"
            case lastReadMessageId = "last_read_message_id"
        }
    }

    struct IconUpload: Decodable, Equatable {
        let url: String?
        let origin: String?

        enum CodingKeys: String, CodingKey {
            case url
            case origin = "original_url"
        }

        init(url: String?, origin: String? = nil) {
            self.url = url
            self.origin = origin
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let value = try? single.decode(String.self) {
                url = value
                origin = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            origin = try container.decodeIfPresent(String.self, forKey: .origin)
        }

        var resolvedURL: String? {
            let raw = (url ?? origin)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
    }

    /// Category / DirectMessage payload. DM carries peer avatars; category channels carry color + logo.
    struct Chatable: Decodable, Equatable {
        let users: [ChatUser]?
        let color: String?
        let name: String?
        let uploadedLogo: IconUpload?

        struct ChatUser: Decodable, Equatable {
            let id: Int?
            let username: String?
            let name: String?
            let avatarTemplate: String?

            enum CodingKeys: String, CodingKey {
                case id, username, name
                case avatarTemplate = "avatar_template"
            }
        }

        enum CodingKeys: String, CodingKey {
            case users, color, name
            case uploadedLogo = "uploaded_logo"
        }

        init(users: [ChatUser]? = nil, color: String? = nil, name: String? = nil, uploadedLogo: IconUpload? = nil) {
            self.users = users
            self.color = color
            self.name = name
            self.uploadedLogo = uploadedLogo
        }

        init(from decoder: Decoder) throws {
            // Category chatable is a full object; some payloads send only an id integer.
            // Throw so the channel decoder can treat that as a missing chatable.
            let c = try decoder.container(keyedBy: CodingKeys.self)
            users = try c.decodeIfPresent([ChatUser].self, forKey: .users)
            color = try c.decodeIfPresent(String.self, forKey: .color)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            uploadedLogo = try? c.decodeIfPresent(IconUpload.self, forKey: .uploadedLogo) ?? nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, slug, emoji, icon
        case lastMessageSentAt = "last_message_sent_at"
        case currentUserMembership = "current_user_membership"
        case iconUploadURL = "icon_upload_url"
        case iconUpload = "icon_upload"
        case chatableType = "chatable_type"
        case chatable
    }

    init(
        id: Int,
        title: String? = nil,
        slug: String? = nil,
        lastMessageSentAt: String? = nil,
        currentUserMembership: Membership? = nil,
        iconUploadURL: String? = nil,
        iconUpload: IconUpload? = nil,
        emoji: String? = nil,
        chatableType: String? = nil,
        chatable: Chatable? = nil
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.lastMessageSentAt = lastMessageSentAt
        self.currentUserMembership = currentUserMembership
        self.iconUploadURL = iconUploadURL
        self.iconUpload = iconUpload
        self.emoji = emoji
        self.chatableType = chatableType
        self.chatable = chatable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        lastMessageSentAt = try c.decodeIfPresent(String.self, forKey: .lastMessageSentAt)
        currentUserMembership = try c.decodeIfPresent(Membership.self, forKey: .currentUserMembership)
        iconUploadURL = try c.decodeIfPresent(String.self, forKey: .iconUploadURL)
        iconUpload = (try? c.decodeIfPresent(IconUpload.self, forKey: .iconUpload))
            ?? (try? c.decodeIfPresent(IconUpload.self, forKey: .icon))
            ?? nil
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji)
        chatableType = try c.decodeIfPresent(String.self, forKey: .chatableType)
        chatable = try? c.decodeIfPresent(Chatable.self, forKey: .chatable) ?? nil
    }

    var displayTitle: String {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        // DM channels often have empty title — use peer usernames.
        if let users = chatable?.users, !users.isEmpty {
            let names = users.compactMap { user -> String? in
                let name = user.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !name.isEmpty { return name }
                let username = user.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return username.isEmpty ? nil : username
            }
            if !names.isEmpty {
                return names.joined(separator: ", ")
            }
        }
        let s = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "#\(id)" : s
    }

    var unreadCount: Int {
        max(currentUserMembership?.unreadCount ?? 0, 0)
    }

    /// Best-effort channel avatar: custom icon → emoji PNG → category logo → first DM peer → nil.
    func avatarURL(baseURL: String) -> URL? {
        if let raw = resolvedIconURLString {
            return Self.absoluteURL(raw, baseURL: baseURL)
        }
        if let emojiURL = namedEmojiImageURL(baseURL: baseURL) {
            return emojiURL
        }
        if let template = chatable?.users?.first(where: {
            ($0.avatarTemplate?.isEmpty == false)
        })?.avatarTemplate {
            return AvatarImageLoader.url(from: template, baseURL: baseURL, size: 96)
        }
        return nil
    }

    var isPublicChannel: Bool {
        (chatableType ?? "").caseInsensitiveCompare("Category") == .orderedSame
    }

    var monogramLetter: String {
        // Named shortcodes (`:speech_balloon:`) render as the Twemoji PNG avatar.
        // Unicode glyphs (💬) stay as the letter-tile fallback.
        if namedEmojiCode == nil,
           let mark = emoji?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mark.isEmpty {
            return mark
        }
        // Discourse / FluxDo public rooms use a # tile on the category color.
        if isPublicChannel { return "#" }
        let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        return String(first).uppercased()
    }

    var monogramColor: UIColor {
        if let hex = accentHexColor, let color = Self.color(fromHex: hex) {
            return color
        }
        return Self.hashedColor(for: displayTitle)
    }

    var monogramForegroundColor: UIColor {
        Self.contrastingForeground(for: monogramColor)
    }

    var avatarTemplate: String? {
        chatable?.users?.first(where: { $0.avatarTemplate?.isEmpty == false })?.avatarTemplate
    }

    /// Category color (hex without #) for letter-tile fallback when no icon.
    var accentHexColor: String? {
        chatable?.color
    }

    private var resolvedIconURLString: String? {
        if let raw = iconUploadURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        if let raw = iconUpload?.resolvedURL {
            return raw
        }
        return chatable?.uploadedLogo?.resolvedURL
    }

    /// ASCII shortcode without colons (`speech_balloon`), when the site configured a named emoji.
    var namedEmojiCode: String? {
        guard let raw = emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let stripped = raw.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !stripped.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-"))
        guard stripped.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return stripped
    }

    private func namedEmojiImageURL(baseURL: String) -> URL? {
        guard let code = namedEmojiCode else { return nil }
        guard let raw = EmojiStore.resolvedURLString(for: code, baseURL: baseURL),
              !raw.isEmpty
        else { return nil }
        return URL(string: raw) ?? Self.absoluteURL(raw, baseURL: baseURL)
    }

    private static func color(fromHex hex: String) -> UIColor? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    static func contrastingForeground(for background: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        background.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.55 ? UIColor.black.withAlphaComponent(0.85) : .white
    }

    private static func hashedColor(for seed: String) -> UIColor {
        let palette: [UIColor] = [
            UIColor(red: 0.20, green: 0.56, blue: 0.93, alpha: 1),
            UIColor(red: 0.40, green: 0.73, blue: 0.42, alpha: 1),
            UIColor(red: 0.91, green: 0.40, blue: 0.38, alpha: 1),
            UIColor(red: 0.55, green: 0.48, blue: 0.91, alpha: 1),
            UIColor(red: 0.20, green: 0.70, blue: 0.70, alpha: 1),
            UIColor(red: 0.95, green: 0.61, blue: 0.25, alpha: 1),
        ]
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    private static func absoluteURL(_ raw: String, baseURL: String) -> URL? {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if raw.hasPrefix("/") {
            return URL(string: base + raw)
        }
        return URL(string: base + "/" + raw)
    }
}

struct DiscourseChatChannelsResponse: Decodable {
    let publicChannels: [DiscourseChatChannel]
    let directMessageChannels: [DiscourseChatChannel]

    enum CodingKeys: String, CodingKey {
        case publicChannels = "public_channels"
        case directMessageChannels = "direct_message_channels"
        case channels
    }

    init(publicChannels: [DiscourseChatChannel] = [], directMessageChannels: [DiscourseChatChannel] = []) {
        self.publicChannels = publicChannels
        self.directMessageChannels = directMessageChannels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicChannels = (try? c.decodeIfPresent([DiscourseChatChannel].self, forKey: .publicChannels))
            ?? (try? c.decodeIfPresent([DiscourseChatChannel].self, forKey: .channels))
            ?? []
        directMessageChannels = (try? c.decodeIfPresent([DiscourseChatChannel].self, forKey: .directMessageChannels)) ?? []
    }

    var all: [DiscourseChatChannel] {
        publicChannels + directMessageChannels
    }
}

struct DiscourseChatMessage: Decodable, Identifiable, Equatable {
    let id: Int
    let message: String?
    let createdAt: String?
    private(set) var user: User?
    let cooked: String?
    let inReplyToId: Int?
    let userId: Int?

    struct User: Decodable, Equatable {
        let id: Int?
        let username: String?
        let name: String?
        let avatarTemplate: String?

        enum CodingKeys: String, CodingKey {
            case id, username, name
            case avatarTemplate = "avatar_template"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, message, cooked, user
        case createdAt = "created_at"
        case inReplyToId = "in_reply_to_id"
        case userId = "user_id"
    }

    mutating func resolveUser(from usersById: [Int: User]) {
        if user?.avatarTemplate?.isEmpty == false { return }
        let key = user?.id ?? userId
        guard let key, let resolved = usersById[key] else { return }
        // Prefer sideloaded user when nested user is missing avatar.
        if user == nil || (user?.avatarTemplate?.isEmpty != false) {
            user = resolved
        }
    }

    var displayBody: String {
        let raw = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty {
            // Prefer raw when it already carries shortcodes (e.g. `:smile:`).
            if TitleEmojiRenderer.containsShortcode(raw) {
                return raw
            }
            // Raw may be plain text while cooked still has emoji <img alt=":code:">.
            if let cooked, cooked.contains("<img") || cooked.contains("<IMG") {
                let recovered = TitleEmojiRenderer.recoverShortcodesFromHTML(cooked)
                if TitleEmojiRenderer.containsShortcode(recovered) {
                    return recovered
                }
            }
            return raw
        }
        // Fall back to cooked HTML → shortcodes, then strip remaining tags.
        let cookedHTML = cooked ?? ""
        if cookedHTML.contains("<") {
            let recovered = TitleEmojiRenderer.recoverShortcodesFromHTML(cookedHTML)
            if TitleEmojiRenderer.containsShortcode(recovered) {
                return recovered
            }
        }
        return cookedHTML
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func formattedSendTime(now: Date = Date()) -> String {
        Self.formatSendTime(createdAt, now: now)
    }

    static func formatSendTime(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = parseISODate(iso) else { return "" }
        let calendar = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.locale = .current
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "chat.time.yesterday", defaultValue: "昨天")
                + "\n" + time
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateFormat = "M/d"
        return dateFormatter.string(from: date) + "\n" + time
    }

    private static func parseISODate(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        // ISO8601DateFormatter rejects 1/2/6-digit fractional seconds; strip them and retry.
        if let dot = trimmed.firstIndex(of: ".") {
            var suffix = trimmed[trimmed.index(after: dot)...]
            while let first = suffix.first, first.isNumber {
                suffix = suffix.dropFirst()
            }
            let stripped = String(trimmed[..<dot]) + suffix
            if let date = plain.date(from: stripped) { return date }
            if let date = withFraction.date(from: stripped) { return date }
        }
        return nil
    }
}

struct DiscourseChatMessagesResponse: Decodable {
    let messages: [DiscourseChatMessage]

    enum CodingKeys: String, CodingKey {
        case messages
        case chatMessages = "chat_messages"
        case users
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var raw = (try? c.decodeIfPresent([DiscourseChatMessage].self, forKey: .messages))
            ?? (try? c.decodeIfPresent([DiscourseChatMessage].self, forKey: .chatMessages))
            ?? []
        let users = (try? c.decodeIfPresent([DiscourseChatMessage.User].self, forKey: .users)) ?? []
        if !users.isEmpty {
            var byId: [Int: DiscourseChatMessage.User] = [:]
            for user in users {
                if let id = user.id {
                    byId[id] = user
                }
            }
            for index in raw.indices {
                raw[index].resolveUser(from: byId)
            }
        }
        messages = raw
    }
}

// MARK: - Routes
//
// Discourse Chat keeps two families:
// - REST `/chat/api/*` for list/read (linux.do + current Discourse)
// - Legacy `POST /chat/:id` to create a message (linux.do / FluxDo).
//   `POST /chat/api/channels/:id/messages` 404s on linux.do with
//   `error_type: not_found` / 「找不到请求的 URL 或资源。」

enum DiscourseChatEndpoint {
    static func channels() -> String { "/chat/api/me/channels" }

    static func messages(channelId: Int, pageSize: Int) -> String {
        "/chat/api/channels/\(channelId)/messages?page_size=\(pageSize)"
    }

    static func sendMessage(channelId: Int) -> String {
        "/chat/\(channelId)"
    }

    static func sendMessageModern(channelId: Int) -> String {
        "/chat/api/channels/\(channelId)/messages"
    }
}

// MARK: - API

extension DiscourseAPI {
    func fetchChatChannels() async throws -> DiscourseChatChannelsResponse {
        let url = baseURL + DiscourseChatEndpoint.channels()
        let response = await session.request(url, method: .get).serializingData().response
        if let http = response.response, let responseURL = http.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: responseURL) {
            WebCookieStore.shared.mergeResponseHeaders(http.allHeaderFields, for: responseURL)
        }
        if let error = response.error { throw error }
        guard let data = response.data, !data.isEmpty else {
            return DiscourseChatChannelsResponse()
        }
        return (try? JSONDecoder().decode(DiscourseChatChannelsResponse.self, from: data))
            ?? DiscourseChatChannelsResponse()
    }

    func fetchChatMessages(channelId: Int, pageSize: Int = 50) async throws -> [DiscourseChatMessage] {
        let url = baseURL + DiscourseChatEndpoint.messages(channelId: channelId, pageSize: pageSize)
        let response = await session.request(url, method: .get).serializingData().response
        try throwIfUnsuccessfulChatResponse(response)
        guard let data = response.data, !data.isEmpty else { return [] }
        let decoded = try JSONDecoder().decode(DiscourseChatMessagesResponse.self, from: data)
        return decoded.messages
    }

    func sendChatMessage(
        channelId: Int,
        message: String,
        inReplyToId: Int? = nil,
        uploadIds: [Int] = []
    ) async throws {
        var parameters: Parameters = ["message": message]
        if let inReplyToId {
            parameters["in_reply_to_id"] = inReplyToId
        }
        if !uploadIds.isEmpty {
            parameters["upload_ids"] = uploadIds
        }
        do {
            try await postChatMessage(
                path: DiscourseChatEndpoint.sendMessage(channelId: channelId),
                parameters: parameters
            )
        } catch let error as DiscourseAPIError where error.errorType == "not_found" {
            try await postChatMessage(
                path: DiscourseChatEndpoint.sendMessageModern(channelId: channelId),
                parameters: parameters
            )
        }
    }

    private func postChatMessage(path: String, parameters: Parameters) async throws {
        let response = await session.request(
            baseURL + path,
            method: .post,
            parameters: parameters,
            encoding: JSONEncoding.default
        ).serializingData().response
        try throwIfUnsuccessfulChatResponse(response)
    }

    private func throwIfUnsuccessfulChatResponse(_ response: AFDataResponse<Data>) throws {
        if let http = response.response, let responseURL = http.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: responseURL) {
            WebCookieStore.shared.mergeResponseHeaders(http.allHeaderFields, for: responseURL)
        }
        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }
        if let error = response.error { throw error }
        guard let status = response.response?.statusCode, !(200 ..< 300).contains(status) else {
            return
        }
        if let data = response.data {
            if let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
               !errBody.errors.isEmpty {
                throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
            }
        }
        throw DiscourseAPIError(
            messages: [String(localized: "chat.request.failed", defaultValue: "请求失败")],
            errorType: "chat_request_failed"
        )
    }

    func castPostVotingVote(postId: Int, direction: String) async throws {
        let url = baseURL + "/post_voting/vote"
        let parameters: Parameters = [
            "post_id": postId,
            "direction": direction,
        ]
        try await requestVoidURL(url, method: .put, parameters: parameters)
    }

    func removePostVotingVote(postId: Int) async throws {
        let url = baseURL + "/post_voting/vote"
        let parameters: Parameters = ["post_id": postId]
        try await requestVoidURL(url, method: .delete, parameters: parameters)
    }

    private func requestVoidURL(_ url: String, method: HTTPMethod, parameters: Parameters) async throws {
        let response = await session.request(
            url,
            method: method,
            parameters: parameters,
            encoding: JSONEncoding.default
        ).serializingData().response
        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }
        if let error = response.error { throw error }
        if let status = response.response?.statusCode, !(200 ..< 300).contains(status) {
            throw DiscourseAPIError(messages: ["HTTP \(status)"], errorType: nil)
        }
    }
}

