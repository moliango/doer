import UIKit

/// Floating min-length chip above the composer toolbar (FluxDo warden hint).
final class ComposerLengthHintView: UIView {
    private let label: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        layer.cornerRadius = 13
        layer.cornerCurve = .continuous
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ progress: ComposerLengthProgress) {
        isHidden = !progress.shouldShowHint
        guard progress.shouldShowHint else { return }
        if progress.meetsMinimum {
            label.text = String(
                format: String(localized: "composer.warden.progress %lld %lld", defaultValue: "%lld / %lld"),
                Int64(progress.current),
                Int64(progress.minimum)
            )
            label.textColor = ComposerTypography.accentColor
            backgroundColor = ComposerTypography.accentColor.withAlphaComponent(0.14)
        } else {
            label.text = String(
                format: String(localized: "composer.warden.remaining %lld", defaultValue: "还需 %lld 字"),
                Int64(progress.remaining)
            )
            label.textColor = .systemOrange
            backgroundColor = UIColor.systemOrange.withAlphaComponent(0.16)
        }
    }
}
