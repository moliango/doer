import UIKit

/// Liquid-glass capsule drawn behind a tab bar's items.
///
/// Pure decoration: the view never takes a touch, owns no tab state and has no
/// reference to the tab bar controller, so selection, badges, scroll-hide and
/// navigation all keep behaving exactly as before. The host only feeds it the
/// current selection so the highlight pill can slide to the active item.
final class FloatingTabBarGlassView: UIView {
    private enum Metrics {
        /// Side margin of the floating capsule inside the tab bar's bounds.
        static let horizontalInset: CGFloat = 12
        /// Gap above/below the capsule inside the bar's content area.
        static let verticalInset: CGFloat = 1
        /// Inset between the capsule edge and the selection pill.
        static let pillInset: CGFloat = 5
        /// Capsule never grows past this even when the bar is unusually tall.
        static let maximumCapsuleHeight: CGFloat = 56
        /// Widest the selection pill may get, so sparse tab bars stay tidy.
        static let maximumPillWidth: CGFloat = 96
        static let minimumCapsuleHeight: CGFloat = 44
    }

    private let capsuleView = UIView()
    private let effectView = UIVisualEffectView(effect: nil)
    private let tintView = UIView()
    private let pillView = UIView()

    private var appliedThemeStyle: AppSettings.ThemeStyle?
    private var itemCount = 0
    private var selectedIndex = 0
    /// True while the pill is sliding; a layout pass must not snap it to its
    /// destination mid-flight.
    private var isAnimatingPill = false

    override init(frame: CGRect) {
        super.init(frame: frame)

        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false

        capsuleView.isUserInteractionEnabled = false
        capsuleView.clipsToBounds = true
        capsuleView.layer.cornerCurve = .continuous
        addSubview(capsuleView)

        effectView.isUserInteractionEnabled = false
        capsuleView.addSubview(effectView)

        tintView.isUserInteractionEnabled = false
        capsuleView.addSubview(tintView)

        pillView.isUserInteractionEnabled = false
        pillView.layer.cornerCurve = .continuous
        capsuleView.addSubview(pillView)

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 20

        applyTheme(AppSettings.shared.themeStyle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Attaches the shell behind the tab bar's own item views. The bar's
    /// background appearance is made transparent by the caller, so the capsule
    /// is what the user sees.
    func install(in tabBar: UITabBar) {
        guard superview == nil else { return }
        // iOS 26 already floats a liquid-glass platter with a selection lens
        // behind the items; a second capsule would only double it up.
        if #available(iOS 26.0, *) { return }
        tabBar.insertSubview(self, at: 0)
    }

    /// Re-resolves material and colors for the current theme.
    func applyTheme(_ theme: AppSettings.ThemeStyle) {
        appliedThemeStyle = theme

        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = false
            effectView.effect = glass
        } else {
            effectView.effect = UIBlurEffect(style: .systemThinMaterial)
        }

        tintView.backgroundColor = Self.tintColor(for: theme)
        pillView.backgroundColor = Self.pillColor(for: theme)
        layer.shadowOpacity = theme.prefersOpaqueChrome ? 0.10 : 0.16
        updateBorderColor()
        setNeedsLayout()
    }

    /// Keeps the capsule aligned with the bar's item area.
    ///
    /// - Parameters:
    ///   - barBounds: The tab bar's own bounds.
    ///   - bottomInset: The bar's bottom safe-area inset; the capsule stays in
    ///     the content area above it so the home indicator keeps its room.
    ///   - animated: `true` when only the selection changed (pill slides).
    func update(
        barBounds: CGRect,
        bottomInset: CGFloat,
        itemCount: Int,
        selectedIndex: Int,
        animated: Bool
    ) {
        guard barBounds.width > 0, barBounds.height > 0 else { return }
        self.itemCount = max(itemCount, 1)
        self.selectedIndex = selectedIndex
        if frame != barBounds {
            frame = barBounds
        }
        layoutCapsule(barBounds: barBounds, bottomInset: bottomInset, animatedSelection: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        layoutCapsule(
            barBounds: bounds,
            bottomInset: superview?.safeAreaInsets.bottom ?? 0,
            animatedSelection: false
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        if let appliedThemeStyle {
            applyTheme(appliedThemeStyle)
        }
    }

    private func layoutCapsule(barBounds: CGRect, bottomInset: CGFloat, animatedSelection: Bool) {
        let contentHeight = max(barBounds.height - bottomInset, 0)
        let capsuleHeight = min(
            max(contentHeight - Metrics.verticalInset * 2, Metrics.minimumCapsuleHeight),
            Metrics.maximumCapsuleHeight
        )
        let capsuleWidth = max(barBounds.width - Metrics.horizontalInset * 2, 0)
        let capsuleFrame = CGRect(
            x: Metrics.horizontalInset,
            y: max((contentHeight - capsuleHeight) / 2, 0),
            width: capsuleWidth,
            height: capsuleHeight
        )

        if capsuleView.frame != capsuleFrame {
            capsuleView.frame = capsuleFrame
            capsuleView.layer.cornerRadius = capsuleHeight / 2
            layer.shadowPath = UIBezierPath(
                roundedRect: capsuleFrame,
                cornerRadius: capsuleHeight / 2
            ).cgPath
        }

        let localBounds = CGRect(origin: .zero, size: capsuleFrame.size)
        if effectView.frame != localBounds {
            effectView.frame = localBounds
            tintView.frame = localBounds
        }

        layoutPill(in: capsuleFrame, animated: animatedSelection)
    }

    private func layoutPill(in capsuleFrame: CGRect, animated: Bool) {
        guard itemCount > 0, capsuleFrame.width > 0 else { return }
        let itemWidth = bounds.width / CGFloat(itemCount)
        // Keep the pill hugging the icon+label cluster instead of stretching
        // across a wide item when there are only two or three tabs.
        let pillWidth = max(min(itemWidth - Metrics.pillInset * 2, Metrics.maximumPillWidth), 0)
        let pillHeight = max(capsuleFrame.height - Metrics.pillInset * 2, 0)
        let centerX = (CGFloat(selectedIndex) + 0.5) * itemWidth - capsuleFrame.minX
        let maximumX = capsuleFrame.width - pillWidth - Metrics.pillInset
        let target = CGRect(
            x: min(max(centerX - pillWidth / 2, Metrics.pillInset), max(maximumX, Metrics.pillInset)),
            y: Metrics.pillInset,
            width: pillWidth,
            height: pillHeight
        )

        guard pillView.frame != target else { return }
        pillView.layer.cornerRadius = pillHeight / 2
        guard !isAnimatingPill else { return }

        let canAnimate = animated && !pillView.bounds.isEmpty && !UIAccessibility.isReduceMotionEnabled
        guard canAnimate else {
            UIView.performWithoutAnimation { pillView.frame = target }
            return
        }
        isAnimatingPill = true
        DoerMotion.animate(
            duration: DoerMotion.emphasized,
            animations: { self.pillView.frame = target },
            completion: { [weak self] _ in self?.isAnimatingPill = false }
        )
    }

    private func updateBorderColor() {
        capsuleView.layer.borderWidth = 1
        capsuleView.layer.borderColor = UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.10)
                : UIColor.black.withAlphaComponent(0.06)
        }.resolvedColor(with: traitCollection).cgColor
    }

    private static func tintColor(for theme: AppSettings.ThemeStyle) -> UIColor {
        switch theme {
        case .systemDefault:
            // Let the system material speak for itself.
            return .clear
        case .oled:
            return UIColor.black.withAlphaComponent(0.62)
        case .eyeCare, .xiaohongshu:
            return theme.contentBackgroundColor.withAlphaComponent(0.52)
        case .weChat, .telegram, .kraftPaper:
            // Opaque-chrome themes keep their identity, just floated and rounded.
            return theme.chromeBackgroundColor.withAlphaComponent(0.82)
        }
    }

    private static func pillColor(for theme: AppSettings.ThemeStyle) -> UIColor {
        if theme == .oled {
            return UIColor.white.withAlphaComponent(0.12)
        }
        return UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.14)
                : UIColor.white.withAlphaComponent(0.56)
        }
    }
}
