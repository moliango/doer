import UIKit

/// Top notice shown when the clipboard holds a link:
/// `[link] 打开复制的链接?        粘贴   ✕`
///
/// Checking the clipboard happens without reading it, so this banner can appear on
/// launch without the system paste alert. Only tapping 粘贴 reads the pasteboard,
/// which is when iOS raises its own "Allow Paste" prompt.
final class ClipboardLinkBannerView: UIView {
    var onPaste: (() -> Void)?
    var onClose: (() -> Void)?

    private let backgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let pasteButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 14
        layer.shadowOffset = CGSize(width: 0, height: 6)

        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.clipsToBounds = true
        backgroundView.layer.cornerRadius = 16
        backgroundView.layer.cornerCurve = .continuous
        addSubview(backgroundView)

        let content = backgroundView.contentView

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.image = UIImage(
            systemName: "link",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = String(localized: "clipboard.link.banner.title", defaultValue: "打开复制的链接？")
        titleLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 15,
            weight: .medium,
            fallback: .systemFont(ofSize: 15, weight: .medium)
        )
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.85
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        pasteButton.setTitle(String(localized: "clipboard.link.banner.paste", defaultValue: "粘贴"), for: .normal)
        pasteButton.titleLabel?.font = AppSettings.shared.appInterfaceFont(
            ofSize: 15,
            weight: .semibold,
            fallback: .systemFont(ofSize: 15, weight: .semibold)
        )
        pasteButton.setContentHuggingPriority(.required, for: .horizontal)
        pasteButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        pasteButton.addAction(UIAction { [weak self] _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self?.onPaste?()
        }, for: .touchUpInside)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(
            UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            ),
            for: .normal
        )
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = String(localized: "common.close")
        closeButton.addAction(UIAction { [weak self] _ in
            self?.onClose?()
        }, for: .touchUpInside)

        content.addSubview(iconView)
        content.addSubview(titleLabel)
        content.addSubview(pasteButton)
        content.addSubview(closeButton)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 52),

            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pasteButton.leadingAnchor, constant: -12),

            pasteButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            pasteButton.heightAnchor.constraint(equalToConstant: 44),
            pasteButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    func applyTheme() {
        let accent = AppSettings.shared.themeStyle.accentColor
        iconView.tintColor = accent
        pasteButton.setTitleColor(accent, for: .normal)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyTheme()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: backgroundView.layer.cornerRadius
        ).cgPath
    }

    func present(animated: Bool) {
        guard animated else {
            alpha = 1
            transform = .identity
            return
        }
        alpha = 0
        transform = CGAffineTransform(translationX: 0, y: -16)
        DoerMotion.animate(duration: DoerMotion.standard) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        let finish = {
            self.removeFromSuperview()
            completion?()
        }
        guard animated else {
            finish()
            return
        }
        DoerMotion.animate(
            duration: DoerMotion.quick,
            animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 0, y: -16)
            },
            completion: { _ in
                finish()
            }
        )
    }
}
