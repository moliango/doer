import UIKit

final class TopicTaxonomyBadgeView: UIControl {
    enum Variant: Equatable {
        case compact
        case regular

        var fontSize: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 12.5
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .compact: return 9
            case .regular: return 12
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .compact: return 6
            // Regular chips are pills; the radius is derived from the laid-out height.
            case .regular: return 999
            }
        }

        var isPill: Bool { self == .regular }

        var contentInsets: NSDirectionalEdgeInsets {
            switch self {
            case .compact:
                return NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
            case .regular:
                return NSDirectionalEdgeInsets(top: 6, leading: 11, bottom: 6, trailing: 12)
            }
        }

        var contentSpacing: CGFloat {
            switch self {
            case .compact: return 4
            case .regular: return 5
            }
        }

        var maximumTextWidth: CGFloat {
            switch self {
            case .compact: return 96
            case .regular: return 190
            }
        }

        /// Regular chips lead with a readable tint over a light color wash.
        var fillAlpha: CGFloat {
            switch self {
            case .compact: return 0.10
            case .regular: return 0.13
            }
        }

        var borderAlpha: CGFloat {
            switch self {
            case .compact: return 0.18
            case .regular: return 0.22
            }
        }
    }

    private let contentStack = UIStackView()
    private var usesPillCorners = false

    init(
        category presentation: TopicCategoryBadgePresentation,
        baseURL: String,
        variant: Variant,
        isInteractive: Bool = false
    ) {
        super.init(frame: .zero)
        // Categories without a server hue still get a stable, fresh tint (e.g. 运营反馈).
        let fallbackColor = TopicTaxonomyColor.resolve(hex: presentation.colorHex)
            ?? Self.derivedTaxonomyColor(for: presentation.name)
        let color = TopicTagVisualStyle.categoryColor(
            for: presentation.name,
            fallback: fallbackColor
        )
        setup(
            text: presentation.name,
            color: color,
            variant: variant,
            isCategory: true,
            iconView: makeCategoryIconView(
                source: presentation.iconSource,
                color: Self.readableLabelColor(color),
                baseURL: baseURL,
                variant: variant
            ),
            isInteractive: isInteractive
        )
    }

    init(
        tag: String,
        color: UIColor,
        variant: Variant,
        isInteractive: Bool = false
    ) {
        super.init(frame: .zero)
        let tagPresentation = TopicTagIconCatalog.presentation(for: tag)
        let iconColor = tagPresentation
            .flatMap { TopicTaxonomyColor.resolve(hex: $0.colorHex) }
            ?? color
        let iconView = makeFontAwesomeIcon(
            name: tagPresentation?.iconName ?? "tag",
            color: Self.readableLabelColor(iconColor),
            size: variant.iconSize
        )
        setup(
            text: tag,
            color: color,
            variant: variant,
            isCategory: false,
            iconView: iconView,
            isInteractive: isInteractive
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        contentStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if usesPillCorners {
            layer.cornerRadius = bounds.height / 2
        }
    }

    private func setup(
        text: String,
        color: UIColor,
        variant: Variant,
        isCategory: Bool,
        iconView: UIView?,
        isInteractive: Bool
    ) {
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = isInteractive
        accessibilityLabel = text
        accessibilityTraits = isInteractive ? .button : .staticText
        backgroundColor = color.withAlphaComponent(
            isCategory ? variant.fillAlpha * 0.85 : variant.fillAlpha
        )
        layer.cornerRadius = variant.cornerRadius
        usesPillCorners = variant.isPill
        layer.cornerCurve = .continuous
        layer.borderColor = color.withAlphaComponent(variant.borderAlpha).cgColor
        layer.borderWidth = 1

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = variant.contentSpacing
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.directionalLayoutMargins = variant.contentInsets
        contentStack.isUserInteractionEnabled = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        if let iconView {
            contentStack.addArrangedSubview(iconView)
        }

        let label = UILabel()
        label.text = text
        label.font = variant == .regular
            ? TopicDetailTypography.chromeFont(.taxonomyChip, weight: .medium)
            : Self.interfaceFont(ofSize: variant.fontSize, weight: .medium)
        label.textColor = isCategory && variant == .compact && AppSettings.shared.themeStyle == .systemDefault
            ? .label
            : Self.readableLabelColor(color)
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: variant.maximumTextWidth).isActive = true
        contentStack.addArrangedSubview(label)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeCategoryIconView(
        source: TopicCategoryBadgePresentation.IconSource,
        color: UIColor,
        baseURL: String,
        variant: Variant
    ) -> UIView {
        switch source {
        case .fontAwesome(let iconName):
            return makeFontAwesomeIcon(name: iconName, color: color, size: variant.iconSize)
        case .logo(let rawURL):
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.isUserInteractionEnabled = false
            imageView.translatesAutoresizingMaskIntoConstraints = false
            let placeholder = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: variant.iconSize * 0.68)
            )
            imageView.tintColor = color
            ForumImageLoader.setImage(
                on: imageView,
                url: Self.resolveURL(rawURL, baseURL: baseURL),
                placeholder: placeholder,
                cloudflareBaseURL: baseURL
            )
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: variant.iconSize + 2),
                imageView.heightAnchor.constraint(equalToConstant: variant.iconSize + 2),
            ])
            return imageView
        case .lock:
            return makeSymbolIcon(name: "lock.fill", color: color, size: variant.iconSize)
        case .dot:
            let dot = UIView()
            dot.backgroundColor = color
            dot.layer.cornerRadius = variant == .compact ? 3 : 4
            dot.isUserInteractionEnabled = false
            dot.translatesAutoresizingMaskIntoConstraints = false
            let diameter: CGFloat = variant == .compact ? 6 : 8
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: diameter),
                dot.heightAnchor.constraint(equalToConstant: diameter),
            ])
            return dot
        }
    }

    private func makeFontAwesomeIcon(name: String, color: UIColor, size: CGFloat) -> UILabel {
        let label = UILabel()
        label.text = DiscourseFontAwesomeIcon.glyph(for: name)
        label.font = UIFont(name: DiscourseFontAwesomeIcon.fontName, size: size)
            ?? .systemFont(ofSize: size, weight: .semibold)
        label.textColor = color
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: size + 2),
            label.heightAnchor.constraint(equalToConstant: size + 2),
        ])
        return label
    }

    private func makeSymbolIcon(name: String, color: UIColor, size: CGFloat) -> UIImageView {
        let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let imageView = UIImageView(image: UIImage(systemName: name, withConfiguration: configuration))
        imageView.tintColor = color
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: size + 1),
            imageView.heightAnchor.constraint(equalToConstant: size + 1),
        ])
        return imageView
    }

    private static func resolveURL(_ rawURL: String, baseURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            return absoluteURL
        }
        guard let base = URL(string: baseURL) else { return URL(string: trimmed) }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    /// Deterministic palette hue for taxonomies the server shipped without a color.
    private static func derivedTaxonomyColor(for name: String) -> UIColor {
        guard AppSettings.shared.themeTaxonomyColorsEnabled else { return .systemGray }
        return AppSettings.shared.themeStyle.topicTagColor(for: name)
    }

    /// Chip tint lifted toward the label color so 12.5pt text keeps ~4.5:1 on the wash.
    private static func readableLabelColor(_ color: UIColor) -> UIColor {
        UIColor { trait in
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard color.resolvedColor(with: trait).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return color
            }
            let isDark = trait.userInterfaceStyle == .dark
            let amount: CGFloat = isDark ? 0.22 : 0.16
            let target: CGFloat = isDark ? 1 : 0
            return UIColor(
                red: red + (target - red) * amount,
                green: green + (target - green) * amount,
                blue: blue + (target - blue) * amount,
                alpha: alpha
            )
        }
    }

    private static func interfaceFont(ofSize pointSize: CGFloat, weight: UIFont.Weight) -> UIFont {
        let settings = AppSettings.shared
        let adjustedPointSize = settings.effectiveInterfacePointSize(for: pointSize)
        return settings.appInterfaceFont(matching: .systemFont(ofSize: adjustedPointSize, weight: weight))
    }

}
