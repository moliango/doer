import Alamofire
import Foundation
import UniformTypeIdentifiers

enum PostEditingRequest {
    static func parameters(raw: String) -> Parameters {
        let post: Parameters = ["raw": raw]
        return ["post": post]
    }
}

enum PrivateMessageFilter: Int, CaseIterable {
    case inbox
    case sent
    case archive

    var title: String {
        switch self {
        case .inbox: return String(localized: "messages.filter.inbox")
        case .sent: return String(localized: "messages.filter.sent")
        case .archive: return String(localized: "messages.filter.archive")
        }
    }
}

enum DiscourseRequestAuthMode: String {
    case none
    case cloudflareOnly = "cfOnly"
    case webCookie
}

enum DiscourseAPIExecutionContext {
    case foreground
    case backgroundRefresh

    var allowsInteractiveWebRecovery: Bool {
        self == .foreground
    }
}

func discourseRequestAuthMode(baseURL _: String, url: URL) -> DiscourseRequestAuthMode {
    if WebCookieStore.shared.hasDiscourseWebSessionCookie(for: url) {
        return .webCookie
    }
    if WebCookieStore.shared.hasCookie(named: "cf_clearance", for: url) {
        return .cloudflareOnly
    }
    return .none
}

func discourseRequestHasAuthCredentials(baseURL: String, url: URL) -> Bool {
    switch discourseRequestAuthMode(baseURL: baseURL, url: url) {
    case .webCookie:
        return true
    case .cloudflareOnly, .none:
        return false
    }
}

func shouldMergeWebCookieResponseHeaders(
    baseURL: String,
    responseURL: URL,
    statusCode: Int? = nil
) -> Bool {
    if let statusCode, !(200 ..< 300).contains(statusCode) {
        return false
    }
    return discourseRequestAuthMode(baseURL: baseURL, url: responseURL) == .webCookie
}

struct CloudflareChallengeDetection: Sendable {
    let statusCode: Int?
    let responseURL: URL?
    let server: String?
    let cfMitigated: String?
    let contentType: String?
    let reason: String

    var logSummary: String {
        var parts: [String] = []
        if let statusCode {
            parts.append("status=\(statusCode)")
        }
        if let responseURL {
            parts.append("response=\(responseURL.absoluteString)")
        }
        parts.append("reason=\(reason)")
        if let cfMitigated, !cfMitigated.isEmpty {
            parts.append("cfMitigated=\(cfMitigated)")
        }
        if let server, !server.isEmpty {
            parts.append("server=\(server)")
        }
        if let contentType, !contentType.isEmpty {
            parts.append("contentType=\(contentType)")
        }
        return parts.joined(separator: " ")
    }
}

struct DiscourseReactionToggleResponse: Decodable {
    let reactions: [DiscourseTopicDetail.Reaction]
    let reactionUsersCount: Int?
    let currentUserReaction: DiscourseTopicDetail.Reaction?

    enum CodingKeys: String, CodingKey {
        case reactions
        case reactionUsersCount = "reaction_users_count"
        case currentUserReaction = "current_user_reaction"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reactions = (try? container.decodeIfPresent([DiscourseTopicDetail.Reaction].self, forKey: .reactions)) ?? []
        reactionUsersCount = container.decodeLossyAPIInt(forKey: .reactionUsersCount)
        currentUserReaction = try? container.decodeIfPresent(
            DiscourseTopicDetail.Reaction.self,
            forKey: .currentUserReaction
        )
    }
}

struct DiscourseSharedIssueResponse: Decodable {
    let count: Int
    let userCreatedSharedIssue: Bool

    enum CodingKeys: String, CodingKey {
        case count
        case userCreatedSharedIssue = "user_created_shared_issue"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = container.decodeLossyAPIInt(forKey: .count) ?? 0
        userCreatedSharedIssue = (try? container.decodeIfPresent(Bool.self, forKey: .userCreatedSharedIssue)) ?? false
    }
}
