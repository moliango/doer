import CookedHTML
import UIKit

final class RepliesViewController: UIViewController {
    private let api: DiscourseAPI
    private let postId: Int
    private let topicId: Int
    private let baseURL: String

    private var replies: [DiscourseTopicDetail.Post] = []
    private var parsedBlocks: [Int: [AnnotatedBlock]] = [:]
    private var unsupportedPostIds: Set<Int> = []
    private var downloadedAttachmentURLs: Set<URL> = []
    private var cloudflareCompletionObservationToken: NSObjectProtocol?

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.register(PostNativeCell.self, forCellReuseIdentifier: PostNativeCell.reuseIdentifier)
        tv.delegate = self
        tv.separatorStyle = .none
        return tv
    }()

    private lazy var dataSource: UITableViewDiffableDataSource<Int, Int> = .init(tableView: tableView) { [weak self] tableView, indexPath, postId in
        guard let self,
              let post = self.replies.first(where: { $0.id == postId }),
              let annotatedBlocks = self.parsedBlocks[postId],
              let cell = tableView.dequeueReusableCell(withIdentifier: PostNativeCell.reuseIdentifier, for: indexPath) as? PostNativeCell
        else {
            return UITableViewCell()
        }
        let postLink = "\(self.baseURL)/t/\(self.topicId)/\(post.postNumber)"
        let galleryImageURLs = TopicImageGallerySources.urls(from: annotatedBlocks)
        let config = NativeRenderConfig.default(
            contentWidth: PostNativeCell.renderContentWidth(for: tableView.bounds.width, isFirstPost: false),
            baseURL: self.baseURL,
            postId: post.id,
            galleryImageURLs: galleryImageURLs
        )
        let hasUnsupported = self.unsupportedPostIds.contains(postId)
        cell.configure(
            with: post,
            annotatedBlocks: annotatedBlocks,
            config: config,
            delegate: self,
            floorNumber: indexPath.row + 1,
            postLink: postLink,
            baseURL: self.baseURL,
            hasUnsupportedBlocks: hasUnsupported,
            cookedHTML: post.cooked,
            validReactions: [],
            sharedIssue: nil,
        )
        return cell
    }

    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .medium)
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    init(api: DiscourseAPI, postId: Int, topicId: Int) {
        self.api = api
        self.postId = postId
        self.topicId = topicId
        self.baseURL = api.baseURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let cloudflareCompletionObservationToken {
            NotificationCenter.default.removeObserver(cloudflareCompletionObservationToken)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Replies"
        view.backgroundColor = .systemBackground
        startObservingCloudflareVerification()

        view.addSubview(tableView)
        view.addSubview(activityIndicator)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        Task {
            await loadReplies()
        }
        Task {
            await api.loadOrFetchEmojiMap()
            tableView.reloadData()
        }
    }

    // MARK: - Data Loading

    private func loadReplies(
        pollVoteResponse: DiscoursePollVoteResponse? = nil,
        votedPostId: Int? = nil,
        submittedOptionIds: Set<String> = []
    ) async {
        activityIndicator.startAnimating()

        do {
            let response = try await api.fetchPostReplies(postId: postId)
            replies = response
            parsedBlocks = [:]
            unsupportedPostIds = []

            let snapshots = response.map { TopicDetailPostHTML(postId: $0.id, cooked: $0.cooked) }
            let parsedReplies = await TopicDetailHTMLParsing.parse(posts: snapshots, baseURL: baseURL)
            let repliesById = Dictionary(uniqueKeysWithValues: response.map { ($0.id, $0) })
            for parsedReply in parsedReplies {
                if let reply = repliesById[parsedReply.postId] {
                    parsedBlocks[parsedReply.postId] = TopicDetailPollResultMerger.mergeInitialPollState(
                        blocks: parsedReply.annotatedBlocks,
                        post: reply
                    )
                } else {
                    parsedBlocks[parsedReply.postId] = parsedReply.annotatedBlocks
                }
                if parsedReply.hasUnsupportedBlocks {
                    unsupportedPostIds.insert(parsedReply.postId)
                }
            }
            if let pollVoteResponse,
               let votedPostId,
               let blocks = parsedBlocks[votedPostId] {
                parsedBlocks[votedPostId] = TopicDetailPollResultMerger.merge(
                    blocks: blocks,
                    voteResponse: pollVoteResponse,
                    submittedOptionIds: submittedOptionIds
                )
            }
            prefetchReplyImages()

            var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
            snapshot.appendSections([0])
            snapshot.appendItems(response.map(\.id), toSection: 0)
            await dataSource.apply(snapshot, animatingDifferences: false)
        } catch {
            // silently fail
        }

        activityIndicator.stopAnimating()
    }

    private func prefetchReplyImages() {
        let contentURLs = parsedBlocks.values.flatMap(\.imageSourceURLs).compactMap(URL.init(string:))
        ForumImageLoader.prefetch(urls: contentURLs, cloudflareBaseURL: baseURL)
        AvatarImageLoader.prefetch(
            urls: replyAvatarURLs(),
            cloudflareBaseURL: baseURL
        )
    }

    private func replyAvatarURLs() -> [URL] {
        replies.compactMap { reply in
            AvatarImageLoader.url(
                from: reply.avatarTemplate,
                baseURL: baseURL,
                size: AvatarImageLoader.primaryAvatarPixelSize
            )
        }
    }

    private func startObservingCloudflareVerification() {
        cloudflareCompletionObservationToken = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareVerificationCompletedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleCloudflareVerificationCompleted(notification)
        }
    }

    private func handleCloudflareVerificationCompleted(_ notification: Notification) {
        guard let verifiedBaseURL = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String,
              ForumInstance.normalizedBaseURL(verifiedBaseURL) == ForumInstance.normalizedBaseURL(baseURL)
        else { return }

        AvatarImageLoader.credentialsDidChange(
            for: baseURL,
            retrying: replyAvatarURLs()
        )
        prefetchReplyImages()
        guard let visibleRows = tableView.indexPathsForVisibleRows, !visibleRows.isEmpty else { return }
        tableView.reloadRows(at: visibleRows, with: .none)
    }
}

// MARK: - UITableViewDelegate

extension RepliesViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        200
    }
}

// MARK: - PostCellDelegate

extension RepliesViewController: PostCellDelegate {
    func postCell(didTapImageURL url: URL, imageURLs: [URL], sourceView: UIView?) {
        presentTopicImageGallery(currentURL: url, imageURLs: imageURLs, sourceView: sourceView)
    }

    func postCell(didTapLinkURL url: URL) {
        handleLink(url)
    }

    func postCell(didTapShowRepliesForPostId postId: Int) {
        let repliesVC = RepliesViewController(api: api, postId: postId, topicId: topicId)
        if let sheet = repliesVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(repliesVC, animated: true)
    }

    func postCell(didTapToggleDetails detailsIndex: Int, postId: Int) {
        // Details toggle not supported in native rendering — no-op
    }

    func postCell(didTapReplyToPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.presentReplyComposer(for: post)
        }
    }

    func postCell(didQuoteSelectedText text: String, postId: Int?) {
        let post = postId.flatMap { id in replies.first(where: { $0.id == id }) }
        guard let post else { return }
        let markdown = DiscourseQuoteMarkdown.make(
            username: post.username,
            postNumber: post.postNumber,
            topicId: topicId,
            excerpt: text
        )
        guard !markdown.isEmpty else { return }
        performAuthenticated { [weak self] in
            self?.presentReplyComposer(for: post, initialText: markdown)
        }
    }

    func postCell(didRequestDecrypt text: String, postId: Int?) {
        CryptoSheetViewController.present(
            mode: .decrypt,
            text: text,
            from: self,
            onQuoteReply: { [weak self] plaintext in
                self?.postCell(didQuoteSelectedText: plaintext, postId: postId)
            }
        )
    }

    func postCell(didTapEditPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.loadAndPresentPostEditor(postId: post.id)
        }
    }

    func postCell(didToggleBookmarkForPost post: DiscourseTopicDetail.Post, isBookmarked: Bool) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    if isBookmarked {
                        _ = try await self.api.createBookmark(postId: post.id)
                    } else if let bookmarkId = post.bookmarkId {
                        try await self.api.deleteBookmark(id: bookmarkId)
                    }
                } catch {
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didTapAvatarForUsername username: String) {
        let previewVC = UserProfilePreviewViewController(api: api, username: username)
        previewVC.onViewProfile = { [weak self] selectedUsername in
            guard let self else { return }
            let vc = UserProfileViewController(api: self.api, username: selectedUsername)
            let nav = UINavigationController(rootViewController: vc)
            self.present(nav, animated: true)
        }
        present(previewVC, animated: true)
    }

    func postCell(didTapQuotedPostNumber postNumber: Int) {
        let detailVC = TopicDetailFactory.make(api: api, topicId: topicId, initialFloor: postNumber)
        openInternalViewController(detailVC)
    }

    func postCell(didTapReaction reactionId: String, forPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    _ = try await self.api.toggleReaction(postId: post.id, reactionId: reactionId)
                    await self.loadReplies()
                } catch {
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didTapToggleSharedIssueForTopicId topicId: Int) {
        // Shared issue belongs to the topic OP in the main detail page only.
    }

    func postCell(didSubmitPollVoteForPostId postId: Int, pollName: String, optionIds: [String]) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let voteResponse = try await self.api.votePoll(postId: postId, pollName: pollName, optionIds: optionIds)
                    let submittedOptionIds = Set(optionIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    await self.loadReplies(
                        pollVoteResponse: voteResponse,
                        votedPostId: postId,
                        submittedOptionIds: submittedOptionIds
                    )
                } catch {
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didTapBoostForPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            self?.presentBoostInput(for: post)
        }
    }

    func postCell(didRequestDeleteBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {
        performAuthenticated { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.api.deleteBoost(boostId: boost.id)
                    if let idx = self.replies.firstIndex(where: { $0.id == post.id }) {
                        self.replies[idx].boosts.removeAll { $0.id == boost.id }
                        self.replies[idx].canBoost = true
                    }
                    await self.loadReplies()
                } catch {
                    self.showPostActionError(error)
                }
            }
        }
    }

    func postCell(didUpdateBoost boost: DiscourseTopicDetail.Boost, forPost post: DiscourseTopicDetail.Post) {
        if let idx = replies.firstIndex(where: { $0.id == post.id }),
           let existing = replies[idx].boosts.firstIndex(where: { $0.id == boost.id }) {
            replies[idx].boosts[existing] = boost
        }
    }

    private func performAuthenticated(_ action: @escaping () -> Void) {
        if let authGate = findAuthGating() {
            authGate.requireAuth(then: action)
        } else {
            action()
        }
    }

    private func findAuthGating() -> AuthGating? {
        nearestAuthGating()
    }

    private func handleLink(_ url: URL) {
        let linkURL = ForumInternalLinkParser.normalizedURL(from: url, baseURL: baseURL)
        if ForumInternalLinkParser.isInternalURL(linkURL, baseURL: baseURL),
           let destination = ForumInternalLinkParser.destination(for: linkURL) {
            openInternalDestination(destination)
        } else if ForumAttachmentLinkParser.isAttachmentURL(linkURL) {
            downloadAndShareAttachment(linkURL)
        } else {
            presentSafari(linkURL)
        }
    }

    private func openInternalDestination(_ destination: ForumInternalLinkDestination) {
        switch destination {
        case let .topic(topicId, postNumber):
            let detailVC = TopicDetailFactory.make(api: api, topicId: topicId, initialFloor: postNumber)
            openInternalViewController(detailVC)
        case let .category(slug, categoryId):
            let category = DiscourseCategory(id: categoryId, name: slug, slug: slug)
            let vc = CategoryTopicsViewController(api: api, category: category)
            openInternalViewController(vc)
        case let .tag(tagName):
            let vc = TagTopicsViewController(api: api, tagName: tagName)
            openInternalViewController(vc)
        case let .user(username):
            openInternalViewController(UserProfileViewController(api: api, username: username))
        }
    }

    private func downloadAndShareAttachment(_ url: URL) {
        let progressAlert = makeAttachmentDownloadAlert()
        present(progressAlert, animated: true)
        let attachmentBaseURL = baseURL

        Task { @MainActor [weak self, weak progressAlert] in
            do {
                let fileURL = try await ForumAttachmentDownloader.download(url: url, baseURL: attachmentBaseURL)
                guard let self else {
                    ForumAttachmentDownloader.cleanupDownloadedFile(fileURL)
                    return
                }
                self.downloadedAttachmentURLs.insert(fileURL)
                progressAlert?.dismiss(animated: true) {
                    self.presentAttachmentShareSheet(fileURL)
                }
            } catch {
                progressAlert?.dismiss(animated: true) { [weak self] in
                    self?.showPostActionError(error)
                }
            }
        }
    }

    private func makeAttachmentDownloadAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: String(localized: "attachment.downloading"),
            message: "\n\n",
            preferredStyle: .alert
        )
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        alert.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerXAnchor.constraint(equalTo: alert.view.centerXAnchor),
            indicator.bottomAnchor.constraint(equalTo: alert.view.bottomAnchor, constant: -22),
        ])
        return alert
    }

    private func presentAttachmentShareSheet(_ fileURL: URL) {
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = view.bounds
        activity.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.downloadedAttachmentURLs.remove(fileURL)
            ForumAttachmentDownloader.cleanupDownloadedFile(fileURL)
        }
        present(activity, animated: true)
    }

    private func openInternalViewController(_ viewController: UIViewController) {
        if let navigationController {
            navigationController.pushViewController(viewController, animated: true)
            return
        }

        guard let targetNavigationController = presenterNavigationController() else {
            let nav = UINavigationController(rootViewController: viewController)
            present(nav, animated: true)
            return
        }

        if let presenter = presentingViewController {
            presenter.dismiss(animated: true) {
                targetNavigationController.pushViewController(viewController, animated: true)
            }
        } else {
            targetNavigationController.pushViewController(viewController, animated: true)
        }
    }

    private func presenterNavigationController() -> UINavigationController? {
        var candidate = presentingViewController
        while let viewController = candidate {
            if let navigationController = viewController as? UINavigationController {
                return navigationController
            }
            if let navigationController = viewController.navigationController {
                return navigationController
            }
            candidate = viewController.presentingViewController
        }
        return nil
    }

    private func presentSafari(_ url: URL) {
        DoerSafariPresenter.present(
            url: url,
            from: self,
            api: api,
            username: AuthManager.shared.username(for: api.baseURL)
        )
    }

    private func showPostActionError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "post.action.failed"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentBoostInput(for post: DiscourseTopicDetail.Post) {
        let input = BoostInputViewController(api: api)
        input.onSubmit = { [weak self] result in
            guard let self else { return }
            switch result {
            case let .boost(raw):
                Task {
                    do {
                        let boost = try await self.api.createBoost(postId: post.id, raw: raw)
                        if let idx = self.replies.firstIndex(where: { $0.id == post.id }) {
                            if !self.replies[idx].boosts.contains(where: { $0.id == boost.id }) {
                                self.replies[idx].boosts.append(boost)
                            }
                            self.replies[idx].canBoost = false
                        }
                        await self.loadReplies()
                    } catch {
                        self.showPostActionError(error)
                    }
                }
            case let .reply(raw):
                self.presentReplyComposer(for: post, initialText: raw)
            }
        }
        input.modalPresentationStyle = .pageSheet
        if let sheet = input.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(input, animated: true)
    }

    private func presentReplyComposer(for post: DiscourseTopicDetail.Post, initialText: String? = nil) {
        let composer = ReplyComposerViewController(
            api: api,
            topicId: topicId,
            replyToPost: post,
            baseURL: baseURL,
            initialText: initialText,
            mentionSeedUsers: [
                DiscourseMentionUser(
                    username: post.username,
                    name: post.name,
                    avatarTemplate: post.avatarTemplate
                )
            ]
        )
        composer.onPostCreated = { [weak self] in
            guard let self else { return }
            Task { await self.loadReplies() }
        }
        composer.modalPresentationStyle = .pageSheet
        if let sheet = composer.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(composer, animated: true)
    }

    private func loadAndPresentPostEditor(postId: Int) {
        Task {
            do {
                let editablePost = try await api.fetchPost(id: postId)
                guard editablePost.canEdit, let raw = editablePost.raw else {
                    throw DiscourseAPIError(
                        messages: [String(localized: "post.edit.unavailable", defaultValue: "这条评论当前无法编辑。")],
                        errorType: "post_not_editable"
                    )
                }
                let composer = ReplyComposerViewController(
                    api: api,
                    topicId: topicId,
                    replyToPost: nil,
                    baseURL: baseURL,
                    initialText: raw,
                    submissionMode: .edit(postId: postId)
                )
                composer.onPostUpdated = { [weak self] _ in
                    guard let self else { return }
                    Task { await self.loadReplies() }
                }
                composer.modalPresentationStyle = .pageSheet
                if let sheet = composer.sheetPresentationController {
                    sheet.detents = [.large()]
                    sheet.prefersGrabberVisible = false
                    sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                }
                present(composer, animated: true)
            } catch {
                showPostActionError(error)
            }
        }
    }
}
