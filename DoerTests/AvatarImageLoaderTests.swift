import UIKit
import XCTest
@testable import Doer

final class AvatarImageLoaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AvatarImageLoader.clearUserAvatarCacheForTesting()
    }

    override func tearDown() {
        AvatarImageLoader.clearUserAvatarCacheForTesting()
        super.tearDown()
    }

    func testCachesSuccessfulAvatarByBaseURLAndUserId() {
        let image = UIImage(systemName: "person.circle")!
        let url = URL(string: "https://linux.do/user_avatar/linux.do/demo/120/1.png")!

        AvatarImageLoader.storeUserAvatarForTesting(
            image,
            url: url,
            baseURL: "https://linux.do",
            userId: 42
        )

        let cached = AvatarImageLoader.cachedUserAvatarForTesting(baseURL: "https://linux.do/", userId: 42)

        XCTAssertTrue(cached?.image === image)
        XCTAssertEqual(cached?.url, url)
    }

    func testUserAvatarCacheIsScopedByBaseURL() {
        let image = UIImage(systemName: "person.circle")!
        let url = URL(string: "https://linux.do/user_avatar/linux.do/demo/120/1.png")!

        AvatarImageLoader.storeUserAvatarForTesting(
            image,
            url: url,
            baseURL: "https://linux.do",
            userId: 42
        )

        XCTAssertNil(AvatarImageLoader.cachedUserAvatarForTesting(baseURL: "https://example.com", userId: 42))
    }

    func testImageLoadOptionsDoNotQueryDiskSynchronously() {
        XCTAssertFalse(AvatarImageLoader.usesSynchronousDiskCacheQueryForTesting())
    }

    func testImageLoadOptionsQueryMemorySynchronously() {
        XCTAssertTrue(AvatarImageLoader.usesSynchronousMemoryCacheQueryForTesting())
    }

    func testImageLoadOptionsDelayPlaceholderUntilFinished() {
        XCTAssertTrue(AvatarImageLoader.delaysPlaceholderUntilLoadFinishesForTesting())
    }

    func testUserAvatarCacheHitSkipsNetworkForSizeVariants() throws {
        let cached = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/demo/120/1.png"))
        let requested = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/demo/96/1.png"))
        XCTAssertTrue(
            AvatarCachePolicy.shouldSkipNetworkAfterUserCacheHit(
                cachedURL: cached,
                requestedURL: requested
            )
        )
    }

    func testUserAvatarCacheDoesNotSkipNetworkWhenUploadChanges() throws {
        let cached = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/demo/120/1.png"))
        let requested = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/demo/120/2.png"))
        XCTAssertFalse(
            AvatarCachePolicy.shouldSkipNetworkAfterUserCacheHit(
                cachedURL: cached,
                requestedURL: requested
            )
        )
    }

    func testSetImageReusesUserCacheForEquivalentURLWithoutNetwork() throws {
        let image = UIImage(systemName: "person.circle")!
        let cachedURL = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/demo/120/1.png"))
        let requestedURL = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/demo/96/1.png"))
        AvatarImageLoader.storeUserAvatarForTesting(
            image,
            url: cachedURL,
            baseURL: "https://linux.do",
            userId: 7
        )

        let imageView = UIImageView()
        AvatarImageLoader.setImage(
            on: imageView,
            url: requestedURL,
            avatarBaseURL: "https://linux.do",
            userId: 7
        )

        XCTAssertTrue(imageView.image === image)
    }

    func testLetterAvatarCacheHitSkipsNetworkForSizeVariants() throws {
        let cached = try XCTUnwrap(
            URL(string: "https://linux.do/letter_avatar_proxy/v4/letter/n/8e8ea6/120.png")
        )
        let requested = try XCTUnwrap(
            URL(string: "https://linux.do/letter_avatar_proxy/v4/letter/n/8e8ea6/48.png")
        )
        XCTAssertTrue(
            AvatarCachePolicy.shouldSkipNetworkAfterUserCacheHit(
                cachedURL: cached,
                requestedURL: requested
            )
        )
    }
}
