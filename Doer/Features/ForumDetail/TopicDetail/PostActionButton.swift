import UIKit

/// Shared press wash so Topic Detail icon buttons read as tappable.
enum TopicDetailPressChrome {
    static let fill = UIColor.label.withAlphaComponent(0.10)
    static let haloSize: CGFloat = 32
    static let cornerRadius: CGFloat = 16
    static let iconScale: CGFloat = 0.92
    static let pressedIconAlpha: CGFloat = 0.55
    static let minimumVisibleDuration: TimeInterval = 0.12

    static func install(on button: UIButton) {
        let latch = TopicDetailPressLatch()
        objc_setAssociatedObject(button, &TopicDetailPressLatch.associationKey, latch, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        latch.attach(to: button) { [weak button] pressed in
            guard let button else { return }
            var config = button.configuration ?? .plain()
            config.background.backgroundColor = pressed ? fill : .clear
            config.background.cornerRadius = cornerRadius
            button.configuration = config
        }
    }
}

/// Holds a press wash for a minimum time so a quick tap still reads as a hit.
final class TopicDetailPressLatch: NSObject {
    fileprivate static var associationKey: UInt8 = 0

    private var hideWork: DispatchWorkItem?
    private var shownAt: CFTimeInterval = 0
    private var onChange: ((Bool) -> Void)?

    func attach(to control: UIControl, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        control.addTarget(self, action: #selector(pressDown), for: [.touchDown, .touchDragEnter])
        control.addTarget(
            self,
            action: #selector(pressUp),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @objc private func pressDown() {
        hideWork?.cancel()
        hideWork = nil
        shownAt = CACurrentMediaTime()
        onChange?(true)
    }

    @objc private func pressUp() {
        let remaining = max(0, TopicDetailPressChrome.minimumVisibleDuration - (CACurrentMediaTime() - shownAt))
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?(false)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }
}

final class PostActionButton: UIButton {
    static let iconSize = CGSize(width: 22, height: 22)

    private let haloView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = TopicDetailPressChrome.fill
        view.layer.cornerRadius = TopicDetailPressChrome.cornerRadius
        view.layer.cornerCurve = .continuous
        view.alpha = 0
        return view
    }()

    private(set) lazy var fixedIconView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        return imageView
    }()

    var isShowingPressHalo: Bool { haloView.alpha > 0.01 }

    private let pressLatch = TopicDetailPressLatch()

    override init(frame: CGRect) {
        super.init(frame: frame)
        adjustsImageWhenHighlighted = false
        addSubview(haloView)
        addSubview(fixedIconView)
        NSLayoutConstraint.activate([
            haloView.centerXAnchor.constraint(equalTo: centerXAnchor),
            haloView.centerYAnchor.constraint(equalTo: centerYAnchor),
            haloView.widthAnchor.constraint(equalToConstant: TopicDetailPressChrome.haloSize),
            haloView.heightAnchor.constraint(equalToConstant: TopicDetailPressChrome.haloSize),
            fixedIconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            fixedIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            fixedIconView.widthAnchor.constraint(equalToConstant: Self.iconSize.width),
            fixedIconView.heightAnchor.constraint(equalToConstant: Self.iconSize.height),
        ])
        pressLatch.attach(to: self) { [weak self] pressed in
            self?.applyPressChrome(pressed, animated: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                applyPressChrome(false, animated: false)
            }
        }
    }

    func setFixedIcon(_ image: UIImage?, tintColor: UIColor) {
        fixedIconView.image = image?.withRenderingMode(.alwaysTemplate)
        fixedIconView.tintColor = tintColor
    }

    private func applyPressChrome(_ pressed: Bool, animated: Bool) {
        let show = pressed && isEnabled
        haloView.alpha = show ? 1 : 0
        let iconChanges = {
            self.fixedIconView.alpha = show ? TopicDetailPressChrome.pressedIconAlpha : 1
            self.fixedIconView.transform = show
                ? CGAffineTransform(
                    scaleX: TopicDetailPressChrome.iconScale,
                    y: TopicDetailPressChrome.iconScale
                )
                : .identity
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            iconChanges()
            return
        }
        UIView.animate(
            withDuration: show ? 0.08 : 0.16,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: iconChanges
        )
    }
}
