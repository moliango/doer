import UIKit
import WebKit

final class InAppBrowserViewController: UIViewController {
    private let baseURL: URL
    private let store: BrowserHistoryStore
    private let initialURL: URL?
    let hidesHostTabBarAtRoot: Bool
    private let hidesBrowserControlBar: Bool
    private var isCookieObserverRegistered = false
    /// Set when the mini-program host (or parent) is destroying this browser.
    private var isTornDown = false

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        // Persistent default store keeps login cookies / localStorage across close → reopen.
        // WKProcessPool no longer isolates storage on iOS 15+.
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Mini-program chrome owns the 20pt follow-finger back. WK's own
        // back-forward gesture fights that pan and rubber-bands the page.
        webView.allowsBackForwardNavigationGestures = !hidesBrowserControlBar
        if let userAgent = WebCookieStore.shared.userAgent {
            webView.customUserAgent = userAgent
        }
        return webView
    }()

    private let progressView: UIProgressView = {
        let progress = UIProgressView(progressViewStyle: .bar)
        progress.translatesAutoresizingMaskIntoConstraints = false
        return progress
    }()

    private let topBar = UIView()
    private let errorView = BrowserErrorView()
    private lazy var closeButton = makeControlButton(systemName: "xmark", action: #selector(closeTapped))
    private lazy var backButton = makeControlButton(systemName: "chevron.backward", action: #selector(backTapped))
    private lazy var forwardButton = makeControlButton(systemName: "chevron.forward", action: #selector(forwardTapped))
    private lazy var reloadButton = makeControlButton(systemName: "arrow.clockwise", action: #selector(reloadTapped))
    private lazy var moreButton = makeControlButton(systemName: "ellipsis", action: #selector(moreTapped))
    private let titleCapsule = UIControl()
    private let securityImageView = UIImageView()
    private let titleLabel = UILabel()
    private var topBarHeightConstraint: NSLayoutConstraint?

    private var progressObservation: NSKeyValueObservation?
    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var popupWebView: WKWebView?
    /// Mini-program host lock: disable horizontal rubber-band / swipe-back and pinch zoom.
    private(set) var isPageInteractionLocked = false
    init(
        api: DiscourseAPI,
        username: String?,
        initialURL: URL? = nil,
        hidesHostTabBarAtRoot: Bool = false,
        hidesBrowserControlBar: Bool = false,
        historyStore: BrowserHistoryStore? = nil
    ) {
        let normalizedBase = api.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.baseURL = URL(string: normalizedBase) ?? URL(string: "https://linux.do")!
        self.store = historyStore ?? BrowserHistoryStore.shared(baseURL: api.baseURL, username: username)
        self.initialURL = initialURL
        self.hidesHostTabBarAtRoot = hidesHostTabBarAtRoot
        self.hidesBrowserControlBar = hidesBrowserControlBar
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        // FluxDo 风格顶栏自绘，隐藏系统导航栏标题区。
        navigationController?.setNavigationBarHidden(true, animated: false)
        configureTopBar()
        topBar.isHidden = hidesBrowserControlBar
        topBar.isUserInteractionEnabled = !hidesBrowserControlBar

        closeButton.accessibilityLabel = String(localized: "common.close", defaultValue: "关闭")
        backButton.accessibilityLabel = String(localized: "me.browser.back", defaultValue: "后退")
        forwardButton.accessibilityLabel = String(localized: "me.browser.forward", defaultValue: "前进")
        reloadButton.accessibilityLabel = String(localized: "me.browser.reload", defaultValue: "刷新")
        moreButton.accessibilityLabel = String(localized: "me.browser.toolbar_action", defaultValue: "更多操作")

        view.addSubview(topBar)
        view.addSubview(progressView)
        view.addSubview(webView)
        view.addSubview(errorView)

        let topBarHeight = topBar.heightAnchor.constraint(equalToConstant: hidesBrowserControlBar ? 0 : 48)
        topBarHeightConstraint = topBarHeight
        // Mini-program host already provides chrome — hide the browser progress strip.
        progressView.isHidden = hidesBrowserControlBar
        let progressHeight = progressView.heightAnchor.constraint(
            equalToConstant: hidesBrowserControlBar ? 0 : 2
        )

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarHeight,

            progressView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressHeight,

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            errorView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self, !self.hidesBrowserControlBar, !self.isTornDown else { return }
                self.progressView.progress = Float(webView.estimatedProgress)
                self.progressView.isHidden = webView.estimatedProgress >= 1
            }
        }
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateTitleCapsule()
                self?.updateControlState()
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateTitleCapsule()
                self?.updateControlState()
            }
        }

        errorView.onRetry = { [weak self] in self?.reloadTapped() }
        registerCookieObserverIfNeeded()
        Task { await load(initialURL ?? baseURL) }
    }

    deinit {
        // Observations only — cookie observer must be removed on the main thread
        // before deallocation (see prepareForHostTeardown / viewDidDisappear).
        progressObservation?.invalidate()
        titleObservation?.invalidate()
        urlObservation?.invalidate()
    }

    /// Call before the host tears this browser down (mini-program close / float discard).
    /// Stops network work and detaches WK observers so offline failures cannot race free.
    func prepareForHostTeardown() {
        isTornDown = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        progressObservation?.invalidate()
        progressObservation = nil
        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil
        unregisterCookieObserverIfNeeded()
    }

    /// Lock page interaction to prevent left/right rubber-band shake and pinch zoom.
    func setPageInteractionLocked(_ locked: Bool) {
        isPageInteractionLocked = locked
        applyPageInteractionLock()
        if locked {
            Task { @MainActor in
                await injectViewportZoomLockIfNeeded()
            }
        }
    }

    private func applyPageInteractionLock() {
        let locked = isPageInteractionLocked
        // Mini-program host owns edge-back; keep WK's gesture off there even unlocked.
        let allowWKBackForward = !hidesBrowserControlBar && !locked
        webView.allowsBackForwardNavigationGestures = allowWKBackForward
        applyLock(to: webView.scrollView, locked: locked)
        if let popup = popupWebView {
            popup.allowsBackForwardNavigationGestures = allowWKBackForward
            applyLock(to: popup.scrollView, locked: locked)
        }
    }

    private func applyLock(to scrollView: UIScrollView, locked: Bool) {
        scrollView.bounces = !locked
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = !locked
        scrollView.bouncesZoom = !locked
        scrollView.pinchGestureRecognizer?.isEnabled = !locked
        if locked {
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 1
            if abs(scrollView.zoomScale - 1) > 0.01 {
                scrollView.setZoomScale(1, animated: false)
            }
        }
    }

    private func injectViewportZoomLockIfNeeded() async {
        guard isPageInteractionLocked, !isTornDown else { return }
        let script = """
        (function() {
          var meta = document.querySelector('meta[name="viewport"]');
          if (!meta) {
            meta = document.createElement('meta');
            meta.name = 'viewport';
            document.head.appendChild(meta);
          }
          var content = meta.getAttribute('content') || 'width=device-width, initial-scale=1';
          content = content
            .replace(/user-scalable\\s*=\\s*yes/gi, 'user-scalable=no')
            .replace(/maximum-scale\\s*=\\s*[0-9.]+/gi, 'maximum-scale=1');
          if (!/user-scalable\\s*=/i.test(content)) content += ', user-scalable=no';
          if (!/maximum-scale\\s*=/i.test(content)) content += ', maximum-scale=1';
          meta.setAttribute('content', content);
        })();
        """
        _ = try? await webView.evaluateJavaScript(script)
    }

    private func unregisterCookieObserverIfNeeded() {
        guard isCookieObserverRegistered else { return }
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        isCookieObserverRegistered = false
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.setToolbarHidden(true, animated: animated)
        store.reload()
        updateControlState()
        updateTitleCapsule()
        if hidesHostTabBarAtRoot {
            (tabBarController as? ForumTabBarController)?.syncTabBarVisibilityForCurrentContent()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Flush cookies before the web view is torn down (mini-program close, pop, dismiss).
        persistCookiesForCurrentPage()
        if isMovingFromParent || isBeingDismissed {
            // Stop loads early so offline errors don't fire after the page is gone.
            webView.stopLoading()
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            persistCookiesForCurrentPage()
            unregisterCookieObserverIfNeeded()
        }
    }

    private func registerCookieObserverIfNeeded() {
        guard !isCookieObserverRegistered else { return }
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        isCookieObserverRegistered = true
    }

    /// Pull cookies for the current page (or initial URL) into the durable jar.
    private func persistCookiesForCurrentPage() {
        let url = webView.url ?? initialURL
        Task { @MainActor in
            await WebCookieStore.shared.syncFromWebView(
                webView.configuration.websiteDataStore,
                for: url
            )
        }
    }


    private func makeControlButton(systemName: String, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func configureTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = .systemBackground

        titleCapsule.translatesAutoresizingMaskIntoConstraints = false
        titleCapsule.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
        titleCapsule.layer.cornerRadius = 16
        titleCapsule.layer.cornerCurve = .continuous
        titleCapsule.addTarget(self, action: #selector(titleCapsuleTapped), for: .touchUpInside)

        securityImageView.translatesAutoresizingMaskIntoConstraints = false
        securityImageView.image = UIImage(systemName: "lock.fill")
        securityImageView.tintColor = .secondaryLabel
        securityImageView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .left
        titleLabel.text = String(localized: "me.browser.page", defaultValue: "浏览器")

        titleCapsule.addSubview(securityImageView)
        titleCapsule.addSubview(titleLabel)

        let stack = UIStackView(arrangedSubviews: [
            closeButton, titleCapsule, backButton, forwardButton, reloadButton, moreButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        topBar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -4),

            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            backButton.widthAnchor.constraint(equalToConstant: 32),
            forwardButton.widthAnchor.constraint(equalToConstant: 32),
            reloadButton.widthAnchor.constraint(equalToConstant: 32),
            moreButton.widthAnchor.constraint(equalToConstant: 32),

            titleCapsule.heightAnchor.constraint(equalToConstant: 32),
            titleCapsule.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            securityImageView.leadingAnchor.constraint(equalTo: titleCapsule.leadingAnchor, constant: 10),
            securityImageView.centerYAnchor.constraint(equalTo: titleCapsule.centerYAnchor),
            securityImageView.widthAnchor.constraint(equalToConstant: 11),
            securityImageView.heightAnchor.constraint(equalToConstant: 11),

            titleLabel.leadingAnchor.constraint(equalTo: securityImageView.trailingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: titleCapsule.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: titleCapsule.centerYAnchor),
        ])
        titleCapsule.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleCapsule.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func updateTitleCapsule() {
        let pageTitle = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageTitle.isEmpty, pageTitle.count < 40 {
            titleLabel.text = pageTitle
        } else if let host = webView.url?.host, !host.isEmpty {
            titleLabel.text = host
        } else {
            titleLabel.text = String(localized: "me.browser.page", defaultValue: "浏览器")
        }
        let isHTTPS = webView.url?.scheme?.lowercased() == "https"
        securityImageView.image = UIImage(systemName: isHTTPS ? "lock.fill" : "globe")
    }

    private func load(_ url: URL) async {
        guard !isTornDown else { return }
        guard let normalizedURL = BrowserHistoryStore.normalizedPageURL(url) else {
            showMessage(BrowserHistoryStoreError.unsupportedURL.localizedDescription)
            return
        }
        // 先写入历史，保证从任意入口打开内部浏览器都能记一笔。
        try? store.recordVisit(url: normalizedURL, title: webView.title ?? normalizedURL.host)

        let dataStore = webView.configuration.websiteDataStore
        // Push the app's durable Discourse session into WK before the first navigation
        // (forum apex + optional page host), then flush so the document request is signed in.
        await WebCookieStore.shared.primeBrowserSession(
            to: dataStore,
            forumURL: baseURL,
            pageURL: normalizedURL
        )
        // After awaits the host may have closed the mini-program (common offline).
        guard !isTornDown, isViewLoaded else { return }

        errorView.isHidden = true
        var request = URLRequest(url: normalizedURL)
        // Offline / flaky networks: fail faster instead of hanging the first paint.
        request.timeoutInterval = 30
        // Also attach Cookie header as a belt-and-suspenders for the first navigation
        // (some WebKit builds apply httpCookieStore slightly after the first load).
        let cookieHeader = WebCookieStore.shared.cookieHeader(for: normalizedURL)
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let userAgent = WebCookieStore.shared.userAgent {
            webView.customUserAgent = userAgent
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        webView.load(request)
        updateTitleCapsule()
        updateControlState()
    }

    private func updateControlState() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        let reloadName = webView.isLoading ? "xmark" : "arrow.clockwise"
        reloadButton.configuration?.image = UIImage(
            systemName: reloadName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        updateTitleCapsule()
    }

    private func showMessage(_ message: String) {
        guard !isTornDown, presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }

    private static func friendlyNetworkMessage(for error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return String(
                localized: "me.browser.offline",
                defaultValue: "当前无网络连接，请检查网络后重试"
            )
        case NSURLErrorTimedOut:
            return String(
                localized: "me.browser.timeout",
                defaultValue: "连接超时，请稍后重试"
            )
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return String(
                localized: "me.browser.dns_failed",
                defaultValue: "无法解析网站地址，请检查网络或网址"
            )
        default:
            return error.localizedDescription
        }
    }


    @objc private func closeTapped() {
        if hidesHostTabBarAtRoot {
            tabBarController?.selectedIndex = 0
            (tabBarController as? ForumTabBarController)?.syncTabBarVisibilityForCurrentContent()
            return
        }
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func titleCapsuleTapped() {
        // 点击标题胶囊：复制当前链接（不展示完整地址栏）
        guard let url = webView.url else { return }
        UIPasteboard.general.url = url
        showMessage(String(localized: "me.browser.link_copied", defaultValue: "链接已复制"))
    }

    @objc private func closeRootBrowserTapped() {
        closeTapped()
    }

    @objc private func backTapped() { webView.goBack() }

    var canGoBack: Bool { webView.canGoBack }

    /// Go back in web history if possible; return true if a back was performed.
    @discardableResult
    func goBackIfPossible() -> Bool {
        guard webView.canGoBack else { return false }
        webView.goBack()
        return true
    }

    /// Restore the page that `goBackIfPossible` left, used when an interactive back cancels.
    @discardableResult
    func goForwardIfPossible() -> Bool {
        guard webView.canGoForward else { return false }
        webView.goForward()
        return true
    }

    /// Current page for mini-program host bookmark / share.
    var currentPageURL: URL? { webView.url }
    var currentPageTitle: String? { webView.title }
    var browserHistoryStore: BrowserHistoryStore { store }
    @objc private func forwardTapped() { webView.goForward() }
    @objc private func reloadTapped() {
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
        updateControlState()
    }
    @objc private func homeTapped() {
        // 回到「网页浏览」主页（收藏/历史入口），不再跳 Linux.do 站点首页。
        if let nav = navigationController,
           let hub = nav.viewControllers.first(where: { $0 is WebBrowsingHomeViewController }) {
            nav.popToViewController(hub, animated: true)
            return
        }
        if let nav = navigationController {
            let hub = WebBrowsingHomeViewController(
                api: DiscourseAPI(baseURL: baseURL.absoluteString),
                username: nil,
                historyStore: store
            )
            // Prefer replace current browser with hub if no hub in stack.
            var stack = nav.viewControllers.filter { !($0 is InAppBrowserViewController) }
            stack.append(hub)
            nav.setViewControllers(stack, animated: true)
            return
        }
        Task { await load(baseURL) }
    }

    @objc private func bookmarkTapped() {
        guard let url = webView.url ?? initialURL else {
            DoerFeedback.presentToast(
                String(localized: "mini_program.bookmark.unavailable", defaultValue: "当前页无法收藏"),
                on: self
            )
            return
        }
        do {
            if store.isBookmarked(url) {
                try store.removeBookmark(url: url)
                DoerFeedback.presentToast(
                    String(localized: "me.browser.bookmark_removed", defaultValue: "已取消收藏"),
                    on: self
                )
            } else {
                try store.addBookmark(url: url, title: webView.title)
                DoerFeedback.presentToast(
                    String(localized: "me.browser.bookmark_added", defaultValue: "已收藏"),
                    on: self
                )
            }
            updateControlState()
        } catch {
            DoerFeedback.presentToast(error.localizedDescription, on: self)
        }
    }

    @objc private func libraryTapped() {
        let library = BrowserLibraryViewController(store: store) { [weak self] url in
            guard let self else { return }
            self.navigationController?.popViewController(animated: true)
            Task { await self.load(url) }
        }
        navigationController?.pushViewController(library, animated: true)
    }

    @objc private func shareTapped() {
        guard let url = webView.url else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = moreButton
        activity.popoverPresentationController?.sourceRect = moreButton.bounds
        present(activity, animated: true)
    }

    @objc private func moreTapped() {
        let isBookmarked = store.isBookmarked(webView.url)
        // FluxDo 更多菜单：收藏 / 复制链接 / 外部浏览器
        let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(
            title: isBookmarked
                ? String(localized: "me.browser.remove_bookmark", defaultValue: "取消收藏")
                : String(localized: "me.browser.add_bookmark", defaultValue: "收藏此页"),
            style: .default
        ) { [weak self] _ in self?.bookmarkTapped() })
        
        menu.addAction(UIAlertAction(title: String(localized: "mini_program.add_as_program", defaultValue: "添加到小程序"), style: .default) { [weak self] _ in
            self?.addCurrentPageAsMiniProgram()
        })
        menu.addAction(UIAlertAction(
            title: String(localized: "plugins.newapi.add_from_browser", defaultValue: "添加到 NewAPI 签到"),
            style: .default
        ) { [weak self] _ in
            self?.addCurrentPageAsNewAPICheckIn()
        })
        
        menu.addAction(UIAlertAction(title: String(localized: "me.browser.copy_url", defaultValue: "复制链接"), style: .default) { [weak self] _ in
            UIPasteboard.general.url = self?.webView.url
        })
        menu.addAction(UIAlertAction(title: String(localized: "me.browser.open_external", defaultValue: "在外部浏览器打开"), style: .default) { [weak self] _ in
            guard let url = self?.webView.url else { return }
            UIApplication.shared.open(url)
        })
        menu.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        menu.popoverPresentationController?.sourceView = moreButton
        menu.popoverPresentationController?.sourceRect = moreButton.bounds
        present(menu, animated: true)
    }

    @objc private func addCurrentPageAsMiniProgram() {
        guard let url = webView.url else { return }
        Task { @MainActor in
            let service = MiniProgramMetadataService()
            let metadata = await service.fetch(url: url)
            let logoData = try? await service.fetchLogoImageData(for: metadata.sourceURL)

            let alert = UIAlertController(
                title: String(localized: "mini_program.add_as_program.title", defaultValue: "添加到小程序"),
                message: metadata.sourceURL.host ?? metadata.name,
                preferredStyle: .alert
            )
            alert.addTextField { field in
                field.placeholder = String(localized: "mini_program.name", defaultValue: "名称")
                field.text = metadata.name
            }
            alert.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "common.done"), style: .default) { [weak self] _ in
                guard let self else { return }
                let name = alert.textFields?.first?.text ?? metadata.name
                do {
                    let programStore = MiniProgramStore.shared
                    let programID = try programStore.addCustomProgram(
                        name: name,
                        url: metadata.sourceURL,
                        categoryID: MiniProgramCategoryID.other,
                        icon: .none
                    )
                    if let logoData,
                       let path = try? MiniProgramIconStore.shared.saveIconData(logoData, programID: programID) {
                        try? programStore.updateCustomProgram(
                            id: programID,
                            name: name,
                            url: metadata.sourceURL,
                            categoryID: MiniProgramCategoryID.other,
                            icon: .local(relativePath: path),
                            isVisible: true
                        )
                    }
                    programStore.addFavorite(programID)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    DoerFeedback.presentToast(
                        String(localized: "mini_program.added", defaultValue: "已添加到小程序"),
                        on: self
                    )
                } catch {
                    DoerFeedback.presentToast(error.localizedDescription, on: self)
                }
            })
            self.present(alert, animated: true)
        }
    }

    @objc private func addCurrentPageAsNewAPICheckIn() {
        let pageURL = webView.url ?? initialURL
        guard let pageURL,
              let origin = NewAPICheckInLoginSupport.siteOrigin(from: pageURL)
        else {
            DoerFeedback.presentToast(
                String(localized: "plugins.newapi.add_from_browser.invalid_url", defaultValue: "无法识别当前站点地址"),
                on: self
            )
            return
        }

        Task { @MainActor in
            let runtime = NewAPICheckInRuntime.shared
            let platforms = await runtime.store.platforms()
            let existing = NewAPICheckInLoginSupport.matchingPlatform(in: platforms, url: origin)
            let login = NewAPICheckInLoginViewController(
                baseURL: origin,
                mode: .newAPI,
                store: runtime.store,
                service: runtime.service,
                existingPlatform: existing
            ) { [weak self] in
                guard let self else { return }
                DoerFeedback.presentToast(
                    String(
                        localized: "plugins.newapi.add_from_browser.saved",
                        defaultValue: "已添加到 NewAPI 签到"
                    ),
                    on: self
                )
            }
            login.hidesBottomBarWhenPushed = true
            if let navigationController {
                navigationController.setNavigationBarHidden(false, animated: true)
                navigationController.pushViewController(login, animated: true)
            } else {
                let nav = UINavigationController(rootViewController: login)
                nav.modalPresentationStyle = .pageSheet
                present(nav, animated: true)
            }
        }
    }
}


extension InAppBrowserViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if webView !== self.webView {
            switch BrowserNavigationURLClassifier.classify(url) {
            case .web:
                self.webView.load(navigationAction.request)
                popupWebView = nil
                decisionHandler(.cancel)
            case .internalWebKit:
                decisionHandler(.allow)
            case .externalApp:
                popupWebView = nil
                decisionHandler(.cancel)
                confirmExternalScheme(url)
            case .invalid:
                popupWebView = nil
                decisionHandler(.cancel)
            }
            return
        }
        switch BrowserNavigationURLClassifier.classify(url) {
        case .web, .internalWebKit:
            decisionHandler(.allow)
        case .externalApp:
            decisionHandler(.cancel)
            confirmExternalScheme(url)
        case .invalid:
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorView.isHidden = true
        updateControlState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else {
            updateControlState()
            return
        }
        guard BrowserNavigationURLClassifier.classify(url) == .web else {
            updateControlState()
            return
        }
        updateTitleCapsule()
        updateControlState()
        // Re-apply after navigation — WebKit may reset zoom/bounce on new documents.
        if isPageInteractionLocked {
            applyPageInteractionLock()
        }
        try? store.recordVisit(url: url, title: webView.title)
        Task {
            await WebCookieStore.shared.syncFromWebView(webView.configuration.websiteDataStore, for: url)
            if let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String {
                WebCookieStore.shared.userAgent = userAgent
            }
            if isPageInteractionLocked {
                await injectViewportZoomLockIfNeeded()
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard !isTornDown else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        // Offline / DNS failures: show inline error instead of letting WK leave a blank crashy state.
        let message = Self.friendlyNetworkMessage(for: error)
        errorView.configure(message: message)
        errorView.isHidden = false
        progressView.isHidden = true
        updateControlState()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isTornDown else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        let message = Self.friendlyNetworkMessage(for: error)
        errorView.configure(message: message)
        errorView.isHidden = false
        progressView.isHidden = true
        updateControlState()
    }

    private func confirmExternalScheme(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            showMessage(BrowserHistoryStoreError.unsupportedURL.localizedDescription)
            return
        }
        let alert = UIAlertController(
            title: String(localized: "me.browser.external_scheme.title", defaultValue: "打开其他应用？"),
            message: String(
                format: String(localized: "me.browser.external_scheme.message %@", defaultValue: "此链接需要交给 %@ 应用处理。"),
                scheme
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "me.browser.external_scheme.open", defaultValue: "继续打开"), style: .default) { _ in
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }
}

extension InAppBrowserViewController: WKHTTPCookieStoreObserver {
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // SPA logins often set cookies without a full document navigation.
        // Keep the durable jar in sync so the next mini-program open stays logged in.
        let url = webView.url ?? initialURL
        Task { @MainActor in
            await WebCookieStore.shared.syncFromWebView(
                webView.configuration.websiteDataStore,
                for: url
            )
        }
    }
}

extension InAppBrowserViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              let url = navigationAction.request.url
        else { return nil }
        switch BrowserNavigationURLClassifier.classify(url) {
        case .web:
            webView.load(navigationAction.request)
            return nil
        case .internalWebKit:
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            popupWebView = popup
            return popup
        case .externalApp:
            confirmExternalScheme(url)
            return nil
        case .invalid:
            return nil
        }
    }
}

private final class BrowserErrorView: UIView {
    var onRetry: (() -> Void)?

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        let imageView = UIImageView(image: UIImage(systemName: "wifi.exclamationmark"))
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.heightAnchor.constraint(equalToConstant: 38).isActive = true

        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "action.retry", defaultValue: "重试")
        configuration.cornerStyle = .capsule
        let retryButton = UIButton(configuration: configuration)
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [imageView, messageLabel, retryButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: String) {
        messageLabel.text = message
    }
}

final class BrowserLibraryViewController: UIViewController {
    enum Section: Int {
        case history
        case bookmarks
    }

    private let store: BrowserHistoryStore
    private let onOpen: (URL) -> Void
    private var selectedSection: Section
    private var searchQuery = ""

    private lazy var searchController: UISearchController = {
        let controller = UISearchController(searchResultsController: nil)
        controller.obscuresBackgroundDuringPresentation = false
        controller.searchResultsUpdater = self
        controller.searchBar.placeholder = String(localized: "me.browser.library.search", defaultValue: "搜索标题或网址")
        return controller
    }()

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [
            String(localized: "me.browser.history", defaultValue: "历史"),
            String(localized: "me.browser.bookmarks", defaultValue: "书签"),
        ])
        control.selectedSegmentIndex = 0
        control.addTarget(self, action: #selector(sectionChanged), for: .valueChanged)
        return control
    }()

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.separatorStyle = .none
        tableView.backgroundColor = .systemGroupedBackground
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 20, right: 0)
        tableView.register(BrowserLibraryCardCell.self, forCellReuseIdentifier: BrowserLibraryCardCell.reuseID)
        return tableView
    }()

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        return label
    }()

    init(
        store: BrowserHistoryStore,
        initialSection: Section = .history,
        onOpen: @escaping (URL) -> Void
    ) {
        self.store = store
        self.onOpen = onOpen
        self.selectedSection = initialSection
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "me.browser.library", defaultValue: "浏览器资料库")
        view.backgroundColor = .systemGroupedBackground
        segmentedControl.selectedSegmentIndex = selectedSection.rawValue
        navigationItem.titleView = segmentedControl
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        let clearItem = UIBarButtonItem(
            title: String(localized: "action.clear", defaultValue: "清空"),
            style: .plain,
            target: self,
            action: #selector(clearTapped)
        )
        let addItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            style: .plain,
            target: self,
            action: #selector(addBookmarkTapped)
        )
        addItem.accessibilityLabel = String(localized: "me.browser.bookmark.manual_add", defaultValue: "手动添加书签")
        navigationItem.rightBarButtonItems = [clearItem, addItem]
        navigationController?.setToolbarHidden(true, animated: false)

        view.addSubview(tableView)
        view.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.reload()
        reloadData()
    }

    private var records: [BrowserPageRecord] {
        let source = selectedSection == .history ? store.history : store.bookmarks
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter { record in
            record.title.localizedCaseInsensitiveContains(query)
                || record.urlString.localizedCaseInsensitiveContains(query)
        }
    }

    private var unfilteredRecords: [BrowserPageRecord] {
        selectedSection == .history ? store.history : store.bookmarks
    }

    private func reloadData() {
        tableView.reloadData()
        // 有数据时显示列表，空数据时显示空态文案（之前写反了导致“有书签/历史也空白”）。
        tableView.isHidden = records.isEmpty
        stateLabel.isHidden = !records.isEmpty
        if !searchQuery.isEmpty, records.isEmpty, !unfilteredRecords.isEmpty {
            stateLabel.text = String(localized: "me.browser.library.search.empty", defaultValue: "没有匹配的记录")
        } else {
            stateLabel.text = selectedSection == .history
                ? String(localized: "me.browser.history.empty", defaultValue: "没有本地浏览记录")
                : String(localized: "me.browser.bookmarks.empty", defaultValue: "没有本地书签")
        }
        navigationItem.rightBarButtonItems?.first?.isEnabled = !unfilteredRecords.isEmpty
    }

    @objc private func sectionChanged() {
        selectedSection = Section(rawValue: segmentedControl.selectedSegmentIndex) ?? .history
        reloadData()
    }

    @objc private func clearTapped() {
        let alert = UIAlertController(
            title: String(localized: "me.browser.clear.title", defaultValue: "清空当前列表？"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.clear", defaultValue: "清空"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                if self.selectedSection == .history {
                    try self.store.clearHistory()
                } else {
                    try self.store.clearBookmarks()
                }
                self.reloadData()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }

    @objc private func addBookmarkTapped() {
        let alert = UIAlertController(
            title: String(localized: "me.browser.bookmark.manual_add", defaultValue: "手动添加书签"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "me.browser.bookmark.title", defaultValue: "名称（可选）")
        }
        alert.addTextField { field in
            field.placeholder = String(localized: "me.browser.address.placeholder", defaultValue: "输入网址或路径")
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.add", defaultValue: "添加"), style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let address = alert?.textFields?[safe: 1]?.text,
                  let url = Self.normalizedManualURL(address)
            else {
                self?.showError(BrowserHistoryStoreError.unsupportedURL)
                return
            }
            do {
                try self.store.addBookmark(url: url, title: alert?.textFields?[safe: 0]?.text)
                self.selectedSection = .bookmarks
                self.segmentedControl.selectedSegmentIndex = Section.bookmarks.rawValue
                self.reloadData()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private static func normalizedManualURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate) else { return nil }
        return BrowserHistoryStore.normalizedPageURL(url)
    }

    private func rename(_ record: BrowserPageRecord) {
        let alert = UIAlertController(
            title: String(localized: "me.browser.bookmark.rename", defaultValue: "重命名书签"),
            message: record.urlString,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.text = record.title
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "action.save", defaultValue: "保存"), style: .default) { [weak self, weak alert] _ in
            guard let self, let title = alert?.textFields?.first?.text else { return }
            do {
                try self.store.renameBookmark(record, title: title)
                self.reloadData()
            } catch {
                self.showError(error)
            }
        })
        present(alert, animated: true)
    }

    private func remove(_ record: BrowserPageRecord) {
        do {
            if selectedSection == .history {
                try store.removeHistory(record)
            } else {
                try store.removeBookmark(record)
            }
            reloadData()
        } catch {
            showError(error)
        }
    }

    private func convertBookmarkToMiniProgram(_ record: BrowserPageRecord) {
        guard let url = URL(string: record.urlString) else {
            showError(BrowserHistoryStoreError.unsupportedURL)
            return
        }
        let name = record.title
        do {
            let programStore = MiniProgramStore.shared
            let programID = try programStore.addCustomProgram(
                name: name,
                url: url,
                categoryID: MiniProgramCategoryID.other,
                icon: .none
            )
            programStore.addFavorite(programID)
            Task { @MainActor in
                let service = MiniProgramMetadataService()
                if let logoData = try? await service.fetchLogoImageData(for: url),
                   let path = try? MiniProgramIconStore.shared.saveIconData(logoData, programID: programID) {
                    try? programStore.updateCustomProgram(
                        id: programID,
                        name: name,
                        url: url,
                        categoryID: MiniProgramCategoryID.other,
                        icon: .local(relativePath: path),
                        isVisible: true
                    )
                }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            let alert = UIAlertController(
                title: String(localized: "mini_program.added", defaultValue: "已添加到小程序"),
                message: name,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.ok", defaultValue: "好"), style: .default))
            present(alert, animated: true)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "common.ok"), style: .default))
        present(alert, animated: true)
    }
}

extension BrowserLibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text ?? ""
        reloadData()
    }
}

extension BrowserLibraryViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        records.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let record = records[indexPath.row]
        let cell = tableView.dequeueReusableCell(
            withIdentifier: BrowserLibraryCardCell.reuseID,
            for: indexPath
        ) as! BrowserLibraryCardCell
        cell.configure(
            record: record,
            kind: selectedSection == .history ? .history : .bookmark,
            relativeDate: relativeDate(record.timestamp)
        )
        return cell
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

extension BrowserLibraryViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let url = URL(string: records[indexPath.row].urlString) else { return }
        onOpen(url)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let record = records[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: String(localized: "action.delete", defaultValue: "删除")) { [weak self] _, _, completion in
            self?.remove(record)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        var actions = [delete]
        if selectedSection == .bookmarks {
            let rename = UIContextualAction(style: .normal, title: String(localized: "action.rename", defaultValue: "重命名")) { [weak self] _, _, completion in
                self?.rename(record)
                completion(true)
            }
            rename.backgroundColor = .systemBlue
            rename.image = UIImage(systemName: "pencil")
            actions.append(rename)

            let toMini = UIContextualAction(
                style: .normal,
                title: String(localized: "mini_program.convert_from_bookmark", defaultValue: "转小程序")
            ) { [weak self] _, _, completion in
                self?.convertBookmarkToMiniProgram(record)
                completion(true)
            }
            toMini.backgroundColor = .systemGreen
            toMini.image = UIImage(systemName: "app.badge.fill")
            actions.insert(toMini, at: 0)
        }
        return UISwipeActionsConfiguration(actions: actions)
    }
}

// MARK: - Library card cell

private final class BrowserLibraryCardCell: UITableViewCell {
    static let reuseID = "BrowserLibraryCardCell"

    enum Kind {
        case history
        case bookmark
    }

    private let cardView = UIView()
    private let iconBackground = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let hostLabel = UILabel()
    private let timeLabel = UILabel()
    private let chevronView = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemGroupedBackground
        cardView.layer.cornerRadius = 16
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1.0 / UIScreen.main.scale
        cardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.22).cgColor

        iconBackground.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.layer.cornerRadius = 12
        iconBackground.layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2

        hostLabel.translatesAutoresizingMaskIntoConstraints = false
        hostLabel.font = .systemFont(ofSize: 13, weight: .regular)
        hostLabel.textColor = .secondaryLabel
        hostLabel.lineBreakMode = .byTruncatingMiddle

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevronView.tintColor = .tertiaryLabel
        chevronView.contentMode = .scaleAspectFit

        contentView.addSubview(cardView)
        cardView.addSubview(iconBackground)
        iconBackground.addSubview(iconView)
        cardView.addSubview(titleLabel)
        cardView.addSubview(hostLabel)
        cardView.addSubview(timeLabel)
        cardView.addSubview(chevronView)

        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),

            iconBackground.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
            iconBackground.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 40),
            iconBackground.heightAnchor.constraint(equalToConstant: 40),

            iconView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -8),

            hostLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            hostLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            hostLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            hostLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),

            timeLabel.centerYAnchor.constraint(equalTo: hostLabel.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -6),

            chevronView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
            chevronView.centerYAnchor.constraint(equalTo: cardView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(record: BrowserPageRecord, kind: Kind, relativeDate: String) {
        let isHistory = kind == .history
        let tint: UIColor = isHistory ? .systemTeal : .systemOrange
        iconBackground.backgroundColor = tint.withAlphaComponent(0.14)
        iconView.tintColor = tint
        iconView.image = UIImage(
            systemName: isHistory ? "clock.fill" : "bookmark.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        titleLabel.text = record.title
        let host = URL(string: record.urlString)?.host ?? record.urlString
        hostLabel.text = host
        timeLabel.text = relativeDate
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        let alpha: CGFloat = highlighted ? 0.82 : 1
        UIView.animate(withDuration: 0.15) {
            self.cardView.alpha = alpha
            self.cardView.transform = highlighted
                ? CGAffineTransform(scaleX: 0.985, y: 0.985)
                : .identity
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
