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
}
