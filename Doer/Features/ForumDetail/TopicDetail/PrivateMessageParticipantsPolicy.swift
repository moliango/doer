import Foundation

enum PrivateMessageParticipantsPolicy {
    /// Discourse `showBottomTopicMap` uses posts_count > 3.
    static let minPostsCountForBottomPanel = 3

    static func shouldShow(
        isPrivateMessage: Bool,
        userCount: Int,
        groupCount: Int
    ) -> Bool {
        isPrivateMessage && (userCount + groupCount) > 0
    }

    static func shouldShowAtBottom(
        isPrivateMessage: Bool,
        postsCount: Int,
        userCount: Int,
        groupCount: Int
    ) -> Bool {
        shouldShow(isPrivateMessage: isPrivateMessage, userCount: userCount, groupCount: groupCount)
            && postsCount > minPostsCountForBottomPanel
    }

    static func canRemoveUser(
        userId: Int,
        canRemoveAllowedUsers: Bool,
        canRemoveSelfId: Int?
    ) -> Bool {
        canRemoveAllowedUsers || userId == canRemoveSelfId
    }

    static func canRemoveGroup(canRemoveAllowedUsers: Bool) -> Bool {
        canRemoveAllowedUsers
    }

    static func isSelf(userId: Int, canRemoveSelfId: Int?) -> Bool {
        userId == canRemoveSelfId
    }
}
