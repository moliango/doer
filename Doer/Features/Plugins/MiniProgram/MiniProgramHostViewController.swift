import UIKit
import WebKit

/// Full-screen mini-program shell with WeChat-style capsule (··· / close).
@MainActor
final class MiniProgramHostViewController: UIViewController {
    private var content: UIViewController
    private let program: MiniProgramDescriptor
    private let api: DiscourseAPI
    private let username: String?
    private var popGestureEnablers: [ObjectIdentifier: NavigationPopGestureEnabler] = [:]
    private let interactiveBack = MiniProgramInteractiveBackController()
    /// When true, embedded web content disables edge-swipe shake and pinch zoom.
    /// Default on so pages don't rubber-band or pinch-zoom until the user unlocks.
    private var isInteractionLocked = false

    private let chromeView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemGroupedBackground
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let iconView: UIImageView = {
        let imageView = UIImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.layer.cornerRadius = 14
        imageView.layer.cornerCurve = .continuous
        imageView.clipsToBounds = true
        return imageView
    }()

    /// WeChat-like capsule: white bar, black ··· | ◎ (ring + solid dot).
    private let capsuleView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .white
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1.0 / UIScreen.main.scale
        view.layer.borderColor = UIColor.black.withAlphaComponent(0.12).cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.08
        view.layer.shadowRadius = 6
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        return view
    }()

    private lazy var moreButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        button.setImage(UIImage(systemName: "ellipsis", withConfiguration: config), for: .normal)
        button.tintColor = .black
        button.accessibilityLabel = String(localized: "mini_program.more", defaultValue: "更多")
        button.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        return button
    }()

    private let capsuleDivider: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        return view
    }()

    private lazy var closeButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        // Outer ring + solid inner dot (WeChat mini-program close).
        button.setImage(Self.wechatCloseIcon(size: 18, color: .black), for: .normal)
        button.tintColor = .black
        button.accessibilityLabel = String(localized: "mini_program.close", defaultValue: "关闭")
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }()

    private let contentContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    init(
        content: UIViewController,
        program: MiniProgramDescriptor,
        api: DiscourseAPI,
        username: String?,
        icon: UIImage? = nil
    ) {
        self.content = content
        self.program = program
        self.api = api
        self.username = username
        super.init(nibName: nil, bundle: nil)
        // overFullScreen keeps Home mounted under the cover so dismiss does not
        // tear down / re-insert the tab stack (fullScreen pop on ProMotion / iPhone 17).
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        titleLabel.text = program.displayName
        iconView.image = icon
        iconView.isHidden = icon == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        view.addSubview(chromeView)
        view.addSubview(contentContainer)
        chromeView.addSubview(iconView)
        chromeView.addSubview(titleLabel)
        chromeView.addSubview(capsuleView)
        capsuleView.addSubview(moreButton)
        capsuleView.addSubview(capsuleDivider)
        capsuleView.addSubview(closeButton)

        embedContent(content)

        NSLayoutConstraint.activate([
            chromeView.topAnchor.constraint(equalTo: view.topAnchor),
            chromeView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),

            capsuleView.trailingAnchor.constraint(equalTo: chromeView.trailingAnchor, constant: -12),
            capsuleView.bottomAnchor.constraint(equalTo: chromeView.bottomAnchor, constant: -10),
            capsuleView.widthAnchor.constraint(equalToConstant: 87),
            capsuleView.heightAnchor.constraint(equalToConstant: 32),

            moreButton.leadingAnchor.constraint(equalTo: capsuleView.leadingAnchor),
            moreButton.topAnchor.constraint(equalTo: capsuleView.topAnchor),
            moreButton.bottomAnchor.constraint(equalTo: capsuleView.bottomAnchor),
            moreButton.widthAnchor.constraint(equalTo: capsuleView.widthAnchor, multiplier: 0.5),

            capsuleDivider.centerXAnchor.constraint(equalTo: capsuleView.centerXAnchor),
            capsuleDivider.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),
            capsuleDivider.widthAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            capsuleDivider.heightAnchor.constraint(equalToConstant: 18),

            closeButton.trailingAnchor.constraint(equalTo: capsuleView.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: capsuleView.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: capsuleView.bottomAnchor),
            closeButton.widthAnchor.constraint(equalTo: capsuleView.widthAnchor, multiplier: 0.5),

            iconView.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: iconView.isHidden ? 0 : 10
            ),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: capsuleView.leadingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: capsuleView.centerYAnchor),

            contentContainer.topAnchor.constraint(equalTo: chromeView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if iconView.isHidden {
            titleLabel.leadingAnchor.constraint(equalTo: chromeView.leadingAnchor, constant: 16).isActive = true
        }

        // Follow-finger edge back, same 20pt strip as TopicDetail. History only —
        // never dismiss the host (close stays on the capsule ◎).
        interactiveBack.attach(hostView: view, slidingView: contentContainer)
        interactiveBack.canBegin = { [weak self] pan in
            guard let self else { return false }
            return MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: pan.location(in: self.view).x,
                translation: pan.translation(in: self.view),
                velocity: pan.velocity(in: self.view),
                webCanGoBack: self.webCanGoBack(),
                nestedNavCanPop: self.embeddedNavCanPop(),
                hasPresentedOverlay: self.presentedViewController != nil
            )
        }
        interactiveBack.peekBack = { [weak self] in
            self?.tryGoBackInContent(animated: false) ?? false
        }
        interactiveBack.peekForward = { [weak self] in
            self?.tryGoForwardInContent() ?? false
        }
    }

    /// Try to go back in embedded content (web history / nav stack).
    /// Returns true if a back action was performed.
    @discardableResult
    private func tryGoBackInContent(animated: Bool = true) -> Bool {
        var stack: [UIViewController] = [content]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let browser = vc as? InAppBrowserViewController {
                if browser.goBackIfPossible() {
                    return true
                }
            }
            if let nav = vc as? UINavigationController {
                if nav.viewControllers.count > 1 {
                    nav.popViewController(animated: animated)
                    return true
                }
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
        }
        return false
    }

    @discardableResult
    private func tryGoForwardInContent() -> Bool {
        var stack: [UIViewController] = [content]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let browser = vc as? InAppBrowserViewController {
                if browser.goForwardIfPossible() {
                    return true
                }
            }
            if let nav = vc as? UINavigationController {
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
        }
        return false
    }

    private func webCanGoBack() -> Bool {
        currentEmbeddedBrowser()?.canGoBack == true
    }

    private func embeddedNavCanPop() -> Bool {
        var stack: [UIViewController] = [content]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let nav = vc as? UINavigationController, nav.viewControllers.count > 1 {
                return true
            }
            if let nav = vc as? UINavigationController {
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
        }
        return false
    }

    private func attachPopEnablers(in root: UIViewController) {
        popGestureEnablers.removeAll()
        var stack: [UIViewController] = [root]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let nav = vc as? UINavigationController {
                let enabler = NavigationPopGestureEnabler()
                enabler.attach(to: nav)
                popGestureEnablers[ObjectIdentifier(nav)] = enabler
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
        }
    }

    // MARK: - Capsule icon

    /// WeChat-style close glyph: thin outer ring with a solid filled center.
    private static func wechatCloseIcon(size: CGFloat, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let image = renderer.image { _ in
            let lineWidth: CGFloat = max(1.4, size * 0.09)
            let outerInset = lineWidth / 2
            let outerRect = CGRect(
                x: outerInset,
                y: outerInset,
                width: size - lineWidth,
                height: size - lineWidth
            )
            let outer = UIBezierPath(ovalIn: outerRect)
            color.setStroke()
            outer.lineWidth = lineWidth
            outer.stroke()

            // Solid inner disc — roughly half the outer diameter, matching WeChat.
            let innerDiameter = size * 0.42
            let innerOrigin = (size - innerDiameter) / 2
            let innerRect = CGRect(
                x: innerOrigin,
                y: innerOrigin,
                width: innerDiameter,
                height: innerDiameter
            )
            color.setFill()
            UIBezierPath(ovalIn: innerRect).fill()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        destroyAndDismiss()
    }

    @objc private func moreTapped() {
        presentMoreSheet()
    }

    /// WeChat-style bottom icon panel (not system action sheet / select).
    private func presentMoreSheet() {
        let sheet = MiniProgramMoreSheetViewController(
            currentProgram: program,
            isInteractionLocked: isInteractionLocked,
            isPageBookmarked: isCurrentPageBookmarked()
        )
        sheet.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .floatWindow:
                self.floatToBubble()
            case .reenter:
                self.reenterProgram()
            case .copyLink:
                self.copyLink()
            case .bookmark:
                self.toggleCurrentPageBookmark()
            case .toggleInteractionLock:
                self.toggleInteractionLock()
            }
        }
        sheet.onSelectRecent = { [weak self] recent in
            guard let self else { return }
            // Switch to another recent mini-program from the more panel.
            MiniProgramFactory.present(
                program: recent,
                from: self,
                api: self.api,
                username: self.username
            )
        }
        present(sheet, animated: false)
    }

    private func floatToBubble() {
        MiniProgramFloatingManager.shared.float(
            host: self,
            program: program,
            api: api,
            username: username
        )
    }

    private func reenterProgram() {
        guard let fresh = MiniProgramFactory.makeContent(
            for: program.id,
            api: api,
            username: username
        ) else {
            presentToast(String(localized: "mini_program.reenter.failed", defaultValue: "无法重新进入"))
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        replaceContent(with: fresh)
        // Keep lock across re-enter so bounce/zoom stay disabled if user locked them.
        applyInteractionLockToContent()
        presentToast(String(localized: "mini_program.reenter.done", defaultValue: "已重新进入"))
    }

    private func copyLink() {
        guard let link = MiniProgramFactory.linkURL(for: program) else {
            presentToast(String(localized: "mini_program.copy_link.unavailable", defaultValue: "暂无链接可复制"))
            return
        }
        UIPasteboard.general.string = link.absoluteString
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        presentToast(String(localized: "mini_program.copy_link.done", defaultValue: "链接已复制"))
    }

    private func currentEmbeddedBrowser() -> InAppBrowserViewController? {
        var stack: [UIViewController] = [content]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let browser = vc as? InAppBrowserViewController {
                return browser
            }
            if let nav = vc as? UINavigationController {
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
        }
        return nil
    }

    private func currentPageBookmarkTarget() -> (url: URL, title: String?, store: BrowserHistoryStore)? {
        if let browser = currentEmbeddedBrowser(), let url = browser.currentPageURL {
            return (url, browser.currentPageTitle, browser.browserHistoryStore)
        }
        // Fallback: program entry URL when content is not a browser.
        if let link = MiniProgramFactory.linkURL(for: program) {
            let store = BrowserHistoryStore.shared(baseURL: api.baseURL, username: username)
            return (link, program.displayName, store)
        }
        return nil
    }

    private func isCurrentPageBookmarked() -> Bool {
        guard let target = currentPageBookmarkTarget() else { return false }
        return target.store.isBookmarked(target.url)
    }

    private func toggleCurrentPageBookmark() {
        guard let target = currentPageBookmarkTarget() else {
            presentToast(String(localized: "mini_program.bookmark.unavailable", defaultValue: "当前页无法收藏"))
            return
        }
        do {
            if target.store.isBookmarked(target.url) {
                try target.store.removeBookmark(url: target.url)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                presentToast(String(localized: "me.browser.bookmark_removed", defaultValue: "已取消收藏"))
            } else {
                try target.store.addBookmark(url: target.url, title: target.title)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                presentToast(String(localized: "me.browser.bookmark_added", defaultValue: "已收藏"))
            }
        } catch {
            presentToast(error.localizedDescription)
        }
    }

    private func toggleInteractionLock() {
        isInteractionLocked.toggle()
        applyInteractionLockToContent()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        presentToast(
            isInteractionLocked
                ? String(localized: "mini_program.lock.on", defaultValue: "已锁定，防止左右晃动和缩放")
                : String(localized: "mini_program.lock.off", defaultValue: "已取消锁定")
        )
    }

    private func applyInteractionLockToContent() {
        var stack: [UIViewController] = [content]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let browser = vc as? InAppBrowserViewController {
                browser.setPageInteractionLocked(isInteractionLocked)
            }
            if let nav = vc as? UINavigationController {
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
        }
    }

    // MARK: - Content lifecycle

    private func embedContent(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        child.didMove(toParent: self)
        attachPopEnablers(in: child)
    }

    private func replaceContent(with newContent: UIViewController) {
        content.willMove(toParent: nil)
        content.view.removeFromSuperview()
        content.removeFromParent()
        content = newContent
        embedContent(newContent)
    }

    /// Close = destroy immediately. Floating keeps the instance via MiniProgramFloatingManager.
    func destroyAndDismiss() {
        prepareContentForTeardown(content)
        settleUnderlyingChromeBeforeDismiss()

        let teardown = { [weak self] in
            guard let self else { return }
            self.content.willMove(toParent: nil)
            self.content.view.removeFromSuperview()
            self.content.removeFromParent()
            if let home = Self.homeViewControllerFromKeyWindow() {
                home.finalizeTabBarOrderingAfterMiniProgramChrome()
            }
        }

        // CDK/LDC CF sheets present on top of this host. `self.dismiss()` would only
        // pop the shield and leave the mini-program stuck. Dismiss from the presenter
        // so the whole modal stack (shield + host) goes away.
        if let presenter = presentingViewController {
            presenter.dismiss(animated: true, completion: teardown)
        } else if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in
                self?.destroyAndDismiss()
            }
        } else {
            teardown()
            view.removeFromSuperview()
            removeFromParent()
        }
    }

    /// Restore home/tab-bar chrome while still covered by the mini-program host.
    func settleUnderlyingChromeBeforeDismiss() {
        Self.restoreHostTabBarIfNeeded()
    }

    private func prepareContentForTeardown(_ root: UIViewController) {
        var stack: [UIViewController] = [root]
        var visited = Set<ObjectIdentifier>()
        while let vc = stack.popLast() {
            let id = ObjectIdentifier(vc)
            guard visited.insert(id).inserted else { continue }
            if let nav = vc as? UINavigationController {
                stack.append(contentsOf: nav.viewControllers)
            }
            if let tab = vc as? UITabBarController {
                stack.append(contentsOf: tab.viewControllers ?? [])
            }
            stack.append(contentsOf: vc.children)
            if let browser = vc as? InAppBrowserViewController {
                browser.prepareForHostTeardown()
            }
        }
    }

    private static func restoreHostTabBarIfNeeded() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        guard let root = window?.rootViewController else { return }

        var queue: [UIViewController] = [root]
        var visited = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let id = ObjectIdentifier(current)
            guard visited.insert(id).inserted else { continue }
            if let forumTab = current as? ForumTabBarController {
                // Prefer Home's coordinated restore so list contentInset.bottom
                // matches the re-shown tab bar before the host starts dismissing.
                if let home = homeViewController(in: forumTab) {
                    home.restoreTabBarAfterMiniProgramChrome()
                } else {
                    forumTab.quietlyRestoreTabBarAfterOverlay()
                }
                return
            }
            if let tab = current as? UITabBarController {
                tab.tabBar.isHidden = false
                if let selected = tab.selectedViewController {
                    queue.append(selected)
                }
                queue.append(contentsOf: tab.viewControllers ?? [])
            }
            if let nav = current as? UINavigationController {
                queue.append(contentsOf: nav.viewControllers)
            }
            if let presented = current.presentedViewController {
                queue.append(presented)
            }
            queue.append(contentsOf: current.children)
        }
    }

    private static func homeViewControllerFromKeyWindow() -> HomeViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        guard let root = window?.rootViewController else { return nil }
        var queue: [UIViewController] = [root]
        var visited = Set<ObjectIdentifier>()
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let id = ObjectIdentifier(current)
            guard visited.insert(id).inserted else { continue }
            if let forumTab = current as? ForumTabBarController {
                return homeViewController(in: forumTab)
            }
            if let tab = current as? UITabBarController {
                if let selected = tab.selectedViewController { queue.append(selected) }
                queue.append(contentsOf: tab.viewControllers ?? [])
            }
            if let nav = current as? UINavigationController {
                queue.append(contentsOf: nav.viewControllers)
            }
            queue.append(contentsOf: current.children)
            if let presented = current.presentedViewController {
                queue.append(presented)
            }
        }
        return nil
    }

    private static func homeViewController(in tabBarController: ForumTabBarController) -> HomeViewController? {
        var candidates: [UIViewController] = tabBarController.viewControllers ?? []
        if let selected = tabBarController.selectedViewController {
            candidates.insert(selected, at: 0)
        }
        for candidate in candidates {
            if let home = candidate as? HomeViewController {
                return home
            }
            if let nav = candidate as? UINavigationController {
                if let home = nav.viewControllers.first as? HomeViewController {
                    return home
                }
                if let home = nav.viewControllers.compactMap({ $0 as? HomeViewController }).first {
                    return home
                }
            }
        }
        return nil
    }

    private func presentToast(_ message: String) {
        DoerFeedback.presentToast(message, on: self)
    }
}
