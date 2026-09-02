import UIKit

enum MeCustomizeEditorChrome {
    static var accentColor: UIColor { AppSettings.shared.themeStyle.accentColor }
    static var cardBackground: UIColor { AppSettings.shared.themeStyle.topicCardBackgroundColor }
    static var screenBackground: UIColor {
        AppSettings.shared.themeStyle.topicListBackgroundColor
    }

    static func makeCard() -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = cardBackground
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = accentColor.withAlphaComponent(0.12).cgColor
        return view
    }

    static func makeSectionStack(title: String, symbolName: String) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(
            DataManagementSectionHeaderView(title: title, symbolName: symbolName, tintColor: accentColor)
        )
        return stack
    }

    static func makeHeroCard(
        eyebrow: String,
        title: String,
        subtitle: String,
        preview: UIView
    ) -> UIView {
        let card = makeCard()
        let pill = makePill(text: eyebrow, color: accentColor)
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0

        let eyebrowRow = UIStackView(arrangedSubviews: [pill, UIView()])
        eyebrowRow.axis = .horizontal
        let stack = UIStackView(arrangedSubviews: [eyebrowRow, titleLabel, subtitleLabel, preview])
        stack.axis = .vertical
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(12, after: subtitleLabel)
        card.addSubview(stack)
        pin(stack, to: card)
        return card
    }

    static func makeChipScroller(_ chips: [UIView]) -> UIView {
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = chips.count > 4
        let stack = UIStackView(arrangedSubviews: chips)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 54),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        return scroll
    }

    static func makeChip(title: String, symbolName: String, tintColor: UIColor) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = tintColor.withAlphaComponent(0.12)
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous

        let icon = UIImageView(
            image: UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        )
        icon.tintColor = tintColor
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = tintColor
        label.lineBreakMode = .byTruncatingTail

        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 54),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 58),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
        ])
        return view
    }

    static func makeItemRow(
        title: String,
        subtitle: String,
        symbolName: String,
        tintColor: UIColor,
        accessory: UIView,
        dimmed: Bool = false
    ) -> UIView {
        let card = makeCard()
        card.alpha = dimmed ? 0.72 : 1

        let iconContainer = UIView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.backgroundColor = tintColor.withAlphaComponent(0.14)
        iconContainer.layer.cornerRadius = 13
        iconContainer.layer.cornerCurve = .continuous

        let icon = UIImageView(
            image: UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.tintColor = tintColor
        iconContainer.addSubview(icon)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = dimmed ? .secondaryLabel : .label

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 2

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [iconContainer, textStack, accessory])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 12)
        card.addSubview(row)
        pin(row, to: card)
        accessory.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 40),
            iconContainer.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
        ])
        return card
    }

    static func makeVisibleAccessory(
        canHide: Bool = true,
        onHide: @escaping () -> Void
    ) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 6
        stack.addArrangedSubview(makePill(text: String(localized: "me.customize.visible", defaultValue: "显示"), color: accentColor))
        stack.addArrangedSubview(makeDragHandle())
        stack.addArrangedSubview(makeActionButton(
            symbolName: "minus",
            enabled: canHide,
            color: .systemRed,
            accessibilityLabel: String(localized: "me.customize.hide", defaultValue: "隐藏"),
            action: onHide
        ))
        return stack
    }

    static func makeDragHandle() -> UIImageView {
        let view = UIImageView(
            image: UIImage(systemName: "line.3.horizontal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        view.tintColor = .tertiaryLabel
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "me.customize.drag", defaultValue: "拖动排序")
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 22),
            view.heightAnchor.constraint(equalToConstant: 22),
        ])
        return view
    }

    static func applyListStyle(to tableView: UITableView) {
        tableView.backgroundColor = screenBackground
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 76
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 52
        tableView.sectionHeaderTopPadding = 4
        tableView.dragInteractionEnabled = true
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
    }

    static func makeTableSectionHeader(title: String, symbolName: String) -> UIView {
        let header = DataManagementSectionHeaderView(title: title, symbolName: symbolName, tintColor: accentColor)
        let container = UIView()
        header.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            header.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    static func sizedHeader(_ header: UIView, width: CGFloat) -> UIView {
        let size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        header.frame = CGRect(origin: .zero, size: CGSize(width: width, height: size.height))
        return header
    }

    static func makeRestoreAccessory(action: @escaping () -> Void) -> UIView {
        makeActionButton(
            symbolName: "plus",
            enabled: true,
            color: accentColor,
            accessibilityLabel: String(localized: "me.customize.show", defaultValue: "显示"),
            action: action
        )
    }

    static func makeActionButton(
        symbolName: String,
        enabled: Bool,
        color: UIColor = .secondaryLabel,
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.tintColor = enabled ? color : .tertiaryLabel
        button.backgroundColor = (enabled ? color : UIColor.tertiaryLabel).withAlphaComponent(enabled ? 0.12 : 0.06)
        button.layer.cornerRadius = 14
        button.layer.cornerCurve = .continuous
        button.isEnabled = enabled
        button.accessibilityLabel = accessibilityLabel
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    static func makePill(text: String, color: UIColor) -> UILabel {
        let label = PaddingLabel()
        label.text = text
        label.font = .systemFont(ofSize: 12, weight: .bold)
        label.textColor = color
        label.backgroundColor = color.withAlphaComponent(0.11)
        label.layer.cornerRadius = 12
        label.layer.cornerCurve = .continuous
        label.clipsToBounds = true
        label.contentInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        return label
    }

    static func makeInfoCard(text: String) -> UIView {
        let card = makeCard()
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    static func pin(_ view: UIView, to container: UIView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

final class MeStatsLayoutOptionView: UIControl {
    let layout: MeStatsLayout
    private let card = MeCustomizeEditorChrome.makeCard()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let preview = MeStatsLayoutPreviewView()
    private let checkView = UIImageView()

    init(layout: MeStatsLayout) {
        self.layout = layout
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = layout.title
        accessibilityHint = layout.subtitle
        preview.layoutStyle = layout
        preview.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.text = layout.title
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textAlignment = .center

        subtitleLabel.text = layout.subtitle
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 2

        checkView.contentMode = .scaleAspectFit
        checkView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [preview, titleLabel, subtitleLabel, checkView])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 12, bottom: 14, trailing: 12)
        stack.isUserInteractionEnabled = false

        card.isUserInteractionEnabled = false
        addSubview(card)
        card.addSubview(stack)
        MeCustomizeEditorChrome.pin(card, to: self)
        MeCustomizeEditorChrome.pin(stack, to: card)
        NSLayoutConstraint.activate([
            preview.heightAnchor.constraint(equalToConstant: 44),
            preview.widthAnchor.constraint(equalToConstant: 88),
            checkView.widthAnchor.constraint(equalToConstant: 18),
            checkView.heightAnchor.constraint(equalToConstant: 18),
        ])
        addTarget(self, action: #selector(touchDown), for: .touchDown)
        addTarget(self, action: #selector(touchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(selected: Bool) {
        let accent = MeCustomizeEditorChrome.accentColor
        card.layer.borderWidth = selected ? 1.5 : 1
        card.layer.borderColor = (selected ? accent : UIColor.separator.withAlphaComponent(0.28)).cgColor
        card.backgroundColor = selected ? accent.withAlphaComponent(0.10) : MeCustomizeEditorChrome.cardBackground
        titleLabel.textColor = selected ? accent : .label
        checkView.image = UIImage(
            systemName: selected ? "checkmark.circle.fill" : "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        )
        checkView.tintColor = selected ? accent : .tertiaryLabel
        preview.tintColor = selected ? accent : .secondaryLabel
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    @objc private func touchDown() {
        alpha = 0.72
    }

    @objc private func touchUp() {
        alpha = 1
    }
}

private final class MeStatsLayoutPreviewView: UIView {
    var layoutStyle: MeStatsLayout = .grid {
        didSet { rebuild() }
    }

    private let stack = UIStackView()
    private let sampleColors: [UIColor] = [
        MeStatType.daysVisited.tintColor,
        MeStatType.postCount.tintColor,
        MeStatType.likesReceived.tintColor,
        MeStatType.topicCount.tintColor,
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.clipsToBounds = true
        switch layoutStyle {
        case .grid:
            stack.spacing = 3
            stack.distribution = .fillEqually
            for color in sampleColors {
                stack.addArrangedSubview(makeTile(color: color))
            }
        case .horizontal:
            stack.spacing = 4
            stack.distribution = .fill
            for (index, color) in sampleColors.enumerated() {
                let tile = makeTile(color: color)
                tile.widthAnchor.constraint(equalToConstant: index == sampleColors.count - 1 ? 10 : 22).isActive = true
                stack.addArrangedSubview(tile)
            }
        }
    }

    private func makeTile(color: UIColor) -> UIView {
        let tile = UIView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.backgroundColor = color.withAlphaComponent(0.18)
        tile.layer.cornerRadius = 6
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = 1
        tile.layer.borderColor = color.withAlphaComponent(0.35).cgColor
        let icon = UIView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.backgroundColor = color.withAlphaComponent(0.7)
        icon.layer.cornerRadius = 3
        tile.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor, constant: -3),
            icon.widthAnchor.constraint(equalToConstant: 6),
            icon.heightAnchor.constraint(equalToConstant: 6),
        ])
        return tile
    }
}


final class MeCustomizeHostCell: UITableViewCell {
    static let reuseIdentifier = "MeCustomizeHostCell"

    private var hostedView: UIView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hostedView?.removeFromSuperview()
        hostedView = nil
    }

    func display(_ view: UIView, insets: UIEdgeInsets = UIEdgeInsets(top: 6, left: 18, bottom: 6, right: 18)) {
        hostedView?.removeFromSuperview()
        hostedView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insets.bottom),
        ])
    }
}
