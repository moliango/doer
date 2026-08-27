import Foundation

enum NewAPICheckInStatus: String, Codable, CaseIterable, Sendable {
    case success
    case alreadySigned = "already_signed"
    case authenticationExpired = "authentication_expired"
    case serverError = "server_error"
    case unknown
}

enum NewAPICheckInPlatformType: String, Codable, Sendable {
    case newAPI = "newapi"
    case custom
}

enum NewAPICheckInPlatformSource: String, Codable, Sendable {
    case webView = "webview"
    case curl
    case manual
}

struct NewAPICheckInCredential: Equatable, Codable, Sendable {
    var accessToken: String?
    var userID: String?
    var cookieHeader: String?
    var additionalHeaders: [String: String]

    nonisolated init(
        accessToken: String? = nil,
        userID: String? = nil,
        cookieHeader: String? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        self.accessToken = accessToken
        self.userID = userID
        self.cookieHeader = cookieHeader
        self.additionalHeaders = additionalHeaders
    }

    nonisolated var hasUsableSession: Bool {
        let token = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cookie = cookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !token.isEmpty || !cookie.isEmpty
    }
}

enum NewAPICheckInAuthRefreshResult: Sendable {
    case refreshed
    case unavailable
    case rejected(String?)
    case failed(String?)

    nonisolated var isRefreshed: Bool {
        if case .refreshed = self { return true }
        return false
    }

    /// Open the login page only when the server rejected the session, or when
    /// there is nothing stored to sign in with. Missing `/auth/refresh` must
    /// not send the user through web login again after they just signed in.
    nonisolated func requiresInteractiveLogin(hasUsableCredential: Bool) -> Bool {
        switch self {
        case .refreshed:
            return false
        case .rejected:
            return true
        case .unavailable, .failed:
            return !hasUsableCredential
        }
    }
}

struct NewAPICheckInLoginHints: Equatable, Sendable {
    let userID: String?
    let accessToken: String?
}

struct NewAPICheckInLoginProbeResult: Equatable, Sendable {
    let isLoggedIn: Bool
    let userID: String?
    let accessToken: String?
    let quotaValue: Int64?
    let quotaUnit: String?
    /// Lifetime consumed tokens from `/api/user/self` (`used_quota`).
    let usedQuota: Int64?
    /// Lifetime request count from `/api/user/self` (`request_count`).
    let requestCount: Int?
    let message: String?

    nonisolated init(
        isLoggedIn: Bool,
        userID: String?,
        accessToken: String?,
        quotaValue: Int64?,
        quotaUnit: String?,
        usedQuota: Int64? = nil,
        requestCount: Int? = nil,
        message: String?
    ) {
        self.isLoggedIn = isLoggedIn
        self.userID = userID
        self.accessToken = accessToken
        self.quotaValue = quotaValue
        self.quotaUnit = quotaUnit
        self.usedQuota = usedQuota
        self.requestCount = requestCount
        self.message = message
    }
}

struct NewAPICheckInPlatform: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var endpoint: String
    var method: String
    var body: String?
    var platformType: NewAPICheckInPlatformType?
    var source: NewAPICheckInPlatformSource?
    /// Opt-in because interactive Web login cannot run from background intents.
    var reloginBeforeSignIn: Bool?
    var createdAt: Date
    var updatedAt: Date
    var lastStatus: NewAPICheckInStatus?
    var lastAttemptAt: Date?
    var lastMessage: String?
    var lastQuotaValue: Int64?
    var lastQuotaUnit: String?

    nonisolated init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        endpoint: String = "/api/user/checkin",
        method: String = "POST",
        body: String? = "{}",
        platformType: NewAPICheckInPlatformType? = .newAPI,
        source: NewAPICheckInPlatformSource? = .webView,
        reloginBeforeSignIn: Bool? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastStatus: NewAPICheckInStatus? = nil,
        lastAttemptAt: Date? = nil,
        lastMessage: String? = nil,
        lastQuotaValue: Int64? = nil,
        lastQuotaUnit: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.endpoint = endpoint
        self.method = method
        self.body = body
        self.platformType = platformType
        self.source = source
        self.reloginBeforeSignIn = reloginBeforeSignIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastStatus = lastStatus
        self.lastAttemptAt = lastAttemptAt
        self.lastMessage = lastMessage
        self.lastQuotaValue = lastQuotaValue
        self.lastQuotaUnit = lastQuotaUnit
    }

    nonisolated var requiresReloginBeforeSignIn: Bool {
        reloginBeforeSignIn == true
    }
}

struct NewAPICheckInResult: Equatable, Sendable {
    let status: NewAPICheckInStatus
    let statusCode: Int?
    let message: String?
    let rawResponse: String?
    let durationMilliseconds: Int
    let quotaValue: Int64?
    let quotaUnit: String?
}

struct NewAPICheckInAttempt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let platformID: UUID
    let attemptedAt: Date
    let status: NewAPICheckInStatus
    let statusCode: Int?
    let message: String?
    let rawResponse: String?
    let durationMilliseconds: Int

    nonisolated init(
        id: UUID = UUID(),
        platformID: UUID,
        attemptedAt: Date = Date(),
        result: NewAPICheckInResult
    ) {
        self.id = id
        self.platformID = platformID
        self.attemptedAt = attemptedAt
        self.status = result.status
        self.statusCode = result.statusCode
        self.message = result.message
        self.rawResponse = result.rawResponse
        self.durationMilliseconds = result.durationMilliseconds
    }
}

struct NewAPICheckInBatchSummary: Equatable, Sendable {
    var total = 0
    var success = 0
    var alreadySigned = 0
    var authenticationExpired = 0
    var failed = 0

    nonisolated mutating func record(_ status: NewAPICheckInStatus) {
        switch status {
        case .success: success += 1
        case .alreadySigned: alreadySigned += 1
        case .authenticationExpired: authenticationExpired += 1
        case .serverError, .unknown: failed += 1
        }
    }

    var localizedSummary: String {
        guard total > 0 else {
            return String(localized: "plugins.newapi.empty", defaultValue: "还没有配置 NewAPI 平台")
        }
        var parts = [String(format: String(localized: "plugins.newapi.summary.total", defaultValue: "共 %d 个平台"), total)]
        if success > 0 { parts.append("\(success) 成功") }
        if alreadySigned > 0 { parts.append("\(alreadySigned) 已签到") }
        if authenticationExpired > 0 { parts.append("\(authenticationExpired) 需重新登录") }
        if failed > 0 { parts.append("\(failed) 失败") }
        return parts.joined(separator: " · ")
    }
}

struct NewAPICheckInExportPayload: Codable, Equatable, Sendable {
    var version: Int
    var accounts: [Account]
    var customPages: [NewAPICheckInCustomPage]

    struct Account: Codable, Equatable, Sendable {
        var scopeKey: String
        var platforms: [NewAPICheckInPlatform]
        var attempts: [NewAPICheckInAttempt]
        /// Keyed by platform UUID string.
        var credentials: [String: NewAPICheckInCredential]
    }
}
