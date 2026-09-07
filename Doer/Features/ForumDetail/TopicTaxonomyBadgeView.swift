import UIKit

final class TopicTaxonomyBadgeView: UIControl {
    enum Variant: Equatable {
        case compact
        case regular

        var fontSize: CGFloat {
            switch self {
            case .compact: return 10
            case .regular: return 13
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .compact: return 9
            case .regular: return 13
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .compact: return 6
            case .regular: return 9
            }
        }

        var contentInsets: NSDirectionalEdgeInsets {
            switch self {
            case .compact:
                return NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
            case .regular:
                return NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 12)
            }
        }

        var maximumTextWidth: CGFloat {
            switch self {
            case .compact: return 96
            case .regular: return 180
            }
        }
    }

    private let contentStack = UIStackView()

    init(
        category presentation: TopicCategoryBadgePresentation,
        baseURL: String,
        variant: Variant,
        isInteractive: Bool = false
    ) {
        super.init(frame: .zero)
        let fallbackColor = TopicTaxonomyColor.resolve(hex: presentation.colorHex) ?? .systemGray
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
                color: color,
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
            color: iconColor,
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
        backgroundColor = color.withAlphaComponent(isCategory ? 0.08 : 0.10)
        layer.cornerRadius = variant.cornerRadius
        layer.cornerCurve = .continuous
        layer.borderColor = color.withAlphaComponent(isCategory ? 0.20 : 0.18).cgColor
        layer.borderWidth = 1

        contentStack.axis = .horizontal
        contentStack.alignment = .center
        contentStack.spacing = 4
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
        label.font = Self.interfaceFont(ofSize: variant.fontSize, weight: .medium)
        label.textColor = isCategory && variant == .compact && AppSettings.shared.themeStyle == .systemDefault
            ? .label
            : color
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

    private static func interfaceFont(ofSize pointSize: CGFloat, weight: UIFont.Weight) -> UIFont {
        let settings = AppSettings.shared
        let adjustedPointSize = settings.effectiveInterfacePointSize(for: pointSize)
        return settings.appInterfaceFont(matching: .systemFont(ofSize: adjustedPointSize, weight: weight))
    }

}
