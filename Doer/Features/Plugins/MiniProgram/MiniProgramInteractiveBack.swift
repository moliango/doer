import UIKit

/// Mini-program history back: follow-finger from the same 20pt strip as TopicDetail.
/// Never dismisses the host — close stays on the capsule.
enum MiniProgramBackGesturePolicy {
    static let commitFraction: CGFloat = 0.5
    static let commitVelocity: CGFloat = 300
    static let parallax: CGFloat = 0.3
    static let dimAlpha: CGFloat = 0.35

    static func shouldBeginHostPan(
        locationX: CGFloat,
        translation: CGPoint,
        velocity: CGPoint,
        webCanGoBack: Bool,
        nestedNavCanPop: Bool,
        hasPresentedOverlay: Bool
    ) -> Bool {
        guard webCanGoBack, !nestedNavCanPop, !hasPresentedOverlay else { return false }
        return NavigationPopGesturePriority.shouldYieldScrollPanToSystemPop(
            locationX: locationX,
            translation: translation,
            velocity: velocity
        )
    }

    static func shouldCommit(translationX: CGFloat, velocityX: CGFloat, width: CGFloat) -> Bool {
        let distance = width > 1 ? width * commitFraction : 80
        return translationX >= distance || velocityX >= commitVelocity
    }

    static func progress(translationX: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        return min(1, max(0, translationX / width))
    }
}

/// Drives a TopicDetail-style interactive back on the mini-program content pane.
final class MiniProgramInteractiveBackController: NSObject, UIGestureRecognizerDelegate {
    private let pan = UIPanGestureRecognizer()
    private weak var hostView: UIView?
    private weak var slidingView: UIView?
    private var snapshot: UIView?
    private var dimView: UIView?
    private var didPeekBack = false
    private var isActive = false

    var canBegin: ((UIPanGestureRecognizer) -> Bool)?
    var peekBack: (() -> Bool)?
    var peekForward: (() -> Bool)?

    func attach(hostView: UIView, slidingView: UIView) {
        self.hostView = hostView
        self.slidingView = slidingView
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.addTarget(self, action: #selector(handlePan(_:)))
        hostView.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }
        return canBegin?(pan) ?? false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === pan && other.view is UIScrollView
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let hostView, let slidingView else { return }
        let translationX = max(0, gesture.translation(in: hostView).x)
        let width = hostView.bounds.width
        switch gesture.state {
        case .began:
            begin(in: hostView, slidingView: slidingView)
        case .changed:
            apply(translationX: translationX, width: width)
        case .ended:
            let velocityX = gesture.velocity(in: hostView).x
            if MiniProgramBackGesturePolicy.shouldCommit(
                translationX: translationX,
                velocityX: velocityX,
                width: width
            ) {
                finish(width: width)
            } else {
                cancel()
            }
        default:
            if isActive { cancel() }
        }
    }

    private func begin(in hostView: UIView, slidingView: UIView) {
        isActive = true
        didPeekBack = false
        NavigationPopGesturePriority.stopScrollTracking(in: slidingView)
        slidingView.isUserInteractionEnabled = false

        if let snapshot = slidingView.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = slidingView.frame
            snapshot.layer.shadowColor = UIColor.black.cgColor
            snapshot.layer.shadowOpacity = 0
            snapshot.layer.shadowRadius = 12
            snapshot.layer.shadowOffset = CGSize(width: -2, height: 0)
            hostView.insertSubview(snapshot, aboveSubview: slidingView)
            self.snapshot = snapshot
        }

        let cover = snapshot ?? slidingView
        let dim = UIView(frame: slidingView.frame)
        dim.backgroundColor = UIColor.black
        dim.alpha = MiniProgramBackGesturePolicy.dimAlpha
        dim.isUserInteractionEnabled = false
        hostView.insertSubview(dim, belowSubview: cover)
        dimView = dim

        if snapshot != nil, peekBack?() == true {
            didPeekBack = true
            apply(translationX: 0, width: hostView.bounds.width)
        } else if snapshot != nil {
            abortBegin()
        }
    }

    private func abortBegin() {
        snapshot?.removeFromSuperview()
        snapshot = nil
        dimView?.removeFromSuperview()
        dimView = nil
        slidingView?.transform = .identity
        slidingView?.isUserInteractionEnabled = true
        didPeekBack = false
        isActive = false
        pan.isEnabled = false
        pan.isEnabled = true
    }

    private func apply(translationX: CGFloat, width: CGFloat) {
        let progress = MiniProgramBackGesturePolicy.progress(translationX: translationX, width: width)
        let moving = snapshot ?? slidingView
        moving?.transform = CGAffineTransform(translationX: translationX, y: 0)
        moving?.layer.shadowOpacity = Float(0.22 * min(1, progress * 2.5))
        dimView?.alpha = MiniProgramBackGesturePolicy.dimAlpha * (1 - progress)
        if didPeekBack {
            let shift = -MiniProgramBackGesturePolicy.parallax * width * (1 - progress)
            slidingView?.transform = CGAffineTransform(translationX: shift, y: 0)
        }
    }

    private func finish(width: CGFloat) {
        let moving = snapshot ?? slidingView
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            moving?.transform = CGAffineTransform(translationX: width, y: 0)
            moving?.layer.shadowOpacity = 0
            self.dimView?.alpha = 0
            self.slidingView?.transform = .identity
        } completion: { _ in
            if !self.didPeekBack {
                _ = self.peekBack?()
            }
            self.teardown()
        }
    }

    private func cancel() {
        if didPeekBack {
            _ = peekForward?()
        }
        let moving = snapshot ?? slidingView
        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            moving?.transform = .identity
            moving?.layer.shadowOpacity = 0
            self.dimView?.alpha = MiniProgramBackGesturePolicy.dimAlpha
            self.slidingView?.transform = .identity
        } completion: { _ in
            self.teardown()
        }
    }

    private func teardown() {
        snapshot?.removeFromSuperview()
        snapshot = nil
        dimView?.removeFromSuperview()
        dimView = nil
        slidingView?.transform = .identity
        slidingView?.isUserInteractionEnabled = true
        didPeekBack = false
        isActive = false
    }
}
