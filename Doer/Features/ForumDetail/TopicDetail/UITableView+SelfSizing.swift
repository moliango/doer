import ObjectiveC
import UIKit

/// Safe self-sizing invalidation for DiffableDataSource-backed tables.
///
/// Raw `beginUpdates()` / `endUpdates()` while a snapshot apply, `reloadItems`,
/// or `scrollToRow` is in flight desyncs UITableView's internal
/// `_visibleRows` vs `_visibleCells` and traps with:
/// `UITableView internal inconsistency: _visibleRows and _visibleCells must be of same length`.
///
/// Scroll-busy gate: while the user is dragging/decelerating, height passes are
/// only marked pending and flush after scrolling settles — avoids mid-scroll
/// `beginUpdates` jank on long image posts.
extension UITableView {
    private static var mutationDepthKey: UInt8 = 0
    private static var pendingHeightPassKey: UInt8 = 0
    private static var heightPassScheduledKey: UInt8 = 0
    private static var scrollBusyKey: UInt8 = 0
    private static var scrollSettleWorkItemKey: UInt8 = 0
    private static var scrollSettledHandlerKey: UInt8 = 0

    /// `numberOfRows(inSection:)` throws if the section does not exist.
    func doer_numberOfRows(inSection section: Int) -> Int {
        guard section >= 0, numberOfSections > section else { return 0 }
        return numberOfRows(inSection: section)
    }

    func doer_hasRow(at indexPath: IndexPath) -> Bool {
        indexPath.row >= 0 && indexPath.row < doer_numberOfRows(inSection: indexPath.section)
    }

    /// True while any Diffable `apply` / structural mutation is in flight.
    var doer_isMutatingData: Bool {
        get { doer_mutationDepth > 0 }
        set {
            if newValue {
                doer_beginDataMutation()
            } else {
                doer_endDataMutation()
            }
        }
    }

    /// True while the user is actively scrolling (drag or decelerate), or during
    /// the short settle window after lift. Height flushes wait until this clears.
    var doer_isScrollBusy: Bool {
        get { (objc_getAssociatedObject(self, &Self.scrollBusyKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.scrollBusyKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Invoked once after scroll busy clears (post-settle). Used to finish progressive
    /// post bodies and resume GIF/media without fighting the fling.
    var doer_onScrollSettled: (() -> Void)? {
        get { objc_getAssociatedObject(self, &Self.scrollSettledHandlerKey) as? (() -> Void) }
        set { objc_setAssociatedObject(self, &Self.scrollSettledHandlerKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    private var doer_mutationDepth: Int {
        get { (objc_getAssociatedObject(self, &Self.mutationDepthKey) as? Int) ?? 0 }
        set { objc_setAssociatedObject(self, &Self.mutationDepthKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var doer_hasPendingHeightPass: Bool {
        get { (objc_getAssociatedObject(self, &Self.pendingHeightPassKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.pendingHeightPassKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var doer_heightPassScheduled: Bool {
        get { (objc_getAssociatedObject(self, &Self.heightPassScheduledKey) as? Bool) ?? false }
        set { objc_setAssociatedObject(self, &Self.heightPassScheduledKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var doer_scrollSettleWorkItem: DispatchWorkItem? {
        get { objc_getAssociatedObject(self, &Self.scrollSettleWorkItemKey) as? DispatchWorkItem }
        set { objc_setAssociatedObject(self, &Self.scrollSettleWorkItemKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func doer_beginDataMutation() {
        doer_mutationDepth += 1
    }

    func doer_endDataMutation() {
        doer_mutationDepth = max(0, doer_mutationDepth - 1)
        if doer_mutationDepth == 0 {
            doer_flushPendingSelfSizingUpdateIfNeeded()
        }
    }

    /// Mark table as scroll-busy so self-sizing passes queue instead of flushing.
    /// Call with `false` when drag ends without decelerate, or when decelerate ends.
    func doer_setScrollBusy(_ busy: Bool) {
        doer_scrollSettleWorkItem?.cancel()
        doer_scrollSettleWorkItem = nil

        if busy {
            doer_isScrollBusy = true
            return
        }

        // Short settle window: coalesce late image-load height requests after fling ends.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.doer_isScrollBusy = false
            self.doer_scrollSettleWorkItem = nil
            self.doer_flushPendingSelfSizingUpdateIfNeeded()
            self.doer_onScrollSettled?()
        }
        doer_scrollSettleWorkItem = work
        // Keep busy true until settle fires so mid-settle invalidates still queue.
        doer_isScrollBusy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            work.perform()
        }
    }

    /// Coalesced, mutation- and scroll-gated replacement for `beginUpdates()` / `endUpdates()`
    /// used only to re-measure automatic-dimension rows after media/layout changes.
    func doer_invalidateSelfSizingRows() {
        doer_hasPendingHeightPass = true
        #if DEBUG
        TopicDetailPerfCounters.heightInvalidateRequests += 1
        #endif
        guard !doer_isScrollBusy else { return }
        doer_scheduleSelfSizingPass()
    }

    private func doer_scheduleSelfSizingPass() {
        guard !doer_heightPassScheduled else { return }
        doer_heightPassScheduled = true
        // Next turn — never nest inside an existing layout / Diffable apply callback.
        Task { @MainActor in
            self.doer_heightPassScheduled = false
            self.doer_flushPendingSelfSizingUpdateIfNeeded()
        }
    }

    private func doer_flushPendingSelfSizingUpdateIfNeeded() {
        guard doer_hasPendingHeightPass else { return }
        guard window != nil else { return }
        guard !doer_isScrollBusy else { return }
        guard !doer_isMutatingData else {
            // Still applying a snapshot — try again after the flag clears.
            doer_scheduleSelfSizingPass()
            return
        }
        // Table must already have sections; empty tables crash on beginUpdates mid-teardown.
        guard doer_numberOfRows(inSection: 0) > 0 else {
            doer_hasPendingHeightPass = false
            return
        }

        doer_hasPendingHeightPass = false
        UIView.performWithoutAnimation {
            self.beginUpdates()
            self.endUpdates()
        }
    }

    /// Two-pass jump so upward floor targeting is not stuck on estimated heights.
    @discardableResult
    func doer_scrollRow(
        at indexPath: IndexPath,
        position: UITableView.ScrollPosition,
        animated: Bool
    ) -> Bool {
        guard doer_hasRow(at: indexPath) else { return false }

        func applyPreciseOffset() {
            guard doer_hasRow(at: indexPath) else { return }
            layoutIfNeeded()
            guard doer_hasRow(at: indexPath) else { return }
            let rect = rectForRow(at: indexPath)
            guard rect.height > 1 else { return }
            let inset = adjustedContentInset
            let y = TopicDetailJumpScrollPolicy.contentOffsetY(
                rowRect: rect,
                viewportHeight: bounds.height,
                contentHeight: contentSize.height,
                insetTop: inset.top,
                insetBottom: inset.bottom,
                position: position
            )
            setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }

        var didScroll = false
        UIView.performWithoutAnimation {
            self.layoutIfNeeded()
            guard self.doer_hasRow(at: indexPath) else { return }
            self.scrollToRow(at: indexPath, at: position, animated: false)
            applyPreciseOffset()
            applyPreciseOffset()
            didScroll = true
        }
        if didScroll, animated {
            applyPreciseOffset()
        }
        return didScroll
    }
}
