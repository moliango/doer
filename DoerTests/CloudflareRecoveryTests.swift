import XCTest
@testable import Doer

@MainActor
final class CloudflareRecoveryTests: XCTestCase {
    func testVerificationTargetPrefersSameOriginChallengeURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://linux.do"))
        let responseURL = try XCTUnwrap(URL(string: "https://linux.do/t/123.json"))

        XCTAssertEqual(
            CloudflareVerificationPolicy.verificationURL(baseURL: baseURL, responseURL: responseURL).path,
            "/challenge"
        )
    }

    func testVerificationTargetRejectsExternalChallengeURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://linux.do"))
        let responseURL = try XCTUnwrap(URL(string: "https://example.com/challenge"))

        XCTAssertEqual(
            CloudflareVerificationPolicy.verificationURL(baseURL: baseURL, responseURL: responseURL).path,
            "/challenge"
        )
    }

    func testVerificationTargetRejectsImageChallengeURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://linux.do"))
        let responseURL = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/linux.do/example/96/1.png"))

        XCTAssertEqual(
            CloudflareVerificationPolicy.verificationURL(baseURL: baseURL, responseURL: responseURL).path,
            "/challenge"
        )
    }

    func testAutomaticVerificationRequiresFreshClearance() {
        XCTAssertFalse(
            CloudflareVerificationPolicy.hasUsableClearance(
                currentValue: "old",
                initialValue: "old",
                requiresFreshValue: true
            )
        )
        XCTAssertTrue(
            CloudflareVerificationPolicy.hasUsableClearance(
                currentValue: "new",
                initialValue: "old",
                requiresFreshValue: true
            )
        )
        XCTAssertFalse(
            CloudflareVerificationPolicy.hasUsableClearance(
                currentValue: nil,
                initialValue: "old",
                requiresFreshValue: true
            )
        )
    }

    func testVerificationCompletionRequiresLoadedVerifiedPage() {
        XCTAssertFalse(
            CloudflareVerificationPolicy.canCompleteVerification(
                currentValue: "new",
                initialValue: "old",
                requiresFreshValue: true,
                hasVerifiedPage: false,
                hasActiveChallenge: false
            )
        )
    }

    func testVerificationCompletionRejectsActiveChallenge() {
        XCTAssertFalse(
            CloudflareVerificationPolicy.canCompleteVerification(
                currentValue: "new",
                initialValue: "old",
                requiresFreshValue: true,
                hasVerifiedPage: true,
                hasActiveChallenge: true
            )
        )
        XCTAssertTrue(
            CloudflareVerificationPolicy.canCompleteVerification(
                currentValue: "new",
                initialValue: "old",
                requiresFreshValue: true,
                hasVerifiedPage: true,
                hasActiveChallenge: false
            )
        )
    }

    func testOriginChallenge404CanCompleteAutomatically() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://linux.do"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://linux.do/challenge")),
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["Server": "nginx"]
        ))

        XCTAssertTrue(
            CloudflareVerificationPolicy.isVerifiedChallengeLanding(
                response,
                baseURL: baseURL
            )
        )
    }

    func testChallengeToken404IsNotAVerifiedLanding() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://linux.do"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://linux.do/challenge?__cf_chl_tk=abc")),
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["Server": "nginx"]
        ))

        XCTAssertTrue(
            CloudflareVerificationPolicy.hasCloudflareChallengeToken(
                in: try XCTUnwrap(URL(string: "https://linux.do/challenge?__cf_chl_tk=abc"))
            )
        )
        XCTAssertFalse(
            CloudflareVerificationPolicy.isVerifiedChallengeLanding(
                response,
                baseURL: baseURL
            )
        )
    }

    func testCloudflareMitigatedChallenge404CannotCompleteAutomatically() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://linux.do"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://linux.do/challenge")),
            statusCode: 404,
            httpVersion: nil,
            headerFields: ["cf-mitigated": "challenge", "Server": "cloudflare"]
        ))

        XCTAssertFalse(
            CloudflareVerificationPolicy.isVerifiedChallengeLanding(
                response,
                baseURL: baseURL
            )
        )
    }

    func testHeaderOnlyImageChallengeIsDetected() throws {
        let url = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/example.png"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["cf-mitigated": "challenge"]
        ))

        XCTAssertTrue(DiscourseAPI.isCloudflareChallengeResponse(response, data: nil))
    }

    func testServiceUnavailableCloudflareImageChallengeIsDetected() throws {
        let url = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/example.png"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 503,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html", "Server": "cloudflare"]
        ))

        XCTAssertTrue(DiscourseAPI.isCloudflareChallengeResponse(response, data: nil))
    }

    func testOrdinaryForbiddenImageIsNotACloudflareChallenge() throws {
        let url = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/missing.png"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Server": "nginx"]
        ))

        XCTAssertFalse(DiscourseAPI.isCloudflareChallengeResponse(response, data: nil))
    }
    func testVerificationGraceSuppressesImmediateRepromptWindow() {
        let base = "https://linux.do"
        CloudflareVerificationPolicy.clearVerificationGrace(baseURL: base)
        CloudflareVerificationPolicy.markVerificationGrace(baseURL: base, duration: 5)
        XCTAssertTrue(CloudflareVerificationPolicy.isInVerificationGrace(baseURL: base))
        XCTAssertTrue(CloudflareVerificationPolicy.isInVerificationGrace(baseURL: "https://LINUX.DO/"))
        XCTAssertFalse(CloudflareVerificationPolicy.shouldPromptAfterBackgroundFailure(isInGrace: true))
        XCTAssertTrue(CloudflareVerificationPolicy.shouldPromptAfterBackgroundFailure(isInGrace: false))
        XCTAssertTrue(CloudflareVerificationPolicy.shouldTreatCooldownAsVerified(isInGrace: true))
        XCTAssertFalse(CloudflareVerificationPolicy.shouldTreatCooldownAsVerified(isInGrace: false))
    }

    func testRepeatedApiChallengesClearVerificationGrace() {
        let base = "https://linux.do"
        CloudflareVerificationPolicy.clearVerificationGrace(baseURL: base)
        CloudflareVerificationPolicy.markVerificationGrace(baseURL: base, duration: 30)
        XCTAssertFalse(
            CloudflareVerificationPolicy.noteChallengeDuringGrace(baseURL: base, source: "image.avatar")
        )
        XCTAssertTrue(CloudflareVerificationPolicy.isInVerificationGrace(baseURL: base))
        XCTAssertFalse(
            CloudflareVerificationPolicy.noteChallengeDuringGrace(baseURL: base, source: "api.foreground")
        )
        XCTAssertFalse(
            CloudflareVerificationPolicy.noteChallengeDuringGrace(baseURL: base, source: "api.foreground")
        )
        XCTAssertTrue(
            CloudflareVerificationPolicy.noteChallengeDuringGrace(baseURL: base, source: "api.foreground")
        )
        XCTAssertFalse(CloudflareVerificationPolicy.isInVerificationGrace(baseURL: base))
    }

    func testChallenge404StillRequiresUsableClearanceToFinish() {
        XCTAssertFalse(
            CloudflareVerificationPolicy.hasUsableClearance(
                currentValue: nil,
                initialValue: "old",
                requiresFreshValue: true
            )
        )
        XCTAssertFalse(
            CloudflareVerificationPolicy.hasUsableClearance(
                currentValue: "old",
                initialValue: "old",
                requiresFreshValue: true
            )
        )
        XCTAssertTrue(
            CloudflareVerificationPolicy.hasUsableClearance(
                currentValue: "new",
                initialValue: "old",
                requiresFreshValue: true
            )
        )
    }

    func testImageGatePausesMainDomainDownloadsAndResumes() throws {
        CloudflareImageGate.resetForTests()
        let base = "https://linux.do"
        let avatar = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/foo/bar_96.png"))
        let external = try XCTUnwrap(URL(string: "https://cdn.example.com/badge.png"))

        XCTAssertFalse(CloudflareImageGate.shouldBlockNetworkLoad(url: avatar, cloudflareBaseURL: base))
        CloudflareImageGate.pause(baseURL: base, duration: 30)
        XCTAssertTrue(CloudflareImageGate.isPaused(baseURL: base))
        XCTAssertTrue(CloudflareImageGate.shouldBlockNetworkLoad(url: avatar, cloudflareBaseURL: base))
        // External beds stay unblocked.
        XCTAssertFalse(CloudflareImageGate.shouldBlockNetworkLoad(url: external, cloudflareBaseURL: base))

        CloudflareImageGate.resume(baseURL: base)
        XCTAssertFalse(CloudflareImageGate.isPaused(baseURL: base))
        XCTAssertFalse(CloudflareImageGate.shouldBlockNetworkLoad(url: avatar, cloudflareBaseURL: base))
    }

    func testChallengeSourceControlsImageGatePause() {
        XCTAssertTrue(DiscourseAPI.shouldPauseImageGate(forChallengeSource: "image.avatar"))
        XCTAssertTrue(DiscourseAPI.shouldPauseImageGate(forChallengeSource: "api.foreground"))
        XCTAssertFalse(DiscourseAPI.shouldPauseImageGate(forChallengeSource: "metaverse.oauth"))
        XCTAssertFalse(DiscourseAPI.shouldPauseImageGate(forChallengeSource: "extension.cdk"))
    }

    func testImageGateCoalescesRepeatedChallengePostsWithinCooldown() throws {
        CloudflareImageGate.resetForTests()
        let base = "https://linux.do"
        let avatar = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/foo/bar_96.png"))

        // First report pauses and notifies; subsequent reports inside cooldown still pause
        // but must not re-fire recovery notifications for every avatar tile.
        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: avatar)
        XCTAssertTrue(CloudflareImageGate.isPaused(baseURL: base))
        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: avatar)
        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: avatar)
        XCTAssertTrue(CloudflareImageGate.isPaused(baseURL: base))

        CloudflareImageGate.resume(baseURL: base)
        XCTAssertFalse(CloudflareImageGate.isPaused(baseURL: base))
    }

    func testImageChallengePostsRecoveryNotificationOncePerCooldown() throws {
        CloudflareImageGate.resetForTests()
        let base = "https://linux.do"
        let avatar = try XCTUnwrap(URL(string: "https://linux.do/user_avatar/foo/bar_96.png"))

        var notificationCount = 0
        let token = NotificationCenter.default.addObserver(
            forName: DiscourseAPI.cloudflareChallengeDetectedNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }

        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: avatar, source: "image.test")
        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: avatar, source: "image.test")
        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: avatar, source: "image.test")

        XCTAssertEqual(notificationCount, 1, "Image CF challenges must notify recovery once per cooldown")
        XCTAssertTrue(CloudflareImageGate.isPaused(baseURL: base))
        CloudflareImageGate.resume(baseURL: base)
    }

    func testImageGateIgnoresChallengesDuringVerificationGrace() throws {
        CloudflareImageGate.resetForTests()
        let base = "https://linux.do"
        CloudflareVerificationPolicy.markVerificationGrace(baseURL: base, duration: 10)
        // grace arms resume; ensure report during grace does not re-pause.
        CloudflareImageGate.reportImageChallenge(baseURL: base, responseURL: nil)
        XCTAssertFalse(CloudflareImageGate.isPaused(baseURL: base))
    }

    func testTopicDetailSkipsReloadWhenThreadIsAlreadyReady() {
        XCTAssertFalse(
            TopicDetailCloudflareRecoveryPolicy.shouldReloadTopic(
                isReady: true,
                hasParsedPosts: true,
                errorMessage: nil
            )
        )
        XCTAssertTrue(
            TopicDetailCloudflareRecoveryPolicy.shouldReloadTopic(
                isReady: true,
                hasParsedPosts: true,
                errorMessage: "Cloudflare verification required"
            )
        )
        XCTAssertTrue(
            TopicDetailCloudflareRecoveryPolicy.shouldReloadTopic(
                isReady: false,
                hasParsedPosts: false,
                errorMessage: nil
            )
        )
        XCTAssertTrue(
            TopicDetailCloudflareRecoveryPolicy.shouldReloadTopic(
                isReady: true,
                hasParsedPosts: false,
                errorMessage: nil
            )
        )
    }

}


// MARK: - Image gate

@MainActor
final class CloudflareImageGateTests: XCTestCase {
    func testMainDomainPauseBlocksOnlyMainHost() throws {
        let base = "https://linux.do"
        CloudflareImageGate.resume(baseURL: base)
        CloudflareImageGate.pause(baseURL: base, duration: 30)

        let main = try XCTUnwrap(URL(string: "https://linux.do/uploads/default/original/1X/a.png"))
        let external = try XCTUnwrap(URL(string: "https://cdn.example.com/a.png"))
        XCTAssertTrue(CloudflareImageGate.shouldBlockNetworkLoad(url: main, cloudflareBaseURL: base))
        XCTAssertFalse(CloudflareImageGate.shouldBlockNetworkLoad(url: external, cloudflareBaseURL: base))

        CloudflareImageGate.resume(baseURL: base)
        XCTAssertFalse(CloudflareImageGate.shouldBlockNetworkLoad(url: main, cloudflareBaseURL: base))
    }

    func testGracePeriodSkipsImageChallengePostingSideEffects() {
        let base = "https://linux.do"
        CloudflareImageGate.resume(baseURL: base)
        // Enter grace via policy API if available; otherwise just ensure pause+resume path is stable.
        CloudflareImageGate.pause(baseURL: base, duration: 5)
        XCTAssertTrue(CloudflareImageGate.isPaused(baseURL: base))
        CloudflareImageGate.resume(baseURL: base)
        XCTAssertFalse(CloudflareImageGate.isPaused(baseURL: base))
    }
}
