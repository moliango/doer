import Alamofire
import Foundation

import UniformTypeIdentifiers

// MARK: - topics
extension DiscourseAPI {
    func fetchLatestTopics(page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .latestTopics(page: page))
    }

    /// 后台刷新用：同时拿到解码结果与原始 JSON（原始数据写入话题列表缓存，
    /// 供首页冷启动/空列表时立即渲染）。

    func fetchLatestTopicsWithRawData(page: Int = 0) async throws -> (list: DiscourseTopicList, rawData: Data) {
        let response = try await performRequest(route: .latestTopics(page: page))
        do {
            let list = try JSONDecoder().decode(DiscourseTopicList.self, from: response.data)
            return (list, response.data)
        } catch {
            throw DiscourseDecodingError(
                route: .latestTopics(page: page),
                url: response.url,
                statusCode: response.statusCode,
                underlying: error,
                bodyPreview: Self.bodyPreview(from: response.data)
            )
        }
    }

    func fetchTopicsByIds(_ ids: [Int]) async throws -> DiscourseTopicList {
        try await request(route: .topicsByIds(ids))
    }

    func fetchNewTopics(page: Int = 0, subset: String? = nil) async throws -> DiscourseTopicList {
        try await request(route: .newTopics(page: page, subset: subset))
    }

    func fetchUnreadTopics(page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .unreadTopics(page: page))
    }

    func fetchReadTopics(page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .readTopics(page: page))
    }

    func fetchHotTopics(page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .hotTopics(page: page))
    }

    func fetchTopTopics(page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .topTopics(page: page))
    }

    func fetchCategories() async throws -> DiscourseCategoryList {
        try await request(route: .categories)
    }

    func fetchCategoryTopics(slug: String, id: Int, page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .categoryTopics(slug: slug, id: id, page: page))
    }

    func fetchCategoryTopics(slug: String, id: Int, filter: String, page: Int = 0, subset: String? = nil) async throws -> DiscourseTopicList {
        try await request(route: .categoryFilteredTopics(slug: slug, id: id, filter: filter, page: page, subset: subset))
    }

    func fetchTagTopics(name: String, page: Int = 0) async throws -> DiscourseTopicList {
        try await request(route: .tagTopics(name: name, page: page))
    }

    func fetchSiteInfo() async throws -> DiscourseSiteInfo {
        try await request(route: .siteInfo)
    }

    func fetchSiteCategories() async throws -> [DiscourseCategory] {
        let info: DiscourseSiteCategoryInfo = try await request(route: .siteInfo)
        return info.categories ?? []
    }

    func fetchBasicInfo() async throws -> DiscourseBasicInfo {
        try await request(route: .basicInfo)
    }

    func fetchPrivateMessages(username: String) async throws -> DiscourseTopicList {
        try await request(route: .privateMessages(username: username))
    }

    func fetchPrivateMessages(username: String, filter: PrivateMessageFilter) async throws -> DiscourseTopicList {
        switch filter {
        case .inbox:
            return try await request(route: .privateMessages(username: username))
        case .sent:
            return try await request(route: .privateMessagesSent(username: username))
        case .archive:
            return try await request(route: .privateMessagesArchive(username: username))
        }
    }

    /// First-post cooked HTML for list long-press preview (FluxDo `getTopicFirstPostCooked`).
    func fetchTopicFirstPostCooked(id: Int) async throws -> String? {
        let detail = try await fetchTopic(id: id, trackVisit: false)
        return detail.postStream.posts.first?.cooked
    }

    func fetchTopic(id: Int, trackVisit: Bool = false) async throws -> DiscourseTopicDetail {
        var headers: HTTPHeaders?
        if trackVisit {
            headers = [
                "Discourse-Track-View": "1",
                "Discourse-Track-View-Topic-Id": "\(id)",
            ]
        }
        let detail: DiscourseTopicDetail = try await request(
            route: .topic(id: id, trackVisit: trackVisit),
            headers: headers
        )
        // Successful topic JSON means the main forum zone is healthy — lift a
        // stale image-gate pause left by best-effort POSTs (e.g. timings CF blip).
        CloudflareImageGate.resume(baseURL: baseURL)
        return detail
    }

    func fetchTopicPosts(topicId: Int, postIds: [Int]) async throws -> DiscourseTopicPostsResponse {
        try await request(route: .topicPosts(topicId: topicId, postIds: postIds))
    }

    func fetchPostReplies(postId: Int) async throws -> [DiscourseTopicDetail.Post] {
        try await request(route: .postReplies(postId: postId))
    }

    func fetchPost(id: Int) async throws -> DiscourseTopicDetail.Post {
        try await fetchPostResponse(route: .post(id: id))
    }

    /// Resolves a Discourse `post_number` (URL/notification floor) to the post payload.
    func fetchPostByNumber(topicId: Int, postNumber: Int) async throws -> DiscourseTopicDetail.Post {
        try await fetchPostResponse(route: .postByNumber(topicId: topicId, postNumber: postNumber))
    }

    private func fetchPostResponse(route: DiscourseRouter) async throws -> DiscourseTopicDetail.Post {
        let response = try await performRequest(route: route)
        let decoder = JSONDecoder()
        if let wrapped = try? decoder.decode(DiscoursePostResponse.self, from: response.data) {
            return wrapped.post
        }
        do {
            return try decoder.decode(DiscourseTopicDetail.Post.self, from: response.data)
        } catch {
            throw DiscourseDecodingError(
                route: route,
                url: response.url,
                statusCode: response.statusCode,
                underlying: error,
                bodyPreview: Self.bodyPreview(from: response.data)
            )
        }
    }

    func updatePost(id: Int, raw: String) async throws {
        try await requestVoid(
            route: .updatePost(id: id),
            parameters: PostEditingRequest.parameters(raw: raw)
        )
    }

    func searchTopic(topicId: Int, term: String, page: Int = 0) async throws -> DiscourseSearchResult {
        let query = "\(term.trimmingCharacters(in: .whitespacesAndNewlines)) topic:\(topicId)"
        return try await search(term: query, page: page)
    }

    func fetchTags() async throws -> DiscourseTagList {
        try await request(route: .tags)
    }

    /// 侧栏标签区：保留 /tags.json 的 extras.tag_groups 分组结构。

    func fetchSiteTagGroups() async throws -> [DiscourseSiteTagGroup] {
        try await fetchTags().tagGroups
    }

    func searchTags(query: String = "", categoryId: Int? = nil) async throws -> [DiscourseTag] {
        struct TagSearchResponse: Decodable {
            let results: [TagSearchItem]
            struct TagSearchItem: Decodable {
                let name: String
                let count: Int?
            }
        }
        let response: TagSearchResponse = try await request(route: .tagSearch(query: query, categoryId: categoryId))
        return response.results.map { DiscourseTag(text: $0.name, count: $0.count ?? 0) }
    }

    @discardableResult
    func toggleSharedIssue(topicId: Int) async throws -> DiscourseSharedIssueResponse {
        let route = DiscourseRouter.toggleSharedIssue
        let url = baseURL + route.path
        let parameters: Parameters = ["topic_id": topicId]
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
                throw DiscourseAPIError(messages: [String(localized: "shared_issue.rate_limited")], errorType: "rate_limited")
            }
            if let data = response.data,
               let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
               !errBody.errors.isEmpty {
                throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
            }
            throw DiscourseAPIError(messages: [String(localized: "post.action.failed")], errorType: nil)
        }

        guard let data = response.data, !data.isEmpty else {
            throw DiscourseAPIError(messages: [String(localized: "post.action.failed")], errorType: nil)
        }

        do {
            return try JSONDecoder().decode(DiscourseSharedIssueResponse.self, from: data)
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

    func fetchPostRevision(postId: Int, revision: String = "latest") async throws -> DiscoursePostRevision {
        try await request(route: .postRevision(postId: postId, revision: revision))
    }

    // MARK: - Nested / tree view (FluxDo /n/topic)

    func fetchNestedRoots(
        topicId: Int,
        sort: String = "old",
        page: Int = 0,
        trackVisit: Bool = false
    ) async throws -> DiscourseNestedRootsResponse {
        try await request(
            route: .nestedTopicRoots(
                topicId: topicId,
                sort: sort,
                page: page,
                trackVisit: trackVisit
            )
        )
    }

    func fetchNestedChildren(
        topicId: Int,
        postNumber: Int,
        sort: String = "old",
        page: Int = 0,
        depth: Int = 1
    ) async throws -> DiscourseNestedChildrenResponse {
        try await request(
            route: .nestedTopicChildren(
                topicId: topicId,
                postNumber: postNumber,
                sort: sort,
                page: page,
                depth: depth
            )
        )
    }
}
