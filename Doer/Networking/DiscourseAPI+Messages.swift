import Alamofire
import Foundation
import UniformTypeIdentifiers

// MARK: - messages
extension DiscourseAPI {
    func fetchNotifications() async throws -> DiscourseNotificationList {
        let primary: DiscourseNotificationList = try await request(route: .notifications)
        let chat: DiscourseNotificationList
        do {
            chat = try await request(route: .chatNotifications)
        } catch {
            return primary
        }
        guard !chat.notifications.isEmpty else { return primary }
        return primary.merging(chat)
    }

    func markNotificationRead(id: Int) async throws {
        try await markNotificationsRead(parameters: ["id": id])
    }

    func markAllNotificationsRead() async throws {
        try await markNotificationsRead(parameters: nil)
    }

    func updateUserNotificationLevel(username: String, level: String, expiringAt: Date?) async throws {
        var parameters: Parameters = ["notification_level": level]
        if let expiringAt {
            parameters["expiring_at"] = ISO8601DateFormatter().string(from: expiringAt)
        }
        try await requestVoid(
            route: .userNotificationLevel(username: username),
            parameters: parameters
        )
    }

    func sendPrivateMessage(to username: String, title: String, raw: String) async throws -> DiscourseCreatePostResponse {
        try await request(
            route: .createTopic,
            parameters: [
                "archetype": "private_message",
                "target_recipients": username,
                "title": title,
                "raw": raw,
            ]
        )
    }

    func invitePrivateMessageUser(topicId: Int, username: String) async throws -> DiscourseTopicDetail.AllowedUser? {
        let response = try await performRequest(
            route: .invitePrivateMessageUser(topicId: topicId),
            parameters: ["user": username],
            encoding: URLEncoding.httpBody
        )
        guard !response.data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(DiscourseInvitePrivateMessageUserResponse.self, from: response.data))?.user
    }

    func invitePrivateMessageGroup(topicId: Int, groupName: String) async throws {
        try await requestVoid(
            route: .invitePrivateMessageGroup(topicId: topicId),
            parameters: ["group": groupName],
            encoding: URLEncoding.httpBody
        )
    }

    func removePrivateMessageUser(topicId: Int, username: String) async throws {
        try await requestVoid(
            route: .removePrivateMessageUser(topicId: topicId),
            parameters: ["username": username],
            encoding: URLEncoding.httpBody
        )
    }

    func removePrivateMessageGroup(topicId: Int, groupName: String) async throws {
        try await requestVoid(
            route: .removePrivateMessageGroup(topicId: topicId),
            parameters: ["name": groupName],
            encoding: URLEncoding.httpBody
        )
    }

    func archivePrivateMessage(topicId: Int) async throws {
        try await requestVoid(route: .archivePrivateMessage(topicId: topicId))
    }

    func movePrivateMessageToInbox(topicId: Int) async throws {
        try await requestVoid(route: .movePrivateMessageToInbox(topicId: topicId))
    }
}

private struct DiscourseInvitePrivateMessageUserResponse: Decodable {
    let user: DiscourseTopicDetail.AllowedUser?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try? container.decodeIfPresent(DiscourseTopicDetail.AllowedUser.self, forKey: .user)
    }

    private enum CodingKeys: String, CodingKey {
        case user
    }
}
