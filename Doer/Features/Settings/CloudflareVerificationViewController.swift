import UIKit
import WebKit

enum CloudflareVerificationPolicy {
    /// After a successful pass, suppress challenge re-prompts while cookies propagate
    /// and Topic Detail / image retries settle.
    private static let verificationGraceDuration: TimeInterval = 30
    private static var verificationGraceUntilByBaseURL: [String: Date] = [:]
    private static let graceLock = NSLock()

    static func normalizedBaseKey(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// Native API challenges allowed during grace before we admit the pass failed.
    private static let graceApiChallengeLimit = 3
    private static var graceApiChallengeCounts: [String: Int] = [:]

    static func markVerificationGrace(baseURL: String, duration: TimeInterval = verificationGraceDuration) {
        let key = normalizedBaseKey(baseURL)
        graceLock.lock()
        verificationGraceUntilByBaseURL[key] = Date().addingTimeInterval(duration)
        graceApiChallengeCounts[key] = 0
        graceLock.unlock()
        // Allow avatar/upload fetches again once clearance is considered good.
        CloudflareImageGate.resume(baseURL: baseURL)
        DiscourseAPI.clearCloudflareForegroundGate(baseURL: baseURL)
        DohDebugLog.record("verification grace armed base=\(key) duration=\(Int(duration))s", subsystem: "CF")
    }

    static func clearVerificationGrace(baseURL: String) {
        let key = normalizedBaseKey(baseURL)
        graceLock.lock()
        verificationGraceUntilByBaseURL[key] = nil
        graceApiChallengeCounts[key] = nil
        graceLock.unlock()
        DohDebugLog.record("verification grace cleared base=\(key)", subsystem: "CF")
    }

    /// Returns true when grace was cleared because native API traffic is still challenged.
    static func noteChallengeDuringGrace(baseURL: String, source: String) -> Bool {
        guard source.hasPrefix("api.") else { return false }
        let key = normalizedBaseKey(baseURL)
        let clearedCount: Int?
        graceLock.lock()
        if let until = verificationGraceUntilByBaseURL[key], Date() < until {
            let count = (graceApiChallengeCounts[key] ?? 0) + 1
            graceApiChallengeCounts[key] = count
            if count >= graceApiChallengeLimit {
                verificationGraceUntilByBaseURL[key] = nil
                graceApiChallengeCounts[key] = nil
                clearedCount = count
            } else {
                clearedCount = nil
            }
        } else {
            clearedCount = nil
        }
        graceLock.unlock()
        guard let count = clearedCount else { return false }
        DohDebugLog.record(
            "verification grace cleared after repeated api challenges base=\(key) count=\(count) source=\(source)",
            subsystem: "CF"
        )
        return true
    }

    static func markVerificationGrace(baseURL: URL, duration: TimeInterval = verificationGraceDuration) {
        markVerificationGrace(baseURL: baseURL.absoluteString, duration: duration)
    }

    static func isInVerificationGrace(baseURL: String, now: Date = Date()) -> Bool {
        let key = normalizedBaseKey(baseURL)
        graceLock.lock()
        defer { graceLock.unlock() }
        guard let until = verificationGraceUntilByBaseURL[key] else { return false }
        if now < until {
            return true
        }
        verificationGraceUntilByBaseURL[key] = nil
        return false
    }

    static func isInVerificationGrace(baseURL: URL, now: Date = Date()) -> Bool {
        isInVerificationGrace(baseURL: baseURL.absoluteString, now: now)
    }

    static func verificationURL(baseURL: URL, responseURL: URL?) -> URL {
        _ = responseURL
        return URL(string: "/challenge", relativeTo: baseURL)?.absoluteURL ?? baseURL
    }

    static func hasUsableClearance(
        currentValue: String?,
        initialValue: String?,
        requiresFreshValue: Bool
    ) -> Bool {
        guard let currentValue, !currentValue.isEmpty else { return false }
        return !requiresFreshValue || currentValue != initialValue
    }

    static func canCompleteVerification(
        currentValue: String?,
        initialValue: String?,
        requiresFreshValue: Bool,
        hasVerifiedPage: Bool,
        hasActiveChallenge: Bool
    ) -> Bool {
        hasVerifiedPage
            && !hasActiveChallenge
            && hasUsableClearance(
                currentValue: currentValue,
                initialValue: initialValue,
                requiresFreshValue: requiresFreshValue
            )
    }

    static func isVerifiedChallengeLanding(
        _ response: HTTPURLResponse,
        baseURL: URL
    ) -> Bool {
        guard response.statusCode == 404,
              let responseURL = response.url,
              responseURL.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              responseURL.host?.lowercased() == baseURL.host?.lowercased(),
              responseURL.port == baseURL.port,
              responseURL.path.lowercased() == "/challenge"
        else { return false }

        // `/challenge?__cf_chl_tk=...` is still inside the Cloudflare hop.
        // Treating that 404 as success cancels the navigation ("frame load
        // interrupted") and auto-dismisses the global shield while Turnstile
        // is still running.
        if hasCloudflareChallengeToken(in: responseURL) {
            return false
        }

        let cfMitigated = response.allHeaderFields.first { key, _ in
            "\(key)".caseInsensitiveCompare("cf-mitigated") == .orderedSame
        }.map { "\($0.value)".lowercased() }
        return cfMitigated?.contains("challenge") != true
    }

    static func hasCloudflareChallengeToken(in url: URL) -> Bool {
        let query = url.query?.lowercased() ?? ""
        guard !query.isEmpty else { return false }
        return query.contains("__cf_chl_") || query.contains("cf_chl_")
    }
}

/// After CF verification: only rebuild Topic Detail when the page is empty or already
/// showing a Cloudflare error. A populated thread must keep its parse and only retry images.
enum TopicDetailCloudflareRecoveryPolicy {
    static func shouldReloadTopic(
        isReady: Bool,
        hasParsedPosts: Bool,
        errorMessage: String?
    ) -> Bool {
        if let errorMessage, errorMessage.localizedCaseInsensitiveContains("cloudflare") {
            return true
        }
        return !isReady || !hasParsedPosts
    }
}

final class CloudflareVerificationViewController: UIViewController {
    private let baseURL: URL
    private let challengeURL: URL
    private let autoDismissOnSuccess: Bool
    private let onFinish: () -> Void
    private var progressObservation: NSKeyValueObservation?
    private var didDetectClearance = false
    private var isCheckingClearance = false
    private var needsVerificationRecheck = false
    private var initialClearanceValue: String?
    private var preparationTask: Task<Void, Never>?
    private var verificationCheckTask: Task<Void, Never>?
    private var didCallOnFinish = false
    private var preparationGeneration = 0
    private var isPreparingChallenge = false
    private var isClosing = false
    private var isCookieObserverRegistered = false
    private var didFinishVerifiedNavigation = false
    private var isFinishing = false
    private var failureCleanupTask: Task<Void, Never>?

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let statusContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }()

    private let statusIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "shield.fill"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .systemOrange
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "cloudflare.verify.instructions")
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }()

    private let progressView: UIProgressView = {
        let view = UIProgressView(progressViewStyle: .bar)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(
        baseURL: URL,
        responseURL: URL? = nil,
        verificationURL: URL? = nil,
        autoDismissOnSuccess: Bool = false,
        onFinish: @escaping () -> Void
    ) {
        self.baseURL = baseURL
        self.challengeURL = verificationURL
            ?? CloudflareVerificationPolicy.verificationURL(
                baseURL: baseURL,
                responseURL: responseURL
            )
        self.autoDismissOnSuccess = autoDismissOnSuccess
        self.onFinish = onFinish
        self.initialClearanceValue = WebCookieStore.shared.cookieValue(
            named: "cf_clearance",
            for: baseURL
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor deinit {
        preparationTask?.cancel()
        verificationCheckTask?.cancel()
        failureCleanupTask?.cancel()
        if isCookieObserverRegistered {
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "cloudflare.verify.title")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(closeTapped)
        )
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                title: String(localized: "weblogin.done"),
                style: .done,
                target: self,
                action: #selector(doneTapped)
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "arrow.clockwise"),
                style: .plain,
                target: self,
                action: #selector(reloadTapped)
            ),
        ]

        statusContainer.addSubview(statusIconView)
        statusContainer.addSubview(statusLabel)
        view.addSubview(statusContainer)
        view.addSubview(progressView)
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            statusContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            statusIconView.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor, constant: 16),
            statusIconView.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 12),
            statusIconView.widthAnchor.constraint(equalToConstant: 20),
            statusIconView.heightAnchor.constraint(equalToConstant: 20),
            statusIconView.bottomAnchor.constraint(lessThanOrEqualTo: statusContainer.bottomAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: statusIconView.trailingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: statusContainer.topAnchor, constant: 10),
            statusLabel.bottomAnchor.constraint(equalTo: statusContainer.bottomAnchor, constant: -10),

            progressView.topAnchor.constraint(equalTo: statusContainer.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.progressView.progress = Float(webView.estimatedProgress)
                self.progressView.isHidden = webView.estimatedProgress >= 1.0
                guard webView.estimatedProgress >= 1.0 else { return }
                self.scheduleVerificationChecks()
            }
        }

        startChallengePreparation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let wasDismissed = isBeingDismissed
            || navigationController?.isBeingDismissed == true
            || isMovingFromParent
        guard wasDismissed else { return }
        isClosing = true
        if didDetectClearance {
            notifyFinishIfNeeded()
            return
        }
        Task { @MainActor [self] in
            await self.ensureFailureCleanup().value
            self.notifyFinishIfNeeded()
        }
    }

    @objc private func closeTapped() {
        guard !isFinishing else { return }
        isFinishing = true
        isClosing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cancelPendingVerificationWork()
            self.finishAndClose()
        }
    }

    @objc private func doneTapped() {
        guard !isFinishing else { return }
        isFinishing = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.didDetectClearance, !self.isPreparingChallenge {
                await self.cancelVerificationCheckTask()
                await self.syncCookiesAndDetectClearance()
            }
            if !self.didDetectClearance {
                await self.ensureFailureCleanup().value
            } else {
                self.isClosing = true
            }
            self.finishAndClose()
        }
    }

    @objc private func reloadTapped() {
        guard !isClosing else { return }
        log("foreground reload tapped base=\(baseURL.absoluteString)")
        didDetectClearance = false
        isCheckingClearance = false
        needsVerificationRecheck = false
        didFinishVerifiedNavigation = false
        preparationTask?.cancel()
        verificationCheckTask?.cancel()
        verificationCheckTask = nil
        updateStatus(
            text: String(localized: "cloudflare.verify.instructions"),
            symbolName: "shield.fill",
            color: .systemOrange
        )
        startChallengePreparation()
    }

    @MainActor
    private func startChallengePreparation() {
        preparationGeneration += 1
        let generation = preparationGeneration
        isPreparingChallenge = true
        didFinishVerifiedNavigation = false
        preparationTask = Task { @MainActor [weak self] in
            await self?.prepareAndLoadChallenge(generation: generation)
        }
    }

    @MainActor
    private func prepareAndLoadChallenge(generation: Int) async {
        defer {
            if generation == preparationGeneration {
                isPreparingChallenge = false
                preparationTask = nil
            }
        }
        guard !isClosing else { return }
        await LightweightDohProxyService.shared.prepareBrowserProxy()
        guard generation == preparationGeneration, !Task.isCancelled, !isClosing else { return }
        log(
            "foreground load challenge base=\(baseURL.absoluteString) url=\(challengeURL.absoluteString) autoDismiss=\(autoDismissOnSuccess) dohBrowser=\(LightweightDohProxyService.shared.ensureRunning() != nil)"
        )
        await WebCookieStore.shared.syncToWebView(
            webView.configuration.websiteDataStore,
            for: baseURL
        )
        guard generation == preparationGeneration, !Task.isCancelled, !isClosing else { return }
        if autoDismissOnSuccess {
            WebCookieStore.shared.deleteCookie(named: "cf_clearance", for: baseURL)
            await deleteWebViewCookie(named: "cf_clearance")
        }
        guard generation == preparationGeneration, !Task.isCancelled, !isClosing else { return }
        registerCookieObserverIfNeeded()
        var request = URLRequest(url: challengeURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        webView.load(request)
    }

    @MainActor
    private func registerCookieObserverIfNeeded() {
        guard !isCookieObserverRegistered else { return }
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        isCookieObserverRegistered = true
    }

    @MainActor
    private func deleteWebViewCookie(named name: String) async {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard let host = baseURL.host?.lowercased() else { return }
        for cookie in cookies where cookie.name == name {
            let domain = cookie.domain.lowercased()
            let domainMatch = host == domain
                || (domain.hasPrefix(".") && (host == String(domain.dropFirst()) || host.hasSuffix(domain)))
            guard domainMatch else { continue }
            await withCheckedContinuation { continuation in
                cookieStore.delete(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    private func syncCookiesAndDetectClearance() async {
        guard !didDetectClearance, !isPreparingChallenge, !isClosing else { return }
        if isCheckingClearance {
            needsVerificationRecheck = true
            return
        }

        isCheckingClearance = true
        defer {
            isCheckingClearance = false
            if needsVerificationRecheck, !didDetectClearance {
                scheduleVerificationChecks()
            }
        }

        repeat {
            needsVerificationRecheck = false
            await performVerificationCheck()
        } while needsVerificationRecheck && !didDetectClearance
    }

    @MainActor
    private func performVerificationCheck() async {
        if await hasLoadedKnownVerifiedNotFoundPage() {
            await completeKnownVerifiedLanding(
                reason: "foreground known verified not-found page"
            )
            return
        }

        await syncCloudflareCookieFromWebView()
        guard !Task.isCancelled, !isClosing else { return }
        let clearanceValue = WebCookieStore.shared.cookieValue(named: "cf_clearance", for: baseURL)
        let hasVerifiedPage = await hasLoadedVerifiedBasePage()
        guard !Task.isCancelled, !isClosing else { return }
        let hasActiveChallenge = hasVerifiedPage ? await pageHasActiveCloudflareChallenge() : true
        let canComplete = CloudflareVerificationPolicy.canCompleteVerification(
            currentValue: clearanceValue,
            initialValue: initialClearanceValue,
            requiresFreshValue: autoDismissOnSuccess,
            hasVerifiedPage: hasVerifiedPage,
            hasActiveChallenge: hasActiveChallenge
        )
        log(
            "foreground check url=\(webView.url?.absoluteString ?? "none") cf=\(clearanceValue?.isEmpty == false) verifiedPage=\(hasVerifiedPage) activeChallenge=\(hasActiveChallenge) complete=\(canComplete)"
        )
        guard canComplete else {
            if hasVerifiedPage {
                log("foreground verified page loaded but verification state is incomplete; waiting")
            }
            return
        }
        await updateStoredUserAgentFromWebView()
        completeVerification()
    }

    @MainActor
    private func completeIfKnownVerifiedRedirect(_ url: URL?) async {
        guard isKnownVerifiedRedirectURL(url) else { return }
        await completeKnownVerifiedLanding(
            reason: "foreground known verified redirect url=\(url?.absoluteString ?? "none")"
        )
    }

    @MainActor
    private func completeKnownVerifiedLanding(reason: String) async {
        guard !didDetectClearance, !isClosing else { return }
        log(reason)
        await syncCloudflareCookieFromWebView()
        await updateStoredUserAgentFromWebView()
        completeVerification()
    }

    @MainActor
    private func syncCloudflareCookieFromWebView() async {
        await WebCookieStore.shared.syncFromWebView(
            webView.configuration.websiteDataStore,
            names: ["cf_clearance"],
            for: baseURL
        )
    }

    @MainActor
    private func updateStoredUserAgentFromWebView() async {
        if let userAgent = try? await webView.evaluateJavaScript("navigator.userAgent") as? String {
            WebCookieStore.shared.userAgent = userAgent
        }
    }

    @MainActor
    private func cancelVerificationCheckTask() async {
        let task = verificationCheckTask
        verificationCheckTask = nil
        task?.cancel()
        await task?.value
    }

    @MainActor
    private func cancelPendingVerificationWork() async {
        isClosing = true
        preparationGeneration += 1
        let preparation = preparationTask
        preparationTask = nil
        preparation?.cancel()
        await preparation?.value
        isPreparingChallenge = false
        await cancelVerificationCheckTask()
    }

    @MainActor
    private func ensureFailureCleanup() -> Task<Void, Never> {
        if let failureCleanupTask {
            return failureCleanupTask
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cancelPendingVerificationWork()
        }
        failureCleanupTask = task
        return task
    }

    @MainActor
    private func completeVerification() {
        guard !didDetectClearance else { return }
        log("foreground complete base=\(baseURL.absoluteString)")
        CloudflareVerificationPolicy.markVerificationGrace(baseURL: baseURL)
        didDetectClearance = true
        needsVerificationRecheck = false
        verificationCheckTask?.cancel()
        verificationCheckTask = nil
        updateStatus(
            text: String(localized: "cloudflare.verify.success"),
            symbolName: "checkmark.shield.fill",
            color: .systemGreen
        )
        NotificationCenter.default.post(
            name: DiscourseAPI.cloudflareVerificationCompletedNotification,
            object: nil,
            userInfo: [
                DiscourseAPI.cloudflareBaseURLUserInfoKey: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            ]
        )
        guard autoDismissOnSuccess else { return }
        isFinishing = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            // Dismiss the whole presented nav (not just push), and always notify finish
            // so ForumContainer clears isPresentingCloudflareVerification / unsticks UI.
            let presenter = self.navigationController ?? self
            if presenter.presentingViewController != nil {
                presenter.dismiss(animated: true) {
                    self.notifyFinishIfNeeded()
                }
            } else {
                self.notifyFinishIfNeeded()
            }
        }
    }

    @MainActor
    private func completeFromVerifiedChallengeLanding() async {
        guard !didDetectClearance, !isClosing else { return }
        await syncCloudflareCookieFromWebView()
        try? await Task.sleep(nanoseconds: 150_000_000)
        await syncCloudflareCookieFromWebView()
        await updateStoredUserAgentFromWebView()
        let clearanceValue = WebCookieStore.shared.cookieValue(named: "cf_clearance", for: baseURL)
        guard CloudflareVerificationPolicy.hasUsableClearance(
            currentValue: clearanceValue,
            initialValue: initialClearanceValue,
            requiresFreshValue: autoDismissOnSuccess
        ) else {
            log("foreground /challenge 404 without usable clearance; keep waiting")
            return
        }
        log("foreground complete from origin /challenge 404")
        completeVerification()
    }

    @MainActor
    private func notifyFinishIfNeeded() {
        guard !didCallOnFinish else { return }
        didCallOnFinish = true
        onFinish()
    }

    @MainActor
    private func finishAndClose() {
        if navigationController?.viewControllers.first === self,
           navigationController?.presentingViewController != nil {
            navigationController?.dismiss(animated: true)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @MainActor
    private func hasLoadedVerifiedBasePage() async -> Bool {
        guard didFinishVerifiedNavigation,
              let currentURL = webView.url,
              let currentHost = currentURL.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased()
        else { return false }

        let hostMatches = currentHost == baseHost || currentHost.hasSuffix(".\(baseHost)")
        guard hostMatches else { return false }

        let path = currentURL.path.lowercased()
        guard !path.contains("/cdn-cgi/") else { return false }
        return !(await pageHasActiveCloudflareChallenge())
    }

    private func isKnownVerifiedRedirectURL(_ url: URL?) -> Bool {
        guard let url,
              let currentHost = url.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased()
        else { return false }

        let hostMatches = currentHost == baseHost || currentHost.hasSuffix(".\(baseHost)")
        guard hostMatches else { return false }

        let path = url.path.lowercased()
        return path == "/404" || path == "/404/"
    }

    @MainActor
    private func hasLoadedKnownVerifiedNotFoundPage() async -> Bool {
        guard didFinishVerifiedNavigation,
              let currentURL = webView.url,
              let currentHost = currentURL.host?.lowercased(),
              let baseHost = baseURL.host?.lowercased()
        else { return false }

        let hostMatches = currentHost == baseHost || currentHost.hasSuffix(".\(baseHost)")
        guard hostMatches, !currentURL.path.lowercased().contains("/cdn-cgi/") else {
            return false
        }

        guard let pageText = try? await webView.evaluateJavaScript("""
            [
              document.title || '',
              document.body ? document.body.innerText : ''
            ].join('\\n')
            """) as? String,
            !Self.hasActiveCloudflareChallenge(in: pageText)
        else { return false }

        let lowerText = pageText.lowercased()
        return lowerText.contains("该页面不存在")
            || lowerText.contains("該頁面不存在")
            || lowerText.contains("that page doesn't exist")
            || lowerText.contains("that page doesn’t exist")
    }

    @MainActor
    private func pageHasActiveCloudflareChallenge() async -> Bool {
        guard let pageText = try? await webView.evaluateJavaScript("""
            [
              document.title || '',
              document.body ? document.body.innerText : '',
              document.body ? document.body.innerHTML : ''
            ].join('\\n')
            """) as? String else { return true }
        return Self.hasActiveCloudflareChallenge(in: pageText)
    }

    @MainActor
    private func scheduleVerificationChecks() {
        guard !didDetectClearance, !isPreparingChallenge, !isClosing else { return }
        verificationCheckTask?.cancel()
        verificationCheckTask = Task { @MainActor [weak self] in
            let delays: [UInt64] = [
                0,
                250_000_000,
                700_000_000,
                1_500_000_000,
                2_500_000_000,
                4_000_000_000,
                7_000_000_000,
                10_000_000_000,
            ]
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled, let self, !self.didDetectClearance else { return }
                await self.syncCookiesAndDetectClearance()
            }
        }
    }

    private static func hasActiveCloudflareChallenge(in pageText: String) -> Bool {
        let lowerText = pageText.lowercased()
        return lowerText.contains("cf-turnstile")
            || lowerText.contains("challenge-running")
            || lowerText.contains("challenge-stage")
            || lowerText.contains("cf_chl_opt")
            || lowerText.contains("challenge-platform")
            || (lowerText.contains("just a moment") && lowerText.contains("cloudflare"))
    }

    private func failingURL(from error: Error) -> URL? {
        let nsError = error as NSError
        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return url
        }
        if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            return URL(string: urlString)
        }
        return nil
    }

    private func log(_ message: String) {
        DohDebugLog.record(message, subsystem: "CF")
    }

    private func updateStatus(text: String, symbolName: String, color: UIColor) {
        statusLabel.text = text
        statusIconView.image = UIImage(systemName: symbolName)
        statusIconView.tintColor = color
    }
}

extension CloudflareVerificationViewController: WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            self?.scheduleVerificationChecks()
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              CloudflareVerificationPolicy.isVerifiedChallengeLanding(
                  response,
                  baseURL: baseURL
              )
        else {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        Task { @MainActor [weak self] in
            await self?.completeFromVerifiedChallengeLanding()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinishVerifiedNavigation = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.scheduleVerificationChecks()
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        didFinishVerifiedNavigation = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if didDetectClearance { return }
        if let url = failingURL(from: error), isKnownVerifiedRedirectURL(url) {
            log("foreground didFail verified url=\(url.absoluteString) error=\(error.localizedDescription)")
            Task { @MainActor [weak self] in
                await self?.completeIfKnownVerifiedRedirect(url)
            }
            return
        }
        log("foreground didFail url=\(webView.url?.absoluteString ?? "none") error=\(error.localizedDescription)")
        updateStatus(
            text: String(localized: "cloudflare.verify.load_failed"),
            symbolName: "exclamationmark.triangle.fill",
            color: .systemRed
        )
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if didDetectClearance { return }
        if let url = failingURL(from: error), isKnownVerifiedRedirectURL(url) {
            log("foreground didFailProvisional verified url=\(url.absoluteString) error=\(error.localizedDescription)")
            Task { @MainActor [weak self] in
                await self?.completeIfKnownVerifiedRedirect(url)
            }
            return
        }
        log("foreground didFailProvisional url=\(webView.url?.absoluteString ?? "none") error=\(error.localizedDescription)")
        updateStatus(
            text: String(localized: "cloudflare.verify.load_failed"),
            symbolName: "exclamationmark.triangle.fill",
            color: .systemRed
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
