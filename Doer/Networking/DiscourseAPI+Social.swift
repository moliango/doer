import Alamofire
import Foundation
import UniformTypeIdentifiers

// MARK: - social
extension DiscourseAPI {
    func updateTopicNotificationLevel(topicId: Int, level: DiscourseTopicDetail.NotificationLevel) async throws {
        try await requestVoid(
            route: .topicNotificationLevel(topicId: topicId),
            parameters: ["notification_level": level.rawValue]
        )
    }

    func updateTopic(topicId: Int, title: String) async throws {
        try await requestVoid(
            route: .updateTopic(topicId: topicId),
            parameters: ["title": title]
        )
    }

    func createBookmark(postId: Int) async throws -> DiscourseCreateBookmarkResponse {
        try await request(route: .createBookmark, parameters: [
            "bookmarkable_id": postId,
            "bookmarkable_type": "Post",
        ])
    }

    func createBookmark(topicId: Int) async throws -> DiscourseCreateBookmarkResponse {
        try await request(route: .createBookmark, parameters: [
            "bookmarkable_id": topicId,
            "bookmarkable_type": "Topic",
        ])
    }

    func deleteBookmark(id: Int) async throws {
        let route = DiscourseRouter.deleteBookmark(id: id)
        let url = baseURL + route.path
        let response = await session.request(url, method: route.method).serializingData().response
        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }
        if let httpResponse = response.response, let responseURL = httpResponse.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: responseURL) {
            WebCookieStore.shared.mergeResponseHeaders(httpResponse.allHeaderFields, for: responseURL)
        }
        if handleCloudflareChallengeIfNeeded(route: route, response: response, source: "api.action") {
            throw Self.cloudflareChallengeError()
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            throw DiscourseAPIError(messages: ["Failed to delete bookmark"], errorType: nil)
        }
    }

    func createBoost(postId: Int, raw: String) async throws -> DiscourseTopicDetail.Boost {
        let route = DiscourseRouter.createBoost(postId: postId)
        let url = baseURL + route.path
        let parameters: Parameters = ["raw": raw]
        let response = await session.request(
            url,
            method: route.method,
            parameters: parameters,
            encoding: URLEncoding.httpBody
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
        if handleCloudflareChallengeIfNeeded(route: route, response: response, source: "api.action") {
            throw Self.cloudflareChallengeError()
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 429 {
                throw DiscourseAPIError(messages: [String(localized: "error.rate_limited")], errorType: "rate_limited")
            }
            if let data = response.data,
               let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
               !errBody.errors.isEmpty {
                throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
            }
            throw DiscourseAPIError(messages: [String(localized: "post.boost.failed")], errorType: nil)
        }

        switch response.result {
        case .success(let data):
            do {
                return try Self.decodeBoostPayload(data)
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

    func getBoost(boostId: Int) async throws -> DiscourseTopicDetail.Boost {
        let route = DiscourseRouter.getBoost(boostId: boostId)
        let response = try await performRequest(route: route)
        return try Self.decodeBoostPayload(response.data)
    }

    func deleteBoost(boostId: Int) async throws {
        try await requestVoid(route: .deleteBoost(boostId: boostId))
    }

    func flagBoost(boostId: Int, flagTypeId: Int, message: String?) async throws {
        let route = DiscourseRouter.flagBoost(boostId: boostId)
        let url = baseURL + route.path
        var parameters: Parameters = ["flag_type_id": flagTypeId]
        if let message, !message.isEmpty {
            parameters["message"] = message
        }
        let response = await session.request(
            url,
            method: route.method,
            parameters: parameters,
            encoding: URLEncoding.httpBody
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
        if handleCloudflareChallengeIfNeeded(route: route, response: response, source: "api.action") {
            throw Self.cloudflareChallengeError()
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 429 {
                throw DiscourseAPIError(messages: [String(localized: "error.rate_limited")], errorType: "rate_limited")
            }
            if let data = response.data,
               let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
               !errBody.errors.isEmpty {
                throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
            }
            throw DiscourseAPIError(
                messages: [String(localized: "post.boost.flag_failed", defaultValue: "举报 Boost 失败")],
                errorType: nil
            )
        }
        if let error = response.error {
            throw error
        }
    }

    func fetchBoostFlagTypes() async throws -> [DiscourseFlagType] {
        let types = (try? await fetchSiteInfo().postActionTypes) ?? []
        let enabled = types.filter { $0.isFlag && $0.enabled }
        return enabled.isEmpty ? DiscourseFlagType.defaultTypes : enabled
    }

    private static func decodeBoostPayload(_ data: Data) throws -> DiscourseTopicDetail.Boost {
        // Plugin may return bare Boost or `{ "boost": {…} }`.
        if let boost = try? JSONDecoder().decode(DiscourseTopicDetail.Boost.self, from: data) {
            return boost
        }
        struct Envelope: Decodable { let boost: DiscourseTopicDetail.Boost }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data) {
            return env.boost
        }
        return try JSONDecoder().decode(DiscourseTopicDetail.Boost.self, from: data)
    }


    func votePoll(postId: Int, pollName: String, optionIds: [String]) async throws -> DiscoursePollVoteResponse {
        let cleanedOptions = optionIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard postId > 0, !pollName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cleanedOptions.isEmpty else {
            throw DiscourseAPIError(messages: [String(localized: "post.poll.invalid_selection")], errorType: "invalid_poll_vote")
        }

        let route = DiscourseRouter.votePoll
        let url = baseURL + route.path
        let parameters: Parameters = [
            "post_id": postId,
            "poll_name": pollName,
            "options": cleanedOptions,
        ]
        let response = await session.request(
            url,
            method: route.method,
            parameters: parameters,
            encoding: URLEncoding.httpBody
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
        if handleCloudflareChallengeIfNeeded(route: route, response: response, source: "api.action") {
            throw Self.cloudflareChallengeError()
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 429 {
                throw DiscourseAPIError(messages: [String(localized: "error.rate_limited")], errorType: "rate_limited")
            }
            if let data = response.data,
               let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
               !errBody.errors.isEmpty {
                throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
            }
            throw DiscourseAPIError(messages: [String(localized: "post.poll.vote_failed")], errorType: nil)
        }
        if let error = response.error {
            throw error
        }
        guard let data = response.data, !data.isEmpty else {
            return DiscoursePollVoteResponse()
        }
        return (try? JSONDecoder().decode(DiscoursePollVoteResponse.self, from: data)) ?? DiscoursePollVoteResponse()
    }

    /// Assign topic to a user (discourse-assign plugin). `username` nil = claim for current user when supported.
    func assignTopic(topicId: Int, username: String?) async throws {
        var parameters: Parameters = [
            "target_type": "Topic",
            "target_id": topicId,
        ]
        if let username, !username.isEmpty {
            parameters["username"] = username
        }
        try await requestVoid(route: .assignTopic, parameters: parameters)
    }

    func unassignTopic(topicId: Int) async throws {
        try await requestVoid(
            route: .unassignTopic,
            parameters: [
                "target_type": "Topic",
                "target_id": topicId,
            ]
        )
    }

    /// Best-effort read progress report. CF 403 here must NOT pause the image gate
    /// (that freezes avatars for 60s while the user is still browsing).
    func sendTopicTimings(topicId: Int, topicTime: Int, timings: [Int: Int]) async -> Int? {
        let url = baseURL + "/topics/timings"
        guard URL(string: url).map({ discourseRequestHasAuthCredentials(baseURL: baseURL, url: $0) }) == true else {
            return nil
        }
        guard topicId > 0, topicTime > 0, !timings.isEmpty else {
            return nil
        }
        // Back off after a recent CF challenge so we don't keep re-arming recovery noise.
        if Self.isTopicTimingsCoolingDown(baseURL: baseURL) {
            return nil
        }

        var parameters: Parameters = [
            "topic_id": topicId,
            "topic_time": topicTime,
        ]
        for (postNumber, milliseconds) in timings where postNumber > 0 && milliseconds > 0 {
            parameters["timings[\(postNumber)]"] = milliseconds
        }
        guard parameters.count > 2 else { return nil }

        let headers: HTTPHeaders = [
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "X-SILENCE-LOGGER": "true",
            "Discourse-Background": "true",
        ]
        let response = await session.request(
            url,
            method: .post,
            parameters: parameters,
            encoding: URLEncoding.httpBody,
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
        if let detection = Self.cloudflareChallengeDetection(response.response, data: response.data) {
            // Log only — never pause image gate / never foreground CF sheet for timings.
            Self.armTopicTimingsCooldown(baseURL: baseURL)
            DohDebugLog.record(
                "topic timings CF challenge ignored (no image gate) base=\(baseURL) \(detection.logSummary)",
                subsystem: "CF"
            )
            // Still run handle with a source that shouldPauseImageGate rejects, notify=false.
            Self.handleCloudflareChallengeDetected(
                baseURL: baseURL,
                responseURL: response.response?.url,
                source: "api.topicTimings",
                routePath: "/topics/timings",
                method: "POST",
                detection: detection,
                shouldNotify: false
            )
        }

        #if DEBUG
        if let error = response.error {
            print("[DiscourseAPI] topic timings failed: \(error)")
        } else if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            print("[DiscourseAPI] topic timings HTTP \(statusCode)")
        }
        #endif

        return response.response?.statusCode
    }

    // MARK: - Topic timings CF cooldown (best-effort path)

    nonisolated private static let topicTimingsCooldownLock = NSLock()
    nonisolated(unsafe) private static var topicTimingsCooldownUntilByBase: [String: Date] = [:]
    nonisolated private static let topicTimingsCooldownDuration: TimeInterval = 120

    nonisolated private static func normalizedTimingsBase(_ baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    nonisolated static func armTopicTimingsCooldown(baseURL: String) {
        let key = normalizedTimingsBase(baseURL)
        topicTimingsCooldownLock.lock()
        topicTimingsCooldownUntilByBase[key] = Date().addingTimeInterval(topicTimingsCooldownDuration)
        topicTimingsCooldownLock.unlock()
    }

    nonisolated static func isTopicTimingsCoolingDown(baseURL: String, now: Date = Date()) -> Bool {
        let key = normalizedTimingsBase(baseURL)
        topicTimingsCooldownLock.lock()
        defer { topicTimingsCooldownLock.unlock() }
        guard let until = topicTimingsCooldownUntilByBase[key] else { return false }
        if now < until { return true }
        topicTimingsCooldownUntilByBase.removeValue(forKey: key)
        return false
    }

    func markNotificationsRead(parameters: Parameters?) async throws {
        let url = baseURL + "/notifications/mark-read"
        let response = await session.request(url, method: .put, parameters: parameters, encoding: JSONEncoding.default)
            .serializingData()
            .response
        if let httpResponse = response.response, let responseURL = httpResponse.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: responseURL) {
            WebCookieStore.shared.mergeResponseHeaders(httpResponse.allHeaderFields, for: responseURL)
        }
        if let detection = Self.cloudflareChallengeDetection(response.response, data: response.data) {
            Self.handleCloudflareChallengeDetected(
                baseURL: baseURL,
                responseURL: response.response?.url,
                source: "api.notifications",
                routePath: "/notifications/mark-read",
                method: "PUT",
                detection: detection,
                shouldNotify: executionContext.allowsInteractiveWebRecovery
            )
            throw Self.cloudflareChallengeError()
        }
        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 429 {
                throw DiscourseAPIError(
                    messages: [String(localized: "error.rate_limited")],
                    errorType: "rate_limited"
                )
            }
            if statusCode == 403 {
                throw Self.errorFromForbiddenStatus(data: response.data)
            }
            throw DiscourseAPIError(messages: ["Failed to mark notifications read"], errorType: nil)
        }
    }

    func acceptPolicy(postId: Int) async throws {
        try await requestVoid(
            route: .acceptPolicy,
            parameters: ["post_id": postId],
            encoding: URLEncoding.httpBody
        )
    }

    func unacceptPolicy(postId: Int) async throws {
        try await requestVoid(
            route: .unacceptPolicy,
            parameters: ["post_id": postId],
            encoding: URLEncoding.httpBody
        )
    }
}
