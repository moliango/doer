import UIKit

/// TopicDetail 页面的生命周期和交互 Coordinator
/// 负责：
/// - 页面的生命周期管理
/// - 子 VC 管理
/// - 通知路由
/// - Cloudflare 验证
/// - 所有 action（reply、share、bookmark、export、notion 等）
final class TopicDetailCoordinator {
    weak var viewController: UIViewController?
    let viewModel: TopicDetailViewModel
    let api: DiscourseAPI
    let forum: ForumInstance
    let topicId: Int
    let initialFloor: Int?
    let initialPostId: Int?

    private var repliesViewController: RepliesViewController?
    private var boostInputViewController: BoostInputViewController?
    private var mermaidViewer: MermaidViewerViewController?
    private var notificationCoordinator: ForumNotificationCoordinator?

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

    func start(in viewController: UIViewController) {
        self.viewController = viewController
        setupSubViewControllers()
        setupObservers()
        handleInitialNavigation()
    }

    private func setupSubViewControllers() {
        // Replies、Boost、Mermaid 等子 VC 后续逐步注入
    }

    private func setupObservers() {
        // NotificationCenter、Cloudflare、PluginStateStore 等观察
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(pluginStateDidChange),
            name: PluginStateStore.stateDidChangeNotification,
            object: nil
        )
        // Cloudflare 观察...
    }

    private func handleInitialNavigation() {
        if let initialPostId {
            viewModel.jumpToPostId(initialPostId)
        } else if let initialFloor {
            viewModel.jumpToPostNumber(initialFloor)
        }
    }

    @objc private func pluginStateDidChange() {
        // 处理插件状态变化
    }

    func handleNotificationRoute(_ route: ForumNotificationRoute) {
        // 实现深链接跳转
        // 例如：跳转到指定楼层
    }

    // MARK: - Action Handlers
    func replyToPost(postId: Int) {
        // 实现回复逻辑
    }

    func shareTopicLink(sourceView: UIView?) {
        // 实现分享
    }

    func bookmarkTopic() {
        // 实现书签
    }

    func exportTopic(format: TopicExportFormat, range: TopicExportRange) {
        // 实现导出
    }

    func notionSync() {
        // 实现 Notion 同步
    }
}
    // MARK: - 子 VC 管理
    private func setupRepliesViewController() {
        // 实现 RepliesViewController 的注入
    }

    private func setupBoostInputViewController() {
        // 实现 BoostInputViewController 的注入
    }

    // MARK: - Cloudflare 处理
    @objc private func cloudflareVerificationCompleted(_ notification: Notification) {
        // 处理 Cloudflare 验证完成
    }

    // MARK: - 通知路由
    private func handleDeepLinkToPostNumber(_ postNumber: Int) {
        viewModel.jumpToPostNumber(postNumber)
    }

    // MARK: - Action 实现
    func presentBoostInput() {
        // 实现 Boost 弹窗
    }

    func presentMermaidViewer(_ content: String) {
        // 实现 Mermaid 预览
    }

    // MARK: - Cleanup
    func cleanup() {
        // 清理观察者
    }
}
    // MARK: - 子 VC 管理
    private func setupRepliesViewController() {
        // 实现 RepliesViewController 的注入
        self.repliesViewController = RepliesViewController(viewModel: viewModel)
    }

    private func setupBoostInputViewController() {
        self.boostInputViewController = BoostInputViewController(viewModel: viewModel)
    }

    private func setupMermaidViewer(_ content: String) {
        self.mermaidViewer = MermaidViewerViewController(content: content)
    }

    // MARK: - Cloudflare 处理
    @objc private func cloudflareVerificationCompleted(_ notification: Notification) {
        // 处理 Cloudflare 验证完成
    }

    // MARK: - 通知路由
    private func handleDeepLinkToPostNumber(_ postNumber: Int) {
        viewModel.jumpToPostNumber(postNumber)
    }

    // MARK: - Action 实现
    func presentBoostInput() {
        guard let boostVC = boostInputViewController else { return }
        viewController?.present(boostVC, animated: true)
    }

    func presentMermaidViewer(_ content: String) {
        guard let mermaidVC = mermaidViewer else { return }
        viewController?.present(mermaidVC, animated: true)
    }

    // MARK: - Cleanup
    func cleanup() {
        NotificationCenter.default.removeObserver(self)
    }
}
