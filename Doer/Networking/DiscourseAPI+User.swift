import Alamofire
import Foundation
import UniformTypeIdentifiers

// MARK: - user
extension DiscourseAPI {
    func fetchCurrentUser() async throws -> DiscourseCurrentUser {
        let response: DiscourseCurrentUserResponse = try await request(route: .currentUser)
        guard let currentUser = response.currentUser else {
            throw DiscourseAPIError(messages: [String(localized: "login.required.message")], errorType: "not_logged_in")
        }
        return currentUser
    }

    func toggleReaction(postId: Int, reactionId: String) async throws -> DiscourseReactionToggleResponse? {
        let route = DiscourseRouter.toggleReaction(postId: postId, reactionId: reactionId)
        let url = baseURL + route.path
        let response = await session.request(url, method: route.method).serializingData().response
        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }
        if let httpResponse = response.response, let responseURL = httpResponse.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: responseURL, statusCode: httpResponse.statusCode) {
            WebCookieStore.shared.mergeResponseHeaders(httpResponse.allHeaderFields, for: responseURL)
        }
        if handleCloudflareChallengeIfNeeded(route: route, response: response, source: "api.action") {
            throw Self.cloudflareChallengeError()
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to toggle reaction"], errorType: nil)
        }

        guard let data = response.data, !data.isEmpty else {
            return nil
        }
        do {
            return try JSONDecoder().decode(DiscourseReactionToggleResponse.self, from: data)
        } catch {
            throw DiscourseDecodingError(
                route: route,
                url: url,
                statusCode: response.response?.statusCode,
                underlying: error,
                bodyPreview: Self.bodyPreview(from: data)
            )
        }
    }

    func fetchBookmarks(username: String, page: Int = 0) async throws -> DiscourseBookmarkList {
        try await request(route: .bookmarks(username: username, page: page))
    }

    func fetchUserSummary(username: String) async throws -> DiscourseUserSummary {
        let response: DiscourseUserSummaryResponse = try await request(route: .userSummary(username: username))
        return response.userSummary
    }

    func fetchUserSummaryResponse(username: String) async throws -> DiscourseUserSummaryResponse {
        try await request(route: .userSummary(username: username))
    }

    func fetchUserProfile(username: String) async throws -> DiscourseUserProfile {
        let response: DiscourseUserProfileResponse = try await request(route: .userProfile(username: username))
        return response.user
    }

    func fetchUserCard(username: String) async throws -> DiscourseUserProfile {
        let response: DiscourseUserCardResponse = try await request(route: .userCard(username: username))
        return response.user
    }

    func followUser(username: String) async throws {
        try await requestVoid(route: .follow(username: username))
    }

    func unfollowUser(username: String) async throws {
        try await requestVoid(route: .unfollow(username: username))
    }

    /// Composer @-mention search. Empty `term` + `topicId` returns recent participants.
    func searchUsersForMention(term: String, topicId: Int? = nil) async throws -> [DiscourseMentionUser] {
        let response: DiscourseUserSearchResponse = try await request(
            route: .userSearch(term: term, topicId: topicId)
        )
        return response.users
    }

    func fetchUserActions(username: String, filter: String, offset: Int = 0) async throws -> [DiscourseUserAction] {
        let response: DiscourseUserActionResponse = try await request(
            route: .userActions(username: username, filter: filter, offset: offset)
        )
        return response.userActions
    }

    func fetchUserReactions(username: String, beforeReactionUserId: Int? = nil) async throws -> [DiscourseUserReaction] {
        let response: DiscourseUserReactionResponse = try await request(
            route: .userReactions(username: username, beforeReactionUserId: beforeReactionUserId)
        )
        return response.reactions
    }

    func fetchFollowing(username: String) async throws -> [DiscourseFollowUser] {
        try await request(route: .following(username: username))
    }

    func fetchFollowers(username: String) async throws -> [DiscourseFollowUser] {
        try await request(route: .followers(username: username))
    }

    func fetchDrafts(offset: Int = 0, limit: Int = 20) async throws -> DiscourseDraftListResponse {
        try await request(route: .drafts(offset: offset, limit: limit))
    }

    /// Single draft by key (FluxDo `GET /drafts/:key.json`). Returns nil when absent.
    func fetchDraft(key: String) async throws -> (data: DiscourseDraftData, sequence: Int)? {
        struct Envelope: Decodable {
            let draft: DiscourseDraftData?
            let draftSequence: Int?
            enum CodingKeys: String, CodingKey {
                case draft
                case draftSequence = "draft_sequence"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                draftSequence = try container.decodeIfPresent(Int.self, forKey: .draftSequence)
                if let object = try? container.decodeIfPresent(DiscourseDraftData.self, forKey: .draft) {
                    draft = object
                } else if let raw = try? container.decodeIfPresent(String.self, forKey: .draft),
                          let rawData = raw.data(using: .utf8),
                          let decoded = try? JSONDecoder().decode(DiscourseDraftData.self, from: rawData) {
                    draft = decoded
                } else {
                    draft = nil
                }
            }
        }

        do {
            let envelope: Envelope = try await request(route: .draft(key: key))
            guard let data = envelope.draft else { return nil }
            return (data, envelope.draftSequence ?? 0)
        } catch let error as DiscourseAPIError where error.errorType == "http_404" {
            return nil
        }
    }

    /// Upsert a Discourse server draft (same API web / FluxDo use).
    /// - Returns the next `draft_sequence` to send on subsequent saves.
    @discardableResult
    func saveDraft(key: String, sequence: Int, dataJSON: String, forceSave: Bool = false) async throws -> Int {
        var parameters: [String: Any] = [
            "draft_key": key,
            "sequence": sequence,
            "data": dataJSON,
        ]
        if forceSave {
            // Discourse / FluxDo: bypass optimistic sequence check after 409.
            parameters["force_save"] = true
        }
        let response: DiscourseSaveDraftResponse = try await request(
            route: .saveDraft,
            parameters: parameters,
            encoding: URLEncoding.default
        )
        return response.draftSequence ?? (sequence + 1)
    }

    func deleteDraft(key: String, sequence: Int) async throws {
        do {
            try await requestVoid(route: .deleteDraft(key: key, sequence: sequence))
        } catch let error as DiscourseAPIError where error.errorType == "http_404" {
            return
        }
    }

    func fetchUserBadges(username: String) async throws -> DiscourseUserBadgesResponse {
        try await request(route: .userBadges(username: username))
    }

    /// Single badge metadata (`GET /badges/:id.json`).
    func fetchBadge(id: Int) async throws -> DiscourseBadge {
        struct Envelope: Decodable {
            let badge: DiscourseBadge
        }
        let envelope: Envelope = try await request(route: .badge(id: id))
        return envelope.badge
    }

    /// Grantees for a badge (`GET /user_badges.json?badge_id=`), FluxDo parity.
    func fetchBadgeUsers(badgeId: Int, username: String? = nil) async throws -> DiscourseBadgeDetailResponse {
        try await request(route: .badgeUsers(badgeId: badgeId, username: username))
    }

    /// Site-wide badge catalog (`/badges.json`) for notification icon / type chrome.
    func fetchAllBadges() async throws -> [DiscourseBadge] {
        let url = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/badges.json"
        let response = await session.request(url, method: .get).serializingData().response
        if let error = response.error { throw error }
        guard let data = response.data, !data.isEmpty else { return [] }
        struct Envelope: Decodable {
            let badges: [DiscourseBadge]?
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.badges ?? []
    }

    func fetchPendingPosts(username: String) async throws -> [DiscoursePendingPost] {
        let response: DiscoursePendingPostsResponse = try await request(route: .pendingPosts(username: username))
        return response.pendingPosts
    }

    func deleteSession(username: String) async {
        let url = baseURL + "/session/\(username)"
        _ = await session.request(url, method: .delete).serializingData().response
    }
}
