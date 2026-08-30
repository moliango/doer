import UIKit
import XCTest
@testable import Doer

@MainActor
final class ImagePaintPolicyTests: XCTestCase {
    func testMemoryHitNeverInstallsPlaceholder() {
        let current = UIImage(systemName: "star.fill")
        XCTAssertNil(ImagePaintPolicy.placeholderForAsyncLoad(currentImage: current, memoryHit: true))
        XCTAssertNil(ImagePaintPolicy.placeholderForAsyncLoad(currentImage: nil, memoryHit: true))
    }

    func testAsyncLoadKeepsCurrentImageInsteadOfGrayPlaceholder() {
        let current = UIImage(systemName: "star.fill")
        let placeholder = ImagePaintPolicy.placeholderForAsyncLoad(currentImage: current, memoryHit: false)
        XCTAssertTrue(placeholder === current)
    }

    func testAsyncLoadWithoutCurrentUsesNilNotGrayImage() {
        XCTAssertNil(ImagePaintPolicy.placeholderForAsyncLoad(currentImage: nil, memoryHit: false))
    }

    func testShouldFadeInDiskAndNetworkButNotMemory() {
        XCTAssertFalse(ImagePaintPolicy.shouldFadeIn(.memory))
        XCTAssertTrue(ImagePaintPolicy.shouldFadeIn(.disk))
        XCTAssertTrue(ImagePaintPolicy.shouldFadeIn(.network))
    }

    func testGalleryDismissesAfterTranslationOrVelocityThreshold() {
        XCTAssertFalse(
            TopicImageGalleryDismissPolicy.shouldDismiss(translationY: 20, velocityY: 0)
        )
        XCTAssertTrue(
            TopicImageGalleryDismissPolicy.shouldDismiss(
                translationY: TopicImageGalleryDismissPolicy.translationThreshold + 1,
                velocityY: 0
            )
        )
        XCTAssertTrue(
            TopicImageGalleryDismissPolicy.shouldDismiss(
                translationY: 12,
                velocityY: TopicImageGalleryDismissPolicy.velocityThreshold + 1
            )
        )
    }

    func testGalleryBackgroundFadesWithDownwardDrag() {
        let start = TopicImageGalleryDismissPolicy.backgroundAlpha(for: 0, viewHeight: 800)
        let mid = TopicImageGalleryDismissPolicy.backgroundAlpha(for: 400, viewHeight: 800)
        XCTAssertEqual(start, 1, accuracy: 0.001)
        XCTAssertLessThan(mid, start)
        XCTAssertGreaterThan(mid, 0)
    }

    func testPrepareForLoadRestoresOpaqueAlphaWithoutClearingImage() {
        let imageView = UIImageView()
        let image = UIImage(systemName: "star.fill")
        imageView.image = image
        imageView.alpha = 0
        ImagePaintPolicy.prepareForLoad(on: imageView)
        XCTAssertEqual(imageView.alpha, 1, accuracy: 0.001)
        XCTAssertTrue(imageView.image === image)
    }

    func testDiskPaintDoesNotHideImageView() {
        let imageView = UIImageView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        imageView.backgroundColor = ImagePaintPolicy.waitingFillColor
        ImagePaintPolicy.paint(UIImage(systemName: "star.fill")!, on: imageView, source: .disk)
        XCTAssertEqual(imageView.alpha, 1, accuracy: 0.001)
        XCTAssertNotNil(imageView.image)
    }

    func testHeroFliesWhenSourceExistsAndReduceMotionIsOff() {
        XCTAssertTrue(TopicImageGalleryHeroPolicy.shouldFly(hasSource: true, reduceMotion: false))
    }

    func testHeroDoesNotFlyWithoutSource() {
        XCTAssertFalse(TopicImageGalleryHeroPolicy.shouldFly(hasSource: false, reduceMotion: false))
    }

    func testHeroDoesNotFlyWhenReduceMotionIsOn() {
        XCTAssertFalse(TopicImageGalleryHeroPolicy.shouldFly(hasSource: true, reduceMotion: true))
    }

    func testHeroReturnsToSourceOnlyWhenOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertFalse(
            TopicImageGalleryHeroPolicy.canReturnToSource(
                sourceInWindow: false,
                sourceFrameInScreen: CGRect(x: 40, y: 80, width: 120, height: 80),
                screenBounds: screen
            )
        )
        XCTAssertFalse(
            TopicImageGalleryHeroPolicy.canReturnToSource(
                sourceInWindow: true,
                sourceFrameInScreen: CGRect(x: 0, y: 900, width: 120, height: 80),
                screenBounds: screen
            )
        )
        XCTAssertTrue(
            TopicImageGalleryHeroPolicy.canReturnToSource(
                sourceInWindow: true,
                sourceFrameInScreen: CGRect(x: 40, y: 80, width: 120, height: 80),
                screenBounds: screen
            )
        )
    }

    func testHeroAspectFitCentersLandscapeImage() {
        let fitted = TopicImageGalleryHeroPolicy.aspectFitFrame(
            for: CGSize(width: 200, height: 100),
            in: CGRect(x: 0, y: 0, width: 400, height: 400)
        )
        XCTAssertEqual(fitted.width, 400, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 200, accuracy: 0.001)
        XCTAssertEqual(fitted.minX, 0, accuracy: 0.001)
        XCTAssertEqual(fitted.minY, 100, accuracy: 0.001)
    }

    func testHeroBitmapPrefersUIImageViewImage() {
        let image = UIImage(systemName: "star.fill")
        let imageView = UIImageView(image: image)
        XCTAssertTrue(TopicImageGalleryHeroPolicy.heroBitmap(from: imageView) === image)
        XCTAssertNil(TopicImageGalleryHeroPolicy.heroBitmap(from: nil))
    }

    func testHeroHidesImageViewSourceAndRestoresAlpha() {
        let imageView = UIImageView(image: UIImage(systemName: "star.fill"))
        imageView.alpha = 1
        TopicImageGalleryHeroPolicy.hideSourceDuringFlight(imageView)
        XCTAssertEqual(imageView.alpha, 0, accuracy: 0.001)
        TopicImageGalleryHeroPolicy.restoreSourceAfterFlight(imageView)
        XCTAssertEqual(imageView.alpha, 1, accuracy: 0.001)
    }

    func testHeroCoversNonImageSourceInsteadOfHidingIt() {
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        parent.backgroundColor = .orange
        let anchor = UIView(frame: CGRect(x: 10, y: 10, width: 80, height: 60))
        anchor.backgroundColor = .clear
        parent.addSubview(anchor)

        TopicImageGalleryHeroPolicy.hideSourceDuringFlight(anchor)
        XCTAssertEqual(anchor.alpha, 1, accuracy: 0.001)
        XCTAssertTrue(anchor.backgroundColor === UIColor.orange)

        TopicImageGalleryHeroPolicy.restoreSourceAfterFlight(anchor)
        XCTAssertEqual(anchor.alpha, 1, accuracy: 0.001)
        XCTAssertEqual(anchor.backgroundColor?.cgColor.alpha ?? 1, 0, accuracy: 0.001)
    }
}
