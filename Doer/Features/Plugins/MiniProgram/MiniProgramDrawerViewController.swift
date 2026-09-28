import UIKit

/// Header chrome for the mini-program drawer. Keep the close pill inside the
/// rounded screen corners and below the status bar / Dynamic Island.
enum MiniProgramDrawerChromePolicy {
    static let closeButtonSize: CGFloat = 32
    static let closeButtonCornerRadius: CGFloat = 16
    static let horizontalInset: CGFloat = 20
    static let grabberTopSpacing: CGFloat = 8
    /// Overlay children of `UITabBarController` often report `safeAreaInsets.top == 0`.
    static let minimumStatusBarInset: CGFloat = 54

    static func headerTopInset(viewSafeAreaTop: CGFloat, windowSafeAreaTop: CGFloat) -> CGFloat {
        max(viewSafeAreaTop, windowSafeAreaTop, minimumStatusBarInset) + grabberTopSpacing
    }
}

/// WeChat-like full-screen mini-program drawer.
/// - Fixed 2×4 grids (max 8)
/// - No vertical scrolling; upward pan / fling closes
/// - 「最近 / 常用」sections always visible (even when empty) so first-run
///   users can still open 我的小程序 management via section actions
/// - 「常用」lists favorites (我的小程序)
/// - Long-press drag: left = add to favorites, right = remove
@MainActor
final class MiniProgramDrawerViewController: UIViewController {
    var onSelectProgram: ((MiniProgramDescriptor) -> Void)?
    var onOpenMyPrograms: (() -> Void)?
    var onDismissed: (() -> Void)?

    private static let gridColumns = 4
    private static let maxGridRows = 2
    private static var maxGridItems: Int { gridColumns * maxGridRows }
    private static let dropZoneHeight: CGFloat = 110

    private let api: DiscourseAPI
    private var username: String?

    private var isOpen = false
    private var isAnimating = false
    private var animationGeneration = 0
    private var panelTopConstraint: NSLayoutConstraint?
    private var panelHeightConstraint: NSLayoutConstraint?
    private var grabberTopConstraint: NSLayoutConstraint?
    private var filteredQuery = ""

    private enum DragSource {
        case recent
        case favorite
    }

    private var isDragging = false
    private var dragProgram: MiniProgramDescriptor?
    private var dragSnapshot: UIView?
    private weak var dragSourceView: UIView?
    private var dragSource: DragSource = .recent

    // MARK: - Views

    private let dimmingView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        view.alpha = 0
        view.isUserInteractionEnabled = true
        return view
    }()

    private let panelView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor(white: 0.12, alpha: 0.98)
        view.clipsToBounds = true
        return view
    }()

    private let headerContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        return view
    }()

    private let grabberView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.white.withAlphaComponent(0.28)
        view.layer.cornerRadius = 2.5
        return view
    }()

    private let avatarImageView: UIImageView = {
        let imageView = UIImageView(image: AvatarImageLoader.defaultPlaceholder)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.tintColor = .tertiaryLabel
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        imageView.layer.cornerRadius = 16
        imageView.clipsToBounds = true
        return imageView
    }()

    private let nameLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.text = String(localized: "mini_program.drawer.recent_title", defaultValue: "最近")
        return label
    }()

    private lazy var closeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: "chevron.up",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        )
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.9)
        config.background.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        config.background.cornerRadius = MiniProgramDrawerChromePolicy.closeButtonCornerRadius
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = String(localized: "mini_program.drawer.close", defaultValue: "收起小程序")
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }()

    private let searchContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        view.layer.cornerRadius = 18
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let searchIconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = UIColor.white.withAlphaComponent(0.45)
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private lazy var searchField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 15, weight: .regular)
        field.textColor = .white
        field.tintColor = .white
        field.attributedPlaceholder = NSAttributedString(
            string: String(localized: "mini_program.drawer.search_placeholder", defaultValue: "搜索小程序"),
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.4)]
        )
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.delegate = self
        field.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        return field
    }()

    /// Non-scrolling body: fixed layout only.
    private let bodyStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        stack.alignment = .fill
        stack.distribution = .fill
        // Content hugs the top; extra vertical space stays empty below.
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setContentCompressionResistancePriority(.required, for: .vertical)
        return stack
    }()

    private let recentSectionHeader = MiniProgramDrawerSectionHeaderView()
    private let recentGrid = MiniProgramDrawerGridView()
    private let frequentSectionHeader = MiniProgramDrawerSectionHeaderView()
    private let frequentGrid = MiniProgramDrawerGridView()

    // Dual drop zones (WeChat-style)
    private let dropZonesContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isHidden = true
        view.alpha = 0
        return view
    }()

    private let addDropZone: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor(white: 0.28, alpha: 0.95)
        return view
    }()

    private let addDropIcon: UIImageView = {
        let imageView = UIImageView(
            image: UIImage(systemName: "square.grid.2x2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        )
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let addDropLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(
            localized: "mini_program.drawer.add_drop",
            defaultValue: "拖动到此处添加为我的小程序"
        )
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    private let deleteDropZone: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemRed
        return view
    }()

    private let deleteDropIcon: UIImageView = {
        let imageView = UIImageView(
            image: UIImage(systemName: "trash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        )
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.tintColor = .white
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let deleteDropLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(
            localized: "mini_program.drawer.delete_drop",
            defaultValue: "拖动到此处删除小程序"
        )
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    // MARK: - Init

    init(api: DiscourseAPI, username: String?) {
        self.api = api
        self.username = username
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isHidden = true
        configureChrome()
        configureLayout()
        configureGestures()
        reloadContent()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateHeaderSafeAreaInsets()
    }

    private func updateHeaderSafeAreaInsets() {
        let inset = MiniProgramDrawerChromePolicy.headerTopInset(
            viewSafeAreaTop: view.safeAreaInsets.top,
            windowSafeAreaTop: view.window?.safeAreaInsets.top ?? 0
        )
        guard grabberTopConstraint?.constant != inset else { return }
        grabberTopConstraint?.constant = inset
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeaderSafeAreaInsets()
        let height = max(view.bounds.height, 1)
        let previous = panelHeightConstraint?.constant ?? height
        panelHeightConstraint?.constant = height
        if !isOpen {
            panelTopConstraint?.constant = -height
        } else if abs(previous - height) > 0.5, !isAnimating {
            panelTopConstraint?.constant = 0
        }
    }

    // MARK: - Public open / close

    func open(animated: Bool, username: String? = nil) {
        if let username {
            self.username = username
        }
        configureChrome()
        reloadContent()
        view.isHidden = false
        view.isUserInteractionEnabled = true
        // Stay above the tab bar even if ForumTabBarController reorders subviews.
        if let host = view.superview {
            host.bringSubviewToFront(view)
        }
        view.layoutIfNeeded()
        updateHeaderSafeAreaInsets()

        let height = max(view.bounds.height, 1)
        panelHeightConstraint?.constant = height
        // Full-screen panel: pin top + match host height (covers tab bar area).
        panelTopConstraint?.constant = -height
        view.layoutIfNeeded()

        isOpen = true
        isAnimating = true
        animationGeneration += 1
        let generation = animationGeneration
        panelTopConstraint?.constant = 0

        let animations = {
            self.dimmingView.alpha = 1
            self.view.layoutIfNeeded()
            // Re-assert z-order mid-animation in case tab bar layout raced us.
            self.view.superview?.bringSubviewToFront(self.view)
        }
        let finish = {
            guard generation == self.animationGeneration else { return }
            self.isAnimating = false
        }
        if animated {
            // Ease-out (no spring): spring overshoot made open/close feel like a bounce.
            UIView.animate(
                withDuration: 0.30,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: { _ in finish() }
            )
        } else {
            animations()
            finish()
        }
    }

    /// - Parameter notifiesDismissed: when false (e.g. selecting a program), skip
    ///   `onDismissed` so the host does not bounce the tab bar back mid-transition.
    func close(
        animated: Bool,
        notifiesDismissed: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        guard isOpen || !view.isHidden else {
            if notifiesDismissed { onDismissed?() }
            completion?()
            return
        }
        if !isOpen, isAnimating {
            completion?()
            return
        }

        searchField.resignFirstResponder()
        // Cancel drag without extra bounce animations during close.
        if isDragging || dragSnapshot != nil {
            dragSnapshot?.removeFromSuperview()
            dragSourceView?.alpha = 1
            dragSnapshot = nil
            dragProgram = nil
            dragSourceView = nil
            isDragging = false
            dropZonesContainer.isHidden = true
            dropZonesContainer.alpha = 0
            dropZonesContainer.transform = .identity
        }
        isOpen = false
        isAnimating = true
        animationGeneration += 1
        let generation = animationGeneration

        // Restore underlying tab bar / home insets under the dimming layer *before*
        // the panel leaves, so close does not end with a post-animation chrome pop.
        // Quiet restore intentionally does not bring the tab bar front mid-flight.
        if notifiesDismissed {
            onDismissed?()
            view.superview?.bringSubviewToFront(view)
        }

        // Use the live host height so the panel fully clears the screen even if
        // bounds changed after open (keyboard / rotation / safe area).
        let height = max(view.bounds.height, panelHeightConstraint?.constant ?? 0, 1)
        panelHeightConstraint?.constant = height
        // Continue from the current drag offset (no snap-to-open then close jitter).
        let currentOffset = panelTopConstraint?.constant ?? 0
        panelTopConstraint?.constant = min(currentOffset, 0)
        view.layoutIfNeeded()
        panelTopConstraint?.constant = -height

        let animations = {
            self.dimmingView.alpha = 0
            self.view.layoutIfNeeded()
            // Stay above content for the whole close; tab bar ordering is finalized
            // only after this view is hidden.
            self.view.superview?.bringSubviewToFront(self.view)
        }
        let finish = {
            guard generation == self.animationGeneration else { return }
            self.isAnimating = false
            self.view.isHidden = true
            // Reset panel off-screen for the next open without an intermediate flash.
            self.panelTopConstraint?.constant = -height
            if notifiesDismissed {
                Self.finalizeHostTabBarOrdering()
            }
            completion?()
        }
        if animated {
            // Ease-in only — spring on close overshoots and reads as bottom jitter.
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseIn, .beginFromCurrentState, .allowUserInteraction],
                animations: animations,
                completion: { _ in finish() }
            )
        } else {
            animations()
            finish()
        }
    }


    private static func finalizeHostTabBarOrdering() {
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
                forumTab.ensureTabBarOrderingAfterOverlay()
                return
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
    }

    // MARK: - Setup

    private func configureChrome() {
        let displayName: String
        let avatarTemplate: String?
        if let username,
           let cached = MeProfileCacheStore.cachedProfile(baseURL: api.baseURL, username: username) {
            let profileName = cached.userProfile.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentName = cached.currentUser.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            displayName = [profileName, currentName, username]
                .compactMap { $0 }
                .first { !$0.isEmpty } ?? username
            avatarTemplate = cached.userProfile.avatarTemplate ?? cached.currentUser.avatarTemplate
        } else if let username {
            displayName = username
            avatarTemplate = nil
        } else {
            displayName = String(localized: "mini_program.drawer.guest", defaultValue: "未登录")
            avatarTemplate = nil
        }
        nameLabel.text = displayName
        AvatarImageLoader.setImage(
            on: avatarImageView,
            template: avatarTemplate,
            baseURL: api.baseURL,
            size: AvatarImageLoader.primaryAvatarPixelSize
        )

        recentSectionHeader.configure(
            title: String(localized: "mini_program.drawer.recent_section", defaultValue: "最近使用的小程序"),
            actionTitle: String(localized: "mini_program.drawer.more", defaultValue: "更多 >")
        )
        recentSectionHeader.onAction = { [weak self] in
            self?.openMyPrograms()
        }

        frequentSectionHeader.configure(
            title: String(localized: "mini_program.drawer.frequent_section", defaultValue: "常用的小程序"),
            actionTitle: String(localized: "mini_program.drawer.my_programs", defaultValue: "我的小程序 >")
        )
        frequentSectionHeader.onAction = { [weak self] in
            self?.openMyPrograms()
        }

        recentGrid.onSelect = { [weak self] program in
            self?.selectProgram(program)
        }
        recentGrid.onLongPressDrag = { [weak self] program, sourceView, gesture in
            self?.handleLongPressDrag(program: program, source: .recent, sourceView: sourceView, gesture: gesture)
        }

        frequentGrid.onSelect = { [weak self] program in
            self?.selectProgram(program)
        }
        frequentGrid.onLongPressDrag = { [weak self] program, sourceView, gesture in
            self?.handleLongPressDrag(program: program, source: .favorite, sourceView: sourceView, gesture: gesture)
        }
    }

    private func configureLayout() {
        view.addSubview(dimmingView)
        view.addSubview(panelView)
        view.addSubview(dropZonesContainer)

        panelView.addSubview(headerContainer)
        headerContainer.addSubview(grabberView)
        headerContainer.addSubview(avatarImageView)
        headerContainer.addSubview(nameLabel)
        headerContainer.addSubview(titleLabel)
        headerContainer.addSubview(closeButton)
        headerContainer.addSubview(searchContainer)
        searchContainer.addSubview(searchIconView)
        searchContainer.addSubview(searchField)
        panelView.addSubview(bodyStack)

        bodyStack.addArrangedSubview(recentSectionHeader)
        bodyStack.addArrangedSubview(recentGrid)
        bodyStack.addArrangedSubview(frequentSectionHeader)
        bodyStack.addArrangedSubview(frequentGrid)

        dropZonesContainer.addSubview(addDropZone)
        dropZonesContainer.addSubview(deleteDropZone)
        addDropZone.addSubview(addDropIcon)
        addDropZone.addSubview(addDropLabel)
        deleteDropZone.addSubview(deleteDropIcon)
        deleteDropZone.addSubview(deleteDropLabel)

        let initialHeight = max(UIScreen.main.bounds.height, 1)
        let heightConstraint = panelView.heightAnchor.constraint(equalToConstant: initialHeight)
        panelHeightConstraint = heightConstraint
        let topConstraint = panelView.topAnchor.constraint(equalTo: view.topAnchor, constant: -initialHeight)
        panelTopConstraint = topConstraint
        let grabberTop = grabberView.topAnchor.constraint(
            equalTo: panelView.topAnchor,
            constant: MiniProgramDrawerChromePolicy.headerTopInset(
                viewSafeAreaTop: 0,
                windowSafeAreaTop: 0
            )
        )
        grabberTopConstraint = grabberTop

        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            topConstraint,
            panelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,

            headerContainer.topAnchor.constraint(equalTo: panelView.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),

            grabberTop,
            grabberView.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: 36),
            grabberView.heightAnchor.constraint(equalToConstant: 5),

            avatarImageView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: MiniProgramDrawerChromePolicy.horizontalInset
            ),
            avatarImageView.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 12),
            avatarImageView.widthAnchor.constraint(equalToConstant: 32),
            avatarImageView.heightAnchor.constraint(equalToConstant: 32),

            nameLabel.leadingAnchor.constraint(equalTo: avatarImageView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.leadingAnchor, constant: -8),

            titleLabel.centerXAnchor.constraint(equalTo: headerContainer.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor,
                constant: -8
            ),

            closeButton.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -MiniProgramDrawerChromePolicy.horizontalInset
            ),
            closeButton.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: MiniProgramDrawerChromePolicy.closeButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: MiniProgramDrawerChromePolicy.closeButtonSize),

            searchContainer.topAnchor.constraint(equalTo: avatarImageView.bottomAnchor, constant: 14),
            searchContainer.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            searchContainer.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            searchContainer.heightAnchor.constraint(equalToConstant: 36),
            searchContainer.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -4),

            searchIconView.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 12),
            searchIconView.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 16),
            searchIconView.heightAnchor.constraint(equalToConstant: 16),

            searchField.leadingAnchor.constraint(equalTo: searchIconView.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),

            // Pack content from the top only — do NOT pin bottom, or UIStackView
            // will stretch and shove 「常用」icons/header into a broken order.
            bodyStack.topAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: 16),
            bodyStack.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 16),
            bodyStack.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -16),
            bodyStack.bottomAnchor.constraint(lessThanOrEqualTo: panelView.bottomAnchor, constant: -24),

            dropZonesContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dropZonesContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dropZonesContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            dropZonesContainer.heightAnchor.constraint(equalToConstant: Self.dropZoneHeight),

            addDropZone.leadingAnchor.constraint(equalTo: dropZonesContainer.leadingAnchor),
            addDropZone.topAnchor.constraint(equalTo: dropZonesContainer.topAnchor),
            addDropZone.bottomAnchor.constraint(equalTo: dropZonesContainer.bottomAnchor),
            addDropZone.trailingAnchor.constraint(equalTo: dropZonesContainer.centerXAnchor),

            deleteDropZone.leadingAnchor.constraint(equalTo: dropZonesContainer.centerXAnchor),
            deleteDropZone.topAnchor.constraint(equalTo: dropZonesContainer.topAnchor),
            deleteDropZone.bottomAnchor.constraint(equalTo: dropZonesContainer.bottomAnchor),
            deleteDropZone.trailingAnchor.constraint(equalTo: dropZonesContainer.trailingAnchor),

            addDropIcon.centerXAnchor.constraint(equalTo: addDropZone.centerXAnchor),
            addDropIcon.topAnchor.constraint(equalTo: addDropZone.safeAreaLayoutGuide.topAnchor, constant: 14),
            addDropIcon.widthAnchor.constraint(equalToConstant: 22),
            addDropIcon.heightAnchor.constraint(equalToConstant: 22),
            addDropLabel.topAnchor.constraint(equalTo: addDropIcon.bottomAnchor, constant: 8),
            addDropLabel.leadingAnchor.constraint(equalTo: addDropZone.leadingAnchor, constant: 10),
            addDropLabel.trailingAnchor.constraint(equalTo: addDropZone.trailingAnchor, constant: -10),

            deleteDropIcon.centerXAnchor.constraint(equalTo: deleteDropZone.centerXAnchor),
            deleteDropIcon.topAnchor.constraint(equalTo: deleteDropZone.safeAreaLayoutGuide.topAnchor, constant: 14),
            deleteDropIcon.widthAnchor.constraint(equalToConstant: 22),
            deleteDropIcon.heightAnchor.constraint(equalToConstant: 22),
            deleteDropLabel.topAnchor.constraint(equalTo: deleteDropIcon.bottomAnchor, constant: 8),
            deleteDropLabel.leadingAnchor.constraint(equalTo: deleteDropZone.leadingAnchor, constant: 10),
            deleteDropLabel.trailingAnchor.constraint(equalTo: deleteDropZone.trailingAnchor, constant: -10),
        ])
    }

    private func configureGestures() {
        let dimTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        dimTap.cancelsTouchesInView = true
        dimmingView.addGestureRecognizer(dimTap)

        // Upward pan anywhere on the panel closes (no vertical scroll).
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.cancelsTouchesInView = false
        panelView.addGestureRecognizer(pan)
    }

    // MARK: - Content

    private func reloadContent() {
        guard !isDragging else { return }

        let query = filteredQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 最近：最多 8 个。空列表也保留分区 +「更多 >」，否则首启无法进管理页。
        var recent = MiniProgramRecentStore.recentPrograms()
        if !query.isEmpty {
            recent = recent.filter { $0.displayName.lowercased().contains(query) }
        }
        recent = Array(recent.prefix(Self.maxGridItems))
        recentSectionHeader.isHidden = false
        recentGrid.isHidden = false
        recentGrid.configure(
            programs: recent,
            columns: Self.gridColumns,
            maxRows: Self.maxGridRows,
            allowsLongPressDrag: true
        )

        // 常用 / 我的小程序：收藏列表。空也保留分区 +「我的小程序 >」。
        var favorites = MiniProgramStore.shared.favoritePrograms().map(MiniProgramDescriptor.init(record:))
        if !query.isEmpty {
            favorites = favorites.filter { $0.displayName.lowercased().contains(query) }
        }
        favorites = Array(favorites.prefix(Self.maxGridItems))
        frequentSectionHeader.isHidden = false
        frequentGrid.isHidden = false
        frequentGrid.configure(
            programs: favorites,
            columns: Self.gridColumns,
            maxRows: Self.maxGridRows,
            allowsLongPressDrag: true
        )
    }

    // MARK: - Long-press dual drop

    private enum DragEndAction {
        case cancel
        case addFavorite
        case delete
    }

    private func handleLongPressDrag(
        program: MiniProgramDescriptor,
        source: DragSource,
        sourceView: UIView,
        gesture: UILongPressGestureRecognizer
    ) {
        switch gesture.state {
        case .began:
            beginDrag(program: program, source: source, sourceView: sourceView)
            moveDrag(to: gesture.location(in: view))
        case .changed:
            guard isDragging else { return }
            moveDrag(to: gesture.location(in: view))
        case .ended:
            guard isDragging else { return }
            let location = gesture.location(in: view)
            let action = resolveDropAction(at: location)
            endDrag(action: action)
        case .cancelled, .failed:
            guard isDragging else { return }
            endDrag(action: .cancel)
        default:
            break
        }
    }

    private func beginDrag(program: MiniProgramDescriptor, source: DragSource, sourceView: UIView) {
        if isDragging {
            endDrag(action: .cancel)
        }
        isDragging = true
        dragProgram = program
        dragSource = source
        dragSourceView = sourceView
        searchField.resignFirstResponder()

        let snapshot = sourceView.snapshotView(afterScreenUpdates: true) ?? {
            let fallback = UIView(frame: sourceView.bounds)
            fallback.backgroundColor = UIColor.white.withAlphaComponent(0.2)
            fallback.layer.cornerRadius = 12
            return fallback
        }()
        let startFrame = sourceView.convert(sourceView.bounds, to: view)
        snapshot.frame = startFrame
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.35
        snapshot.layer.shadowRadius = 10
        snapshot.layer.shadowOffset = CGSize(width: 0, height: 6)
        snapshot.isUserInteractionEnabled = false
        view.addSubview(snapshot)
        dragSnapshot = snapshot
        sourceView.alpha = 0.25

        dropZonesContainer.isHidden = false
        dropZonesContainer.alpha = 0
        dropZonesContainer.transform = CGAffineTransform(translationX: 0, y: 24)
        view.bringSubviewToFront(dropZonesContainer)
        view.bringSubviewToFront(snapshot)

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.5,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.dropZonesContainer.alpha = 1
            self.dropZonesContainer.transform = .identity
            snapshot.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func moveDrag(to point: CGPoint) {
        guard let snapshot = dragSnapshot else { return }
        snapshot.center = point

        let addHit = addDropZone.convert(addDropZone.bounds, to: view).insetBy(dx: 0, dy: -8).contains(point)
        let deleteHit = deleteDropZone.convert(deleteDropZone.bounds, to: view).insetBy(dx: 0, dy: -8).contains(point)
        let scale: CGFloat = (addHit || deleteHit) ? 1.16 : 1.1

        UIView.animate(
            withDuration: 0.1,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            self.addDropZone.backgroundColor = addHit
                ? UIColor(white: 0.38, alpha: 0.98)
                : UIColor(white: 0.28, alpha: 0.95)
            self.deleteDropZone.backgroundColor = deleteHit
                ? UIColor.systemRed.withAlphaComponent(0.95)
                : .systemRed
            self.dropZonesContainer.transform = (addHit || deleteHit)
                ? CGAffineTransform(translationX: 0, y: -4)
                : .identity
        }
    }

    private func resolveDropAction(at point: CGPoint) -> DragEndAction {
        let addFrame = addDropZone.convert(addDropZone.bounds, to: view).insetBy(dx: 0, dy: -8)
        let deleteFrame = deleteDropZone.convert(deleteDropZone.bounds, to: view).insetBy(dx: 0, dy: -8)
        if deleteFrame.contains(point) { return .delete }
        if addFrame.contains(point) { return .addFavorite }
        return .cancel
    }

    private func endDrag(action: DragEndAction) {
        guard isDragging || dragProgram != nil || dragSnapshot != nil else { return }

        let program = dragProgram
        let snapshot = dragSnapshot
        let sourceView = dragSourceView
        let source = dragSource

        isDragging = false
        dragProgram = nil
        dragSnapshot = nil
        dragSourceView = nil

        let hideZones = {
            snapshot?.removeFromSuperview()
            sourceView?.alpha = 1
            self.addDropZone.backgroundColor = UIColor(white: 0.28, alpha: 0.95)
            self.deleteDropZone.backgroundColor = .systemRed
            self.dropZonesContainer.transform = .identity
            UIView.animate(withDuration: 0.2, animations: {
                self.dropZonesContainer.alpha = 0
            }, completion: { _ in
                if !self.isDragging {
                    self.dropZonesContainer.isHidden = true
                }
            })
        }

        switch action {
        case .cancel:
            if let snapshot, let sourceView, sourceView.window != nil {
                let target = sourceView.convert(sourceView.bounds, to: view)
                UIView.animate(withDuration: 0.2, animations: {
                    snapshot.center = CGPoint(x: target.midX, y: target.midY)
                    snapshot.transform = .identity
                    snapshot.alpha = 0.3
                }, completion: { _ in hideZones() })
            } else {
                hideZones()
            }

        case .addFavorite:
            if let program {
                MiniProgramStore.shared.addFavorite(program.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            if let snapshot {
                UIView.animate(withDuration: 0.18, animations: {
                    snapshot.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
                    snapshot.alpha = 0
                }, completion: { _ in
                    hideZones()
                    self.reloadContent()
                })
            } else {
                hideZones()
                reloadContent()
            }

        case .delete:
            if let program {
                switch source {
                case .recent:
                    _ = MiniProgramRecentStore.remove(programID: program.id)
                case .favorite:
                    MiniProgramStore.shared.removeFavorite(program.id)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            if let snapshot {
                UIView.animate(withDuration: 0.18, animations: {
                    snapshot.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
                    snapshot.alpha = 0
                }, completion: { _ in
                    hideZones()
                    self.reloadContent()
                })
            } else {
                hideZones()
                reloadContent()
            }
        }
    }

    // MARK: - Actions

    private func selectProgram(_ program: MiniProgramDescriptor) {
        // Skip onDismissed: presenting the host keeps tab bar hidden; host
        // teardown restores chrome. Avoids tab-bar bounce under the modal.
        close(animated: true, notifiesDismissed: false) { [weak self] in
            self?.onSelectProgram?(program)
        }
    }

    private func openMyPrograms() {
        close(animated: true, notifiesDismissed: true) { [weak self] in
            self?.onOpenMyPrograms?()
        }
    }

    @objc private func closeTapped() {
        close(animated: true, notifiesDismissed: true)
    }

    @objc private func searchTextChanged() {
        filteredQuery = searchField.text ?? ""
        reloadContent()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard isOpen, !isDragging else { return }
        guard !isAnimating || gesture.state == .began || gesture.state == .changed else { return }
        let translation = gesture.translation(in: view)
        let height = panelHeightConstraint?.constant ?? max(view.bounds.height, 1)

        switch gesture.state {
        case .began:
            searchField.resignFirstResponder()
        case .changed:
            // Only drag upward to dismiss.
            let dy = min(0, translation.y)
            panelTopConstraint?.constant = dy
            let progress = min(1, max(0, -dy / max(height, 1)))
            dimmingView.alpha = 1 - progress * 0.85
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: view).y
            let offset = panelTopConstraint?.constant ?? 0
            // Hard upward fling or pull past threshold → close (continues from offset).
            let shouldClose = offset < -56 || velocity < -500
            if shouldClose {
                close(animated: true, notifiesDismissed: true)
            } else {
                isAnimating = true
                animationGeneration += 1
                let generation = animationGeneration
                panelTopConstraint?.constant = 0
                UIView.animate(
                    withDuration: 0.22,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                ) {
                    self.dimmingView.alpha = 1
                    self.view.layoutIfNeeded()
                } completion: { _ in
                    guard generation == self.animationGeneration else { return }
                    self.isAnimating = false
                }
            }
        default:
            break
        }
    }
}

// MARK: - UITextFieldDelegate

extension MiniProgramDrawerViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Section header

private final class MiniProgramDrawerSectionHeaderView: UIView {
    var onAction: (() -> Void)?

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor.white.withAlphaComponent(0.55)
        return label
    }()

    private lazy var actionButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.55)
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var next = attrs
            next.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            return next
        }
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(actionButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, actionTitle: String?) {
        titleLabel.text = title
        let trimmed = actionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        actionButton.isHidden = trimmed.isEmpty
        if !trimmed.isEmpty {
            var config = actionButton.configuration ?? .plain()
            config.title = trimmed
            actionButton.configuration = config
        }
    }

    @objc private func actionTapped() {
        onAction?()
    }
}

// MARK: - Icon grid

private final class MiniProgramDrawerGridView: UIView {
    var onSelect: ((MiniProgramDescriptor) -> Void)?
    var onLongPressDrag: ((MiniProgramDescriptor, UIView, UILongPressGestureRecognizer) -> Void)?

    private var allowsLongPressDrag = false
    private var suppressNextSelect = false
    private var programsByID: [String: MiniProgramDescriptor] = [:]

    private let stack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
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

    func configure(
        programs: [MiniProgramDescriptor],
        columns: Int = 4,
        maxRows: Int = 2,
        allowsLongPressDrag: Bool = false
    ) {
        self.allowsLongPressDrag = allowsLongPressDrag
        let cappedColumns = max(1, columns)
        let cappedRows = max(1, maxRows)
        let visible = Array(programs.prefix(cappedColumns * cappedRows))
        programsByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        suppressNextSelect = false
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        // Always reserve up to maxRows so layout stays stable even when empty-ish.
        var index = 0
        let totalSlots = cappedColumns * cappedRows
        let padded = visible
        while index < totalSlots {
            let end = min(index + cappedColumns, padded.count)
            let rowPrograms = index < padded.count ? Array(padded[index..<end]) : []
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 8
            for program in rowPrograms {
                row.addArrangedSubview(makeTile(for: program))
            }
            while row.arrangedSubviews.count < cappedColumns {
                let spacer = UIView()
                spacer.isUserInteractionEnabled = false
                row.addArrangedSubview(spacer)
            }
            // Stop adding empty rows beyond content, except keep at least one row for layout.
            if rowPrograms.isEmpty, index > 0 { break }
            stack.addArrangedSubview(row)
            index += cappedColumns
            if rowPrograms.isEmpty { break }
        }
    }

    private func makeTile(for program: MiniProgramDescriptor) -> UIView {
        let container = UIControl()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.accessibilityLabel = program.displayName
        container.accessibilityTraits = .button
        container.accessibilityValue = program.id

        let iconBadge = MiniProgramIconBadge.view(for: program.id, size: MiniProgramIconBadge.defaultSize)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = program.displayName
        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.isUserInteractionEnabled = false

        container.addSubview(iconBadge)
        container.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            iconBadge.topAnchor.constraint(equalTo: container.topAnchor),
            iconBadge.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            titleLabel.topAnchor.constraint(equalTo: iconBadge.bottomAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            titleLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if self.suppressNextSelect {
                self.suppressNextSelect = false
                return
            }
            self.onSelect?(program)
        }, for: .touchUpInside)

        if allowsLongPressDrag {
            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(tileLongPressed(_:))
            )
            longPress.minimumPressDuration = 0.4
            longPress.allowableMovement = .greatestFiniteMagnitude
            longPress.cancelsTouchesInView = true
            longPress.delegate = self
            container.addGestureRecognizer(longPress)
        }

        return container
    }

    @objc private func tileLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard let container = gesture.view,
              let programID = container.accessibilityValue,
              let program = programsByID[programID]
        else { return }
        if gesture.state == .began {
            suppressNextSelect = true
        }
        onLongPressDrag?(program, container, gesture)
    }
}

extension MiniProgramDrawerGridView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
