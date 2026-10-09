import UIKit

/// Topic more menu. A grouped sheet: icon shortcuts on top, list actions below.
final class TopicMoreMenuViewController: UIViewController {
    struct Model {
        var isBookmarked: Bool
        var isInReadLater: Bool
        var notificationLevel: DiscourseTopicDetail.NotificationLevel?
        var hasActiveFilter: Bool
        var isFilteringByOP: Bool = false
        var filterUsername: String? = nil
        var isFilteringTopLevel: Bool = false
        var isNestedViewEnabled: Bool = false
        var canEdit: Bool
        var showExport: Bool
        var canAssign: Bool = false
        var assignedToUsername: String? = nil
        var currentFloor: Int = 1
        var totalFloors: Int = 1
        var hasTableOfContents: Bool = false
        var isPrivateMessage: Bool = false
        var messageArchived: Bool = false
    }

    enum Action: Equatable {
        case bookmark
        case readLater
        case shareLink
        case editTopic
        case shareImage
        case openBrowser
        case openTimeline
        case jumpToFloor(Int)
        case readingSettings
        case tableOfContents
        case markUnreadStepBack
        case markUnreadClear
        case assignToMe
        case assignPickUser
        case unassign
        case filterOP
        case filterUser(String)
        case filterTopLevel
        case filterNested
        case filterClear
        case notification(DiscourseTopicDetail.NotificationLevel)
        case export(TopicExportFormat, TopicExportRange)
        case archivePrivateMessage
    }

    var onAction: ((Action) -> Void)?

    private let model: Model
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var expandedSection: ExpandedSection?
    private var scrubFloor: Int?

    private enum ExpandedSection: Equatable {
        case markUnread
        case assign
        case filter
        case notification
        case export
    }

    private var themeStyle: AppSettings.ThemeStyle { AppSettings.shared.themeStyle }
    private var accent: UIColor { themeStyle.accentColor }
    private var menuCanvas: UIColor { themeStyle.topicListBackgroundColor }
    private var menuSurface: UIColor { themeStyle.topicCardBackgroundColor }

    init(model: Model) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        preferredContentSize = CGSize(width: 360, height: 560)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = menuCanvas

        let header = makeHeader()
        view.addSubview(header)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        stack.addArrangedSubview(makeSectionLabel(
            String(localized: "topic.menu.section.shortcuts", defaultValue: "快捷")
        ))
        stack.addArrangedSubview(makeShortcutCard())

        var contentRows: [UIView] = []
        if model.canEdit {
            contentRows.append(makeRow(
                symbol: "pencil",
                title: String(localized: "topic.edit", defaultValue: "编辑话题"),
                action: .editTopic
            ))
        }
        contentRows.append(makeRow(
            symbol: "photo",
            title: String(localized: "topic.share_image", defaultValue: "生成分享图片"),
            action: .shareImage
        ))
        if model.showExport {
            contentRows.append(makeExpandableRow(
                symbol: "square.and.arrow.down",
                title: String(localized: "topic.export", defaultValue: "导出话题"),
                section: .export,
                isActive: false
            ))
            if expandedSection == .export {
                contentRows.append(contentsOf: makeExportRows())
            }
        }
        contentRows.append(makeRow(
            symbol: "safari",
            title: String(localized: "topic.open_browser", defaultValue: "在浏览器打开"),
            action: .openBrowser
        ))
        if model.isPrivateMessage {
            contentRows.append(makeRow(
                symbol: model.messageArchived ? "tray.and.arrow.down" : "archivebox",
                title: model.messageArchived
                    ? String(localized: "pm.move_to_inbox", defaultValue: "Move to inbox")
                    : String(localized: "pm.archive", defaultValue: "Archive"),
                action: .archivePrivateMessage
            ))
        }
        if !contentRows.isEmpty {
            stack.addArrangedSubview(makeSectionLabel(
                String(localized: "topic.menu.section.content", defaultValue: "内容")
            ))
            stack.addArrangedSubview(makeGroup(contentRows))
        }

        var readingRows: [UIView] = [makeTimelineCard()]
        readingRows.append(makeExpandableRow(
            symbol: "eye.slash",
            title: String(localized: "topic.mark_unread", defaultValue: "标记未读"),
            section: .markUnread,
            isActive: false
        ))
        if expandedSection == .markUnread {
            readingRows.append(makeMarkUnreadPanel())
        }
        readingRows.append(makeRow(
            symbol: "text.book.closed",
            title: String(localized: "topic.reading_settings", defaultValue: "阅读设置"),
            action: .readingSettings
        ))
        if model.hasTableOfContents {
            readingRows.append(makeRow(
                symbol: "list.bullet",
                title: String(localized: "topic.toc", defaultValue: "目录"),
                action: .tableOfContents
            ))
        }
        stack.addArrangedSubview(makeSectionLabel(
            String(localized: "topic.menu.section.reading", defaultValue: "阅读")
        ))
        stack.addArrangedSubview(makeGroup(readingRows))

        if model.canAssign {
            let assignTitle: String = {
                if let name = model.assignedToUsername, !name.isEmpty {
                    return String(
                        format: String(localized: "topic.assign.current", defaultValue: "已指定 @%@"),
                        name
                    )
                }
                return String(localized: "topic.assign", defaultValue: "指定处理人")
            }()
            var assignRows = [
                makeExpandableRow(
                    symbol: "person.badge.plus",
                    title: assignTitle,
                    section: .assign,
                    isActive: model.assignedToUsername != nil
                ),
            ]
            if expandedSection == .assign {
                assignRows.append(makeAssignPanel())
            }
            stack.addArrangedSubview(makeSectionLabel(
                String(localized: "topic.menu.section.assign", defaultValue: "指定")
            ))
            stack.addArrangedSubview(makeGroup(assignRows))
        }

        refitPreferredSize()
    }

    private func refitPreferredSize() {
        let width: CGFloat = 328
        var height: CGFloat = 64
        for view in stack.arrangedSubviews {
            let fitting = view.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            height += max(fitting.height, 28)
        }
        height += 36
        preferredContentSize = CGSize(width: 360, height: min(max(height, 360), 760))
        if #available(iOS 16.0, *) {
            sheetPresentationController?.invalidateDetents()
        }
    }

    private func toggleExpand(_ section: ExpandedSection) {
        expandedSection = expandedSection == section ? nil : section
        rebuild()
    }

    // MARK: - Header

    private func makeHeader() -> UIView {
        let header = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = String(localized: "topic.more", defaultValue: "更多操作")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .label

        let close = UIButton(type: .system)
        close.translatesAutoresizingMaskIntoConstraints = false
        let symbol = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: symbol), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = String(localized: "common.close", defaultValue: "关闭")
        close.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        let closePlate = UIView()
        closePlate.translatesAutoresizingMaskIntoConstraints = false
        closePlate.isUserInteractionEnabled = false
        closePlate.backgroundColor = UIColor.tertiarySystemFill
        closePlate.layer.cornerRadius = 14
        closePlate.layer.cornerCurve = .continuous

        header.addSubview(title)
        header.addSubview(close)
        close.addSubview(closePlate)
        close.sendSubviewToBack(closePlate)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            closePlate.centerXAnchor.constraint(equalTo: close.centerXAnchor),
            closePlate.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            closePlate.widthAnchor.constraint(equalToConstant: 28),
            closePlate.heightAnchor.constraint(equalToConstant: 28),
        ])
        return header
    }

    // MARK: - Shortcuts

    private func makeShortcutCard() -> UIView {
        let subscribed: Bool = {
            guard let level = model.notificationLevel else { return false }
            return level == .watching || level == .tracking
        }()
        let items: [(String, String, String, Bool, () -> Void)] = [
            (
                model.isBookmarked ? "bookmark.fill" : "bookmark",
                model.isBookmarked
                    ? String(localized: "topic.menu.quick.bookmarked", defaultValue: "已收藏")
                    : String(localized: "topic.menu.quick.bookmark", defaultValue: "收藏"),
                model.isBookmarked
                    ? String(localized: "topic.bookmark.remove", defaultValue: "取消书签")
                    : String(localized: "topic.bookmark.add", defaultValue: "添加书签"),
                model.isBookmarked,
                { [weak self] in self?.emit(.bookmark) }
            ),
            (
                model.isInReadLater ? "clock.badge.checkmark" : "clock",
                model.isInReadLater
                    ? String(localized: "topic.menu.quick.read_later_on", defaultValue: "已加入")
                    : String(localized: "topic.menu.quick.read_later", defaultValue: "稍后读"),
                model.isInReadLater
                    ? String(localized: "topic.read_later.remove", defaultValue: "移出稍后阅读")
                    : String(localized: "topic.read_later.add", defaultValue: "稍后阅读"),
                model.isInReadLater,
                { [weak self] in self?.emit(.readLater) }
            ),
            (
                notificationSymbol(for: model.notificationLevel),
                String(localized: "topic.menu.quick.notify", defaultValue: "通知"),
                String(localized: "topic.notifications", defaultValue: "通知"),
                subscribed || expandedSection == .notification,
                { [weak self] in self?.toggleExpand(.notification) }
            ),
            (
                "square.and.arrow.up",
                String(localized: "topic.menu.quick.share", defaultValue: "分享"),
                String(localized: "topic.share", defaultValue: "分享"),
                false,
                { [weak self] in self?.emit(.shareLink) }
            ),
            (
                model.hasActiveFilter
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease",
                String(localized: "topic.menu.quick.filter", defaultValue: "筛选"),
                String(localized: "topic.filter", defaultValue: "筛选"),
                model.hasActiveFilter || expandedSection == .filter,
                { [weak self] in self?.toggleExpand(.filter) }
            ),
        ]

        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.alignment = .top
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for item in items {
            row.addArrangedSubview(makeShortcutButton(
                symbol: item.0,
                title: item.1,
                accessibilityLabel: item.2,
                active: item.3,
                handler: item.4
            ))
        }

        let body = UIStackView()
        body.axis = .vertical
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isLayoutMarginsRelativeArrangement = true
        body.layoutMargins = UIEdgeInsets(top: 14, left: 8, bottom: 12, right: 8)
        body.addArrangedSubview(row)
        if expandedSection == .notification {
            body.addArrangedSubview(makeNotificationPanel())
        }
        if expandedSection == .filter {
            body.addArrangedSubview(makeFilterPanel())
        }

        return wrapInCard(body)
    }

    private func makeShortcutButton(
        symbol: String,
        title: String,
        accessibilityLabel: String,
        active: Bool,
        handler: @escaping () -> Void
    ) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)

        let well = UIView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.isUserInteractionEnabled = false
        well.backgroundColor = active ? accent.withAlphaComponent(0.16) : UIColor.tertiarySystemFill
        well.layer.cornerRadius = 16
        well.layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = active ? accent : .label
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        well.addSubview(icon)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = active ? accent : .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.isUserInteractionEnabled = false

        button.addSubview(well)
        button.addSubview(label)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 74),
            well.topAnchor.constraint(equalTo: button.topAnchor),
            well.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            well.widthAnchor.constraint(equalToConstant: 48),
            well.heightAnchor.constraint(equalToConstant: 48),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
            label.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
        ])
        return button
    }

    // MARK: - Groups

    private func makeSectionLabel(_ title: String) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 36),
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8),
        ])
        return wrap
    }

    private func wrapInCard(_ content: UIView) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = menuSurface
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func makeGroup(_ rows: [UIView]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            stack.addArrangedSubview(row)
            if index < rows.count - 1 {
                stack.addArrangedSubview(makeHairline())
            }
        }
        return wrapInCard(stack)
    }

    private func makeHairline() -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.45)
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 52),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        ])
        return wrap
    }

    private func makeRow(symbol: String, title: String, action: Action, destructive: Bool = false) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in
            self?.emit(action)
        }, for: .touchUpInside)

        let iconWell = makeIconWell(symbol: symbol, tint: destructive ? .systemRed : accent)
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 16, weight: .regular)
        label.textColor = destructive ? .systemRed : .label
        label.isUserInteractionEnabled = false

        button.addSubview(iconWell)
        button.addSubview(label)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            iconWell.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            iconWell.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: button.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -14),
        ])
        let highlight = accent.withAlphaComponent(0.08)
        button.configurationUpdateHandler = { btn in
            btn.backgroundColor = btn.isHighlighted ? highlight : .clear
        }
        return button
    }

    private func makeExpandableRow(
        symbol: String,
        title: String,
        section: ExpandedSection,
        isActive: Bool
    ) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = title
        button.addAction(UIAction { [weak self] _ in
            self?.toggleExpand(section)
        }, for: .touchUpInside)

        let iconWell = makeIconWell(symbol: symbol, tint: accent)
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 16, weight: .regular)
        label.textColor = .label
        label.isUserInteractionEnabled = false

        let open = expandedSection == section
        let chevron = UIImageView(image: UIImage(systemName: open ? "chevron.up" : "chevron.down"))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        button.addSubview(iconWell)
        button.addSubview(label)
        button.addSubview(chevron)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            iconWell.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            iconWell.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: iconWell.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
            chevron.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        let highlight = accent.withAlphaComponent(0.08)
        button.configurationUpdateHandler = { btn in
            btn.backgroundColor = btn.isHighlighted ? highlight : .clear
        }
        return button
    }

    private func makeIconWell(symbol: String, tint: UIColor) -> UIView {
        let well = UIView()
        well.translatesAutoresizingMaskIntoConstraints = false
        well.isUserInteractionEnabled = false
        well.backgroundColor = tint.withAlphaComponent(0.12)
        well.layer.cornerRadius = 8
        well.layer.cornerCurve = .continuous

        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = tint
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        well.addSubview(icon)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 28),
            well.heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        return well
    }

    private func makeTimelineCard() -> UIView {
        let total = max(model.totalFloors, 1)
        let current = min(max(scrubFloor ?? max(model.currentFloor, 1), 1), total)

        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false

        let caption = UILabel()
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.text = String(localized: "progress_gesture.action.timeline", defaultValue: "时间线")
        caption.font = .systemFont(ofSize: 13, weight: .semibold)
        caption.textColor = .secondaryLabel

        let valueLabel = UILabel()
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = accent
        valueLabel.accessibilityIdentifier = "topic.menu.floor_value"
        valueLabel.text = floorProgressText(current: current, total: total)

        let slider = UISlider()
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.minimumValue = 1
        slider.maximumValue = Float(max(total, 2))
        slider.value = Float(current)
        slider.minimumTrackTintColor = accent
        slider.isEnabled = total > 1
        slider.accessibilityLabel = String(localized: "progress_gesture.action.timeline", defaultValue: "时间线")
        slider.addAction(UIAction { [weak self] action in
            guard let slider = action.sender as? UISlider else { return }
            let floor = Int(slider.value.rounded())
            self?.scrubFloor = floor
            valueLabel.text = self?.floorProgressText(current: floor, total: total)
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] action in
            guard let slider = action.sender as? UISlider else { return }
            let floor = Int(slider.value.rounded())
            self?.onAction?(.jumpToFloor(floor))
        }, for: [.touchUpInside, .touchUpOutside])

        let openButton = UIButton(type: .system)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()
        config.title = String(localized: "topic.menu.open_timeline", defaultValue: "打开楼层跳转")
        config.image = UIImage(systemName: "list.bullet.rectangle")
        config.imagePadding = 6
        config.imagePlacement = .leading
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 15, weight: .regular)
            return out
        }
        openButton.configuration = config
        openButton.contentHorizontalAlignment = .leading
        openButton.accessibilityLabel = String(localized: "topic.menu.open_timeline", defaultValue: "打开楼层跳转")
        openButton.addAction(UIAction { [weak self] _ in
            self?.emit(.openTimeline)
        }, for: .touchUpInside)

        wrap.addSubview(caption)
        wrap.addSubview(valueLabel)
        wrap.addSubview(slider)
        wrap.addSubview(openButton)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 14),
            caption.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            valueLabel.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            openButton.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 2),
            openButton.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 14),
            openButton.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -14),
            openButton.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -6),
        ])
        return wrap
    }

    private func floorProgressText(current: Int, total: Int) -> String {
        String(
            format: String(localized: "topic.menu.floor_progress", defaultValue: "第 %d / %d 层"),
            current,
            total
        )
    }

    // MARK: - Inline choices

    private func makeChoiceGrid(items: [(String, Bool, () -> Void)]) -> UIView {
        let columns = items.count <= 3 ? max(items.count, 1) : 2
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false

        var index = 0
        while index < items.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            let end = min(index + columns, items.count)
            for item in items[index..<end] {
                row.addArrangedSubview(makeChoiceButton(title: item.0, active: item.1, handler: item.2))
            }
            let missing = columns - (end - index)
            if missing > 0 {
                for _ in 0..<missing {
                    let spacer = UIView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    row.addArrangedSubview(spacer)
                }
            }
            grid.addArrangedSubview(row)
            index = end
        }

        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
            grid.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -12),
        ])
        return wrap
    }

    private func makeChoiceButton(title: String, active: Bool, handler: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .medium
        config.baseForegroundColor = active ? .white : .label
        config.baseBackgroundColor = active ? accent : UIColor.tertiarySystemFill
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = .systemFont(ofSize: 14, weight: .medium)
            return out
        }
        config.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: config)
        button.accessibilityLabel = title
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }

    private func makeMarkUnreadPanel() -> UIView {
        makeChoiceGrid(items: [
            (
                String(localized: "topic.mark_unread.step_back.short", defaultValue: "回退一层"),
                false,
                { [weak self] in self?.emit(.markUnreadStepBack) }
            ),
            (
                String(localized: "topic.mark_unread.clear.short", defaultValue: "清空进度"),
                false,
                { [weak self] in self?.emit(.markUnreadClear) }
            ),
        ])
    }

    private func makeAssignPanel() -> UIView {
        if model.assignedToUsername != nil {
            return makeChoiceGrid(items: [
                (
                    String(localized: "topic.assign.clear", defaultValue: "取消指定"),
                    false,
                    { [weak self] in self?.emit(.unassign) }
                ),
            ])
        }
        return makeChoiceGrid(items: [
            (
                String(localized: "topic.assign.to_me", defaultValue: "指定给我"),
                true,
                { [weak self] in self?.emit(.assignToMe) }
            ),
            (
                String(localized: "topic.assign.pick_user.short", defaultValue: "指定他人"),
                false,
                { [weak self] in self?.emit(.assignPickUser) }
            ),
        ])
    }

    private func makeFilterPanel() -> UIView {
        var items: [(String, Bool, () -> Void)] = [
            (
                String(localized: "topic.filter_op", defaultValue: "只看题主"),
                model.isFilteringByOP,
                { [weak self] in self?.emit(.filterOP) }
            ),
        ]
        if let username = model.filterUsername, !model.isFilteringByOP {
            items.append((
                String(format: String(localized: "topic.filter_user", defaultValue: "只看 %@"), username),
                true,
                { [weak self] in self?.emit(.filterUser(username)) }
            ))
        }
        items.append(contentsOf: [
            (
                String(localized: "topic.filter_top_level", defaultValue: "只看顶层"),
                model.isFilteringTopLevel,
                { [weak self] in self?.emit(.filterTopLevel) }
            ),
            (
                String(localized: "topic.filter_nested", defaultValue: "树形"),
                model.isNestedViewEnabled,
                { [weak self] in self?.emit(.filterNested) }
            ),
        ])
        if model.hasActiveFilter {
            items.append((
                String(localized: "topic.filter_clear", defaultValue: "取消筛选"),
                false,
                { [weak self] in self?.emit(.filterClear) }
            ))
        }
        return makeChoiceGrid(items: items)
    }

    private func makeNotificationPanel() -> UIView {
        let levels: [(DiscourseTopicDetail.NotificationLevel, String)] = [
            (.watching, String(localized: "topic.notification.watching", defaultValue: "关注")),
            (.tracking, String(localized: "topic.notification.tracking", defaultValue: "跟踪")),
            (.regular, String(localized: "topic.notification.regular", defaultValue: "正常")),
            (.muted, String(localized: "topic.notification.muted", defaultValue: "静音")),
        ]
        return makeChoiceGrid(items: levels.map { level, title in
            (
                title,
                model.notificationLevel == level,
                { [weak self] in self?.emit(.notification(level)) }
            )
        })
    }

    private func makeExportRows() -> [UIView] {
        let commons: [(TopicExportFormat, TopicExportRange, String)] = [
            (.markdown, .loadedPosts, String(localized: "topic.export.md_all", defaultValue: "Markdown · 已加载")),
            (.markdown, .firstPost, String(localized: "topic.export.md_op", defaultValue: "Markdown · 仅主帖")),
            (.html, .loadedPosts, String(localized: "topic.export.html_all", defaultValue: "HTML · 已加载")),
        ]
        return commons.map { format, range, title in
            makeRow(
                symbol: format == .markdown ? "doc.plaintext" : "chevron.left.forwardslash.chevron.right",
                title: title,
                action: .export(format, range)
            )
        }
    }

    private func notificationSymbol(for level: DiscourseTopicDetail.NotificationLevel?) -> String {
        switch level {
        case .watching: return "bell.badge.fill"
        case .tracking: return "bell.fill"
        case .muted: return "bell.slash"
        case .regular, .none: return "bell"
        }
    }

    private func emit(_ action: Action) {
        dismiss(animated: true) { [weak self] in
            self?.onAction?(action)
        }
    }
}

// MARK: - Presenter

enum TopicMoreMenuPresenter {
    static func present(
        from host: UIViewController,
        barButtonItem: UIBarButtonItem?,
        model: TopicMoreMenuViewController.Model,
        onAction: @escaping (TopicMoreMenuViewController.Action) -> Void
    ) {
        let menu = TopicMoreMenuViewController(model: model)
        menu.onAction = onAction
        let compact = host.traitCollection.horizontalSizeClass == .compact
        if compact {
            menu.modalPresentationStyle = .pageSheet
            if let sheet = menu.sheetPresentationController {
                if #available(iOS 16.0, *) {
                    let detent = UISheetPresentationController.Detent.custom(
                        identifier: .init("topic.more")
                    ) { context in
                        min(menu.preferredContentSize.height, context.maximumDetentValue * 0.92)
                    }
                    sheet.detents = [detent, .large()]
                    sheet.selectedDetentIdentifier = detent.identifier
                } else {
                    sheet.detents = [.medium(), .large()]
                    sheet.selectedDetentIdentifier = .medium
                }
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 22
                sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            }
        } else if let pop = menu.popoverPresentationController {
            menu.modalPresentationStyle = .popover
            pop.barButtonItem = barButtonItem
            pop.permittedArrowDirections = [.up]
            pop.delegate = PassthroughPopoverDelegate.shared
            pop.backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
        }
        host.present(menu, animated: true)
    }
}

private final class PassthroughPopoverDelegate: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = PassthroughPopoverDelegate()

    func adaptivePresentationStyle(
        for controller: UIPresentationController,
        traitCollection: UITraitCollection
    ) -> UIModalPresentationStyle {
        .none
    }
}
