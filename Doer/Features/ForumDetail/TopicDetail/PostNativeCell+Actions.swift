import UIKit

extension PostNativeCell {
    // MARK: - Actions
    // MARK: - Actions

    @objc func repliesButtonTapped() {
        delegate?.postCell(didTapShowRepliesForPostId: postId)
    }

    @objc func sharedIssueButtonTapped() {
        guard let topicId = currentSharedIssueTopicId else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        delegate?.postCell(didTapToggleSharedIssueForTopicId: topicId)
    }

    @objc func replyButtonTapped() {
        guard let post = currentPost else { return }
        delegate?.postCell(didTapReplyToPost: post)
    }

    @objc func avatarTapped() {
        guard let username = currentPost?.username else { return }
        delegate?.postCell(didTapAvatarForUsername: username)
    }

    @objc func copyLinkTapped() {
        guard let link = postLink else { return }
        UIPasteboard.general.string = link
        configureActionButton(
            moreButton,
            symbolName: "checkmark",
            tintColor: .systemGreen,
            backgroundColor: UIColor.systemGreen.withAlphaComponent(0.14),
            accessibilityLabel: "已复制"
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
            self.configureMoreMenu(isBookmarked: self.isBookmarked)
        }
    }

    @objc func sourceButtonTapped() {
        UIPasteboard.general.string = cookedHTML
        let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        sourceButton.setImage(UIImage(systemName: "checkmark", withConfiguration: config), for: .normal)
        sourceButton.tintColor = .systemGreen
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(1.0 * 1_000_000_000))
            self.sourceButton.setImage(UIImage(systemName: "doc.on.clipboard", withConfiguration: config), for: .normal)
            self.sourceButton.tintColor = .tertiaryLabel
        }
    }

    @objc func reactButtonTapped() {
        guard let post = currentPost, !post.yours else { return }
        let reactionId = post.currentUserReaction?.id ?? "heart"
        delegate?.postCell(didTapReaction: reactionId, forPost: post)
    }

    @objc func reactionPillLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let post = currentPost,
              !post.yours,
              !validReactions.isEmpty
        else { return }
        presentReactionPicker(for: post)
    }

    func presentReactionPicker(for post: DiscourseTopicDetail.Post) {
        guard !post.yours, !validReactions.isEmpty else { return }
        PostReactionPickerViewController.present(
            reactionIds: validReactions,
            from: reactionPillControl
        ) { [weak self] reactionId in
            guard let self, let current = self.currentPost else { return }
            self.delegate?.postCell(didTapReaction: reactionId, forPost: current)
        }
    }

    @objc func boostButtonTapped() {
        guard let post = currentPost else { return }
        delegate?.postCell(didTapBoostForPost: post)
    }

    @objc func bookmarkButtonTapped() {
        guard let post = currentPost else { return }
        let targetState = !isBookmarked
        isBookmarked = targetState
        configureBookmarkButton(isBookmarked: targetState)
        configureMoreMenu(isBookmarked: targetState)
        delegate?.postCell(didToggleBookmarkForPost: post, isBookmarked: targetState)
    }

}
