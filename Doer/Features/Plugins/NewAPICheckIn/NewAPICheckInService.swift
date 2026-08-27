import Foundation

actor NewAPICheckInService {
    private let store: NewAPICheckInStore
    private let session: URLSession

    init(store: NewAPICheckInStore, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    func signIn(_ platform: NewAPICheckInPlatform) async -> NewAPICheckInResult {
        let startedAt = Date()
        let credential = try? await store.credential(for: platform.id)
        guard let request = Self.buildRequest(platform: platform, credential: credential) else {
            let result = NewAPICheckInResult(
                status: .unknown,
                statusCode: nil,
                message: String(localized: "plugins.newapi.invalid_request", defaultValue: "无法构造签到请求"),
                rawResponse: nil,
                durationMilliseconds: milliseconds(since: startedAt),
                quotaValue: nil,
                quotaUnit: nil
            )
            try? await store.record(result, for: platform.id)
            return result
        }

        let result: NewAPICheckInResult
        do {
            let (data, response) = try await session.data(for: request)
            result = Self.classify(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode,
                durationMilliseconds: milliseconds(since: startedAt)
            )
        } catch {
            result = NewAPICheckInResult(
                status: .serverError,
                statusCode: nil,
                message: error.localizedDescription,
                rawResponse: nil,
                durationMilliseconds: milliseconds(since: startedAt),
                quotaValue: nil,
                quotaUnit: nil
            )
        }
        try? await store.record(result, for: platform.id)
        return result
    }

    func refreshAuthentication(
        _ platform: NewAPICheckInPlatform,
        cookieHeaderOverride: String? = nil
    ) async -> NewAPICheckInAuthRefreshResult {
        guard (platform.platformType ?? .newAPI) == .newAPI,
              let baseURL = URL(string: platform.baseURL)
        else {
            return .unavailable
        }
        let credential = (try? await store.credential(for: platform.id))
            ?? NewAPICheckInCredential()
        guard let cookieHeader = cookieHeaderOverride ?? credential.cookieHeader,
              Self.cookieValue(named: "new_api_refresh", in: cookieHeader) != nil,
              let request = Self.buildAuthRefreshRequest(baseURL: baseURL, cookieHeader: cookieHeader)
        else {
            return .unavailable
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return .failed(nil)
            }
            if response.statusCode == 404 || response.statusCode == 405 {
                return .unavailable
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = Self.extractMessage(json)
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
                    return .rejected(message)
                }
                return .failed(message)
            }
            guard (json?["success"] as? Bool) == true,
                  let values = json?["data"] as? [String: Any],
                  let accessToken = values["access_token"] as? String,
                  !accessToken.isEmpty
            else {
                return .rejected(message)
            }

            let responseCookies = Self.responseCookies(
                from: response.allHeaderFields,
                for: baseURL
            )
            let refreshedCredential = NewAPICheckInCredential(
                accessToken: accessToken,
                userID: Self.refreshUserID(from: values) ?? credential.userID,
                cookieHeader: Self.mergingCookieHeader(cookieHeader, with: responseCookies),
                additionalHeaders: credential.additionalHeaders
            )
            try await store.updateExisting(platformID: platform.id, credential: refreshedCredential) { _ in }
            return .refreshed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func needsInteractiveRelogin(for platform: NewAPICheckInPlatform) async -> Bool {
        guard platform.requiresReloginBeforeSignIn else { return false }
        let refresh = await refreshAuthentication(platform)
        let credential = try? await store.credential(for: platform.id)
        return refresh.requiresInteractiveLogin(hasUsableCredential: credential?.hasUsableSession == true)
    }

    private func signInWithoutInteractiveRelogin(
        _ platform: NewAPICheckInPlatform
    ) async -> NewAPICheckInResult {
        if await needsInteractiveRelogin(for: platform) {
            let result = NewAPICheckInResult(
                status: .authenticationExpired,
                statusCode: nil,
                message: String(
                    localized: "plugins.newapi.relogin_required_in_app",
                    defaultValue: "需要先在 Doer 内重新登录后签到"
                ),
                rawResponse: nil,
                durationMilliseconds: 0,
                quotaValue: nil,
                quotaUnit: nil
            )
            try? await store.record(result, for: platform.id)
            return result
        }
        return await signIn(platform)
    }

    func signInAll(maxConcurrent: Int = 3) async -> NewAPICheckInBatchSummary {
        let platforms = await store.platforms()
        var summary = NewAPICheckInBatchSummary(total: platforms.count)
        guard !platforms.isEmpty else { return summary }

        await withTaskGroup(of: NewAPICheckInStatus.self) { group in
            var nextIndex = 0
            let concurrency = max(1, min(maxConcurrent, platforms.count))
            for _ in 0..<concurrency {
                let platform = platforms[nextIndex]
                nextIndex += 1
                group.addTask { await self.signInWithoutInteractiveRelogin(platform).status }
            }
            while let status = await group.next() {
                summary.record(status)
                if nextIndex < platforms.count {
                    let platform = platforms[nextIndex]
                    nextIndex += 1
                    group.addTask { await self.signInWithoutInteractiveRelogin(platform).status }
                }
            }
        }
        return summary
    }

    func refreshAccount(_ platform: NewAPICheckInPlatform) async -> NewAPICheckInLoginProbeResult {
        guard let baseURL = URL(string: platform.baseURL) else {
            return NewAPICheckInLoginProbeResult(
                isLoggedIn: false,
                userID: nil,
                accessToken: nil,
                quotaValue: nil,
                quotaUnit: nil,
                message: String(localized: "plugins.newapi.invalid_url", defaultValue: "平台地址无效")
            )
        }
        let credential = try? await store.credential(for: platform.id)
        let result = await probeLogin(
            baseURL: baseURL,
            cookieHeader: credential?.cookieHeader,
            hints: NewAPICheckInLoginHints(
                userID: credential?.userID,
                accessToken: credential?.accessToken
            )
        )
        if result.isLoggedIn, let quotaValue = result.quotaValue {
            try? await store.updateExisting(platformID: platform.id) { updated in
                updated.lastQuotaValue = quotaValue
                updated.lastQuotaUnit = result.quotaUnit
            }
        }
        return result
    }

    func probeLogin(
        baseURL: URL,
        cookieHeader: String?,
        hints: NewAPICheckInLoginHints
    ) async -> NewAPICheckInLoginProbeResult {
        guard let request = Self.buildLoginProbeRequest(
            baseURL: baseURL,
            cookieHeader: cookieHeader,
            hints: hints
        ) else {
            return NewAPICheckInLoginProbeResult(
                isLoggedIn: false,
                userID: nil,
                accessToken: nil,
                quotaValue: nil,
                quotaUnit: nil,
                message: String(localized: "plugins.newapi.invalid_url", defaultValue: "平台地址无效")
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            return Self.parseLoginProbeResponse(
                data: data,
                statusCode: (response as? HTTPURLResponse)?.statusCode,
                hints: hints
            )
        } catch {
            return NewAPICheckInLoginProbeResult(
                isLoggedIn: false,
                userID: nil,
                accessToken: nil,
                quotaValue: nil,
                quotaUnit: nil,
                message: error.localizedDescription
            )
        }
    }

    nonisolated static func buildAuthRefreshRequest(
        baseURL: URL,
        cookieHeader: String
    ) -> URLRequest? {
        guard let url = URL(string: "/api/user/auth/refresh", relativeTo: baseURL)?.absoluteURL,
              let originURL = NewAPICheckInLoginSupport.siteOrigin(from: baseURL)
        else { return nil }
        let rawOrigin = originURL.absoluteString
        let origin = rawOrigin.hasSuffix("/") ? String(rawOrigin.dropLast()) : rawOrigin
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated private static func responseCookies(
        from headers: [AnyHashable: Any],
        for url: URL
    ) -> [HTTPCookie] {
        headers.flatMap { key, value -> [HTTPCookie] in
            guard String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                return []
            }
            let values = value as? [String] ?? [String(describing: value)]
            return values.flatMap { header in
                HTTPCookie.cookies(
                    withResponseHeaderFields: ["Set-Cookie": header],
                    for: url
                )
            }
        }
    }

    nonisolated static func mergingCookieHeader(
        _ existingHeader: String,
        with responseCookies: [HTTPCookie]
    ) -> String {
        var pairs = cookiePairs(in: existingHeader)
        for cookie in responseCookies {
            pairs.removeAll { $0.name == cookie.name }
            if cookie.expiresDate.map({ $0 > Date() }) ?? true, !cookie.value.isEmpty {
                pairs.append((cookie.name, cookie.value))
            }
        }
        return pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    nonisolated static func cookieValue(named name: String, in header: String) -> String? {
        cookiePairs(in: header).first(where: { $0.name == name })?.value
    }

    nonisolated private static func cookiePairs(in header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { component in
            let pair = component.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return (name, String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    nonisolated private static func refreshUserID(from values: [String: Any]) -> String? {
        let user = values["user"] as? [String: Any]
        let value = user?["id"] ?? values["id"]
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? Int { return String(value) }
        if let value = value as? Int64 { return String(value) }
        return nil
    }

    nonisolated static func buildLoginProbeRequest(
        baseURL: URL,
        cookieHeader: String?,
        hints: NewAPICheckInLoginHints
    ) -> URLRequest? {
        guard let url = URL(string: "/api/user/self", relativeTo: baseURL)?.absoluteURL else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let userID = hints.userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "New-Api-User")
        }
        if let accessToken = hints.accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    nonisolated static func parseLoginProbeResponse(
        data: Data,
        statusCode: Int?,
        hints: NewAPICheckInLoginHints
    ) -> NewAPICheckInLoginProbeResult {
        guard statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return NewAPICheckInLoginProbeResult(
                isLoggedIn: false,
                userID: nil,
                accessToken: nil,
                quotaValue: nil,
                quotaUnit: nil,
                message: nil
            )
        }
        let success = (json["success"] as? Bool) == true || (json["code"] as? Int) == 0
        guard success else {
            return NewAPICheckInLoginProbeResult(
                isLoggedIn: false,
                userID: nil,
                accessToken: nil,
                quotaValue: nil,
                quotaUnit: nil,
                message: extractMessage(json)
            )
        }
        let values = json["data"] as? [String: Any] ?? [:]
        let userID: String? = {
            if let value = values["id"] as? String, !value.isEmpty { return value }
            if let value = values["id"] as? Int { return String(value) }
            if let value = values["id"] as? Int64 { return String(value) }
            return hints.userID
        }()
        let accessToken = [
            values["access_token"] as? String,
            values["accessToken"] as? String,
            hints.accessToken,
        ]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
        let quota = extractQuota(json)
        return NewAPICheckInLoginProbeResult(
            isLoggedIn: true,
            userID: userID,
            accessToken: accessToken,
            quotaValue: quota?.0,
            quotaUnit: quota?.1,
            usedQuota: extractInt64(values, keys: ["used_quota", "usedQuota"]),
            requestCount: extractInt(values, keys: ["request_count", "requestCount", "count"]),
            message: extractMessage(json)
        )
    }

    nonisolated private static func extractInt64(_ dict: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let v = dict[key] as? Int64 { return v }
            if let v = dict[key] as? Int { return Int64(v) }
            if let v = dict[key] as? Double { return Int64(v) }
            if let s = dict[key] as? String, let v = Int64(s) { return v }
        }
        return nil
    }

    nonisolated private static func extractInt(_ dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let v = dict[key] as? Int { return v }
            if let v = dict[key] as? Int64 { return Int(v) }
            if let v = dict[key] as? Double { return Int(v) }
            if let s = dict[key] as? String, let v = Int(s) { return v }
        }
        return nil
    }

    nonisolated static func buildRequest(
        platform: NewAPICheckInPlatform,
        credential: NewAPICheckInCredential?
    ) -> URLRequest? {
        guard let baseURL = URL(string: platform.baseURL) else { return nil }
        let url: URL?
        if let absoluteURL = URL(string: platform.endpoint), absoluteURL.scheme != nil {
            url = absoluteURL
        } else {
            url = URL(string: platform.endpoint, relativeTo: baseURL)?.absoluteURL
        }
        guard let url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = platform.method.uppercased()
        request.timeoutInterval = 30
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let body = platform.body, !body.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        if let accessToken = credential?.accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userID = credential?.userID, !userID.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "New-Api-User")
        }
        if let cookieHeader = credential?.cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        credential?.additionalHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    nonisolated static func classify(
        data: Data,
        statusCode: Int?,
        durationMilliseconds: Int
    ) -> NewAPICheckInResult {
        let raw = String(data: data, encoding: .utf8)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = extractMessage(json)
        let lowered = message?.lowercased() ?? ""

        if statusCode == 401 || statusCode == 403 || containsAny(lowered, values: ["未登录", "请先登录", "unauthorized", "login required"]) {
            return result(.authenticationExpired, statusCode, message, raw, durationMilliseconds, nil)
        }
        if let statusCode, statusCode >= 500 {
            return result(.serverError, statusCode, message ?? "HTTP \(statusCode)", raw, durationMilliseconds, nil)
        }
        if containsAny(lowered, values: ["已签到", "已经签到", "重复签到", "already"]) {
            return result(.alreadySigned, statusCode, message, raw, durationMilliseconds, nil)
        }
        let success = (json?["success"] as? Bool) == true
            || (json?["code"] as? Int) == 0
            || lowered.contains("成功")
            || lowered.contains("success")
        let quota = extractQuota(json)
        if success {
            return result(.success, statusCode, message ?? "签到成功", raw, durationMilliseconds, quota)
        }
        return result(.unknown, statusCode, message, raw, durationMilliseconds, nil)
    }

    nonisolated private static func result(
        _ status: NewAPICheckInStatus,
        _ statusCode: Int?,
        _ message: String?,
        _ raw: String?,
        _ duration: Int,
        _ quota: (Int64, String)?
    ) -> NewAPICheckInResult {
        NewAPICheckInResult(
            status: status,
            statusCode: statusCode,
            message: message,
            rawResponse: raw,
            durationMilliseconds: duration,
            quotaValue: quota?.0,
            quotaUnit: quota?.1
        )
    }

    nonisolated private static func extractMessage(_ json: [String: Any]?) -> String? {
        for key in ["message", "msg", "error", "error_message"] {
            if let value = json?[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    nonisolated private static func containsAny(_ value: String, values: [String]) -> Bool {
        values.contains { value.contains($0.lowercased()) }
    }

    nonisolated static func extractQuota(_ json: [String: Any]?) -> (Int64, String)? {
        let values = (json?["data"] as? [String: Any]) ?? json ?? [:]
        for key in ["quota", "credit", "balance", "remain_quota"] {
            if let value = values[key] as? Int64 { return (value, key) }
            if let value = values[key] as? Int { return (Int64(value), key) }
            if let value = values[key] as? Double { return (Int64(value), key) }
            if let value = values[key] as? String, let number = Int64(value) { return (number, key) }
        }
        return nil
    }

    nonisolated private func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}
