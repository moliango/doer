import UIKit

final class DraftsViewController: ObservableViewController {
    private let api: DiscourseAPI
    private var drafts: [DiscourseDraft] = []
    private var hasMore = false
    private var isLoading = false
    private var isLoadingMore = false
    private var isOpeningDraft = false
    private var errorMessage: String?
    private var categoriesById: [Int: DiscourseCategory] = [:]

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = DraftCell.estimatedHeight
        tableView.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        TopicListCellFactory.registerCells(on: tableView)
        tableView.register(DraftCell.self, forCellReuseIdentifier: DraftCell.reuseIdentifier)
        return tableView
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private let stateIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .tertiaryLabel
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        return label
    }()

    private let retryButton: UIButton = {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = String(localized: "action.retry")
        configuration.cornerStyle = .medium
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private lazy var stateStackView: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [stateIconView, stateLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }()

    private lazy var refreshControl: UIRefreshControl = {
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        return control
    }()

    init(api: DiscourseAPI) {
        self.api = api
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(AppSettings.shared)
        title = String(localized: "me.drafts", defaultValue: "草稿")
        applyThemeStyle()
        tableView.refreshControl = refreshControl
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        view.addSubview(tableView)
        view.addSubview(activityIndicator)
        view.addSubview(stateStackView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateStackView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateStackView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateStackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stateStackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            stateIconView.widthAnchor.constraint(equalToConstant: 48),
            stateIconView.heightAnchor.constraint(equalToConstant: 48)
        ])
        Task { await loadDrafts(reset: true) }
        Task { [weak self] in await self?.loadCategoryMetadata() }
    }

    override func updateUI() {
        applyThemeStyle()
        tableView.reloadData()
    }

    private func applyThemeStyle() {
        let theme = AppSettings.shared.themeStyle
        view.backgroundColor = theme.topicListBackgroundColor
        tableView.backgroundColor = theme.topicListBackgroundColor
        tableView.estimatedRowHeight = TopicListLayoutKind.current.usesChatSessionRows
            ? TopicListCellFactory.estimatedRowHeight
            : DraftCell.estimatedHeight
        tableView.showsVerticalScrollIndicator = !AppSettings.shared.hideScrollIndicators
        view.tintColor = theme.accentColor
        refreshControl.tintColor = theme.accentColor
        activityIndicator.color = theme.accentColor
        stateIconView.tintColor = theme.accentColor.withAlphaComponent(0.78)
        retryButton.tintColor = theme.accentColor
        stateLabel.font = AppSettings.shared.appInterfaceFont(matching: .systemFont(ofSize: 15))
    }

    private func loadDrafts(reset: Bool) async {
        if reset {
            guard !isLoading else { return }
            isLoading = true
            errorMessage = nil
        } else {
            guard hasMore, !isLoading, !isLoadingMore else { return }
            isLoadingMore = true
        }
        updateState()
        defer {
            if reset { isLoading = false } else { isLoadingMore = false }
            refreshControl.endRefreshing()
            updateState()
        }
        do {
            let offset = reset ? 0 : drafts.count
            let response = try await api.fetchDrafts(offset: offset, limit: 20)
            if reset {
                drafts = Self.uniqueDrafts(response.drafts)
            } else {
                let existingKeys = Set(drafts.map(\.draftKey))
                drafts.append(contentsOf: Self.uniqueDrafts(response.drafts).filter { !existingKeys.contains($0.draftKey) })
            }
            hasMore = response.hasMore
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if reset && drafts.isEmpty { hasMore = false }
        }
    }

    private func updateState() {
        tableView.reloadData()
        let hasDrafts = !drafts.isEmpty
        let animated = view.window != nil
        AnimationOptimizer.setVisible(tableView, hasDrafts, animated: animated)
        AnimationOptimizer.setVisible(stateStackView, !hasDrafts && !isLoading, animated: animated)
        retryButton.isHidden = errorMessage == nil
        if (isLoading && !hasDrafts) || isOpeningDraft { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
        tableView.isUserInteractionEnabled = !isOpeningDraft
        if let errorMessage, !hasDrafts {
            configureState(iconName: "exclamationmark.triangle", text: errorMessage)
        } else if !hasDrafts, !isLoading {
            configureState(
                iconName: "doc.text",
                text: String(localized: "me.drafts.empty", defaultValue: "没有云端草稿\n在发帖/回帖时输入内容会自动保存")
            )
        }
        if isLoadingMore {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = AppSettings.shared.themeStyle.accentColor
            spinner.frame = CGRect(x: 0, y: 0, width: 0, height: 48)
            spinner.startAnimating()
            tableView.tableFooterView = spinner
        } else if errorMessage != nil && hasDrafts {
            let button = UIButton(type: .system)
            button.frame = CGRect(x: 0, y: 0, width: 0, height: 52)
            button.tintColor = AppSettings.shared.themeStyle.accentColor
            button.setTitle(String(localized: "me.topic_list.load_more_failed", defaultValue: "加载更多失败，点击重试"), for: .normal)
            button.addTarget(self, action: #selector(loadMoreRetryTapped), for: .touchUpInside)
            tableView.tableFooterView = button
        } else {
            tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
        }
    }

    private func loadCategoryMetadata() async {
        let cachedCategories = DiscourseTaxonomySessionStore.categories(for: api.baseURL)
        if !cachedCategories.isEmpty {
            categoriesById = DiscourseCategory.indexedById(from: cachedCategories)
            updateState()
        }

        let remoteCategories: [DiscourseCategory]
        if let siteCategories = try? await api.fetchSiteCategories(), !siteCategories.isEmpty {
            remoteCategories = siteCategories
        } else {
            remoteCategories = (try? await api.fetchCategories().categoryList.categories) ?? []
        }
        guard !remoteCategories.isEmpty, !Task.isCancelled else { return }
        DiscourseTaxonomySessionStore.replace(categories: remoteCategories, for: api.baseURL)
        categoriesById = DiscourseCategory.indexedById(from: remoteCategories)
        updateState()
    }

    private func configureState(iconName: String, text: String) {
        stateIconView.image = UIImage(systemName: iconName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 42))
        stateLabel.text = text
    }

    private static func uniqueDrafts(_ drafts: [DiscourseDraft]) -> [DiscourseDraft] {
        var seen = Set<String>()
        return drafts.filter { seen.insert($0.draftKey).inserted }
    }

    @objc private func refreshPulled() { Task { await loadDrafts(reset: true) } }
    @objc private func retryTapped() { Task { await loadDrafts(reset: true) } }
    @objc private func loadMoreRetryTapped() { Task { await loadDrafts(reset: false) } }

    private func confirmDelete(_ draft: DiscourseDraft) {
        let alert = UIAlertController(
            title: String(localized: "me.drafts.delete.title", defaultValue: "删除草稿？"),
            message: String(localized: "me.drafts.delete.message", defaultValue: "删除后无法恢复。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.delete", defaultValue: "删除"), style: .destructive) { [weak self] _ in
            Task { await self?.deleteDraft(draft, showError: true) }
        })
        present(alert, animated: true)
    }

    private func deleteDraft(_ draft: DiscourseDraft, showError: Bool) async {
        do {
            try await api.deleteDraft(key: draft.draftKey, sequence: draft.sequence)
            ComposerLocalDraftStore.clearSequence(baseURL: api.baseURL, draftKey: draft.draftKey)
            drafts.removeAll { $0.draftKey == draft.draftKey }
            updateState()
        } catch where showError {
            showErrorAlert(error.localizedDescription)
        } catch { }
    }

    private func open(_ draft: DiscourseDraft) {
        isOpeningDraft = true
        updateState()
        Task {
            defer { isOpeningDraft = false; updateState() }
            do {
                switch draft.destination {
                case .newTopic: try await presentNewTopicDraft(draft)
                case .topicReply(let topicId, let postNumber): try await presentReplyDraft(draft, topicId: topicId, postNumber: postNumber)
                case .privateMessage(let recipient):
                    guard let recipient, !recipient.isEmpty else { throw DraftOpenError.missingRecipient }
                    presentPrivateMessageDraft(draft, recipient: recipient)
                case .unsupported: presentUnsupportedDraft(draft)
                }
            } catch { showErrorAlert(error.localizedDescription) }
        }
    }

    private func presentNewTopicDraft(_ draft: DiscourseDraft) async throws {
        let siteCategories = (try? await api.fetchSiteCategories()) ?? []
        let categories = siteCategories.isEmpty
            ? DiscourseCategory.normalizedTree(fromNested: try await api.fetchCategories().categoryList.categories)
            : siteCategories
        ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draft.draftKey, sequence: draft.sequence)
        let composer = NewTopicComposerViewController(
            api: api,
            categories: categories,
            initialCategoryId: draft.data.categoryId,
            initialTitle: draft.data.title ?? draft.title ?? "",
            initialRaw: draft.data.reply ?? draft.excerpt ?? "",
            initialTags: draft.data.tags,
            draftKey: draft.draftKey
        )
        composer.onTopicCreated = { [weak self] _ in Task { await self?.deleteDraft(draft, showError: false) } }
        composer.onDraftDeleted = { [weak self] in self?.drafts.removeAll { $0.draftKey == draft.draftKey }; self?.updateState() }
        presentComposer(NavigationController: UINavigationController(rootViewController: composer))
    }

    private func presentReplyDraft(_ draft: DiscourseDraft, topicId: Int, postNumber: Int?) async throws {
        let detail = try await api.fetchTopic(id: topicId)
        var replyTarget = postNumber.flatMap { number in detail.postStream.posts.first { $0.postNumber == number } }
        if replyTarget == nil, let postNumber, let stream = detail.postStream.stream, stream.indices.contains(postNumber - 1) {
            replyTarget = try await api.fetchTopicPosts(topicId: topicId, postIds: [stream[postNumber - 1]]).postStream.posts.first
        }
        if postNumber != nil, replyTarget == nil { throw DraftOpenError.missingReplyTarget }
        ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draft.draftKey, sequence: draft.sequence)
        let composer = ReplyComposerViewController(
            api: api,
            topicId: topicId,
            replyToPost: replyTarget,
            baseURL: api.baseURL,
            initialText: draft.data.reply ?? draft.excerpt,
            draftKey: draft.draftKey,
            categoryId: detail.categoryId
        )
        composer.onPostCreated = { [weak self] in Task { await self?.deleteDraft(draft, showError: false) } }
        composer.onDraftDeleted = { [weak self] in self?.drafts.removeAll { $0.draftKey == draft.draftKey }; self?.updateState() }
        presentComposer(NavigationController: UINavigationController(rootViewController: composer))
    }

    private func presentPrivateMessageDraft(_ draft: DiscourseDraft, recipient: String) {
        ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draft.draftKey, sequence: draft.sequence)
        let composer = PrivateMessageComposerViewController(api: api, recipient: recipient, initialTitle: draft.data.title ?? draft.title ?? "", initialRaw: draft.data.reply ?? draft.excerpt ?? "", draftKey: draft.draftKey)
        composer.onMessageSent = { [weak self] _ in Task { await self?.deleteDraft(draft, showError: false) } }
        composer.onDraftDeleted = { [weak self] in self?.drafts.removeAll { $0.draftKey == draft.draftKey }; self?.updateState() }
        presentComposer(NavigationController: UINavigationController(rootViewController: composer))
    }

    private func presentUnsupportedDraft(_ draft: DiscourseDraft) {
        let alert = UIAlertController(
            title: String(localized: "me.drafts.unsupported.title", defaultValue: "无法恢复这个草稿"),
            message: String(localized: "me.drafts.unsupported.message", defaultValue: "草稿类型无法识别，可以保留或删除。"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.delete", defaultValue: "删除"), style: .destructive) { [weak self] _ in Task { await self?.deleteDraft(draft, showError: true) } })
        present(alert, animated: true)
    }

    private func presentComposer(NavigationController navigation: UINavigationController) {
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController { sheet.detents = [.large()] }
        present(navigation, animated: true)
    }

    private func showErrorAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }

    private func displayTitle(for draft: DiscourseDraft) -> String {
        if let title = draft.data.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return kindTitle(for: draft.destination)
    }

    private func displayExcerpt(for draft: DiscourseDraft) -> String? {
        let raw = draft.data.reply ?? draft.excerpt ?? ""
        let excerpt = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return excerpt.isEmpty ? nil : excerpt
    }

    private func displayCategoryName(for draft: DiscourseDraft) -> String? {
        guard let categoryId = draft.data.categoryId else { return nil }
        let category = categoriesById[categoryId]
            ?? DiscourseTaxonomySessionStore.category(id: categoryId, for: api.baseURL)
            ?? LinuxDoCategoryCatalog.category(id: categoryId, baseURL: api.baseURL)
        guard let category else { return "#\(categoryId)" }
        let parent = category.parentCategoryId.flatMap {
            categoriesById[$0]
                ?? DiscourseTaxonomySessionStore.category(id: $0, for: api.baseURL)
                ?? LinuxDoCategoryCatalog.category(id: $0, baseURL: api.baseURL)
        }
        return category.displayName(parent: parent)
    }

    private func displayTaxonomy(for draft: DiscourseDraft) -> String? {
        var parts: [String] = []
        if let categoryName = displayCategoryName(for: draft) {
            parts.append("\(String(localized: "search.filter.category", defaultValue: "分类"))：\(categoryName)")
        }
        let tags = draft.data.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            let tagText = tags.map { $0.hasPrefix("#") ? $0 : "#\($0)" }.joined(separator: " ")
            parts.append("\(String(localized: "search.filter.tags", defaultValue: "标签"))：\(tagText)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func displaySubtitle(for draft: DiscourseDraft) -> String {
        let time = UserProfileFormatting.relativeDate(draft.updatedAt)
        var parts: [String] = []
        if let taxonomy = displayTaxonomy(for: draft) { parts.append(taxonomy) }
        if let excerpt = displayExcerpt(for: draft) { parts.append(String(excerpt.prefix(120))) }
        return parts.isEmpty ? time : "\(parts.joined(separator: " · ")) · \(time)"
    }

    private func kindTitle(for destination: DiscourseDraftDestination) -> String {
        switch destination {
        case .newTopic: return String(localized: "me.drafts.new_topic", defaultValue: "新主题草稿")
        case .topicReply: return String(localized: "me.drafts.reply", defaultValue: "回复草稿")
        case .privateMessage: return String(localized: "me.drafts.private_message", defaultValue: "私信草稿")
        case .unsupported: return String(localized: "me.drafts.unknown", defaultValue: "未识别草稿")
        }
    }

    private func symbolName(for destination: DiscourseDraftDestination) -> String {
        switch destination {
        case .newTopic: return "square.and.pencil"
        case .topicReply: return "arrowshape.turn.up.left.fill"
        case .privateMessage: return "envelope.fill"
        case .unsupported: return "questionmark.folder.fill"
        }
    }

    private func tintColor(for destination: DiscourseDraftDestination) -> UIColor {
        switch destination {
        case .newTopic: return AppSettings.shared.themeStyle.accentColor
        case .topicReply: return .systemGreen
        case .privateMessage: return .systemIndigo
        case .unsupported: return .systemOrange
        }
    }

    private func sessionItem(for draft: DiscourseDraft) -> TopicListSessionItem {
        TopicListSessionItem(title: displayTitle(for: draft), subtitle: displaySubtitle(for: draft), timeText: UserProfileFormatting.relativeDate(draft.updatedAt), isEmphasized: false, badgeText: kindTitle(for: draft.destination), baseURL: api.baseURL)
    }

    private func makeCardCell(tableView: UITableView, indexPath: IndexPath, title: String, excerpt: String?, timeText: String?, kindTitle: String, symbolName: String, accent: UIColor) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: DraftCell.reuseIdentifier, for: indexPath) as? DraftCell else { return UITableViewCell() }
        cell.configure(title: title, excerpt: excerpt, timeText: timeText, kindTitle: kindTitle, taxonomyText: displayTaxonomy(for: drafts[indexPath.row]), symbolName: symbolName, accent: accent)
        return cell
    }
}

extension DraftsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { drafts.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        drafts.isEmpty ? nil : String(localized: "me.drafts.section.cloud", defaultValue: "云端草稿（与网页 / FluxDo 同步）")
    }
    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = AppSettings.shared.appInterfaceFont(matching: .systemFont(ofSize: 13, weight: .semibold))
        header.textLabel?.textColor = .secondaryLabel
        header.contentConfiguration = nil
        header.backgroundConfiguration = UIBackgroundConfiguration.clear()
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let draft = drafts[indexPath.row]
        let layout = TopicListLayoutKind.current
        if layout.usesChatSessionRows { return TopicListCellFactory.makeSessionCell(tableView: tableView, indexPath: indexPath, item: sessionItem(for: draft), layout: layout) }
        return makeCardCell(tableView: tableView, indexPath: indexPath, title: displayTitle(for: draft), excerpt: displayExcerpt(for: draft), timeText: UserProfileFormatting.relativeDate(draft.updatedAt), kindTitle: kindTitle(for: draft.destination), symbolName: symbolName(for: draft.destination), accent: tintColor(for: draft.destination))
    }
}

extension DraftsViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); open(drafts[indexPath.row]) }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let delete = UIContextualAction(style: .destructive, title: String(localized: "action.delete", defaultValue: "删除")) { [weak self] _, _, completion in
            guard let self, self.drafts.indices.contains(indexPath.row) else { completion(false); return }
            self.confirmDelete(self.drafts[indexPath.row]); completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row >= drafts.count - 4 else { return }
        Task { await loadDrafts(reset: false) }
    }
}

private enum DraftOpenError: LocalizedError {
    case missingRecipient
    case missingReplyTarget
    var errorDescription: String? {
        switch self {
        case .missingRecipient: return String(localized: "me.drafts.missing_recipient", defaultValue: "草稿缺少私信收件人。")
        case .missingReplyTarget: return String(localized: "me.drafts.missing_reply_target", defaultValue: "找不到草稿对应的回复楼层。")
        }
    }
}
