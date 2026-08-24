import UIKit

final class ReadingSettingsViewController: ObservableViewController {
    /// FluxDO-aligned reading groups: content look / interaction / threaded / topic card.
    private enum ToggleOption: CaseIterable {
        case readingComfort
        case defaultExpandRelatedLinks
        case showSuggestedTopics
        case composerInstantRender
        case showUserSignatures
        case hideScrollIndicators
        case bottomBarAutoHide
        case openExternalLinksInAppBrowser
        case contentImageCarousel
        case nestedReplyView
        case showTopicCardCategory
        case showTopicCardTags
        case showTopicCardCounts

        var title: String {
            switch self {
            case .readingComfort: return String(localized: "settings.reading.comfort")
            case .defaultExpandRelatedLinks: return String(localized: "settings.reading.expand_related_links")
            case .showSuggestedTopics: return String(localized: "settings.reading.suggested_topics", defaultValue: "相关话题推荐")
            case .composerInstantRender: return String(localized: "settings.reading.instant_render", defaultValue: "编辑器即时渲染")
            case .showUserSignatures: return String(localized: "settings.reading.signatures", defaultValue: "显示用户签名")
            case .hideScrollIndicators: return String(localized: "settings.reading.hide_scroll_indicators")
            case .bottomBarAutoHide: return String(localized: "settings.reading.collapse_navigation")
            case .openExternalLinksInAppBrowser: return String(localized: "settings.reading.in_app_browser")
            case .contentImageCarousel: return String(localized: "settings.reading.image_carousel", defaultValue: "正文图片轮播")
            case .nestedReplyView: return String(localized: "settings.reading.nested", defaultValue: "树形回复视图")
            case .showTopicCardCategory: return String(localized: "settings.card.category", defaultValue: "卡片显示分类")
            case .showTopicCardTags: return String(localized: "settings.card.tags", defaultValue: "卡片显示标签")
            case .showTopicCardCounts: return String(localized: "settings.card.counts", defaultValue: "卡片显示计数")
            }
        }

        var subtitle: String {
            switch self {
            case .readingComfort: return String(localized: "settings.reading.comfort.subtitle")
            case .defaultExpandRelatedLinks: return String(localized: "settings.reading.expand_related_links.subtitle")
            case .showSuggestedTopics: return String(localized: "settings.reading.suggested_topics.subtitle", defaultValue: "读到话题底部时展示相关话题")
            case .composerInstantRender: return String(localized: "settings.reading.instant_render.subtitle", defaultValue: "输入时即时显示 Markdown 样式（默认关闭）")
            case .showUserSignatures: return String(localized: "settings.reading.signatures.subtitle", defaultValue: "在帖子下方显示签名")
            case .hideScrollIndicators: return String(localized: "settings.reading.hide_scroll_indicators.subtitle")
            case .bottomBarAutoHide: return String(localized: "settings.reading.collapse_navigation.subtitle")
            case .openExternalLinksInAppBrowser: return String(localized: "settings.reading.in_app_browser.subtitle")
            case .contentImageCarousel: return String(localized: "settings.reading.image_carousel.subtitle", defaultValue: "新：FluxDo 式轮播；关：沿用原来的单图堆叠")
            case .nestedReplyView: return String(localized: "settings.reading.nested.subtitle", defaultValue: "详情页按回复关系缩进展示")
            case .showTopicCardCategory: return String(localized: "settings.card.category.subtitle", defaultValue: "列表卡片是否显示分类")
            case .showTopicCardTags: return String(localized: "settings.card.tags.subtitle", defaultValue: "列表卡片是否显示标签")
            case .showTopicCardCounts: return String(localized: "settings.card.counts.subtitle", defaultValue: "列表卡片是否显示回复数")
            }
        }

        var symbolName: String {
            switch self {
            case .readingComfort: return "wand.and.stars"
            case .defaultExpandRelatedLinks: return "link"
            case .showSuggestedTopics: return "text.bubble"
            case .composerInstantRender: return "textformat"
            case .showUserSignatures: return "signature"
            case .hideScrollIndicators: return "scroll"
            case .bottomBarAutoHide: return "arrow.up.and.down"
            case .openExternalLinksInAppBrowser: return "rectangle.portrait.and.arrow.right"
            case .contentImageCarousel: return "rectangle.stack"
            case .nestedReplyView: return "list.bullet.indent"
            case .showTopicCardCategory: return "folder"
            case .showTopicCardTags: return "tag"
            case .showTopicCardCounts: return "number"
            }
        }
    }

    private let settings = AppSettings.shared
    private let fontSizeCard = FontScaleCardView()
    private var toggleRows: [ToggleOption: ReadingToggleRowView] = [:]
    private var sectionHeaderViews: [DataManagementSectionHeaderView] = []
    private let progressGesturesEnabledRow = ReadingToggleRowView()
    private let swipeLeftRow = DataManagementActionRowView()
    private let swipeRightRow = DataManagementActionRowView()
    private let swipeUpRow = DataManagementActionRowView()
    private let menuActionsRow = DataManagementActionRowView()

    private let scrollView: UIScrollView = {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        return scroll
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 24
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 20, leading: 18, bottom: 28, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        observe(settings)
        title = String(localized: "settings.reading_design")
        configureRootView()
        wireActions()
        rebuildContent()
        refreshDataViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableSettingsInteractiveBackSwipe()
        refreshDataViews()
    }

    override func updateUI() {
        title = String(localized: "settings.reading_design")
        rebuildContent()
        refreshDataViews()
    }

    private func configureRootView() {
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func wireActions() {
        fontSizeCard.onValueChanged = { [weak self] value in
            guard let self else { return }
            if settings.contentFontSize != .standard {
                settings.contentFontSize = .standard
            }
            settings.contentFontScalePercent = value
            refreshDataViews()
        }
        fontSizeCard.onReset = { [weak self] in
            guard let self else { return }
            settings.contentFontSize = .standard
            settings.contentFontScalePercent = AppSettings.defaultFontScalePercent
            refreshDataViews()
        }
        progressGesturesEnabledRow.onValueChanged = { [weak self] isOn in
            self?.settings.progressGesturesEnabled = isOn
            self?.refreshDataViews()
        }
        swipeLeftRow.addTarget(self, action: #selector(pickSwipeLeft), for: .touchUpInside)
        swipeRightRow.addTarget(self, action: #selector(pickSwipeRight), for: .touchUpInside)
        swipeUpRow.addTarget(self, action: #selector(pickSwipeUp), for: .touchUpInside)
        menuActionsRow.addTarget(self, action: #selector(openMenuActionsEditor), for: .touchUpInside)
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        toggleRows.removeAll()
        sectionHeaderViews.removeAll()

        // Appearance-style clean sections: no hero/stats panel.
        let readingBody = UIStackView()
        readingBody.axis = .vertical
        readingBody.spacing = 12
        readingBody.addArrangedSubview(fontSizeCard)
        readingBody.addArrangedSubview(makeToggleRow(for: .readingComfort))
        readingBody.addArrangedSubview(makeToggleRow(for: .defaultExpandRelatedLinks))
        readingBody.addArrangedSubview(makeToggleRow(for: .showSuggestedTopics))
        readingBody.addArrangedSubview(makeToggleRow(for: .composerInstantRender))
        readingBody.addArrangedSubview(makeToggleRow(for: .showUserSignatures))
        readingBody.addArrangedSubview(makeToggleRow(for: .hideScrollIndicators))
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.reading.section.reading"),
            symbolName: "book.pages",
            body: readingBody
        ))

        let basicBody = UIStackView()
        basicBody.axis = .vertical
        basicBody.spacing = 12
        basicBody.addArrangedSubview(makeToggleRow(for: .bottomBarAutoHide))
        basicBody.addArrangedSubview(makeToggleRow(for: .openExternalLinksInAppBrowser))
        basicBody.addArrangedSubview(makeToggleRow(for: .contentImageCarousel))
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.reading.section.basic"),
            symbolName: "hand.tap",
            body: basicBody
        ))

        // FluxDO progress-bar gestures
        let gestureBody = UIStackView()
        gestureBody.axis = .vertical
        gestureBody.spacing = 12
        gestureBody.addArrangedSubview(progressGesturesEnabledRow)
        gestureBody.addArrangedSubview(swipeLeftRow)
        gestureBody.addArrangedSubview(swipeRightRow)
        gestureBody.addArrangedSubview(swipeUpRow)
        gestureBody.addArrangedSubview(menuActionsRow)
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.reading.section.progress_gesture", defaultValue: "进度条手势"),
            symbolName: "hand.draw",
            body: gestureBody
        ))

        let threadedBody = UIStackView()
        threadedBody.axis = .vertical
        threadedBody.spacing = 12
        threadedBody.addArrangedSubview(makeToggleRow(for: .nestedReplyView))
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.reading.section.threaded", defaultValue: "树形回复"),
            symbolName: "list.bullet.indent",
            body: threadedBody
        ))

        let cardBody = UIStackView()
        cardBody.axis = .vertical
        cardBody.spacing = 12
        cardBody.addArrangedSubview(makeToggleRow(for: .showTopicCardCategory))
        cardBody.addArrangedSubview(makeToggleRow(for: .showTopicCardTags))
        cardBody.addArrangedSubview(makeToggleRow(for: .showTopicCardCounts))
        contentStack.addArrangedSubview(verticalSection(
            title: String(localized: "settings.reading.section.topic_card", defaultValue: "话题卡片"),
            symbolName: "rectangle.on.rectangle",
            body: cardBody
        ))
    }

    private func verticalSection(title: String, symbolName: String, body: UIView) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        let header = DataManagementSectionHeaderView(
            title: title,
            symbolName: symbolName,
            tintColor: settings.themeStyle.accentColor
        )
        sectionHeaderViews.append(header)
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(body)
        return stack
    }

    private func makeToggleRow(for option: ToggleOption) -> ReadingToggleRowView {
        let row = ReadingToggleRowView()
        row.onValueChanged = { [weak self] isOn in
            self?.setToggle(option, isOn: isOn)
        }
        toggleRows[option] = row
        return row
    }

    private func refreshDataViews() {
        view.backgroundColor = DataManagementPalette.screenBackground
        view.tintColor = settings.themeStyle.accentColor
        let cardBackground = settings.themeStyle.topicCardBackgroundColor
        let accentColor = settings.themeStyle.accentColor
        sectionHeaderViews.forEach { $0.setTintColor(accentColor) }

        fontSizeCard.configure(
            title: String(localized: "settings.content_font_size"),
            resetTitle: String(localized: "settings.reading.reset"),
            sliderValue: settings.contentFontScalePercent,
            minimumValue: AppSettings.minimumFontScalePercent,
            maximumValue: AppSettings.maximumFontScalePercent,
            defaultValue: AppSettings.defaultFontScalePercent,
            accentColor: accentColor,
            backgroundColor: cardBackground
        )

        for option in ToggleOption.allCases {
            toggleRows[option]?.configure(
                title: option.title,
                subtitle: option.subtitle,
                symbolName: option.symbolName,
                isOn: isToggleOn(option),
                accentColor: accentColor,
                backgroundColor: cardBackground
            )
        }

        let gesturesOn = settings.progressGesturesEnabled
        progressGesturesEnabledRow.configure(
            title: String(localized: "progress_gesture.enable", defaultValue: "启用进度条手势"),
            subtitle: String(
                localized: "progress_gesture.enable.subtitle",
                defaultValue: "在话题进度条上使用左滑 / 右滑 / 上滑与长按菜单"
            ),
            symbolName: "hand.draw",
            isOn: gesturesOn,
            accentColor: accentColor,
            backgroundColor: cardBackground
        )
        swipeLeftRow.configure(
            title: String(localized: "progress_gesture.swipe_left", defaultValue: "左滑"),
            subtitle: settings.progressGestureSwipeLeft.title,
            symbolName: "arrow.left",
            tintColor: gesturesOn ? accentColor : .tertiaryLabel,
            backgroundColor: cardBackground
        )
        swipeRightRow.configure(
            title: String(localized: "progress_gesture.swipe_right", defaultValue: "右滑"),
            subtitle: settings.progressGestureSwipeRight.title,
            symbolName: "arrow.right",
            tintColor: gesturesOn ? accentColor : .tertiaryLabel,
            backgroundColor: cardBackground
        )
        swipeUpRow.configure(
            title: String(localized: "progress_gesture.swipe_up", defaultValue: "上滑"),
            subtitle: settings.progressGestureSwipeUp.title,
            symbolName: "arrow.up",
            tintColor: gesturesOn ? accentColor : .tertiaryLabel,
            backgroundColor: cardBackground
        )
        let menu = settings.progressGestureMenuActions
        let menuSummary = menu.isEmpty
            ? String(localized: "progress_gesture.menu.empty", defaultValue: "未配置")
            : "\(menu.count)/\(ProgressGestureAction.menuMaxCount) · " + menu.map(\.title).joined(separator: " · ")
        menuActionsRow.configure(
            title: String(localized: "progress_gesture.long_press_menu", defaultValue: "长按菜单"),
            subtitle: menuSummary,
            symbolName: "circle.grid.cross",
            tintColor: gesturesOn ? accentColor : .tertiaryLabel,
            backgroundColor: cardBackground
        )
        swipeLeftRow.isEnabled = gesturesOn
        swipeRightRow.isEnabled = gesturesOn
        swipeUpRow.isEnabled = gesturesOn
        menuActionsRow.isEnabled = gesturesOn
        swipeLeftRow.alpha = gesturesOn ? 1 : 0.55
        swipeRightRow.alpha = gesturesOn ? 1 : 0.55
        swipeUpRow.alpha = gesturesOn ? 1 : 0.55
        menuActionsRow.alpha = gesturesOn ? 1 : 0.55
    }

    @objc private func pickSwipeLeft() {
        pickProgressAction(current: settings.progressGestureSwipeLeft) { [weak self] action in
            self?.settings.progressGestureSwipeLeft = action
            self?.refreshDataViews()
        }
    }

    @objc private func pickSwipeRight() {
        pickProgressAction(current: settings.progressGestureSwipeRight) { [weak self] action in
            self?.settings.progressGestureSwipeRight = action
            self?.refreshDataViews()
        }
    }

    @objc private func pickSwipeUp() {
        pickProgressAction(current: settings.progressGestureSwipeUp) { [weak self] action in
            self?.settings.progressGestureSwipeUp = action
            self?.refreshDataViews()
        }
    }

    @objc private func openMenuActionsEditor() {
        guard settings.progressGesturesEnabled else { return }
        let editor = ProgressGestureMenuSettingsViewController()
        navigationController?.pushViewController(editor, animated: true)
    }

    private func pickProgressAction(
        current: ProgressGestureAction,
        onPicked: @escaping (ProgressGestureAction) -> Void
    ) {
        guard settings.progressGesturesEnabled else { return }
        let sheet = UIAlertController(
            title: String(localized: "progress_gesture.pick_action", defaultValue: "选择手势动作"),
            message: nil,
            preferredStyle: .actionSheet
        )
        for action in ProgressGestureAction.allCases {
            let title = action == current ? "✓ \(action.title)" : action.title
            sheet.addAction(UIAlertAction(title: title, style: .default) { _ in
                onPicked(action)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    private func isToggleOn(_ option: ToggleOption) -> Bool {
        switch option {
        case .readingComfort:
            return settings.readingComfortMode
        case .defaultExpandRelatedLinks:
            return settings.defaultExpandRelatedLinks
        case .showSuggestedTopics:
            return settings.showSuggestedTopics
        case .composerInstantRender:
            return settings.composerInstantRender
        case .showUserSignatures:
            return settings.showUserSignatures
        case .hideScrollIndicators:
            return settings.hideScrollIndicators
        case .bottomBarAutoHide:
            return settings.bottomBarAutoHideEnabled
        case .openExternalLinksInAppBrowser:
            return settings.openExternalLinksInAppBrowser
        case .contentImageCarousel:
            return settings.contentImageCarouselEnabled
        case .nestedReplyView:
            return settings.nestedReplyViewEnabled
        case .showTopicCardTags:
            return settings.showTopicCardTags
        case .showTopicCardCategory:
            return settings.showTopicCardCategory
        case .showTopicCardCounts:
            return settings.showTopicCardCounts
        }
    }

    private func setToggle(_ option: ToggleOption, isOn: Bool) {
        switch option {
        case .readingComfort:
            settings.readingComfortMode = isOn
        case .defaultExpandRelatedLinks:
            settings.defaultExpandRelatedLinks = isOn
        case .showSuggestedTopics:
            settings.showSuggestedTopics = isOn
        case .composerInstantRender:
            settings.composerInstantRender = isOn
        case .showUserSignatures:
            settings.showUserSignatures = isOn
        case .hideScrollIndicators:
            settings.hideScrollIndicators = isOn
        case .bottomBarAutoHide:
            settings.bottomBarAutoHideEnabled = isOn
        case .openExternalLinksInAppBrowser:
            settings.openExternalLinksInAppBrowser = isOn
        case .contentImageCarousel:
            settings.contentImageCarouselEnabled = isOn
        case .nestedReplyView:
            settings.nestedReplyViewEnabled = isOn
        case .showTopicCardTags:
            settings.showTopicCardTags = isOn
        case .showTopicCardCategory:
            settings.showTopicCardCategory = isOn
        case .showTopicCardCounts:
            settings.showTopicCardCounts = isOn
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        refreshDataViews()
    }

}

final class FontScaleCardView: UIView {
    var onValueChanged: ((Int) -> Void)?
    var onReset: (() -> Void)?

    private let iconContainer = UIView()
    private let iconLabel = UILabel()
    private let titleLabel = UILabel()
    private let percentLabel = UILabel()
    private let resetButton = UIButton(type: .system)
    private let decreaseButton = UIButton(type: .system)
    private let increaseButton = UIButton(type: .system)
    private let slider = UISlider()
    private var currentValue = AppSettings.defaultFontScalePercent
    private var defaultValue = AppSettings.defaultFontScalePercent
    private var minimumValue = AppSettings.minimumFontScalePercent
    private var maximumValue = AppSettings.maximumFontScalePercent
    private var stepValue = AppSettings.fontScaleStepPercent
    private var accentColor = UIColor.systemBlue

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DataManagementPalette.borderColor.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 8)
        // 性能优化：预计算阴影路径
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 15
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.isUserInteractionEnabled = false

        iconLabel.text = "Tt"
        iconLabel.font = .systemFont(ofSize: 23, weight: .black)
        iconLabel.textAlignment = .center
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        iconLabel.isUserInteractionEnabled = false
        iconContainer.addSubview(iconLabel)

        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.isUserInteractionEnabled = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        percentLabel.textColor = .secondaryLabel
        percentLabel.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, percentLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.isUserInteractionEnabled = false

        resetButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        resetButton.addAction(UIAction { [weak self] _ in
            self?.onReset?()
        }, for: .touchUpInside)

        let topRow = UIStackView(arrangedSubviews: [iconContainer, textStack, resetButton])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 14
        topRow.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = Float(AppSettings.minimumFontScalePercent)
        slider.maximumValue = Float(AppSettings.maximumFontScalePercent)
        slider.isContinuous = true
        slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false

        configureStepButton(decreaseButton, title: "-")
        configureStepButton(increaseButton, title: "+")
        decreaseButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            adjustValue(by: -stepValue)
        }, for: .touchUpInside)
        increaseButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            adjustValue(by: stepValue)
        }, for: .touchUpInside)

        let sliderRow = UIStackView(arrangedSubviews: [decreaseButton, slider, increaseButton])
        sliderRow.axis = .horizontal
        sliderRow.alignment = .center
        sliderRow.spacing = 10
        sliderRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [topRow, sliderRow])
        stack.axis = .vertical
        stack.spacing = 24
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 20, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),
            iconLabel.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconLabel.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            decreaseButton.widthAnchor.constraint(equalToConstant: 44),
            decreaseButton.heightAnchor.constraint(equalToConstant: 44),
            increaseButton.widthAnchor.constraint(equalToConstant: 44),
            increaseButton.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureStepButton(_ button: UIButton, title: String) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22, weight: .bold)
        button.layer.cornerRadius = 14
        button.layer.cornerCurve = .continuous
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityTraits.insert(.button)
    }

    func configure(
        title: String,
        resetTitle: String,
        sliderValue: Int,
        minimumValue: Int,
        maximumValue: Int,
        defaultValue: Int,
        stepValue: Int = AppSettings.fontScaleStepPercent,
        accentColor: UIColor,
        backgroundColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        self.defaultValue = defaultValue
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.stepValue = max(stepValue, 1)
        self.accentColor = accentColor
        currentValue = min(max(sliderValue, minimumValue), maximumValue)
        layer.shadowColor = accentColor.cgColor
        layer.borderColor = accentColor.withAlphaComponent(0.14).cgColor
        iconContainer.backgroundColor = accentColor.withAlphaComponent(0.14)
        iconLabel.textColor = accentColor
        titleLabel.text = title
        percentLabel.text = "\(currentValue)%"
        resetButton.setTitle(resetTitle, for: .normal)
        resetButton.setTitleColor(currentValue == defaultValue ? .tertiaryLabel : accentColor, for: .normal)
        resetButton.isEnabled = currentValue != defaultValue
        slider.minimumValue = Float(minimumValue)
        slider.maximumValue = Float(maximumValue)
        slider.minimumTrackTintColor = accentColor
        slider.maximumTrackTintColor = UIColor.tertiaryLabel.withAlphaComponent(0.35)
        slider.thumbTintColor = accentColor
        slider.setValue(Float(currentValue), animated: false)
        applyStepButtonStyle()
        accessibilityLabel = "\(title)，\(currentValue)%"
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        let value = snappedValue(Int(round(sender.value)))
        setCurrentValue(value, animated: false, notify: true)
    }

    private func adjustValue(by delta: Int) {
        setCurrentValue(currentValue + delta, animated: true, notify: true)
    }

    private func setCurrentValue(_ rawValue: Int, animated: Bool, notify: Bool) {
        let value = snappedValue(rawValue)
        slider.setValue(Float(value), animated: animated)
        guard value != currentValue else {
            applyStepButtonStyle()
            return
        }
        currentValue = value
        percentLabel.text = "\(value)%"
        resetButton.setTitleColor(value == defaultValue ? .tertiaryLabel : accentColor, for: .normal)
        resetButton.isEnabled = value != defaultValue
        applyStepButtonStyle()
        UISelectionFeedbackGenerator().selectionChanged()
        if notify {
            onValueChanged?(value)
        }
    }

    private func snappedValue(_ rawValue: Int) -> Int {
        let clamped = min(max(rawValue, minimumValue), maximumValue)
        let offset = clamped - minimumValue
        let snappedOffset = Int((Double(offset) / Double(stepValue)).rounded()) * stepValue
        return min(max(minimumValue + snappedOffset, minimumValue), maximumValue)
    }

    private func applyStepButtonStyle() {
        decreaseButton.isEnabled = currentValue > minimumValue
        increaseButton.isEnabled = currentValue < maximumValue
        for button in [decreaseButton, increaseButton] {
            button.backgroundColor = accentColor.withAlphaComponent(button.isEnabled ? 0.12 : 0.06)
            button.setTitleColor(button.isEnabled ? accentColor : .tertiaryLabel, for: .normal)
        }
    }
}

final class ReadingToggleRowView: UIControl {
    var onValueChanged: ((Bool) -> Void)?

    private let iconContainer = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let toggle = UISwitch()

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.14, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.99, y: 0.99) : .identity
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = DataManagementPalette.borderColor.cgColor
        layer.shadowOpacity = 0.07
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 5)
        addTarget(self, action: #selector(rowTapped), for: .touchUpInside)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.layer.cornerRadius = 13
        iconContainer.layer.cornerCurve = .continuous
        iconContainer.isUserInteractionEnabled = false

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isUserInteractionEnabled = false
        iconContainer.addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.isUserInteractionEnabled = false

        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2
        subtitleLabel.isUserInteractionEnabled = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.isUserInteractionEnabled = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)

        addSubview(iconContainer)
        addSubview(textStack)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -14),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        accessibilityTraits = [.button]
    }

    func configure(
        title: String,
        subtitle: String,
        symbolName: String,
        isOn: Bool,
        accentColor: UIColor,
        backgroundColor: UIColor
    ) {
        self.backgroundColor = backgroundColor
        layer.shadowColor = accentColor.cgColor
        layer.borderColor = accentColor.withAlphaComponent(0.14).cgColor
        iconContainer.backgroundColor = accentColor.withAlphaComponent(0.14)
        iconView.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        iconView.tintColor = accentColor
        titleLabel.text = title
        subtitleLabel.text = subtitle
        toggle.onTintColor = accentColor
        toggle.setOn(isOn, animated: false)
        accessibilityLabel = "\(title)，\(subtitle)"
        accessibilityValue = isOn ? String(localized: "common.on") : String(localized: "common.off")
    }

    @objc private func rowTapped() {
        toggle.setOn(!toggle.isOn, animated: true)
        onValueChanged?(toggle.isOn)
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        onValueChanged?(sender.isOn)
    }
}
