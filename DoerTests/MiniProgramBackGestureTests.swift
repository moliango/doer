import XCTest
@testable import Doer

final class MiniProgramBackGestureTests: XCTestCase {
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
