import UIKit

/// TopicDetail lifecycle / navigation / observers / actions Coordinator.
/// Host VC keeps view setup, data source, and layout; actions & observers live here.
@MainActor
final class TopicDetailCoordinator {
    weak var host: TopicDetailViewController?
    let viewModel: TopicDetailViewModel
    let api: DiscourseAPI
    let forum: ForumInstance
    let topicId: Int
    let initialFloor: Int?
    let initialPostId: Int?

    private var cloudflareCompletionObservationToken: NSObjectProtocol?
    private var pluginObservationToken: NSObjectProtocol?

    private var baseURL: String { api.baseURL }

    init(
        viewModel: TopicDetailViewModel,
        api: DiscourseAPI,
        forum: ForumInstance,
        topicId: Int,
        initialFloor: Int? = nil,
        initialPostId: Int? = nil
    ) {
        self.viewModel = viewModel
        self.api = api
        self.forum = forum
        self.topicId = topicId
        self.initialFloor = initialFloor
        self.initialPostId = initialPostId
    }

    func start(in host: TopicDetailViewController) {
        self.host = host
        setupObservers()
    }

    func stop() {
        if let cloudflareCompletionObservationToken {
            NotificationCenter.default.removeObserver(cloudflareCompletionObservationToken)
            self.cloudflareCompletionObservationToken = nil
        }
        if let pluginObservationToken {
            NotificationCenter.default.removeObserver(pluginObservationToken)
            self.pluginObservationToken = nil
        }
    }

    // MARK: - Observers

    private func setupObservers() {
        guard pluginObservationToken == nil else { return }

        pluginObservationToken = NotificationCenter.default.addObserver(
            forName: PluginStateStore.stateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.host?.configureTopicActions()
            }
        }

        cloudflareCompletionObservationToken = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareVerificationCompletedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let verifiedBaseURL = notification.userInfo?[DiscourseAPI.cloudflareBaseURLUserInfoKey] as? String
            Task { @MainActor [weak self] in
                var userInfo: [AnyHashable: Any] = [:]
                if let verifiedBaseURL {
                    userInfo[DiscourseAPI.cloudflareBaseURLUserInfoKey] = verifiedBaseURL
                }
                self?.host?.handleCloudflareVerificationCompleted(
                    Notification(name: DiscourseAPI.cloudflareVerificationCompletedNotification, object: nil, userInfo: userInfo)
                )
            }
        }
    }

    deinit {
        if let cloudflareCompletionObservationToken {
            NotificationCenter.default.removeObserver(cloudflareCompletionObservationToken)
        }
        if let pluginObservationToken {
            NotificationCenter.default.removeObserver(pluginObservationToken)
        }
    }

    // MARK: - Notification routing

    func handleNotificationRoute(_ route: ForumNotificationRoute) {
        guard route.topicId == topicId else { return }
        if let postId = route.postId {
            host?.jumpToPostId(postId)
        } else if let postNumber = route.postNumber {
            Task { @MainActor [weak self] in
                await self?.host?.jumpToPostNumber(postNumber)
            }
        }
    }

    // MARK: - Child VC presentation (on demand)

    func presentReplies(forPostId postId: Int) {
        guard let host else { return }
        let repliesVC = RepliesViewController(api: api, postId: postId, topicId: topicId)
        repliesVC.modalPresentationStyle = .pageSheet
        if let sheet = repliesVC.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(repliesVC, animated: true)
    }

    func presentBoostInput(
        for post: DiscourseTopicDetail.Post,
        onSubmit: ((BoostInputResult) -> Void)? = nil
    ) {
        guard let host else { return }
        let input = BoostInputViewController(api: api)
        input.onSubmit = onSubmit
        input.modalPresentationStyle = .pageSheet
        if let sheet = input.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = false
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        host.present(input, animated: true)
    }

    func presentMermaidViewer(source: String) {
        guard let host else { return }
        let viewer = MermaidViewerViewController(source: source)
        let nav = UINavigationController(rootViewController: viewer)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(nav, animated: true)
    }

    // MARK: - Actions

    func replyButtonTapped() {
        host?.performAuthenticated { [weak self] in
            self?.host?.presentReplyComposer()
        }
    }

    func shareTopicLink(sourceView: UIView?) {
        guard let host else { return }
        let link = "\(baseURL)/t/\(topicId)"
        let activity = UIActivityViewController(activityItems: [link], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView ?? host.view
        activity.popoverPresentationController?.sourceRect = sourceView?.bounds ?? host.view.bounds
        host.present(activity, animated: true)
    }

    func bookmarkTopic() {
        host?.performAuthenticated { [weak self] in
            guard let self, let host = self.host else { return }
            Task {
                do {
                    if self.viewModel.topic?.bookmarked == true,
                       let bookmarkId = self.viewModel.topic?.bookmarkId {
                        try await self.api.deleteBookmark(id: bookmarkId)
                    } else {
                        _ = try await self.api.createBookmark(topicId: self.topicId)
                        await MainActor.run { self.maybeAutoSyncNotionAfterBookmark() }
                    }
                    await self.viewModel.loadTopic(
                        id: self.topicId,
                        containerWidth: host.view.bounds.width
                    )
                } catch {
                    host.showPostActionError(error)
                }
            }
        }
    }

    func exportTopic(format: TopicExportFormat, range: TopicExportRange) {
        guard let host else { return }
        guard let topic = viewModel.topic else {
            host.showPostActionError(TopicExportError.noPosts)
            return
        }
        let title = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
        let posts = viewModel.posts
        let username = host.findAuthGating()?.currentUsername()
        let service = TopicExportService(baseURL: baseURL, username: username)
        let history = ExportHistoryStore(baseURL: baseURL, username: username)
        let selectedPostCount = range == .firstPost
            ? min(posts.count, 1)
            : posts.filter { $0.actionCode == nil }.count

        do {
            let fileURL = try service.export(
                topicId: topicId,
                title: title,
                posts: posts,
                format: format,
                range: range
            )
            let record = TopicExportRecord(
                topicId: topicId,
                title: title,
                format: format,
                filePath: fileURL.path,
                postCount: selectedPostCount,
                errorMessage: nil
            )
            try history.add(record)
            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activity.popoverPresentationController?.barButtonItem = host.navigationItem.rightBarButtonItem
            host.present(activity, animated: true)
        } catch {
            let failedRecord = TopicExportRecord(
                topicId: topicId,
                title: title,
                format: format,
                filePath: nil,
                postCount: selectedPostCount,
                errorMessage: error.localizedDescription
            )
            try? history.add(failedRecord)
            host.showPostActionError(error)
        }
    }

    func notionSync() {
        // Default scope from config; UI menu usually calls syncTopicToNotion(scope:)
        let username = host?.findAuthGating()?.currentUsername()
        let scopeKey = NotionConfigStore.shared.scopeKey(baseURL: baseURL, username: username)
        let config = NotionConfigStore.shared.loadConfig(scopeKey: scopeKey)
        syncTopicToNotion(scope: config.syncScope)
    }

    func syncTopicToNotion(scope: NotionSyncScope, duplicate: NotionDuplicateAction = .skip) {
        guard let host else { return }
        guard let topic = viewModel.topic else { return }
        let username = host.findAuthGating()?.currentUsername()
        let scopeKey = NotionConfigStore.shared.scopeKey(baseURL: baseURL, username: username)
        guard let token = NotionConfigStore.shared.token(scopeKey: scopeKey), !token.isEmpty,
              NotionConfigStore.shared.isComplete(scopeKey: scopeKey) else {
            let alert = UIAlertController(
                title: String(localized: "notion.not_configured", defaultValue: "请先配置 Notion"),
                message: String(localized: "notion.not_configured.message", defaultValue: "在「我的」里打开 Notion 同步并填写 Token 与 Database ID"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
            host.present(alert, animated: true)
            return
        }

        let config = NotionConfigStore.shared.loadConfig(scopeKey: scopeKey)
        let title = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
        let posts = viewModel.posts
        let hud = UIAlertController(
            title: String(localized: "notion.syncing", defaultValue: "正在同步到 Notion…"),
            message: nil,
            preferredStyle: .alert
        )
        host.present(hud, animated: true)

        Task { [weak self, weak host] in
            guard let self, let host else { return }
            do {
                let service = NotionSyncService(config: config, token: token, baseURL: self.baseURL)
                let result = try await service.syncTopic(
                    topicId: self.topicId,
                    title: title,
                    posts: posts,
                    scope: scope,
                    onDuplicate: duplicate
                )
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        if result.duplicated && duplicate == .skip {
                            let ask = UIAlertController(
                                title: String(localized: "notion.duplicate.title", defaultValue: "Notion 中已存在"),
                                message: String(localized: "notion.duplicate.message", defaultValue: "该话题已同步过，选择跳过或覆盖"),
                                preferredStyle: .alert
                            )
                            ask.addAction(UIAlertAction(title: String(localized: "notion.duplicate.skip", defaultValue: "跳过"), style: .cancel))
                            ask.addAction(UIAlertAction(title: String(localized: "notion.open_page", defaultValue: "打开已有页面"), style: .default) { _ in
                                if let url = URL(string: result.pageURL) {
                                    UIApplication.shared.open(url)
                                }
                            })
                            ask.addAction(UIAlertAction(title: String(localized: "notion.duplicate.overwrite", defaultValue: "覆盖"), style: .destructive) { [weak self] _ in
                                self?.syncTopicToNotion(scope: scope, duplicate: .overwrite)
                            })
                            host.present(ask, animated: true)
                        } else {
                            self.presentNotionSuccess(result)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        host.showPostActionError(error)
                    }
                }
            }
        }
    }

    func maybeAutoSyncNotionAfterBookmark() {
        let username = host?.findAuthGating()?.currentUsername()
        let scopeKey = NotionConfigStore.shared.scopeKey(baseURL: baseURL, username: username)
        let config = NotionConfigStore.shared.loadConfig(scopeKey: scopeKey)
        guard config.autoSyncOnBookmark,
              let token = NotionConfigStore.shared.token(scopeKey: scopeKey),
              NotionConfigStore.shared.isComplete(scopeKey: scopeKey),
              let topic = viewModel.topic
        else { return }
        Task {
            let service = NotionSyncService(config: config, token: token, baseURL: baseURL)
            _ = try? await service.syncTopic(
                topicId: topicId,
                title: TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title),
                posts: viewModel.posts,
                scope: config.syncScope,
                onDuplicate: .skip
            )
        }
    }

    private func presentNotionSuccess(_ result: NotionSyncResult) {
        guard let host else { return }
        let alert = UIAlertController(
            title: String(localized: "notion.sync.success", defaultValue: "同步成功"),
            message: String(localized: "notion.sync.success_message", defaultValue: "已写入 Notion"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "notion.open_page", defaultValue: "打开页面"), style: .default) { _ in
            if let url = URL(string: result.pageURL) {
                UIApplication.shared.open(url)
            }
        })
        host.present(alert, animated: true)
    }

    func aiAssistantTapped() {
        guard let host else { return }
        let chat = AIChatSheetViewController(
            api: api,
            topicId: topicId,
            topicTitle: viewModel.topic?.title
        )
        if let sheet = chat.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(chat, animated: true)
    }

    func searchTopicTapped() {
        host?.searchTopicTapped()
    }

    func editTopic() {
        guard let host, let topic = viewModel.topic, topic.canEdit else { return }
        let alert = UIAlertController(
            title: String(localized: "topic.edit", defaultValue: "编辑话题"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { $0.text = topic.title }
        alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.done"), style: .default) { [weak self, weak alert, weak host] _ in
            guard let self, let host,
                  let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else { return }
            Task {
                do {
                    try await self.api.updateTopic(topicId: self.topicId, title: title)
                    host.hasTitleHeader = false
                    await self.viewModel.loadTopic(id: self.topicId, containerWidth: host.view.bounds.width)
                } catch {
                    host.showPostActionError(error)
                }
            }
        })
        host.present(alert, animated: true)
    }

    func shareTopicImage(postId: Int? = nil) {
        guard let host, let topic = viewModel.topic else { return }
        let post: DiscourseTopicDetail.Post? = {
            if let postId {
                return viewModel.posts.first(where: { $0.id == postId })
            }
            return viewModel.posts.first(where: { $0.postNumber == 1 && $0.actionCode == nil })
                ?? viewModel.posts.first(where: { $0.actionCode == nil })
        }()
        guard let post else {
            host.showPostActionError(NSError(
                domain: "ShareImage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "share.image.no_content", defaultValue: "暂无可分享内容")]
            ))
            return
        }

        let displayTitle = TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title)
        let authorName = (post.name?.isEmpty == false ? post.name! : post.username)
        let createdAtText: String? = {
            guard !post.createdAt.isEmpty else { return nil }
            return TopicCell.formatDate(post.createdAt)
        }()
        let avatarURL = AvatarImageLoader.url(from: post.avatarTemplate, baseURL: baseURL, size: 120)
        let hostName = URL(string: baseURL)?.host?.lowercased() ?? ""
        let brandName = hostName.contains("linux.do") ? "LINUX DO" : "Doer"
        let trimmedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let shareURL = "\(trimmedBase)/t/\(topicId)/\(post.postNumber)"

        let cookedTrimmed = post.cooked.trimmingCharacters(in: .whitespacesAndNewlines)
        let shareHTML: String = {
            if !cookedTrimmed.isEmpty {
                return PostImageLinkPreprocessor.rewrite(cookedTrimmed)
            }
            if let raw = post.raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return ShareImageBodyComposer.normalizeCookedInput(raw)
            }
            return ""
        }()
        let contentBlocks = (viewModel.parsedBlocks[post.id] ?? []).map(\.block)

        let preview = ShareImagePreviewViewController(
            model: .init(
                topicId: topicId,
                baseURL: baseURL,
                title: displayTitle,
                brandName: brandName,
                authorName: authorName,
                username: post.username,
                createdAtText: createdAtText,
                avatarURL: avatarURL,
                cookedHTML: shareHTML,
                contentBlocks: contentBlocks,
                shareURL: shareURL,
                postNumber: post.postNumber
            )
        )
        host.present(preview, animated: true)
    }

    func handleLink(_ url: URL) {
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

    func openInternalDestination(_ destination: ForumInternalLinkDestination) {
        switch destination {
        case let .topic(topicId, postNumber):
            if topicId == self.topicId, let postNumber {
                Task { @MainActor [weak self] in
                    await self?.host?.jumpToPostNumber(postNumber)
                }
                return
            }
            let detailVC = TopicDetailFactory.make(
                api: api,
                topicId: topicId,
                initialFloor: postNumber,
                forum: forum
            )
            openInternalViewController(detailVC)
        case let .category(slug, categoryId):
            let category = DiscourseCategory(id: categoryId, name: slug, slug: slug)
            openInternalViewController(CategoryTopicsViewController(api: api, category: category))
        case let .tag(tagName):
            openInternalViewController(TagTopicsViewController(api: api, tagName: tagName))
        case let .user(username):
            openInternalViewController(UserProfileViewController(api: api, username: username))
        }
    }

    func downloadAndShareAttachment(_ url: URL) {
        guard let host else { return }
        let progressAlert = makeAttachmentDownloadAlert()
        host.present(progressAlert, animated: true)
        let attachmentBaseURL = baseURL

        Task { @MainActor [weak self, weak host, weak progressAlert] in
            do {
                let fileURL = try await ForumAttachmentDownloader.download(url: url, baseURL: attachmentBaseURL)
                guard let self, let host else {
                    ForumAttachmentDownloader.cleanupDownloadedFile(fileURL)
                    return
                }
                host.downloadedAttachmentURLs.insert(fileURL)
                progressAlert?.dismiss(animated: true) {
                    self.presentAttachmentShareSheet(fileURL)
                }
            } catch {
                progressAlert?.dismiss(animated: true) {
                    host?.showPostActionError(error)
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
        guard let host else { return }
        let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = host.view
        activity.popoverPresentationController?.sourceRect = host.view.bounds
        activity.completionWithItemsHandler = { [weak host] _, _, _, _ in
            host?.downloadedAttachmentURLs.remove(fileURL)
            ForumAttachmentDownloader.cleanupDownloadedFile(fileURL)
        }
        host.present(activity, animated: true)
    }

    func openInternalViewController(_ viewController: UIViewController) {
        guard let host else { return }
        if let navigationController = host.navigationController {
            navigationController.pushViewController(viewController, animated: true)
        } else {
            host.present(UINavigationController(rootViewController: viewController), animated: true)
        }
    }

    func presentSafari(_ url: URL) {
        guard let host else { return }
        DoerSafariPresenter.present(
            url: url,
            from: host,
            api: api,
            username: AuthManager.shared.username(for: api.baseURL)
        )
    }

    func setNotificationLevel(_ level: DiscourseTopicDetail.NotificationLevel) {
        host?.performAuthenticated { [weak self] in
            guard let self, let host = self.host else { return }
            Task {
                do {
                    try await self.api.updateTopicNotificationLevel(topicId: self.topicId, level: level)
                    self.viewModel.topic?.notificationLevel = level
                    host.configureTopicActions()
                } catch {
                    host.showPostActionError(error)
                }
            }
        }
    }
}
