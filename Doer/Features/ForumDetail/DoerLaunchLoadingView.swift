import UIKit

final class DoerLaunchLoadingView: UIView {
    private let rootStackView = UIStackView()
    private let linuxLogoView = UIImageView()
    private let brandLabel = UILabel()
    private let valuesLabel = UILabel()
    private let loadingLabel = UILabel()
    private let dotsStackView = UIStackView()
    private let versionLabel = UILabel()
    private var dotViews: [UIView] = []
    private let loadingDotColor = UIColor { trait in
        if trait.userInterfaceStyle == .dark {
            return UIColor(red: 1.0, green: 0.78, blue: 0.18, alpha: 1)
        }
        return UIColor(red: 1.0, green: 0.68, blue: 0.02, alpha: 1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
        isOpaque = true
        isUserInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "launch.loading.accessibility")
        setupUI()
        applyThemeStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyThemeStyle() {
        backgroundColor = AppSettings.shared.themeStyle.topicListBackgroundColor
        brandLabel.textColor = .label
        brandLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 30,
            weight: .heavy,
            fallback: .systemFont(ofSize: 30, weight: .heavy)
        )
        valuesLabel.text = String(localized: "launch.loading.values")
        valuesLabel.textColor = .secondaryLabel
        valuesLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 15,
            weight: .semibold,
            fallback: .systemFont(ofSize: 15, weight: .semibold)
        )
        loadingLabel.text = String(localized: "launch.loading.subtitle")
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 12,
            weight: .medium,
            fallback: .systemFont(ofSize: 12, weight: .medium)
        )
        versionLabel.text = AppVersion.installed().marketingDisplayString
        versionLabel.textColor = .tertiaryLabel
        versionLabel.font = AppSettings.shared.appInterfaceFont(
            ofSize: 12,
            weight: .medium,
            fallback: .systemFont(ofSize: 12, weight: .medium)
        )
        dotViews.forEach { $0.backgroundColor = loadingDotColor }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stopLoadingDots()
            stopLogoBreathing()
            return
        }
        startLoadingDots()
        startLogoBreathing()
    }

    func startPresenting() {
        alpha = 1
        rootStackView.alpha = 1
        rootStackView.transform = .identity
        valuesLabel.alpha = 1
        valuesLabel.transform = .identity
        loadingLabel.alpha = 1
        dotsStackView.alpha = 1
        startLoadingDots()
        startLogoBreathing()
    }

    func dismiss(completion: @escaping () -> Void) {
        stopLogoBreathing()
        DoerMotion.animate(
            duration: DoerMotion.standard,
            timingParameters: DoerMotion.easeInOutCubic,
            animations: {
                self.alpha = 0
                self.rootStackView.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
            }
        ) { _ in
            self.stopLoadingDots()
            completion()
        }
    }

    private func setupUI() {
        rootStackView.axis = .vertical
        rootStackView.alignment = .center
        rootStackView.spacing = 18
        rootStackView.translatesAutoresizingMaskIntoConstraints = false

        linuxLogoView.image = UIImage(named: "LinuxDoLogo") ?? UIImage(named: "launchImg")
        linuxLogoView.contentMode = .scaleAspectFit
        linuxLogoView.translatesAutoresizingMaskIntoConstraints = false

        brandLabel.text = "Doer"
        brandLabel.textAlignment = .center
        brandLabel.translatesAutoresizingMaskIntoConstraints = false

        valuesLabel.textAlignment = .center
        valuesLabel.numberOfLines = 2

        loadingLabel.textAlignment = .center

        dotsStackView.axis = .horizontal
        dotsStackView.alignment = .center
        dotsStackView.spacing = 7
        dotsStackView.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<3 {
            let dot = UIView()
            dot.layer.cornerRadius = 3.5
            dot.layer.cornerCurve = .continuous
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dotsStackView.addArrangedSubview(dot)
            dotViews.append(dot)
        }

        let loadingStack = UIStackView(arrangedSubviews: [loadingLabel, dotsStackView])
        loadingStack.axis = .vertical
        loadingStack.alignment = .center
        loadingStack.spacing = 12
        loadingStack.translatesAutoresizingMaskIntoConstraints = false

        rootStackView.addArrangedSubview(linuxLogoView)
        rootStackView.setCustomSpacing(24, after: linuxLogoView)
        rootStackView.addArrangedSubview(brandLabel)
        rootStackView.addArrangedSubview(valuesLabel)
        rootStackView.setCustomSpacing(28, after: valuesLabel)
        rootStackView.addArrangedSubview(loadingStack)
        addSubview(rootStackView)

        versionLabel.textAlignment = .center
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.isAccessibilityElement = true
        versionLabel.accessibilityIdentifier = "launch.version"
        addSubview(versionLabel)

        let preferredLogoWidth = linuxLogoView.widthAnchor.constraint(equalToConstant: 300)
        preferredLogoWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            rootStackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            rootStackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -18),
            rootStackView.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 26),
            rootStackView.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -26),

            preferredLogoWidth,
            linuxLogoView.widthAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.widthAnchor, multiplier: 0.84),
            linuxLogoView.heightAnchor.constraint(equalTo: linuxLogoView.widthAnchor, multiplier: 1.0 / 3.0),

            versionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            versionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 24),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -24),
            versionLabel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func startLoadingDots() {
        guard self.window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        for (index, dot) in dotViews.enumerated() {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0.25
            animation.toValue = 1
            animation.duration = 0.62
            animation.beginTime = CACurrentMediaTime() + (Double(index) * 0.16)
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dot.layer.add(animation, forKey: "doer.launch.dot")
        }
    }

    private func stopLoadingDots() {
        dotViews.forEach { $0.layer.removeAnimation(forKey: "doer.launch.dot") }
    }

    private func startLogoBreathing() {
        guard self.window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1
        animation.toValue = 1.025
        animation.duration = 1.1
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        linuxLogoView.layer.add(animation, forKey: "doer.launch.breathe")
    }

    private func stopLogoBreathing() {
        linuxLogoView.layer.removeAnimation(forKey: "doer.launch.breathe")
    }
}

