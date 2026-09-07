import UIKit

@MainActor
enum PrivateMessageParticipantsFlow {
    static func presentInvite(
        from host: UIViewController,
        api: DiscourseAPI,
        viewModel: TopicDetailViewModel
    ) {
        guard viewModel.topic?.isPrivateMessage == true, viewModel.topic?.canInviteTo == true else { return }
        let invite = PrivateMessageInviteViewController(api: api)
        invite.onConfirm = { selection in
            Task { await submitInvite(selection, api: api, viewModel: viewModel, host: host) }
        }
        host.present(UINavigationController(rootViewController: invite), animated: true)
    }

    static func confirmRemoveUser(
        _ user: DiscourseTopicDetail.AllowedUser,
        from host: UIViewController,
        api: DiscourseAPI,
        viewModel: TopicDetailViewModel,
        topicId: Int,
        setRemovingUserId: @escaping (Int?) -> Void,
        onLeave: @escaping () -> Void
    ) {
        guard let topic = viewModel.topic, topic.isPrivateMessage else { return }
        let isSelf = PrivateMessageParticipantsPolicy.isSelf(
            userId: user.id,
            canRemoveSelfId: topic.canRemoveSelfId
        )
        guard PrivateMessageParticipantsPolicy.canRemoveUser(
            userId: user.id,
            canRemoveAllowedUsers: topic.canRemoveAllowedUsers,
            canRemoveSelfId: topic.canRemoveSelfId
        ) else { return }

        let title = isSelf
            ? String(localized: "pm.leave", defaultValue: "Leave")
            : String(localized: "pm.remove", defaultValue: "Remove")
        let message = isSelf
            ? String(localized: "pm.leave.confirm", defaultValue: "Leave this private message?")
            : String(format: String(localized: "pm.remove.user_confirm %@", defaultValue: "Remove @%@ from this message?"), user.username)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in
            Task {
                setRemovingUserId(user.id)
                do {
                    try await api.removePrivateMessageUser(topicId: topicId, username: user.username)
                    viewModel.mutateTopic { $0.removeAllowedUser(id: user.id) }
                    if isSelf {
                        onLeave()
                    } else {
                        DoerFeedback.presentToast(
                            String(format: String(localized: "pm.removed.user %@", defaultValue: "Removed @%@"), user.username),
                            on: host
                        )
                    }
                } catch {
                    DoerFeedback.presentToast(error.localizedDescription, on: host)
                }
                setRemovingUserId(nil)
            }
        })
        host.present(alert, animated: true)
    }

    static func confirmRemoveGroup(
        _ group: DiscourseTopicDetail.AllowedGroup,
        from host: UIViewController,
        api: DiscourseAPI,
        viewModel: TopicDetailViewModel,
        topicId: Int,
        setRemovingGroupName: @escaping (String?) -> Void
    ) {
        guard let topic = viewModel.topic,
              topic.isPrivateMessage,
              PrivateMessageParticipantsPolicy.canRemoveGroup(canRemoveAllowedUsers: topic.canRemoveAllowedUsers)
        else { return }

        let title = String(localized: "pm.remove", defaultValue: "Remove")
        let message = String(
            format: String(localized: "pm.remove.group_confirm %@", defaultValue: "Remove @%@ from this message?"),
            group.name
        )
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in
            Task {
                setRemovingGroupName(group.name)
                do {
                    try await api.removePrivateMessageGroup(topicId: topicId, groupName: group.name)
                    viewModel.mutateTopic { $0.removeAllowedGroup(named: group.name) }
                    DoerFeedback.presentToast(
                        String(format: String(localized: "pm.removed.group %@", defaultValue: "Removed @%@"), group.name),
                        on: host
                    )
                } catch {
                    DoerFeedback.presentToast(error.localizedDescription, on: host)
                }
                setRemovingGroupName(nil)
            }
        })
        host.present(alert, animated: true)
    }

    static func toggleArchive(
        from host: UIViewController,
        api: DiscourseAPI,
        viewModel: TopicDetailViewModel,
        topicId: Int,
        onArchivedLeave: @escaping () -> Void
    ) {
        guard let topic = viewModel.topic, topic.isPrivateMessage else { return }
        let archive = !topic.messageArchived
        Task {
            do {
                if archive {
                    try await api.archivePrivateMessage(topicId: topicId)
                } else {
                    try await api.movePrivateMessageToInbox(topicId: topicId)
                }
                viewModel.mutateTopic { $0.setMessageArchived(archive) }
                if archive {
                    DoerFeedback.presentToast(
                        String(localized: "pm.archived", defaultValue: "Archived"),
                        on: host
                    )
                    onArchivedLeave()
                } else {
                    DoerFeedback.presentToast(
                        String(localized: "pm.moved_to_inbox", defaultValue: "Moved to inbox"),
                        on: host
                    )
                }
            } catch {
                DoerFeedback.presentToast(error.localizedDescription, on: host)
            }
        }
    }

    static func leavePage(_ host: UIViewController) {
        if let navigation = host.navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            host.dismiss(animated: true)
        }
    }

    private static func submitInvite(
        _ selection: PrivateMessageRecipientSelection,
        api: DiscourseAPI,
        viewModel: TopicDetailViewModel,
        host: UIViewController
    ) async {
        guard viewModel.topic?.isPrivateMessage == true else { return }
        let topicId = viewModel.topic?.id
        guard let topicId else { return }
        var failed: [String] = []
        for username in selection.usernames {
            do {
                if let user = try await api.invitePrivateMessageUser(topicId: topicId, username: username) {
                    viewModel.mutateTopic { $0.addAllowedUser(user) }
                } else {
                    viewModel.mutateTopic {
                        $0.addAllowedUser(
                            DiscourseTopicDetail.AllowedUser(
                                id: username.hashValue,
                                username: username,
                                name: nil,
                                avatarTemplate: nil
                            )
                        )
                    }
                }
            } catch {
                failed.append(username)
            }
        }
        for groupName in selection.names.filter({ selection.groupNames.contains($0) }) {
            do {
                try await api.invitePrivateMessageGroup(topicId: topicId, groupName: groupName)
                viewModel.mutateTopic { $0.addAllowedGroup(DiscourseTopicDetail.AllowedGroup(name: groupName)) }
            } catch {
                failed.append(groupName)
            }
        }
        if failed.isEmpty {
            DoerFeedback.presentToast(
                String(localized: "pm.invite.success", defaultValue: "Invited"),
                on: host
            )
        } else {
            DoerFeedback.presentToast(
                String(format: String(localized: "pm.invite.partial_failed %@", defaultValue: "Couldn't invite %@"), failed.joined(separator: ", ")),
                on: host
            )
        }
    }
}
