import XCTest
@testable import Doer

final class PrivateMessageParticipantsTests: XCTestCase {
    func testDecodesMembersAndPermissions() throws {
        let detail = try decodeTopic(
            details: [
                "allowed_users": [
                    [
                        "id": 7,
                        "username": "alice",
                        "name": "Alice",
                        "avatar_template": "/user_avatar/alice/{size}/1.png",
                    ],
                    [
                        "id": 8,
                        "username": "bob",
                        "avatar_template": "/user_avatar/bob/{size}/1.png",
                    ],
                ],
                "can_remove_allowed_users": true,
                "can_remove_self_id": 7,
            ]
        )

        XCTAssertTrue(detail.isPrivateMessage)
        XCTAssertEqual(detail.allowedUsers.map(\.username), ["alice", "bob"])
        XCTAssertEqual(detail.allowedUsers.first?.displayName, "Alice")
        XCTAssertTrue(detail.canRemoveAllowedUsers)
        XCTAssertEqual(detail.canRemoveSelfId, 7)
    }

    func testDecodesGroupsAndInvite() throws {
        let detail = try decodeTopic(
            details: [
                "allowed_users": [] as [Any],
                "allowed_groups": [
                    ["id": 9, "name": "staff", "full_name": "管理组", "user_count": 12],
                    ["name": "moderators"],
                ],
                "can_invite_to": true,
            ]
        )

        XCTAssertEqual(detail.allowedGroups.count, 2)
        XCTAssertEqual(detail.allowedGroups.first?.id, 9)
        XCTAssertEqual(detail.allowedGroups.first?.displayName, "管理组")
        XCTAssertNil(detail.allowedGroups.last?.id)
        XCTAssertEqual(detail.allowedGroups.last?.displayName, "moderators")
        XCTAssertTrue(detail.canInviteTo)
    }

    func testDecodesArchiveFlagOnTopicRoot() throws {
        var archived = try decodeTopic(extra: ["message_archived": true])
        XCTAssertTrue(archived.messageArchived)
        archived.setMessageArchived(false)
        XCTAssertFalse(archived.messageArchived)

        let plain = try decodeTopic()
        XCTAssertFalse(plain.messageArchived)
    }

    func testRegularTopicDefaultsAreSafe() throws {
        let detail = try decodeTopic(archetype: "regular")
        XCTAssertFalse(detail.isPrivateMessage)
        XCTAssertTrue(detail.allowedUsers.isEmpty)
        XCTAssertTrue(detail.allowedGroups.isEmpty)
        XCTAssertFalse(detail.canRemoveAllowedUsers)
        XCTAssertNil(detail.canRemoveSelfId)
        XCTAssertFalse(detail.canInviteTo)
    }

    func testMutationsUpdateLocalMemberLists() throws {
        var detail = try decodeTopic(
            details: [
                "allowed_users": [
                    ["id": 7, "username": "alice", "avatar_template": ""],
                    ["id": 8, "username": "bob", "avatar_template": ""],
                ],
                "allowed_groups": [
                    ["name": "staff"],
                ],
                "can_remove_self_id": 7,
            ]
        )
        detail.removeAllowedUser(id: 7)
        XCTAssertEqual(detail.allowedUsers.map(\.username), ["bob"])
        XCTAssertNil(detail.canRemoveSelfId)

        detail.removeAllowedGroup(named: "STAFF")
        XCTAssertTrue(detail.allowedGroups.isEmpty)

        detail.addAllowedUser(.init(id: 9, username: "cara", name: nil, avatarTemplate: nil))
        detail.addAllowedGroup(.init(name: "moderators"))
        XCTAssertEqual(detail.allowedUsers.last?.username, "cara")
        XCTAssertEqual(detail.allowedGroups.last?.name, "moderators")
    }

    func testPanelVisibilityMatchesDiscourseTopicMap() {
        XCTAssertTrue(
            PrivateMessageParticipantsPolicy.shouldShow(
                isPrivateMessage: true,
                userCount: 0,
                groupCount: 1
            )
        )
        XCTAssertFalse(
            PrivateMessageParticipantsPolicy.shouldShow(
                isPrivateMessage: true,
                userCount: 0,
                groupCount: 0
            )
        )
        XCTAssertFalse(
            PrivateMessageParticipantsPolicy.shouldShowAtBottom(
                isPrivateMessage: true,
                postsCount: 3,
                userCount: 2,
                groupCount: 0
            )
        )
        XCTAssertTrue(
            PrivateMessageParticipantsPolicy.shouldShowAtBottom(
                isPrivateMessage: true,
                postsCount: 4,
                userCount: 2,
                groupCount: 0
            )
        )
        XCTAssertTrue(
            PrivateMessageParticipantsPolicy.canRemoveUser(
                userId: 7,
                canRemoveAllowedUsers: false,
                canRemoveSelfId: 7
            )
        )
        XCTAssertFalse(
            PrivateMessageParticipantsPolicy.canRemoveGroup(canRemoveAllowedUsers: false)
        )
    }

    func testUserSearchDecodesGroups() throws {
        let json = """
        {
          "users": [{"username": "alice", "name": "Alice"}],
          "groups": [{"name": "staff", "full_name": "Staff"}]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DiscourseUserSearchResponse.self, from: json)
        XCTAssertEqual(decoded.users.map(\.username), ["alice"])
        XCTAssertEqual(decoded.groups.map(\.name), ["staff"])
        XCTAssertEqual(decoded.groups.first?.displayName, "Staff")
    }

    private func decodeTopic(
        archetype: String = "private_message",
        extra: [String: Any] = [:],
        details: [String: Any] = [:]
    ) throws -> DiscourseTopicDetail {
        var payload: [String: Any] = [
            "id": 42,
            "title": "Private message",
            "posts_count": 1,
            "reply_count": 0,
            "views": 1,
            "created_at": "2026-09-07T00:00:00.000Z",
            "post_stream": [
                "posts": [] as [Any],
                "stream": [] as [Any],
            ],
            "archetype": archetype,
            "details": details,
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(DiscourseTopicDetail.self, from: data)
    }
}
