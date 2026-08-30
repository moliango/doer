import UIKit

// MARK: - Balance card (LDC / CDK)

struct MeBalanceRowModel {
    let service: LinuxDoExtensionService
    let title: String
    let valueText: String
    let dailyIncomeText: String?
    let isLoading: Bool
    let isConnected: Bool

    var displayValueText: String {
        if isLoading {
            return String(localized: "extensions.connecting", defaultValue: "连接中…")
        }
        return valueText
    }
}

final class MeBalanceCardView: UIView {
    var onSelect: ((LinuxDoExtensionService) -> Void)?

    private let cardView = MeCardSurfaceView()
    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.isUserInteractionEnabled = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = true
        addSubview(cardView)
        cardView.isUserInteractionEnabled = true
        cardView.clipsToBounds = true
        cardView.addSubview(stackView)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(rows: [MeBalanceRowModel]) {
        isHidden = rows.isEmpty
        let existing = stackView.arrangedSubviews.compactMap { $0 as? MeBalanceRowControl }
        if existing.map(\.service) == rows.map(\.service) {
            zip(existing, rows).forEach { control, row in
                bindSelection(control)
                control.apply(row)
            }
            return
        }
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                stackView.addArrangedSubview(makeDivider())
            }
            let control = existing.first(where: { $0.service == row.service }) ?? MeBalanceRowControl(service: row.service)
            bindSelection(control)
            control.apply(row)
            stackView.addArrangedSubview(control)
        }
    }

    private func bindSelection(_ control: MeBalanceRowControl) {
        control.onSelect = { [weak self, weak control] in
            guard let service = control?.service else { return }
            self?.onSelect?(service)
        }
    }

    private func makeDivider() -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.isUserInteractionEnabled = false
        let line = UIView()
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.28)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 62),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
        ])
        return wrap
    }
}

/// Full-row hit target for LDC / CDK. Decorative subviews must not own touches.
private final class MeBalanceRowControl: UIControl {
    private(set) var service: LinuxDoExtensionService
    var onSelect: (() -> Void)?

    private let pressBackground = UIView()
    private let contentView = UIView()
    private let iconBg = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let badge = UIView()
    private let badgeTrend = UIImageView()
    private let badgeLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        view.hidesWhenStopped = true
        view.color = .tertiaryLabel
        return view
    }()
    private let trailingStack = UIStackView()
    private var isConnecting = false
    private var isPressed = false

    init(service: LinuxDoExtensionService) {
        self.service = service
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(_ model: MeBalanceRowModel) {
        service = model.service
        isConnecting = model.isLoading
        isPressed = false
        accessibilityIdentifier = "me.balance.\(model.service.rawValue)"
        isAccessibilityElement = true
        accessibilityTraits = model.isLoading ? [.button, .updatesFrequently] : .button
        accessibilityLabel = model.title
        accessibilityValue = model.displayValueText
        isEnabled = true
        isUserInteractionEnabled = !model.isLoading

        let accent = model.service == .ldc ? UIColor.systemBlue : UIColor.systemPurple
        iconBg.backgroundColor = accent.withAlphaComponent(0.14)
        iconView.image = UIImage(systemName: model.service == .ldc ? "creditcard.fill" : "shippingbox.fill")
        iconView.tintColor = accent
        titleLabel.text = model.title
        valueLabel.text = model.displayValueText
        valueLabel.textColor = model.isLoading ? .secondaryLabel : .label
        badge.backgroundColor = accent.withAlphaComponent(0.12)
        badgeTrend.tintColor = accent
        badgeLabel.text = model.dailyIncomeText
        badge.isHidden = model.dailyIncomeText == nil || model.isLoading
        chevron.isHidden = model.isLoading
        if model.isLoading {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
        alpha = 1
        updatePressAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, isConnecting {
            spinner.startAnimating()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isEnabled, isUserInteractionEnabled, !isHidden, alpha > 0.01, self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard !isConnecting else { return }
        isPressed = true
        updatePressAppearance()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard !isConnecting, let touch = touches.first else { return }
        isPressed = point(inside: touch.location(in: self), with: event)
        updatePressAppearance()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let inside = touches.contains { point(inside: $0.location(in: self), with: event) }
        super.touchesEnded(touches, with: event)
        isPressed = false
        guard !isConnecting else { return }
        if inside {
            beginConnectingAppearance()
            onSelect?()
        } else {
            updatePressAppearance()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        isPressed = false
        if !isConnecting {
            updatePressAppearance()
        }
    }

    private func beginConnectingAppearance() {
        isConnecting = true
        isPressed = false
        isUserInteractionEnabled = false
        valueLabel.text = String(localized: "extensions.connecting", defaultValue: "连接中…")
        valueLabel.textColor = .secondaryLabel
        accessibilityValue = valueLabel.text
        badge.isHidden = true
        chevron.isHidden = true
        spinner.startAnimating()
        updatePressAppearance()
    }

    private func updatePressAppearance() {
        pressBackground.backgroundColor = .tertiarySystemFill
        pressBackground.alpha = (isConnecting || isPressed) ? 1 : 0
    }

    private func buildLayout() {
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.isUserInteractionEnabled = false

        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.layer.cornerRadius = 18
        iconBg.layer.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabel

        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        valueLabel.textColor = .label

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.layer.cornerRadius = 12
        badge.layer.cornerCurve = .continuous
        badgeTrend.translatesAutoresizingMaskIntoConstraints = false
        badgeTrend.image = UIImage(
            systemName: "chart.line.uptrend.xyaxis",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        )
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        badgeLabel.textColor = .label
        badge.addSubview(badgeTrend)
        badge.addSubview(badgeLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 8
        trailingStack.isUserInteractionEnabled = false
        trailingStack.addArrangedSubview(badge)
        trailingStack.addArrangedSubview(spinner)
        trailingStack.addArrangedSubview(chevron)

        pressBackground.translatesAutoresizingMaskIntoConstraints = false
        pressBackground.isUserInteractionEnabled = false
        pressBackground.alpha = 0

        addSubview(pressBackground)
        addSubview(contentView)
        contentView.addSubview(iconBg)
        iconBg.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(valueLabel)
        contentView.addSubview(trailingStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 68),
            pressBackground.topAnchor.constraint(equalTo: topAnchor),
            pressBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            pressBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            pressBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconBg.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            iconBg.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconBg.widthAnchor.constraint(equalToConstant: 36),
            iconBg.heightAnchor.constraint(equalToConstant: 36),
            iconView.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleLabel.leadingAnchor.constraint(equalTo: iconBg.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),

            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -8),

            trailingStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            trailingStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            badge.heightAnchor.constraint(equalToConstant: 24),
            badgeTrend.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 8),
            badgeTrend.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeTrend.trailingAnchor, constant: 3),
            badgeLabel.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -8),
            badgeLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),

            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])
    }
}

// MARK: - Quick actions grid

struct MeQuickActionItem {
    let title: String
    let symbolName: String
    let tintColor: UIColor
    let action: () -> Void
}

final class MeQuickActionsCardView: UIView {
    private let cardView = MeCardSurfaceView()
    private let stackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardView)
        cardView.addSubview(stackView)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            stackView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -14),
            stackView.heightAnchor.constraint(greaterThanOrEqualToConstant: 78),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [MeQuickActionItem]) {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        stackView.axis = .vertical
        stackView.spacing = 8
        let columns = min(4, max(items.count, 1))
        var index = 0
        while index < items.count {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .fill
            row.distribution = .fillEqually
            row.spacing = 4
            let slice = items[index..<min(index + columns, items.count)]
            for item in slice {
                row.addArrangedSubview(makeItemButton(item))
            }
            while row.arrangedSubviews.count < columns {
                let spacer = UIView()
                spacer.isUserInteractionEnabled = false
                row.addArrangedSubview(spacer)
            }
            stackView.addArrangedSubview(row)
            index += columns
        }
    }

    private func makeItemButton(_ item: MeQuickActionItem) -> UIControl {
        let control = UIControl()
        control.translatesAutoresizingMaskIntoConstraints = false
        control.addAction(UIAction { _ in item.action() }, for: .touchUpInside)

        let iconBg = UIView()
        iconBg.translatesAutoresizingMaskIntoConstraints = false
        iconBg.backgroundColor = item.tintColor.withAlphaComponent(0.14)
        iconBg.layer.cornerRadius = 14
        iconBg.layer.cornerCurve = .continuous
        iconBg.isUserInteractionEnabled = false

        let icon = UIImageView(image: UIImage(systemName: item.symbolName, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = item.tintColor
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = item.title
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .label
        title.textAlignment = .center
        title.numberOfLines = 1
        title.isUserInteractionEnabled = false

        control.addSubview(iconBg)
        iconBg.addSubview(icon)
        control.addSubview(title)

        NSLayoutConstraint.activate([
            iconBg.topAnchor.constraint(equalTo: control.topAnchor, constant: 2),
            iconBg.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            iconBg.widthAnchor.constraint(equalToConstant: 44),
            iconBg.heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: iconBg.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBg.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            title.topAnchor.constraint(equalTo: iconBg.bottomAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 2),
            title.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -2),
            title.bottomAnchor.constraint(lessThanOrEqualTo: control.bottomAnchor),
        ])
        return control
    }
}
