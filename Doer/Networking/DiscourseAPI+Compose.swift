import Alamofire
import Foundation
import UniformTypeIdentifiers

// MARK: - compose
extension DiscourseAPI {
    func createReply(topicId: Int, replyToPostNumber: Int?, raw: String) async throws -> DiscourseCreatePostResponse {
        var params: [String: Any] = [
            "topic_id": topicId,
            "raw": raw,
        ]
        if let replyToPostNumber {
            params["reply_to_post_number"] = replyToPostNumber
        }
        return try await request(route: .createTopic, parameters: params)
    }

    func fetchDiscourseTemplates() async throws -> [DiscourseTemplate] {
        let response: DiscourseTemplatesResponse = try await request(route: .discourseTemplates)
        return response.templates
    }

    func recordDiscourseTemplateUse(id: Int) async {
        try? await requestVoid(route: .useDiscourseTemplate(id: id))
    }

    func createTopic(title: String, raw: String, categoryId: Int?, tags: [String] = []) async throws -> DiscourseCreatePostResponse {
        var params: [String: Any] = [
            "title": title,
            "raw": raw,
            "archetype": "regular",
        ]
        if let categoryId {
            params["category"] = categoryId
        }
        if !tags.isEmpty {
            params["tags"] = tags
        }
        return try await request(route: .createTopic, parameters: params)
    }

    func fetchCustomEmojis() async throws -> [DiscourseCustomEmoji] {
        let siteInfo: DiscourseSiteInfo = try await request(route: .siteInfo)
        return siteInfo.customEmoji ?? []
    }

    func fetchEmojiGroups() async throws -> [DiscourseEmojiGroup] {
        async let emojiGroupsRequest: [String: [DiscourseEmojiEntry]] = request(route: .emojis)
        async let customEmojiRequest: [DiscourseCustomEmoji] = fetchCustomEmojis()

        let emojiGroups = try await emojiGroupsRequest
        let customEmojis = (try? await customEmojiRequest) ?? []
        let orderedKeys = [
            "smileys_&_emotion",
            "people_&_body",
            "animals_&_nature",
            "food_&_drink",
            "activities",
            "travel_&_places",
            "objects",
            "symbols",
            "flags",
        ]

        var result: [DiscourseEmojiGroup] = []
        var consumedKeys = Set<String>()
        for key in orderedKeys {
            guard let entries = emojiGroups[key], !entries.isEmpty else { continue }
            result.append(DiscourseEmojiGroup(key: key, emojis: entries))
            consumedKeys.insert(key)
        }

        let remainingKeys = emojiGroups.keys
            .filter { !consumedKeys.contains($0) }
            .sorted()
        for key in remainingKeys {
            guard let entries = emojiGroups[key], !entries.isEmpty else { continue }
            result.append(DiscourseEmojiGroup(key: key, emojis: entries))
        }

        if !customEmojis.isEmpty {
            let entries = customEmojis.map {
                DiscourseEmojiEntry(name: $0.name, url: $0.url, searchAliases: nil)
            }
            result.insert(DiscourseEmojiGroup(key: "custom", emojis: entries), at: 0)
        }

        EmojiStore.save(result.flatMap { $0.emojis }, for: baseURL)
        emojiReady = true
        return result
    }

    func uploadComposerFile(fileURL: URL, filename: String? = nil) async throws -> DiscourseUploadResponse {
        let route = DiscourseRouter.upload(clientId: composerUploadClientId)
        let url = baseURL + route.path
        let fileName = filename ?? fileURL.lastPathComponent
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let headers: HTTPHeaders = [
            "Accept": "application/json",
        ]

        let response = await session.upload(
            multipartFormData: { formData in
                formData.append(Data("composer".utf8), withName: "upload_type")
                formData.append(Data("true".utf8), withName: "synchronous")
                formData.append(fileURL, withName: "file", fileName: fileName, mimeType: mimeType)
            },
            to: url,
            method: route.method,
            headers: headers
        )
        .serializingData()
        .response

        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }
        if let httpResponse = response.response, let responseURL = httpResponse.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: responseURL) {
            WebCookieStore.shared.mergeResponseHeaders(httpResponse.allHeaderFields, for: responseURL)
        }
        if handleCloudflareChallengeIfNeeded(route: route, response: response, source: "api.upload") {
            throw Self.cloudflareChallengeError()
        }

        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 429 {
                throw DiscourseAPIError(messages: [String(localized: "error.rate_limited")], errorType: "rate_limited")
            }
            if statusCode == 413 {
                throw DiscourseAPIError(messages: [String(localized: "reply.upload.too_large")], errorType: "upload_too_large")
            }
            if let data = response.data,
               let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
               !errBody.errors.isEmpty {
                throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
            }
            throw DiscourseAPIError(messages: [String(localized: "reply.upload.failed")], errorType: "upload_failed")
        }

        switch response.result {
        case .success(let data):
            do {
                return try JSONDecoder().decode(DiscourseUploadResponse.self, from: data)
            } catch {
                throw DiscourseDecodingError(
                    route: route,
                    url: url,
                    statusCode: response.response?.statusCode,
                    underlying: error,
                    bodyPreview: Self.bodyPreview(from: data)
                )
            }
        case .failure(let error):
            throw Self.makeDecodingError(
                error,
                route: route,
                url: url,
                statusCode: response.response?.statusCode,
                data: response.data
            )
        }
    }

    func fetchCreatedTopics(username: String, page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .createdTopics(username: username, page: page))
    }

    func updatePresence(clientId: String, presentChannels: [String], leaveChannels: [String]) async throws {
        var params: [String: Any] = ["client_id": clientId]
        // Discourse accepts array-style params; Alamofire encodes them.
        if !presentChannels.isEmpty { params["present_channels"] = presentChannels }
        if !leaveChannels.isEmpty { params["leave_channels"] = leaveChannels }
        let _: EmptyResponse = try await request(route: .presenceUpdate, parameters: params)
    }

func fetchPendingInvites(username: String) async throws -> [DiscourseInviteLink] {
        let response: DiscoursePendingInvitesResponse = try await request(route: .pendingInvites(username: username))
        return response.invites
    }

    func createInvite(description: String?, expiresAt: Date?, email: String? = nil) async throws -> DiscourseInviteLink {
        var params: [String: Any] = [
            "max_redemptions_allowed": 1,
        ]
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["description"] = description
        }
        if let expiresAt {
            params["expires_at"] = ISO8601DateFormatter().string(from: expiresAt)
        }
        if let email, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["email"] = email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await request(route: .createInvite, parameters: params)
    }

    func loadOrFetchEmojiMap() async {
        if EmojiStore.load(for: baseURL) {
            emojiReady = true
            return
        }
        do {
            _ = try await fetchEmojiGroups()
            emojiReady = true
        } catch {
            // Silent failure — reactions won't show emoji images but functionality is unaffected
        }
    }
}
