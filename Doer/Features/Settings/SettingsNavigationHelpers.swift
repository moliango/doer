import UIKit

/// Edge-pop vs vertical scroll: a rightward back-swipe from the system pop strip
/// should win even while a table is dragging or coasting.
enum NavigationPopGesturePriority {
    static let systemEdgeWidth: CGFloat = 20

    static func shouldYieldScrollPanToSystemPop(
        locationX: CGFloat,
        translation: CGPoint,
        velocity: CGPoint
    ) -> Bool {
        let dx = abs(translation.x) >= 1 ? translation.x : velocity.x
        let dy = abs(translation.y) >= 1 ? translation.y : velocity.y
        return locationX <= systemEdgeWidth && dx > 0 && abs(dx) >= abs(dy)
    }

    /// Freeze in-flight scroll pans so an edge-back gesture can take over.
    static func stopScrollTracking(in root: UIView?) {
        guard let root else { return }
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            if let scrollView = view as? UIScrollView {
                let pan = scrollView.panGestureRecognizer
                pan.isEnabled = false
                pan.isEnabled = true
                if scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking {
                    scrollView.setContentOffset(scrollView.contentOffset, animated: false)
                }
            }
            stack.append(contentsOf: view.subviews)
        }
    }
}

/// Enables system interactive pop (follow-finger edge swipe) on a UINavigationController.
/// Attach once per navigation stack. Do not add a competing pan that pops on lift.
final class NavigationPopGestureEnabler: NSObject, UIGestureRecognizerDelegate {
    private weak var navigationController: UINavigationController?

    func attach(to navigationController: UINavigationController) {
        self.navigationController = navigationController
        guard let pop = navigationController.interactivePopGestureRecognizer else { return }
        pop.isEnabled = true
        pop.delegate = self
        pop.removeTarget(self, action: #selector(handlePopGesture(_:)))
        pop.addTarget(self, action: #selector(handlePopGesture(_:)))
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let nav = navigationController else { return false }
        return nav.viewControllers.count > 1
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === navigationController?.interactivePopGestureRecognizer else {
            return false
        }
        // Scroll pans otherwise keep exclusive ownership while dragging/decelerating,
        // so edge-pop cannot start until the list fully stops.
        return other.view is UIScrollView
    }

    @objc private func handlePopGesture(_ gesture: UIGestureRecognizer) {
        guard gesture.state == .began else { return }
        NavigationPopGesturePriority.stopScrollTracking(in: navigationController?.topViewController?.view)
    }
}

extension UIViewController {
    func enableSettingsInteractiveBackSwipe() {
        enableInteractiveBackSwipe()
    }

    func enableInteractiveBackSwipe() {
        guard let navigationController,
              navigationController.viewControllers.count > 1
        else { return }
        navigationController.interactivePopGestureRecognizer?.isEnabled = true
    }
}
