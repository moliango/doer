import Combine
import UIKit

enum DoerMotion {
    static let quick: TimeInterval = 0.18
    static let short: TimeInterval = 0.20
    static let standard: TimeInterval = 0.24
    static let emphasized: TimeInterval = 0.30

    static var easeOutCubic: UICubicTimingParameters {
        UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.215, y: 0.61),
            controlPoint2: CGPoint(x: 0.355, y: 1)
        )
    }

    static var easeInCubic: UICubicTimingParameters {
        UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.55, y: 0.055),
            controlPoint2: CGPoint(x: 0.675, y: 0.19)
        )
    }

    static var easeInOutCubic: UICubicTimingParameters {
        UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.645, y: 0.045),
            controlPoint2: CGPoint(x: 0.355, y: 1)
        )
    }

    static var softSpring: UISpringTimingParameters {
        UISpringTimingParameters(
            mass: 1,
            stiffness: 230,
            damping: 32,
            initialVelocity: CGVector(dx: 0.18, dy: 0)
        )
    }

    @discardableResult
    static func animate(
        duration: TimeInterval = DoerMotion.standard,
        delay: TimeInterval = 0,
        timingParameters: UICubicTimingParameters = DoerMotion.easeOutCubic,
        animations: @escaping () -> Void,
        completion: ((UIViewAnimatingPosition) -> Void)? = nil
    ) -> UIViewPropertyAnimator {
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(animations)
            completion?(.end)
            return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }

        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timingParameters)
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion(completion)
        }
        animator.startAnimation(afterDelay: delay)
        return animator
    }

    static func propertyAnimator(
        duration: TimeInterval = DoerMotion.standard,
        timingParameters: UITimingCurveProvider = DoerMotion.easeOutCubic
    ) -> UIViewPropertyAnimator {
        guard !UIAccessibility.isReduceMotionEnabled else {
            return UIViewPropertyAnimator(duration: 0, curve: .linear)
        }
        return UIViewPropertyAnimator(duration: duration, timingParameters: timingParameters)
    }
}

class DoerSkeletonPlaceholderView: UIView {
    let skeletonContentView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = false
        return view
    }()

    private var skeletonBlocks: [UIView] = []
    private var isSkeletonActive = false
    private var currentBlockColor = UIColor.secondarySystemFill

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alpha = 0
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true

        addSubview(skeletonContentView)
        NSLayoutConstraint.activate([
            skeletonContentView.topAnchor.constraint(equalTo: topAnchor),
            skeletonContentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            skeletonContentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            skeletonContentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func makeSkeletonBlock(cornerRadius: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = currentBlockColor
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        skeletonBlocks.append(view)
        return view
    }

    func applySkeletonTheme(backgroundColor: UIColor, blockColor: UIColor) {
        self.backgroundColor = backgroundColor
        currentBlockColor = blockColor
        skeletonBlocks.forEach { $0.backgroundColor = blockColor }
    }

    func setSkeletonActive(_ active: Bool, animated: Bool) {
        guard isSkeletonActive != active || isHidden == active else { return }
        isSkeletonActive = active

        if active {
            if isHidden {
                alpha = 0
                isHidden = false
            }
            startSkeletonPulse()
            let show = { self.alpha = 1 }
            if animated {
                DoerMotion.animate(duration: DoerMotion.quick, animations: show)
            } else {
                show()
            }
        } else {
            let finish = {
                self.stopSkeletonPulse()
                self.isHidden = true
            }
            let hide = { self.alpha = 0 }
            if animated {
                DoerMotion.animate(
                    duration: DoerMotion.quick,
                    timingParameters: DoerMotion.easeInCubic,
                    animations: hide
                ) { _ in
                    finish()
                }
            } else {
                hide()
                finish()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, isSkeletonActive {
            startSkeletonPulse()
        } else {
            stopSkeletonPulse()
        }
    }

    private func startSkeletonPulse() {
        skeletonContentView.layer.removeAnimation(forKey: "doer.skeleton.pulse")
        guard !UIAccessibility.isReduceMotionEnabled, window != nil else {
            skeletonContentView.layer.opacity = 1
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.58
        animation.toValue = 1.0
        animation.duration = 0.95
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        skeletonContentView.layer.add(animation, forKey: "doer.skeleton.pulse")
    }

    private func stopSkeletonPulse() {
        skeletonContentView.layer.removeAnimation(forKey: "doer.skeleton.pulse")
        skeletonContentView.layer.opacity = 1
    }
}

@MainActor
class DoerObservableObject: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()

    func notifyChanged() {
        objectWillChange.send()
    }
}

@MainActor
class ObservableViewController: UIViewController {
    private var observedObjects: [ObjectIdentifier: DoerObservableObject] = [:]
    private var observationCancellables = Set<AnyCancellable>()
    private var isObserving = false
    private var pendingUIUpdate = false

    func updateUI() {
        // Subclasses override this to bind observable state to UI.
    }

    func observe(_ object: DoerObservableObject) {
        let identifier = ObjectIdentifier(object)
        guard observedObjects[identifier] == nil else { return }
        observedObjects[identifier] = object
        guard isObserving else { return }
        subscribe(to: object)
    }

    func startObserving() {
        stopObserving()
        isObserving = true
        observedObjects.values.forEach { subscribe(to: $0) }
        updateUI()
    }

    func stopObserving() {
        observationCancellables.removeAll()
        isObserving = false
    }

    private func subscribe(to object: DoerObservableObject) {
        object.objectWillChange
            .sink { [weak self] in
                self?.scheduleUpdateUI()
            }
            .store(in: &observationCancellables)
    }

    /// Do not rebuild the hierarchy inside a UISwitch callback. `notifyChanged`
    /// is synchronous; tearing out the switch while UIKit is still delivering
    /// `.valueChanged` crashes (DoH toggle on the network settings screen).
    private func scheduleUpdateUI() {
        guard !pendingUIUpdate else { return }
        pendingUIUpdate = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingUIUpdate = false
            guard self.isObserving else { return }
            self.updateUI()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startObserving()
        enableInteractiveBackSwipe()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopObserving()
    }
}
