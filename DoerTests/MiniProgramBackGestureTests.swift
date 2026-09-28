import XCTest
@testable import Doer

final class MiniProgramBackGestureTests: XCTestCase {
    func testDrawerCloseButtonFitsInsideRoundedCorners() {
        XCTAssertEqual(MiniProgramDrawerChromePolicy.closeButtonSize, 32)
        XCTAssertEqual(MiniProgramDrawerChromePolicy.closeButtonCornerRadius, 16)
        XCTAssertGreaterThanOrEqual(MiniProgramDrawerChromePolicy.horizontalInset, 16)
        XCTAssertLessThan(
            MiniProgramDrawerChromePolicy.closeButtonSize + MiniProgramDrawerChromePolicy.horizontalInset,
            56,
            "Close pill plus trailing inset must stay clear of the status-bar battery corner"
        )
    }

    func testDrawerHeaderUsesWindowSafeAreaWhenOverlayReportsZero() {
        XCTAssertEqual(
            MiniProgramDrawerChromePolicy.headerTopInset(viewSafeAreaTop: 0, windowSafeAreaTop: 59),
            59 + MiniProgramDrawerChromePolicy.grabberTopSpacing
        )
        XCTAssertEqual(
            MiniProgramDrawerChromePolicy.headerTopInset(viewSafeAreaTop: 0, windowSafeAreaTop: 0),
            MiniProgramDrawerChromePolicy.minimumStatusBarInset
                + MiniProgramDrawerChromePolicy.grabberTopSpacing
        )
        XCTAssertEqual(
            MiniProgramDrawerChromePolicy.headerTopInset(viewSafeAreaTop: 59, windowSafeAreaTop: 47),
            59 + MiniProgramDrawerChromePolicy.grabberTopSpacing
        )
    }

    func testHostPanBeginsOnHorizontalEdgeWhenWebCanGoBack() {
        XCTAssertTrue(
            MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: 12,
                translation: CGPoint(x: 8, y: 1),
                velocity: .zero,
                webCanGoBack: true,
                nestedNavCanPop: false,
                hasPresentedOverlay: false
            )
        )
    }

    func testHostPanYieldsToNestedNavInteractivePop() {
        XCTAssertFalse(
            MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: 12,
                translation: CGPoint(x: 8, y: 0),
                velocity: .zero,
                webCanGoBack: true,
                nestedNavCanPop: true,
                hasPresentedOverlay: false
            )
        )
    }

    func testHostPanDoesNotBeginWithoutHistory() {
        XCTAssertFalse(
            MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: 12,
                translation: CGPoint(x: 8, y: 0),
                velocity: .zero,
                webCanGoBack: false,
                nestedNavCanPop: false,
                hasPresentedOverlay: false
            )
        )
    }

    func testHostPanDoesNotBeginUnderPresentedOverlay() {
        XCTAssertFalse(
            MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: 12,
                translation: CGPoint(x: 8, y: 0),
                velocity: .zero,
                webCanGoBack: true,
                nestedNavCanPop: false,
                hasPresentedOverlay: true
            )
        )
    }

    func testHostPanIgnoresVerticalEdgeScroll() {
        XCTAssertFalse(
            MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: 12,
                translation: CGPoint(x: 1, y: 10),
                velocity: .zero,
                webCanGoBack: true,
                nestedNavCanPop: false,
                hasPresentedOverlay: false
            )
        )
    }

    func testHostPanIgnoresNonEdgeHorizontalPan() {
        XCTAssertFalse(
            MiniProgramBackGesturePolicy.shouldBeginHostPan(
                locationX: 80,
                translation: CGPoint(x: 12, y: 0),
                velocity: .zero,
                webCanGoBack: true,
                nestedNavCanPop: false,
                hasPresentedOverlay: false
            )
        )
    }

    func testCommitUsesDistanceOrVelocityLikeSystemPop() {
        XCTAssertTrue(
            MiniProgramBackGesturePolicy.shouldCommit(translationX: 200, velocityX: 0, width: 390)
        )
        XCTAssertTrue(
            MiniProgramBackGesturePolicy.shouldCommit(translationX: 40, velocityX: 320, width: 390)
        )
        XCTAssertFalse(
            MiniProgramBackGesturePolicy.shouldCommit(translationX: 40, velocityX: 80, width: 390)
        )
    }

    func testProgressClampsToUnitInterval() {
        XCTAssertEqual(MiniProgramBackGesturePolicy.progress(translationX: -10, width: 390), 0)
        XCTAssertEqual(MiniProgramBackGesturePolicy.progress(translationX: 195, width: 390), 0.5, accuracy: 0.001)
        XCTAssertEqual(MiniProgramBackGesturePolicy.progress(translationX: 800, width: 390), 1)
    }
}
