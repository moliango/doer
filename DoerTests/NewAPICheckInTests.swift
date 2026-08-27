import XCTest
@testable import Doer

@MainActor
final class NewAPICheckInTests: XCTestCase {
    func testStoreIsScopedAndKeepsCredentialsOutOfJSON() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryNewAPICredentialVault()
        let samStore = NewAPICheckInStore(
            scope: PluginScope(baseURL: "HTTPS://LINUX.DO/", username: "Sam"),
            directoryURL: directory,
            credentialVault: vault
        )
        let alexStore = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "alex"),
            directoryURL: directory,
            credentialVault: vault
        )
        let platform = NewAPICheckInPlatform(name: "Example", baseURL: "https://api.example.com")
        let credential = NewAPICheckInCredential(
            accessToken: "secret-token",
            userID: "42",
            cookieHeader: "session=secret-cookie"
        )

        try await samStore.save(platform, credential: credential)

        let samPlatforms = await samStore.platforms()
        let alexPlatforms = await alexStore.platforms()
        let storedCredential = try await samStore.credential(for: platform.id)
        XCTAssertEqual(samPlatforms.map(\.id), [platform.id])
        XCTAssertTrue(alexPlatforms.isEmpty)
        XCTAssertEqual(storedCredential, credential)

        let data = try Data(contentsOf: NewAPICheckInStore.storageURL(in: directory))
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(raw.contains("secret-token"))
        XCTAssertFalse(raw.contains("secret-cookie"))
    }

    func testPlatformReloginBeforeSignInRoundTripsAndDefaultsOffForLegacyData() throws {
        let platform = NewAPICheckInPlatform(
            name: "Example",
            baseURL: "https://api.example.com",
            reloginBeforeSignIn: true
        )
        let encoded = try JSONEncoder().encode(platform)
        let decoded = try JSONDecoder().decode(NewAPICheckInPlatform.self, from: encoded)
        XCTAssertTrue(decoded.requiresReloginBeforeSignIn)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "reloginBeforeSignIn")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(NewAPICheckInPlatform.self, from: legacyData)
        XCTAssertNil(legacy.reloginBeforeSignIn)
        XCTAssertFalse(legacy.requiresReloginBeforeSignIn)
    }

    func testServiceBuildsAuthenticatedRequestClassifiesAndPersistsResult() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryNewAPICredentialVault()
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: vault
        )
        let platform = NewAPICheckInPlatform(name: "Example", baseURL: "https://api.example.com")
        try await store.save(
            platform,
            credential: NewAPICheckInCredential(
                accessToken: "token-value",
                userID: "7",
                cookieHeader: "session=cookie-value"
            )
        )

        MockNewAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/user/checkin")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-value")
            XCTAssertEqual(request.value(forHTTPHeaderField: "New-Api-User"), "7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=cookie-value")
            let body = Data(#"{"success":true,"message":"签到成功","data":{"quota":1000000}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(store: store, session: URLSession(configuration: configuration))

        let result = await service.signIn(platform)
        let attempts = await store.attempts()
        let storedPlatforms = await store.platforms()

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.quotaValue, 1_000_000)
        XCTAssertEqual(attempts.first?.status, .success)
        XCTAssertEqual(storedPlatforms.first?.lastQuotaValue, 1_000_000)
    }

    func testRefreshAuthenticationRotatesTokenAndCookie() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        let platform = NewAPICheckInPlatform(name: "Example", baseURL: "https://api.example.com")
        try await store.save(
            platform,
            credential: NewAPICheckInCredential(
                accessToken: "old-token",
                userID: "7",
                cookieHeader: "theme=dark; new_api_refresh=session.stored-secret"
            )
        )

        MockNewAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/user/auth/refresh")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://api.example.com")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                "theme=light; new_api_refresh=session.webview-secret"
            )
            let headers = [
                "Set-Cookie": "new_api_refresh=session.new-secret; Path=/; HttpOnly; Secure; SameSite=Lax",
            ]
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: headers
            )!
            let body = Data(#"{"success":true,"data":{"access_token":"new-token","user":{"id":42}}}"#.utf8)
            return (response, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(
            store: store,
            session: URLSession(configuration: configuration)
        )

        let result = await service.refreshAuthentication(
            platform,
            cookieHeaderOverride: "theme=light; new_api_refresh=session.webview-secret"
        )
        let credential = try await store.credential(for: platform.id)
        XCTAssertTrue(result.isRefreshed)
        XCTAssertEqual(credential?.accessToken, "new-token")
        XCTAssertEqual(credential?.userID, "42")
        XCTAssertEqual(
            credential?.cookieHeader,
            "theme=light; new_api_refresh=session.new-secret"
        )
    }

    func testNonInteractiveBatchRefreshesBeforeSignIn() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        let platform = NewAPICheckInPlatform(
            name: "Example",
            baseURL: "https://api.example.com",
            reloginBeforeSignIn: true
        )
        try await store.save(
            platform,
            credential: NewAPICheckInCredential(
                accessToken: "expired-token",
                userID: "7",
                cookieHeader: "new_api_refresh=session.old-secret"
            )
        )

        MockNewAPIURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/user/auth/refresh":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Set-Cookie": "new_api_refresh=session.new-secret; Path=/; HttpOnly; Secure"]
                )!
                let body = Data(#"{"success":true,"data":{"access_token":"new-token","user":{"id":7}}}"#.utf8)
                return (response, body)
            case "/api/user/checkin":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "new_api_refresh=session.new-secret")
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data(#"{"success":true,"message":"签到成功"}"#.utf8))
            default:
                throw URLError(.badURL)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(
            store: store,
            session: URLSession(configuration: configuration)
        )

        let summary = await service.signInAll()
        XCTAssertEqual(summary.success, 1)
        XCTAssertEqual(summary.authenticationExpired, 0)
    }

    func testRefreshAuthenticationTreatsMissingEndpointAsUnavailable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        let platform = NewAPICheckInPlatform(name: "Legacy", baseURL: "https://legacy.example.com")
        let original = NewAPICheckInCredential(
            accessToken: "legacy-token",
            userID: "8",
            cookieHeader: "new_api_refresh=legacy-cookie"
        )
        try await store.save(platform, credential: original)

        MockNewAPIURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(
            store: store,
            session: URLSession(configuration: configuration)
        )

        let result = await service.refreshAuthentication(platform)
        let credential = try await store.credential(for: platform.id)
        guard case .unavailable = result else {
            XCTFail("Expected an unavailable refresh endpoint")
            return
        }
        XCTAssertEqual(credential, original)
    }

    func testNonInteractiveBatchDoesNotBypassRequiredRelogin() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        let platform = NewAPICheckInPlatform(
            name: "Example",
            baseURL: "https://api.example.com",
            reloginBeforeSignIn: true
        )
        try await store.save(platform)

        MockNewAPIURLProtocol.handler = { request in
            XCTFail("Non-interactive batch must not call \(request.url?.absoluteString ?? "the sign-in API")")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(
            store: store,
            session: URLSession(configuration: configuration)
        )

        let summary = await service.signInAll()
        let attempts = await store.attempts(platformID: platform.id)
        XCTAssertEqual(summary.authenticationExpired, 1)
        XCTAssertEqual(attempts.first?.status, .authenticationExpired)
    }

    func testTokenWithoutRefreshCookieStillSignsInWhenReloginBeforeSignInIsOn() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        let platform = NewAPICheckInPlatform(
            name: "Example",
            baseURL: "https://api.example.com",
            reloginBeforeSignIn: true
        )
        try await store.save(
            platform,
            credential: NewAPICheckInCredential(accessToken: "session-token", userID: "7")
        )

        MockNewAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/user/checkin")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"success":true,"message":"签到成功"}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(
            store: store,
            session: URLSession(configuration: configuration)
        )

        let needsRelogin = await service.needsInteractiveRelogin(for: platform)
        XCTAssertFalse(needsRelogin)
        let summary = await service.signInAll()
        XCTAssertEqual(summary.success, 1)
        XCTAssertEqual(summary.authenticationExpired, 0)
    }

    func testQuotaRefreshDoesNotRestoreDisabledReloginBeforeSignIn() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        var platform = NewAPICheckInPlatform(
            name: "Example",
            baseURL: "https://api.example.com",
            reloginBeforeSignIn: true
        )
        try await store.save(
            platform,
            credential: NewAPICheckInCredential(accessToken: "token", userID: "7")
        )
        platform.reloginBeforeSignIn = false
        try await store.save(platform)

        let stale = NewAPICheckInPlatform(
            id: platform.id,
            name: platform.name,
            baseURL: platform.baseURL,
            reloginBeforeSignIn: true
        )
        MockNewAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/user/self")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(#"{"success":true,"data":{"quota":1000,"used_quota":10,"request_count":3}}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(
            store: store,
            session: URLSession(configuration: configuration)
        )

        _ = await service.refreshAccount(stale)
        let platforms = await store.platforms()
        let stored = try XCTUnwrap(platforms.first)
        XCTAssertFalse(stored.requiresReloginBeforeSignIn)
        XCTAssertEqual(stored.lastQuotaValue, 1000)
    }

    func testRefreshResultDoesNotForceLoginWhenSessionAlreadyExists() {
        XCTAssertFalse(
            NewAPICheckInAuthRefreshResult.unavailable.requiresInteractiveLogin(hasUsableCredential: true)
        )
        XCTAssertTrue(
            NewAPICheckInAuthRefreshResult.unavailable.requiresInteractiveLogin(hasUsableCredential: false)
        )
        XCTAssertTrue(
            NewAPICheckInAuthRefreshResult.rejected("expired").requiresInteractiveLogin(hasUsableCredential: true)
        )
        XCTAssertFalse(
            NewAPICheckInAuthRefreshResult.refreshed.requiresInteractiveLogin(hasUsableCredential: false)
        )
    }

    func testResponseClassificationRecognizesAlreadySignedAndExpiredAuthentication() {
        let already = NewAPICheckInService.classify(
            data: Data(#"{"success":false,"message":"今日已签到"}"#.utf8),
            statusCode: 200,
            durationMilliseconds: 1
        )
        let expired = NewAPICheckInService.classify(
            data: Data(#"{"message":"请先登录"}"#.utf8),
            statusCode: 200,
            durationMilliseconds: 1
        )

        XCTAssertEqual(already.status, .alreadySigned)
        XCTAssertEqual(expired.status, .authenticationExpired)
    }

    func testLoginSupportExtractsLocalStorageHintsAndCookieHeader() throws {
        let hints = NewAPICheckInLoginSupport.parseLocalStorageResult(
            #"{"id":"42","accessToken":"token-value"}"#
        )
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "session",
            .value: "cookie-value",
            .domain: ".example.com",
            .path: "/",
            .secure: "TRUE",
        ]))
        let unrelated = try XCTUnwrap(HTTPCookie(properties: [
            .name: "other",
            .value: "ignored",
            .domain: ".unrelated.test",
            .path: "/",
        ]))
        let baseURL = try XCTUnwrap(URL(string: "https://api.example.com"))
        let header = NewAPICheckInLoginSupport.cookieHeader(
            from: [unrelated, cookie],
            baseURL: baseURL,
            currentURL: URL(string: "https://oauth.unrelated.test/login")
        )

        XCTAssertEqual(hints, NewAPICheckInLoginHints(userID: "42", accessToken: "token-value"))
        XCTAssertEqual(header, "session=cookie-value")
    }

    func testWebLoginURLNormalizationKeepsLoginPathAndQuery() {
        let url = NewAPICheckInLoginSupport.normalizedLoginURL(
            "  api.example.com/oauth/start?tenant=doer#login  "
        )

        XCTAssertEqual(url?.absoluteString, "https://api.example.com/oauth/start?tenant=doer#login")
    }

    func testLocalStorageIdentityCompletesLoginOnlyWithTargetCookie() {
        let hints = NewAPICheckInLoginHints(userID: "42", accessToken: nil)

        XCTAssertTrue(NewAPICheckInLoginSupport.hasValidLoginEvidence(
            apiLoggedIn: false,
            hints: hints,
            hasTargetCookies: true
        ))
        XCTAssertFalse(NewAPICheckInLoginSupport.hasValidLoginEvidence(
            apiLoggedIn: false,
            hints: hints,
            hasTargetCookies: false
        ))
        XCTAssertTrue(NewAPICheckInLoginSupport.hasValidLoginEvidence(
            apiLoggedIn: true,
            hints: NewAPICheckInLoginHints(userID: nil, accessToken: nil),
            hasTargetCookies: false
        ))
    }

    func testLoginProbeUsesHintsAndParsesServerCredentials() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: MemoryNewAPICredentialVault()
        )
        MockNewAPIURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/api/user/self")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "New-Api-User"), "7")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=cookie")
            let data = Data(#"{"success":true,"data":{"id":8,"access_token":"server-token","quota":500000}}"#.utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockNewAPIURLProtocol.self]
        let service = NewAPICheckInService(store: store, session: URLSession(configuration: configuration))

        let result = await service.probeLogin(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.com")),
            cookieHeader: "session=cookie",
            hints: NewAPICheckInLoginHints(userID: "7", accessToken: "local-token")
        )

        XCTAssertTrue(result.isLoggedIn)
        XCTAssertEqual(result.userID, "8")
        XCTAssertEqual(result.accessToken, "server-token")
        XCTAssertEqual(result.quotaValue, 500_000)
    }

    func testCurlParserParsesBrowserCopiedRequest() throws {
        let command = #"""
        curl 'https://api.example.com/api/user/checkin?source=ios' \
          -X put \
          -H 'New-Api-User: 42' \
          -H 'Content-Type: application/json' \
          -H 'Cookie: session=abc; theme=dark' \
          --data-raw '{"message":"it'\''s ready","enabled":true}'
        """#

        let request = try NewAPICurlParser.parse(command)

        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/api/user/checkin?source=ios")
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.headers["New-Api-User"], "42")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Cookie"], "session=abc; theme=dark")
        XCTAssertEqual(request.body, #"{"message":"it's ready","enabled":true}"#)
    }

    func testCurlParserInfersMethodAndHandlesWindowsLineContinuations() throws {
        let command = "curl --location \"https://api.example.com/checkin\" \\\r\n  --data-binary \"{\\\"value\\\":\\\"a b\\\"}\""

        let request = try NewAPICurlParser.parse(command)

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.body, #"{"value":"a b"}"#)
    }

    func testCurlParserNormalizesCookieFlagWithoutOverwritingCookieHeader() throws {
        let request = try NewAPICurlParser.parse(
            "curl https://api.example.com -b 'session=from-flag' -H 'cookie: session=from-header'"
        )

        XCTAssertEqual(request.headers.count, 1)
        XCTAssertEqual(request.headers["cookie"], "session=from-header")
    }

    func testCurlParserSupportsLongOptionsWithEquals() throws {
        let request = try NewAPICurlParser.parse(
            "curl --request=PATCH --header='X-Mode: full sync' --data='{}' https://api.example.com/checkin"
        )

        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.headers["X-Mode"], "full sync")
        XCTAssertEqual(request.body, "{}")
    }

    func testCurlParserRejectsMissingAndNonHTTPURLs() {
        XCTAssertThrowsError(try NewAPICurlParser.parse("curl -X POST")) { error in
            XCTAssertEqual(error as? NewAPICurlParseError, .missingURL)
        }
        XCTAssertThrowsError(try NewAPICurlParser.parse("curl file:///tmp/token")) { error in
            XCTAssertEqual(error as? NewAPICurlParseError, .invalidURL("file:///tmp/token"))
        }
        XCTAssertThrowsError(try NewAPICurlParser.parse("curl 'https://api.example.com")) { error in
            XCTAssertEqual(error as? NewAPICurlParseError, .malformed("unterminated single quote"))
        }
    }

    func testExportPayloadRoundTripsPlatformsCredentialsAndCustomPages() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryNewAPICredentialVault()
        let scope = PluginScope(baseURL: "https://linux.do", username: "sam")
        let store = NewAPICheckInStore(
            scope: scope,
            directoryURL: directory,
            credentialVault: vault
        )
        let platform = NewAPICheckInPlatform(name: "Example", baseURL: "https://api.example.com")
        let credential = NewAPICheckInCredential(
            accessToken: "export-token",
            userID: "9",
            cookieHeader: "session=export-cookie",
            additionalHeaders: ["X-Test": "1"]
        )
        let page = NewAPICheckInCustomPage(name: "Docs", urlString: "https://docs.example.com")
        try await store.save(platform, credential: credential)

        let exported = try NewAPICheckInStore.makeExportPayload(
            directoryURL: directory,
            credentialVault: vault,
            customPages: [page]
        )
        XCTAssertEqual(exported.accounts.count, 1)
        XCTAssertEqual(exported.accounts.first?.platforms.map(\.id), [platform.id])
        XCTAssertEqual(exported.accounts.first?.credentials[platform.id.uuidString], credential)
        XCTAssertEqual(exported.customPages, [page])

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("newapi-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let importVault = MemoryNewAPICredentialVault()
        let suite = UserDefaults(suiteName: "NewAPICustomPages.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.dictionaryRepresentation().keys.first ?? "") }
        let pagesStore = NewAPICheckInCustomPageStore(defaults: suite)
        try NewAPICheckInStore.importExportPayload(
            exported,
            directoryURL: destination,
            credentialVault: importVault,
            customPagesStore: pagesStore
        )

        let importedStore = NewAPICheckInStore(
            scope: scope,
            directoryURL: destination,
            credentialVault: importVault
        )
        let platforms = await importedStore.platforms()
        let restored = try await importedStore.credential(for: platform.id)
        XCTAssertEqual(platforms.map(\.id), [platform.id])
        XCTAssertEqual(restored, credential)
        XCTAssertEqual(pagesStore.all().map(\.urlString), [page.urlString])
    }

    func testClearingAttemptsKeepsPlatformsAndCredentials() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = MemoryNewAPICredentialVault()
        let store = NewAPICheckInStore(
            scope: PluginScope(baseURL: "https://linux.do", username: "sam"),
            directoryURL: directory,
            credentialVault: vault
        )
        let platform = NewAPICheckInPlatform(name: "Example", baseURL: "https://api.example.com")
        try await store.save(platform, credential: NewAPICheckInCredential(accessToken: "token"))
        try await store.record(
            NewAPICheckInResult(
                status: .success,
                statusCode: 200,
                message: "ok",
                rawResponse: "{}",
                durationMilliseconds: 10,
                quotaValue: nil,
                quotaUnit: nil
            ),
            for: platform.id
        )

        try await store.clearAttempts()

        let attempts = await store.attempts()
        let platformIDs = await store.platforms().map(\.id)
        let storedCredential = try await store.credential(for: platform.id)
        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(platformIDs, [platform.id])
        XCTAssertEqual(storedCredential?.accessToken, "token")
    }

    func testSiteOriginStripsPathQueryAndFragment() {
        let url = URL(string: "https://ai.example.com/login?next=/app#hash")!
        let origin = NewAPICheckInLoginSupport.siteOrigin(from: url)
        XCTAssertEqual(origin?.scheme, "https")
        XCTAssertEqual(origin?.host, "ai.example.com")
        XCTAssertTrue(origin?.path.isEmpty == true || origin?.path == "/")
        XCTAssertNil(origin?.query)
        XCTAssertNil(origin?.fragment)
    }

    func testMatchingPlatformUsesHostFamily() {
        let platforms = [
            NewAPICheckInPlatform(name: "API", baseURL: "https://ai.example.com"),
        ]
        let page = URL(string: "https://ai.example.com/console/token")!
        XCTAssertEqual(
            NewAPICheckInLoginSupport.matchingPlatform(in: platforms, url: page)?.name,
            "API"
        )
        let other = URL(string: "https://other.example.com/")!
        XCTAssertNil(NewAPICheckInLoginSupport.matchingPlatform(in: platforms, url: other))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("newapi-checkin-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class MemoryNewAPICredentialVault: NewAPICheckInCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    nonisolated func data(for key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    nonisolated func setData(_ data: Data, for key: String) throws {
        lock.lock()
        values[key] = data
        lock.unlock()
    }

    nonisolated func removeData(for key: String) throws {
        lock.lock()
        values.removeValue(forKey: key)
        lock.unlock()
    }
}

private final class MockNewAPIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request) ?? {
                throw URLError(.badServerResponse)
            }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
