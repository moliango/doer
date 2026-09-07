import CookedHTML
import UIKit

/// Horizontal boost chips (FluxDo-style): group identical content, stack avatars, count badge.
/// Tap opens author list; long-press offers delete when `canDelete`.
final class BoostStripView: UIView {
    private static let emojiShortcodeRegex = try! NSRegularExpression(pattern: ":([^\\s:]+(?::t\\d)?):")

    struct Group {
        let displayText: String
        let cookedHTML: String
        let boosts: [DiscourseTopicDetail.Boost]

        var uniqueUsers: [DiscourseTopicDetail.BoostUser] {
            var seenIds = Set<Int>()
            var seenNames = Set<String>()
            var users: [DiscourseTopicDetail.BoostUser] = []
            for boost in boosts {
                let id = boost.user.id
                let nameKey = boost.user.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if id > 0 {
                    if seenIds.insert(id).inserted {
                        users.append(boost.user)
                    }
                } else if !nameKey.isEmpty, seenNames.insert(nameKey).inserted {
                    users.append(boost.user)
                }
            }
            return users
        }
    }

    var onRequestDeleteBoost: ((DiscourseTopicDetail.Boost) -> Void)?
    var onOpenUserProfile: ((String) -> Void)?
    var onBoostChanged: ((DiscourseTopicDetail.Boost) -> Void)?

    private let groups: [Group]
    private let baseURL: String
    /// Slightly stronger fill for WeChat green bubbles so chips stay readable.
    private let prefersHighContrast: Bool
    private var emojiUpdateObserver: NSObjectProtocol?
    /// Bubble containers by group index — title stack is subview tagged for refresh.
    private var bubbleContainers: [Int: UIView] = [:]
    private var isReloadingTitles = false

    private let scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    init?(
        boosts: [DiscourseTopicDetail.Boost],
        baseURL: String,
        prefersHighContrast: Bool = false
    ) {
        let groups = Self.makeGroups(from: boosts)
        guard !groups.isEmpty else { return nil }
        self.groups = groups
        self.baseURL = baseURL
        self.prefersHighContrast = prefersHighContrast
        super.init(frame: .zero)
        setupViews()
        observeEmojiStoreUpdates()
        ensureEmojiMapLoaded()
    }

    deinit {
        if let emojiUpdateObserver {
            NotificationCenter.default.removeObserver(emojiUpdateObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        // Avatar stack needs a bit more than the old 32pt strip.
        let height: CGFloat = BoostChipLayout.stripHeight
        addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),

            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // Custom + standard emoji shortcodes need the forum map / baseURL fallback.
        _ = EmojiStore.load(for: baseURL)

        bubbleContainers.removeAll()
        for (index, group) in groups.enumerated() {
            let bubble = makeBubble(for: group, index: index)
            bubbleContainers[index] = bubble
            stackView.addArrangedSubview(bubble)
        }
    }

    private func makeBubble(for group: Group, index: Int) -> UIView {
        let accentColor = AppSettings.shared.themeStyle.accentColor
        let container = UIControl()
        container.tag = index
        container.backgroundColor = prefersHighContrast
            ? UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.95)
            : UIColor.tertiarySystemGroupedBackground
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 1.0 / UIScreen.main.scale
        container.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addTarget(self, action: #selector(bubbleTapped(_:)), for: .touchUpInside)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(bubbleLongPressed(_:)))
        longPress.minimumPressDuration = 0.4
        container.addGestureRecognizer(longPress)

        let users = Array(group.uniqueUsers.prefix(3))
        let avatarStack = makeAvatarStack(users: users)
        avatarStack.translatesAutoresizingMaskIntoConstraints = false

        let titleFont = BoostChipLayout.titleFont()
        // UIImageView segments — NSTextAttachment in UILabel kept falling back to ":rofl:" text.
        let titleContent = makeTitleContent(for: group, font: titleFont)
        titleContent.translatesAutoresizingMaskIntoConstraints = false
        titleContent.setContentHuggingPriority(.required, for: .horizontal)
        titleContent.setContentCompressionResistancePriority(.required, for: .horizontal)

        let countLabel = UILabel()
        countLabel.text = "\(group.boosts.count)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        countLabel.textColor = .white
        countLabel.textAlignment = .center
        countLabel.backgroundColor = accentColor
        countLabel.layer.cornerRadius = 8
        countLabel.clipsToBounds = true
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.isHidden = group.boosts.count <= 1

        let chevron = UIImageView(
            image: UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        )
        chevron.tintColor = .tertiaryLabel
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        container.addSubview(avatarStack)
        container.addSubview(titleContent)
        container.addSubview(countLabel)
        container.addSubview(chevron)

        let stackWidth = BoostChipLayout.avatarStackWidth(userCount: max(users.count, 1))
        let showCount = group.boosts.count > 1
        countLabel.isHidden = !showCount
        let titleWidth = BoostChipLayout.measuredTextWidth(
            group.displayText,
            font: titleFont,
            maxWidth: BoostChipLayout.titleMaxWidth(boostCount: group.boosts.count)
        )
        let bubbleWidth = BoostChipLayout.bubbleWidth(
            displayText: group.displayText,
            uniqueUserCount: max(users.count, 1),
            boostCount: group.boosts.count
        )

        var constraints: [NSLayoutConstraint] = [
            container.heightAnchor.constraint(equalToConstant: BoostChipLayout.bubbleHeight),
            container.widthAnchor.constraint(equalToConstant: bubbleWidth),

            avatarStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: BoostChipLayout.leadingPadding),
            avatarStack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            avatarStack.widthAnchor.constraint(equalToConstant: stackWidth),
            avatarStack.heightAnchor.constraint(equalToConstant: BoostChipLayout.avatarSize),

            titleContent.leadingAnchor.constraint(equalTo: avatarStack.trailingAnchor, constant: BoostChipLayout.avatarTextSpacing),
            titleContent.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleContent.widthAnchor.constraint(equalToConstant: titleWidth),
            titleContent.heightAnchor.constraint(equalToConstant: 20),

            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -BoostChipLayout.trailingPadding),
            chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: BoostChipLayout.chevronWidth),
        ]

        if showCount {
            constraints += [
                countLabel.leadingAnchor.constraint(equalTo: titleContent.trailingAnchor, constant: BoostChipLayout.textCountSpacing),
                countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                countLabel.widthAnchor.constraint(equalToConstant: BoostChipLayout.countBadgeWidth(count: group.boosts.count)),
                countLabel.heightAnchor.constraint(equalToConstant: 16),
                chevron.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: BoostChipLayout.countChevronSpacing),
            ]
        } else {
            constraints += [
                chevron.leadingAnchor.constraint(equalTo: titleContent.trailingAnchor, constant: BoostChipLayout.textChevronSpacing),
            ]
        }
        NSLayoutConstraint.activate(constraints)

        return container
    }

    private func makeAvatarStack(users: [DiscourseTopicDetail.BoostUser]) -> UIView {
        let container = UIView()
        container.isUserInteractionEnabled = false
        guard !users.isEmpty else {
            let placeholder = UIImageView(image: UIImage(systemName: "person.crop.circle.fill"))
            placeholder.tintColor = .tertiaryLabel
            placeholder.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(placeholder)
            NSLayoutConstraint.activate([
                placeholder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                placeholder.widthAnchor.constraint(equalToConstant: 20),
                placeholder.heightAnchor.constraint(equalToConstant: 20),
            ])
            return container
        }

        for (index, user) in users.enumerated() {
            let avatarView = UIImageView()
            avatarView.contentMode = .scaleAspectFill
            avatarView.clipsToBounds = true
            avatarView.layer.cornerRadius = 10
            avatarView.layer.borderWidth = 1.5
            avatarView.layer.borderColor = UIColor.systemBackground.cgColor
            avatarView.backgroundColor = .secondarySystemFill
            avatarView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(avatarView)
            // Later avatars under earlier ones? FluxDO stacks with first on top (leading).
            container.sendSubviewToBack(avatarView)

            AvatarImageLoader.setImage(
                on: avatarView,
                url: AvatarImageLoader.url(from: user.avatarTemplate, baseURL: baseURL, size: 48),
                placeholder: UIImage(systemName: "person.crop.circle.fill")
            )

            NSLayoutConstraint.activate([
                avatarView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: CGFloat(index) * 12),
                avatarView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                avatarView.widthAnchor.constraint(equalToConstant: 20),
                avatarView.heightAnchor.constraint(equalToConstant: 20),
            ])
        }
        return container
    }

    @objc private func bubbleTapped(_ sender: UIControl) {
        guard groups.indices.contains(sender.tag) else { return }
        presentBoostActions(for: groups[sender.tag], sourceView: sender)
    }

    @objc private func bubbleLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let view = gesture.view,
              groups.indices.contains(view.tag)
        else { return }
        let group = groups[view.tag]
        let deletable = group.boosts.filter(\.canDelete)
        guard !deletable.isEmpty else {
            presentBoostActions(for: group, sourceView: view)
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let sheet = UIAlertController(
            title: group.displayText.isEmpty
                ? String(localized: "post.boost", defaultValue: "Boost")
                : group.displayText,
            message: nil,
            preferredStyle: .actionSheet
        )
        for boost in deletable {
            let name = boost.user.name?.isEmpty == false ? boost.user.name! : boost.user.username
            sheet.addAction(UIAlertAction(
                title: String(format: String(localized: "post.boost.delete_fmt", defaultValue: "删除 %@ 的 Boost"), name),
                style: .destructive
            ) { [weak self] _ in
                self?.onRequestDeleteBoost?(boost)
            })
        }
        sheet.addAction(UIAlertAction(
            title: String(localized: "post.boost.view_authors", defaultValue: "查看发送者"),
            style: .default
        ) { [weak self] _ in
            self?.presentGroupSheet(group, sourceView: view)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = view.bounds
        }
        nearestViewController()?.present(sheet, animated: true)
    }

    private func presentBoostActions(for group: Group, sourceView: UIView) {
        let host = nearestViewController()
        let currentUsername = AuthManager.shared.username(for: baseURL)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var boosts = group.boosts
            let api = DiscourseAPI(baseURL: self.baseURL)
            for index in boosts.indices where BoostActionPolicy.shouldFetchActionState(
                boost: boosts[index],
                currentUsername: currentUsername
            ) {
                do {
                    let resolved = try await api.getBoost(boostId: boosts[index].id)
                    boosts[index] = resolved
                    self.onBoostChanged?(resolved)
                } catch {
                    // Keep payload permissions; popover still shows author / delete when possible.
                }
            }

            let visible = boosts.filter {
                BoostActionPolicy.canShowActionSheet(boost: $0, currentUsername: currentUsername)
            }
            guard !visible.isEmpty else { return }

            if visible.contains(where: {
                BoostActionPolicy.boostAlreadyReported(boost: $0, currentUsername: currentUsername)
                    && !BoostActionPolicy.canDelete(boost: $0, currentUsername: currentUsername)
            }) {
                if let host {
                    DoerFeedback.presentToast(
                        String(localized: "boost.flag.already_reported", defaultValue: "你已经举报过这条 Boost"),
                        on: host
                    )
                }
            }

            let popover = BoostAuthorPopoverViewController(
                boosts: visible,
                currentUsername: currentUsername,
                baseURL: self.baseURL
            )
            popover.onAction = { [weak self, weak host] action in
                guard let self else { return }
                switch action {
                case .profile(let username):
                    self.onOpenUserProfile?(username)
                case .delete(let boost):
                    self.onRequestDeleteBoost?(boost)
                case .flag(let boost):
                    self.presentFlagSheet(for: boost, from: host, api: api)
                }
            }
            popover.modalPresentationStyle = .popover
            if let pop = popover.popoverPresentationController {
                pop.sourceView = sourceView
                pop.sourceRect = sourceView.bounds
                pop.permittedArrowDirections = [.up, .down]
                pop.delegate = popover
                pop.backgroundColor = .secondarySystemGroupedBackground
            }
            (host ?? self.nearestViewController())?.present(popover, animated: true)
        }
    }

    private func presentFlagSheet(
        for boost: DiscourseTopicDetail.Boost,
        from host: UIViewController?,
        api: DiscourseAPI
    ) {
        let presenter = host ?? nearestViewController()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let allTypes = (try? await api.fetchBoostFlagTypes()) ?? DiscourseFlagType.defaultTypes
            let filtered = BoostActionPolicy.filterFlagTypes(allTypes, availableFlags: boost.availableFlags)
            let types: [DiscourseFlagType]
            if let available = boost.availableFlags, available.isEmpty {
                types = []
            } else if filtered.isEmpty {
                types = allTypes.filter(\.isFlag).filter(\.enabled)
            } else {
                types = filtered
            }
            guard !types.isEmpty else {
                if let presenter {
                    DoerFeedback.presentToast(
                        String(localized: "common.no_data", defaultValue: "暂无数据"),
                        on: presenter
                    )
                }
                return
            }
            let sheet = BoostFlagSheetViewController(boost: boost, flagTypes: types)
            sheet.onSubmit = { [weak self] flagTypeId, message in
                try await api.flagBoost(boostId: boost.id, flagTypeId: flagTypeId, message: message)
                do {
                    let updated = try await api.getBoost(boostId: boost.id)
                    self?.onBoostChanged?(updated)
                } catch {
                    self?.onBoostChanged?(
                        boost.replacingActionState(canFlag: false, userFlagStatus: boost.userFlagStatus ?? 1)
                    )
                }
            }
            sheet.onFinished = {
                presenter.map {
                    DoerFeedback.presentToast(
                        String(localized: "boost.flag.submitted", defaultValue: "已提交举报"),
                        on: $0
                    )
                }
            }
            let nav = UINavigationController(rootViewController: sheet)
            nav.modalPresentationStyle = .pageSheet
            if let sheetController = nav.sheetPresentationController {
                sheetController.detents = [.medium(), .large()]
                sheetController.prefersGrabberVisible = true
                sheetController.preferredCornerRadius = 16
            }
            presenter?.present(nav, animated: true)
        }
    }

    private func presentGroupSheet(_ group: Group, sourceView: UIView) {
        let title = group.displayText.isEmpty
            ? String(localized: "post.boost", defaultValue: "Boost")
            : group.displayText
        let sheet = UIAlertController(
            title: title,
            message: String(
                format: String(localized: "post.boost.authors_count_fmt", defaultValue: "%d 人发送了相同 Boost"),
                group.boosts.count
            ),
            preferredStyle: .actionSheet
        )
        for boost in group.boosts {
            let name = boost.user.name?.isEmpty == false ? boost.user.name! : "@\(boost.user.username)"
            let action = UIAlertAction(title: name, style: .default) { [weak self] _ in
                let username = boost.user.username.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !username.isEmpty else { return }
                self?.onOpenUserProfile?(username)
            }
            sheet.addAction(action)
        }
        if let own = group.boosts.first(where: \.canDelete) {
            sheet.addAction(UIAlertAction(
                title: String(localized: "post.boost.delete_mine", defaultValue: "删除我的 Boost"),
                style: .destructive
            ) { [weak self] _ in
                self?.onRequestDeleteBoost?(own)
            })
        }

        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel", defaultValue: "取消"), style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = sourceView
            pop.sourceRect = sourceView.bounds
        }
        nearestViewController()?.present(sheet, animated: true)
    }


    private enum BoostTitleSegment {
        case text(String)
        case emoji(url: URL, code: String)
    }

    private static let titleStackTag = 0xE10F1

    private func observeEmojiStoreUpdates() {
        emojiUpdateObserver = NotificationCenter.default.addObserver(
            forName: EmojiStore.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isReloadingTitles else { return }
            self.reloadAllTitleContents()
        }
    }

    private func ensureEmojiMapLoaded() {
        let base = baseURL
        // Disk cache hit: lookupMap already filled in setupViews; observer handles future updates.
        if EmojiStore.load(for: base) {
            return
        }
        Task {
            // Same path composers / topic detail use: /emojis.json + custom site emojis.
            do {
                _ = try await DiscourseAPI(baseURL: base).fetchEmojiGroups()
                // save() already posts didUpdateNotification → reloadAllTitleContents via observer.
            } catch {
                // Keep deterministic twitter fallbacks already rendered.
            }
        }
    }

    private func reloadAllTitleContents() {
        guard !isReloadingTitles else { return }
        isReloadingTitles = true
        defer { isReloadingTitles = false }

        // Full bubble rebuild keeps Auto Layout correct after emoji map lands.
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        bubbleContainers.removeAll(keepingCapacity: true)
        for (index, group) in groups.enumerated() {
            let bubble = makeBubble(for: group, index: index)
            bubbleContainers[index] = bubble
            stackView.addArrangedSubview(bubble)
        }
    }

    /// Horizontal text + UIImageView. Emoji URLs come from /emojis.json via EmojiStore.
    private func makeTitleContent(for group: Group, font: UIFont) -> UIView {
        // Do not call EmojiStore.load here — it posts didUpdate and would loop reloads.
        let segments = Self.parseTitleSegments(
            cookedHTML: group.cookedHTML,
            plainFallback: group.displayText,
            baseURL: baseURL
        )

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 2
        stack.isUserInteractionEnabled = false
        stack.tag = Self.titleStackTag

        if segments.isEmpty {
            let label = UILabel()
            label.text = String(localized: "post.boost", defaultValue: "Boost")
            label.font = font
            label.textColor = .label
            stack.addArrangedSubview(label)
            return stack
        }

        let emojiSize = max(font.pointSize + 2, 14)
        for segment in segments {
            switch segment {
            case .text(let value):
                guard !value.isEmpty else { continue }
                let label = UILabel()
                label.text = value
                label.font = font
                label.textColor = .label
                label.numberOfLines = 1
                label.lineBreakMode = .byTruncatingTail
                label.setContentHuggingPriority(.required, for: .horizontal)
                label.setContentCompressionResistancePriority(.required, for: .horizontal)
                stack.addArrangedSubview(label)
            case .emoji(let url, let code):
                let imageView = UIImageView()
                imageView.contentMode = .scaleAspectFit
                imageView.clipsToBounds = true
                imageView.translatesAutoresizingMaskIntoConstraints = false
                imageView.accessibilityLabel = ":\(code):"
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: emojiSize),
                    imageView.heightAnchor.constraint(equalToConstant: emojiSize),
                ])
                stack.addArrangedSubview(imageView)
                // Match emoji picker: public emoji assets don't need CF gate cookies.
                // Uploads (/uploads/) still get forum base for cookie/referer.
                let needsForumAuth = url.path.localizedCaseInsensitiveContains("/uploads/")
                ForumImageLoader.setImage(
                    on: imageView,
                    url: url,
                    cloudflareBaseURL: needsForumAuth ? baseURL : nil
                )
            }
        }
        return stack
    }

    /// Parse boost cooked HTML into text / emoji URL segments.
    /// Emoji URLs prefer EmojiStore map built from /emojis.json.
    private static func parseTitleSegments(
        cookedHTML: String,
        plainFallback: String,
        baseURL: String
    ) -> [BoostTitleSegment] {
        // 1) Cooked HTML tree (text + <img class="emoji">).
        let inlines = displayInlines(from: cookedHTML, baseURL: baseURL)
        if !inlines.isEmpty {
            let fromInlines = segments(fromInlines: inlines, baseURL: baseURL)
            let expanded = expandShortcodesInSegments(fromInlines, baseURL: baseURL)
            if !expanded.isEmpty { return expanded }
        }

        // 2) Recover ":name:" from HTML / plain fallback.
        var working = TitleEmojiRenderer.recoverShortcodesFromHTML(cookedHTML)
        working = TitleEmojiRenderer.decodeHTMLEntities(working)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if working.isEmpty {
            working = plainFallback
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !working.isEmpty else { return [] }
        return expandShortcodesInSegments([.text(working)], baseURL: baseURL)
    }

    private static func segments(fromInlines inlines: [InlineNode], baseURL: String) -> [BoostTitleSegment] {
        var result: [BoostTitleSegment] = []
        func appendText(_ raw: String) {
            guard !raw.isEmpty else { return }
            if case .text(let existing)? = result.last {
                result[result.count - 1] = .text(existing + raw)
            } else {
                result.append(.text(raw))
            }
        }
        func walk(_ nodes: [InlineNode]) {
            for node in nodes {
                switch node {
                case .text(let value), .styledText(let value, _), .code(let value):
                    appendText(value)
                case .lineBreak:
                    appendText(" ")
                case .link(_, let children), .spoiler(let children):
                    walk(children)
                case .mention(let username, _):
                    appendText("@\(username)")
                case .mentionGroup(let name, _):
                    appendText("@\(name)")
                case .hashtag(let value, _, _, _):
                    appendText("#\(value)")
                case .image(let src, let alt, _, _, let isEmoji):
                    guard isEmoji || isTinyEmojiURL(src) else {
                        if let alt, !alt.isEmpty { appendText(alt) }
                        continue
                    }
                    let code = emojiCode(fromAlt: alt, src: src)
                    if let url = resolveEmojiURL(code: code, cookedSrc: src, baseURL: baseURL) {
                        result.append(.emoji(url: url, code: code.isEmpty ? "emoji" : code))
                    } else if !code.isEmpty {
                        // Map cold — keep shortcode text until /emojis.json lands.
                        appendText(":\(code):")
                    } else if let alt, !alt.isEmpty {
                        appendText(alt)
                    }
                }
            }
        }
        walk(inlines)
        return result
    }

    private static func isTinyEmojiURL(_ src: String) -> Bool {
        src.localizedCaseInsensitiveContains("/emoji/")
    }

    private static func emojiCode(fromAlt alt: String?, src: String) -> String {
        if let alt, !alt.isEmpty {
            let trimmed = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if !trimmed.isEmpty { return trimmed }
        }
        return TitleEmojiRenderer.emojiNameForBoost(fromSrc: src)
    }

    /// Resolve emoji image URL with /emojis.json map first (user request).
    private static func resolveEmojiURL(code: String, cookedSrc: String, baseURL: String) -> URL? {
        // 1) EmojiStore map from /emojis.json (custom + standard, real CDN/upload paths).
        if !code.isEmpty,
           let mapped = EmojiStore.lookup(for: code) ?? EmojiStore.url(for: code),
           let url = EmojiPickerView.resolvedEmojiURL(mapped, baseURL: baseURL) {
            return url
        }

        // 2) Cooked HTML src (often already absolute CDN path).
        let absolute = resolveURL(cookedSrc, baseURL: baseURL)
        if let url = URL(string: absolute), url.scheme != nil, !absolute.isEmpty {
            return url
        }

        // 3) Deterministic Discourse twitter path when map is still cold.
        if !code.isEmpty,
           let fallback = EmojiStore.resolvedURLString(for: code, baseURL: baseURL),
           let url = URL(string: fallback) {
            return url
        }
        return nil
    }

    private static func expandShortcodesInSegments(
        _ segments: [BoostTitleSegment],
        baseURL: String
    ) -> [BoostTitleSegment] {
        var result: [BoostTitleSegment] = []
        for segment in segments {
            switch segment {
            case .emoji:
                result.append(segment)
            case .text(let text):
                result.append(contentsOf: splitTextWithShortcodes(text, baseURL: baseURL))
            }
        }
        var collapsed: [BoostTitleSegment] = []
        for segment in result {
            if case .text(let value) = segment, value.isEmpty { continue }
            if case .text(let value) = segment, case .text(let prev)? = collapsed.last {
                collapsed[collapsed.count - 1] = .text(prev + value)
            } else {
                collapsed.append(segment)
            }
        }
        return collapsed
    }

    private static func splitTextWithShortcodes(_ text: String, baseURL: String) -> [BoostTitleSegment] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = emojiShortcodeRegex.matches(in: text, range: full)
        guard !matches.isEmpty else { return [.text(text)] }

        var result: [BoostTitleSegment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            }
            let code = ns.substring(with: match.range(at: 1))
            if let url = resolveEmojiURL(code: code, cookedSrc: "", baseURL: baseURL) {
                result.append(.emoji(url: url, code: code))
            } else {
                // Keep shortcode until map arrives; blank image slot is worse.
                result.append(.text(ns.substring(with: match.range)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(.text(ns.substring(from: cursor)))
        }
        return result
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    private func attributedDisplayText(for group: Group, font: UIFont) -> NSMutableAttributedString {
        // Build a shortcode-friendly string first (FluxDo: emoji <img> → :name:),
        // then turn shortcodes into EmojiTextAttachment with absolute URLs for this forum.
        let fromCooked = TitleEmojiRenderer.recoverShortcodesFromHTML(group.cookedHTML)
        let plain = group.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        var working: String
        if !fromCooked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            working = TitleEmojiRenderer.decodeHTMLEntities(fromCooked)
        } else if !plain.isEmpty {
            working = plain
        } else {
            working = String(localized: "post.boost", defaultValue: "Boost")
        }
        working = working
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if working.isEmpty {
            working = String(localized: "post.boost", defaultValue: "Boost")
        }

        // Also fold any remaining cooked <img emoji> via inline parse so absolute src is kept.
        let inlines = Self.displayInlines(from: group.cookedHTML, baseURL: baseURL)
        let attributed: NSMutableAttributedString
        if !inlines.isEmpty {
            attributed = NSMutableAttributedString(attributedString: inlines.attributedString(config: AttributedStringConfig(
                baseFont: font,
                baseColor: .label,
                linkColor: AppSettings.shared.themeStyle.accentColor,
                codeFont: .monospacedSystemFont(ofSize: max(font.pointSize - 1, 1), weight: .regular),
                codeBackgroundColor: .clear
            )))
            // Resolve relative cookedHTMLImageURL → absolute against forum base.
            Self.absolutizeImageURLs(in: attributed, baseURL: baseURL)
            // Shortcodes that survived as plain text (alt/title recovery).
            return Self.replacingEmojiShortcodes(
                in: attributed,
                font: font,
                textColor: .label,
                baseURL: baseURL
            )
        }

        let base = NSMutableAttributedString(string: working, attributes: [
            .font: font,
            .foregroundColor: UIColor.label,
        ])
        return Self.replacingEmojiShortcodes(
            in: base,
            font: font,
            textColor: .label,
            baseURL: baseURL
        )
    }

    private func loadInlineImages(in label: UILabel, attributedString: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        guard fullRange.length > 0 else { return }

        var entries: [(range: NSRange, attachment: NSTextAttachment, url: URL, shortcode: String?)] = []
        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            guard let attachment = attributes[.attachment] as? NSTextAttachment else { return }

            if let emojiAttachment = attachment as? EmojiTextAttachment {
                if let url = emojiAttachment.emojiURL {
                    entries.append((range, attachment, url, emojiAttachment.shortcode))
                    return
                }
                if let shortcode = emojiAttachment.shortcode {
                    let code = shortcode.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    if let urlString = EmojiStore.resolvedURLString(for: code, baseURL: baseURL),
                       let url = URL(string: urlString) {
                        emojiAttachment.emojiURL = url
                        entries.append((range, attachment, url, shortcode))
                    }
                }
                return
            }

            guard let urlString = attributes[.cookedHTMLImageURL] as? String else { return }
            let absolute = Self.resolveURL(urlString, baseURL: baseURL)
            guard let url = URL(string: absolute), url.scheme != nil else { return }
            entries.append((range, attachment, url, nil))
        }

        guard !entries.isEmpty else { return }

        // Snapshot ranges; mutations shift later indexes so walk reversed on failure replace.
        for entry in entries {
            ForumImageLoader.loadImage(
                with: entry.url,
                cloudflareBaseURL: baseURL
            ) { [weak label] image in
                Task { @MainActor in
                    guard let label else { return }
                    guard let current = label.attributedText else { return }
                    let mutable = NSMutableAttributedString(attributedString: current)

                    if let image {
                        entry.attachment.image = image
                        // Keep same attachment object; force UILabel repaint.
                        label.attributedText = NSAttributedString(attributedString: mutable)
                    } else {
                        // FluxDo parity: never leave a blank chip slot on 404/CF failure.
                        let fallback = entry.shortcode?.isEmpty == false
                            ? entry.shortcode!
                            : ""
                        // Find this attachment in the live string (range may have shifted).
                        var targetRange: NSRange?
                        mutable.enumerateAttribute(
                            .attachment,
                            in: NSRange(location: 0, length: mutable.length)
                        ) { value, range, stop in
                            if value as AnyObject === entry.attachment {
                                targetRange = range
                                stop.pointee = true
                            }
                        }
                        if let targetRange {
                            let attrs: [NSAttributedString.Key: Any] = [
                                .font: label.font ?? TopicDetailTypography.interfaceFont(ofSize: 12, weight: .regular),
                                .foregroundColor: UIColor.label,
                            ]
                            mutable.replaceCharacters(
                                in: targetRange,
                                with: NSAttributedString(string: fallback, attributes: attrs)
                            )
                            label.attributedText = mutable
                        }
                    }
                    label.setNeedsDisplay()
                    label.invalidateIntrinsicContentSize()
                }
            }
        }
    }

    /// Turn cooked `NSTextAttachment` + `cookedHTMLImageURL` into `EmojiTextAttachment`
    /// with absolute URL + shortcode, so load/fallback share one path.
    private static func promoteCookedEmojiAttachments(
        in attributed: NSAttributedString,
        font: UIFont,
        textColor _: UIColor,
        cookedHTML: String,
        baseURL: String
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: result.length)
        guard full.length > 0 else { return result }

        // Build src → shortcode hints from cooked HTML (alt/title/src path).
        let shortcodeHints = emojiShortcodeHints(from: cookedHTML)

        var replacements: [(range: NSRange, replacement: NSAttributedString)] = []
        result.enumerateAttributes(in: full) { attributes, range, _ in
            guard let attachment = attributes[.attachment] as? NSTextAttachment else { return }
            if attachment is EmojiTextAttachment { return }

            guard let rawURL = attributes[.cookedHTMLImageURL] as? String else { return }
            let absolute = resolveURL(rawURL, baseURL: baseURL)
            guard let url = URL(string: absolute), url.scheme != nil else { return }

            let emoji = EmojiTextAttachment()
            emoji.emojiURL = url
            emoji.shortcode = shortcodeHints[rawURL]
                ?? shortcodeHints[absolute]
                ?? shortcodeFromEmojiURL(absolute)
            let size = font.pointSize
            emoji.image = transparentPlaceholderImage()
            emoji.bounds = CGRect(
                x: 0,
                y: (font.capHeight - size) / 2,
                width: size,
                height: size
            )
            replacements.append((range, NSAttributedString(attachment: emoji)))
        }

        for item in replacements.reversed() {
            result.replaceCharacters(in: item.range, with: item.replacement)
        }
        return result
    }

    /// Map raw img src → `:name:` from cooked boost HTML.
    private static func emojiShortcodeHints(from html: String) -> [String: String] {
        var map: [String: String] = [:]
        let pattern = try! NSRegularExpression(
            pattern: #"<img\b([^>]+)>"#,
            options: [.caseInsensitive]
        )
        let ns = html as NSString
        for match in pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: match.range(at: 1))
            guard attrs.localizedCaseInsensitiveContains("emoji") else { continue }

            func attr(_ name: String) -> String? {
                let p = try! NSRegularExpression(
                    pattern: #"\#(name)\s*=\s*[\"']([^\"']+)[\"']"#,
                    options: [.caseInsensitive]
                )
                guard let m = p.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
                      m.numberOfRanges > 1
                else { return nil }
                return (attrs as NSString).substring(with: m.range(at: 1))
            }

            guard let src = attr("src"), !src.isEmpty else { continue }
            var name = ""
            if let titled = attr("title") ?? attr("alt") {
                name = titled.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if name.isEmpty {
                name = TitleEmojiRenderer.emojiNameForBoost(fromSrc: src)
            }
            guard !name.isEmpty else { continue }
            map[src] = ":\(name):"
        }
        return map
    }

    private static func shortcodeFromEmojiURL(_ urlString: String) -> String? {
        let name = TitleEmojiRenderer.emojiNameForBoost(fromSrc: urlString)
        return name.isEmpty ? nil : ":\(name):"
    }

    private static func absolutizeImageURLs(in attributed: NSMutableAttributedString, baseURL: String) {
        let full = NSRange(location: 0, length: attributed.length)
        guard full.length > 0, !baseURL.isEmpty else { return }
        attributed.enumerateAttribute(.cookedHTMLImageURL, in: full) { value, range, _ in
            guard let raw = value as? String else { return }
            let absolute = Self.resolveURL(raw, baseURL: baseURL)
            if absolute != raw {
                attributed.addAttribute(.cookedHTMLImageURL, value: absolute, range: range)
            }
        }
    }

    private static func makeGroups(from boosts: [DiscourseTopicDetail.Boost]) -> [Group] {
        var seenIds = Set<Int>()
        var order: [String] = []
        var grouped: [String: [DiscourseTopicDetail.Boost]] = [:]
        var displayTextByKey: [String: String] = [:]
        var cookedHTMLByKey: [String: String] = [:]

        for boost in boosts {
            guard seenIds.insert(boost.id).inserted else { continue }
            let displayText = plainText(from: boost.cooked)
            // Prefer plain text key (FluxDo). Empty cooked still groups by collapsed HTML.
            let key: String = {
                let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
                return boost.cooked
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }()
            guard !key.isEmpty else { continue }
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
                displayTextByKey[key] = displayText
                cookedHTMLByKey[key] = boost.cooked
            }
            grouped[key]?.append(boost)
        }

        return order.compactMap { key in
            guard let boosts = grouped[key], !boosts.isEmpty else { return nil }
            return Group(
                displayText: displayTextByKey[key] ?? "",
                cookedHTML: cookedHTMLByKey[key] ?? "",
                boosts: boosts
            )
        }
    }

    private static func displayInlines(from html: String, baseURL: String) -> [InlineNode] {
        let blocks = CookedHTMLParser.parse(html: html, baseURL: baseURL.isEmpty ? nil : baseURL)
        var chunks: [[InlineNode]] = []
        for block in blocks {
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                let normalized = normalizedDisplayInlines(inlines)
                if !normalized.isEmpty { chunks.append(normalized) }
            case .image(let src, let alt, let width, let height, _):
                // Emoji-only boosts often land as a lone image block.
                chunks.append([
                    .image(src: src, alt: alt, width: width, height: height, isEmoji: true)
                ])
            default:
                break
            }
        }
        return joinedInlines(chunks)
    }

    private static func isTinyEmojiSize(width: Int?, height: Int?) -> Bool {
        guard let width, let height, width > 0, height > 0 else {
            return false
        }
        return width <= 32 && height <= 32
    }

    private static func normalizedDisplayInlines(_ inlines: [InlineNode]) -> [InlineNode] {
        inlines.map { inline in
            switch inline {
            case .lineBreak:
                return .text(" ")
            case .link(let href, let children):
                return .link(href: href, children: normalizedDisplayInlines(children))
            case .spoiler(let children):
                return .spoiler(children: normalizedDisplayInlines(children))
            default:
                return inline
            }
        }
    }

    private static func joinedInlines(_ chunks: [[InlineNode]]) -> [InlineNode] {
        var result: [InlineNode] = []
        for chunk in chunks where !chunk.isEmpty {
            if !result.isEmpty {
                result.append(.text(" "))
            }
            result.append(contentsOf: chunk)
        }
        return result
    }

    private static func replacingEmojiShortcodes(
        in attributed: NSAttributedString,
        font: UIFont,
        textColor: UIColor,
        baseURL: String
    ) -> NSMutableAttributedString {
        let result = NSMutableAttributedString()
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return result }

        attributed.enumerateAttributes(in: fullRange) { attributes, range, _ in
            if attributes[.attachment] != nil {
                result.append(attributed.attributedSubstring(from: range))
                return
            }

            let text = attributed.attributedSubstring(from: range).string
            guard text.contains(":") else {
                result.append(attributed.attributedSubstring(from: range))
                return
            }

            var textAttributes = attributes
            textAttributes[.font] = textAttributes[.font] ?? font
            textAttributes[.foregroundColor] = textAttributes[.foregroundColor] ?? textColor
            result.append(emojiAttributedString(from: text, attributes: textAttributes, font: font, baseURL: baseURL))
        }
        return result
    }

    private static func emojiAttributedString(
        from text: String,
        attributes: [NSAttributedString.Key: Any],
        font: UIFont,
        baseURL: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = emojiShortcodeRegex.matches(in: text, range: fullRange)
        var lastLocation = 0

        for match in matches {
            let plainLength = match.range.location - lastLocation
            if plainLength > 0 {
                result.append(NSAttributedString(
                    string: nsText.substring(with: NSRange(location: lastLocation, length: plainLength)),
                    attributes: attributes
                ))
            }

            let shortcode = nsText.substring(with: match.range)
            let code = nsText.substring(with: match.range(at: 1))
            if let urlString = EmojiStore.resolvedURLString(for: code, baseURL: baseURL),
               let url = URL(string: urlString) {
                let emojiSize = font.pointSize
                let attachment = EmojiTextAttachment()
                attachment.emojiURL = url
                attachment.shortcode = shortcode
                // Transparent 1x1 placeholder keeps layout size; empty UIImage() can collapse.
                attachment.image = Self.transparentPlaceholderImage()
                attachment.bounds = CGRect(
                    x: 0,
                    y: (font.capHeight - emojiSize) / 2,
                    width: emojiSize,
                    height: emojiSize
                )
                result.append(NSAttributedString(attachment: attachment))
            } else {
                result.append(NSAttributedString(string: shortcode, attributes: attributes))
            }

            lastLocation = match.range.location + match.range.length
        }

        if lastLocation < nsText.length {
            result.append(NSAttributedString(
                string: nsText.substring(from: lastLocation),
                attributes: attributes
            ))
        }
        return result
    }

    private static func plainText(from html: String) -> String {
        CookedContentPipeline.plainTextPreview(fromCooked: html)
    }

    private static func resolveURL(_ raw: String, baseURL: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") {
            return trimmed
        }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        guard !baseURL.isEmpty, let base = URL(string: baseURL) else { return trimmed }
        if trimmed.hasPrefix("/") {
            var components = URLComponents()
            components.scheme = base.scheme
            components.host = base.host
            components.port = base.port
            components.path = trimmed
            return components.url?.absoluteString ?? trimmed
        }
        return base.appendingPathComponent(trimmed).absoluteString
    }

    private static func transparentPlaceholderImage() -> UIImage {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
