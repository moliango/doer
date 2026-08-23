import Alamofire
import DohProxy
import Foundation
import UniformTypeIdentifiers

final class DiscourseAPI {
    static let cloudflareChallengeDetectedNotification = Notification.Name("DiscourseAPI.cloudflareChallengeDetected")
    static let cloudflareVerificationCompletedNotification = Notification.Name("DiscourseAPI.cloudflareVerificationCompleted")
    static let cloudflareBaseURLUserInfoKey = "baseURL"
    static let cloudflareResponseURLUserInfoKey = "responseURL"
    static let cloudflareForegroundGateDuration: TimeInterval = 20
    static let cloudflareForegroundGateLock = NSLock()
    static var cloudflareForegroundGateUntilByBaseURL: [String: Date] = [:]

    let baseURL: String
    let executionContext: DiscourseAPIExecutionContext
    var emojiReady: Bool = false
    let interceptor: DiscourseAuthInterceptor
    let composerUploadClientId = UUID().uuidString.lowercased()

    let sessionLock = NSLock()
    var sessionStorage: Session?
    var sessionSignature = ""
    var retiredSessions: [Session] = []
    var session: Session {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        let service = LightweightDohProxyService.shared
        let signature = service.sessionConfigurationSignature
        if let sessionStorage, sessionSignature == signature {
            return sessionStorage
        }
        let oldSession = sessionStorage
        let newSession = DiscourseAPI.makeSession(baseURL: baseURL, interceptor: interceptor)
        sessionStorage = newSession
        sessionSignature = service.sessionConfigurationSignature
        if let oldSession {
            retainRetiredSession(oldSession)
        }
        return newSession
    }

    init(
        forum: ForumInstance,
        executionContext: DiscourseAPIExecutionContext = .foreground
    ) {
        self.baseURL = forum.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.executionContext = executionContext
        self.interceptor = DiscourseAuthInterceptor(baseURL: baseURL)
    }

    init(
        baseURL: String,
        executionContext: DiscourseAPIExecutionContext = .foreground
    ) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.executionContext = executionContext
        self.interceptor = DiscourseAuthInterceptor(baseURL: self.baseURL)
    }

    func retainRetiredSession(_ session: Session) {
        let id = ObjectIdentifier(session)
        retiredSessions.append(session)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            self.sessionLock.lock()
            defer { self.sessionLock.unlock() }
            self.retiredSessions.removeAll { ObjectIdentifier($0) == id }
        }
    }

    static func makeSession(baseURL: String, interceptor: DiscourseAuthInterceptor) -> Session {
        let config = URLSessionConfiguration.af.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        LightweightDohProxyService.shared.apply(
            to: config,
            hostURL: baseURL,
            preferGateway: true
        )
        let trustManager: ServerTrustManager? = UserDefaults.standard.bool(forKey: "dohEnabled")
            && LocalConnectProxy.shouldMITM(URL(string: baseURL)?.host ?? "")
            ? FluxDoMitmTrustManager.make()
            : nil
        let sessionInterceptor = Interceptor(
            adapters: [interceptor, DohGatewayInterceptor()],
            retriers: [interceptor]
        )
        return Session(
            configuration: config,
            interceptor: sessionInterceptor,
            serverTrustManager: trustManager
        )
    }

    func resetSession() {
        sessionLock.lock()
        let oldSession = sessionStorage
        sessionStorage = nil
        sessionSignature = ""
        if let oldSession {
            retainRetiredSession(oldSession)
        }
        sessionLock.unlock()

        oldSession?.cancelAllRequests()
        interceptor.invalidateCSRFToken()
    }

    func cancelPendingRequests() {
        session.cancelAllRequests()
    }

    static func isExplicitlyCancelledRequest(_ error: Error) -> Bool {
        if let afError = error as? AFError,
           case .explicitlyCancelled = afError {
            return true
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("request explicitly cancelled")
            || message.contains("request explicitly canceled")
            || message.contains("explicitly cancelled")
            || message.contains("explicitly canceled")
    }

    // MARK: - Public API

    // MARK: - Private

    func request<T: Decodable>(
        route: DiscourseRouter,
        parameters: Parameters? = nil,
        headers: HTTPHeaders? = nil,
        encoding: ParameterEncoding? = nil,
        allowAuthRecovery: Bool = true
    ) async throws -> T {
        let response = try await performRequest(
            route: route,
            parameters: parameters,
            headers: headers,
            encoding: encoding,
            allowAuthRecovery: allowAuthRecovery
        )
        do {
            return try JSONDecoder().decode(T.self, from: response.data)
        } catch {
            throw DiscourseDecodingError(
                route: route,
                url: response.url,
                statusCode: response.statusCode,
                underlying: error,
                bodyPreview: Self.bodyPreview(from: response.data)
            )
        }
    }

    func requestVoid(
        route: DiscourseRouter,
        parameters: Parameters? = nil,
        headers: HTTPHeaders? = nil,
        encoding: ParameterEncoding? = nil,
        allowAuthRecovery: Bool = true
    ) async throws {
        _ = try await performRequest(
            route: route,
            parameters: parameters,
            headers: headers,
            encoding: encoding,
            allowAuthRecovery: allowAuthRecovery
        )
    }

    func performRequest(
        route: DiscourseRouter,
        parameters: Parameters? = nil,
        headers: HTTPHeaders? = nil,
        encoding requestedEncoding: ParameterEncoding? = nil,
        allowAuthRecovery: Bool = true
    ) async throws -> RawDiscourseResponse {
        let url = baseURL + route.path
        if executionContext.allowsInteractiveWebRecovery,
           Self.isCloudflareForegroundGateActive(baseURL: baseURL) {
            DohDebugLog.record(
                "request suppressed during active challenge base=\(Self.normalizedCloudflareGateKey(baseURL)) method=\(route.method.rawValue) route=\(route.path)",
                subsystem: "CF"
            )
            throw Self.cloudflareChallengeError()
        }
        let encoding = requestedEncoding ?? (route.method == .post ? JSONEncoding.default : URLEncoding.default)
        let response = await session.request(url, method: route.method, parameters: parameters, encoding: encoding, headers: headers)
            .serializingData(emptyResponseCodes: [200, 201, 202, 204, 205])
            .response

        #if DEBUG
        if let data = response.data, let body = String(data: data, encoding: .utf8) {
            print("[DiscourseAPI] \(route.method.rawValue) \(url)\n\(body)")
        }
        #endif

        if let newToken = response.response?.value(forHTTPHeaderField: "X-CSRF-Token") {
            interceptor.updateCSRFToken(newToken)
        }

        if handleCloudflareChallengeIfNeeded(route: route, response: response) {
            throw Self.cloudflareChallengeError()
        }

        if executionContext.allowsInteractiveWebRecovery,
           allowAuthRecovery,
           await shouldRetryAfterWebSessionRefresh(
               route: route,
               statusCode: response.response?.statusCode,
               error: response.error,
               data: response.data
           ) {
            return try await performRequest(
                route: route,
                parameters: parameters,
                headers: headers,
                encoding: encoding,
                allowAuthRecovery: false
            )
        }

        if let httpResponse = response.response, let url = httpResponse.url,
           shouldMergeWebCookieResponseHeaders(baseURL: baseURL, responseURL: url) {
            WebCookieStore.shared.mergeResponseHeaders(httpResponse.allHeaderFields, for: url)
            if executionContext.allowsInteractiveWebRecovery {
                WebSessionRefreshService.shared.ensureInBackground(baseURL: baseURL, reason: "api_response_cookie")
            }
        }

        if let statusCode = response.response?.statusCode, !(200 ..< 300).contains(statusCode) {
            if statusCode == 429 {
                throw DiscourseAPIError(
                    messages: [String(localized: "error.rate_limited")],
                    errorType: "rate_limited"
                )
            }
            if case .currentUser = route,
               let sessionError = Self.currentUserFailure(statusCode: statusCode, data: response.data) {
                throw sessionError
            }
            if statusCode == 403 {
                throw Self.errorFromForbiddenStatus(data: response.data)
            }
            if let data = response.data {
                if let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data), !errBody.errors.isEmpty {
                    throw DiscourseAPIError(messages: errBody.errors, errorType: errBody.errorType)
                }
                if let failBody = try? JSONDecoder().decode(DiscourseFailedResponse.self, from: data), let message = failBody.message {
                    throw DiscourseAPIError(messages: [message], errorType: failBody.failed)
                }
            }
            throw Self.serverUnavailableError(statusCode: statusCode)
        }

        switch response.result {
        case .success(let data):
            return RawDiscourseResponse(
                data: data,
                url: url,
                statusCode: response.response?.statusCode
            )
        case .failure(let error):
            throw Self.makeDecodingError(
                error,
                route: route,
                url: url,
                statusCode: response.response?.statusCode,
                data: response.data
            )
        }
    }

    func shouldRetryAfterWebSessionRefresh(
        route: DiscourseRouter,
        statusCode: Int?,
        error: AFError?,
        data: Data?
    ) async -> Bool {
        guard let reason = Self.webSessionRefreshRetryReason(
            route: route,
            statusCode: statusCode,
            error: error,
            data: data
        ) else { return false }
        guard let base = URL(string: baseURL),
              WebCookieStore.shared.hasDiscourseWebSessionCookie(for: base)
        else { return false }

        let refreshed = await WebSessionRefreshService.shared.ensureSynced(
            baseURL: baseURL,
            reason: reason,
            force: true
        )
        guard refreshed else { return false }

        interceptor.invalidateCSRFToken()
        DohDebugLog.record(
            "request \(route.method.rawValue) \(route.path) auth failure recovered; retrying once",
            subsystem: "Auth"
        )
        return true
    }

    func handleCloudflareChallengeIfNeeded(
        route: DiscourseRouter,
        response: DataResponse<Data, AFError>,
        source: String? = nil
    ) -> Bool {
        guard let detection = Self.cloudflareChallengeDetection(response.response, data: response.data) else {
            return false
        }
        let shouldNotify = executionContext.allowsInteractiveWebRecovery
        Self.handleCloudflareChallengeDetected(
            baseURL: baseURL,
            responseURL: response.response?.url,
            source: source ?? cloudflareLogSource,
            routePath: route.path,
            method: route.method.rawValue,
            detection: detection,
            shouldNotify: shouldNotify
        )
        return true
    }

    var cloudflareLogSource: String {
        switch executionContext {
        case .foreground:
            return "api.foreground"
        case .backgroundRefresh:
            return "api.background"
        }
    }

    /// `/session/current.json` 401, or 403 with Discourse `not_logged_in` /
    /// `forbidden`, means the server no longer has this session.
    /// Generic `http_403` (often undetected HTML) is left for Cloudflare handling.
    static func currentUserFailure(statusCode: Int, data: Data?) -> DiscourseAPIError? {
        if statusCode == 401 {
            return DiscourseAPIError(
                messages: [String(localized: "login.required.message")],
                errorType: "not_logged_in"
            )
        }
        guard statusCode == 403 else { return nil }
        let error = errorFromForbiddenStatus(data: data)
        if error.isNotLoggedIn || error.isForbidden {
            return DiscourseAPIError(
                messages: [String(localized: "login.required.message")],
                errorType: "not_logged_in"
            )
        }
        return error
    }

    /// 403 is often Cloudflare, CSRF, or a permission check — not logout.
    /// Keep Discourse `error_type` so UI does not treat every 403 as `forbidden`.
    static func errorFromForbiddenStatus(data: Data?) -> DiscourseAPIError {
        if let data, !data.isEmpty,
           let errBody = try? JSONDecoder().decode(DiscourseErrorResponse.self, from: data),
           !errBody.errors.isEmpty {
            let rawType = errBody.errorType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return DiscourseAPIError(
                messages: errBody.errors,
                errorType: rawType.isEmpty ? "forbidden" : rawType
            )
        }
        return DiscourseAPIError(
            messages: [String(format: String(localized: "error.http_status"), 403)],
            errorType: "http_403"
        )
    }

    static func serverUnavailableError(statusCode: Int) -> DiscourseAPIError {
        if (500 ... 599).contains(statusCode) {
            return DiscourseAPIError(
                messages: [String(format: String(localized: "error.server_unavailable"), statusCode)],
                errorType: "server_unavailable"
            )
        }
        return DiscourseAPIError(
            messages: [String(format: String(localized: "error.http_status"), statusCode)],
            errorType: "http_\(statusCode)"
        )
    }

    static func makeDecodingError(
        _ error: AFError,
        route: DiscourseRouter,
        url: String,
        statusCode: Int?,
        data: Data?
    ) -> Error {
        guard case let .responseSerializationFailed(reason) = error,
              case let .decodingFailed(decodingError) = reason
        else {
            if case .currentUser = route,
               case let .responseSerializationFailed(reason) = error,
               case .inputDataNilOrZeroLength = reason {
                return DiscourseAPIError(messages: [String(localized: "login.required.message")], errorType: "not_logged_in")
            }
            return error
        }

        return DiscourseDecodingError(
            route: route,
            url: url,
            statusCode: statusCode,
            underlying: decodingError,
            bodyPreview: data.flatMap(Self.bodyPreview(from:))
        )
    }

    static func isInputDataNilOrZeroLength(_ error: AFError?) -> Bool {
        guard case let .responseSerializationFailed(reason) = error,
              case .inputDataNilOrZeroLength = reason
        else { return false }
        return true
    }

    /// Reasons that should force a web-session refresh before retrying.
    /// Empty 200/204 bodies are Alamofire success (`emptyResponseCodes`) and must not
    /// be treated as logout. Only 401/403, or an empty `/session/current.json` body.
    static func webSessionRefreshRetryReason(
        route: DiscourseRouter,
        statusCode: Int?,
        error: AFError?,
        data: Data?
    ) -> String? {
        if statusCode == 401 || statusCode == 403 {
            return "api_auth_status_\(statusCode ?? 0)"
        }
        let isEmptySerializedBody = isInputDataNilOrZeroLength(error) || data?.isEmpty == true
        if case .currentUser = route, isEmptySerializedBody {
            return "api_empty_auth_response"
        }
        return nil
    }

    static func cloudflareChallengeError() -> DiscourseAPIError {
        DiscourseAPIError(
            messages: [String(localized: "error.cloudflare_challenge")],
            errorType: "cloudflare_challenge"
        )
    }

    static func postCloudflareChallengeDetected(
        baseURL: String,
        responseURL: URL?,
        source: String = "unknown",
        routePath: String? = nil,
        method: String? = nil,
        detection: CloudflareChallengeDetection? = nil
    ) {
        handleCloudflareChallengeDetected(
            baseURL: baseURL,
            responseURL: responseURL,
            source: source,
            routePath: routePath,
            method: method,
            detection: detection,
            shouldNotify: true
        )
    }

    static func handleCloudflareChallengeDetected(
        baseURL: String,
        responseURL: URL?,
        source: String,
        routePath: String?,
        method: String?,
        detection: CloudflareChallengeDetection?,
        shouldNotify: Bool
    ) {
        let hasClearance = URL(string: baseURL).map {
            WebCookieStore.shared.hasCookie(named: "cf_clearance", for: $0)
        } ?? false
        var details = [
            "source=\(source)",
            "base=\(baseURL)",
            "hasClearance=\(hasClearance)",
            "notify=\(shouldNotify)",
        ]
        if let method {
            details.append("method=\(method)")
        }
        if let routePath {
            details.append("route=\(routePath)")
        }
        if let detection {
            details.append(detection.logSummary)
        } else {
            details.append("response=\(responseURL?.absoluteString ?? "none")")
            details.append("reason=unspecified")
        }

        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL) {
            if CloudflareVerificationPolicy.noteChallengeDuringGrace(baseURL: baseURL, source: source) {
                DohDebugLog.record(
                    "challenge broke verification grace \(details.joined(separator: " "))",
                    subsystem: "CF"
                )
            } else {
                DohDebugLog.record(
                    "challenge ignored during grace \(details.joined(separator: " "))",
                    subsystem: "CF"
                )
                return
            }
        }
        // Only pause the image pipeline for image/API forum traffic.
        // metaverse.oauth (cdk/credit.linux.do) is a separate CF zone — pausing it
        // used to spam "image gate pause" logs and did not help OAuth recovery.
        if Self.shouldPauseImageGate(forChallengeSource: source) {
            CloudflareImageGate.pause(baseURL: baseURL)
        }
        if shouldNotify {
            markCloudflareForegroundGate(baseURL: baseURL)
        }
        DohDebugLog.record(
            "challenge detected \(details.joined(separator: " "))",
            subsystem: "CF"
        )
        guard shouldNotify else { return }
        var userInfo: [String: Any] = [
            cloudflareBaseURLUserInfoKey: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        ]
        if let responseURL {
            userInfo[cloudflareResponseURLUserInfoKey] = responseURL
        }
        NotificationCenter.default.post(
            name: cloudflareChallengeDetectedNotification,
            object: nil,
            userInfo: userInfo
        )
    }

    /// Image gate is for forum avatar/upload storms — not extension OAuth hosts
    /// and not best-effort background POSTs (timings) that CF often challenges
    /// without meaning the cookie jar is dead.
    nonisolated static func shouldPauseImageGate(forChallengeSource source: String) -> Bool {
        // Background / non-critical API must never freeze avatars for 60s.
        if source == "api.topicTimings" || source.hasPrefix("api.background.") {
            return false
        }
        if source.hasPrefix("image.") { return true }
        // Real forum API challenges (topic/list/user) can pause images.
        if source.hasPrefix("api.") { return true }
        // Explicit non-image sources that must not touch the image gate.
        if source.hasPrefix("metaverse.") { return false }
        if source.hasPrefix("extension.") { return false }
        return false
    }

    static func clearCloudflareForegroundGate(baseURL: String) {
        let key = normalizedCloudflareGateKey(baseURL)
        cloudflareForegroundGateLock.lock()
        cloudflareForegroundGateUntilByBaseURL.removeValue(forKey: key)
        cloudflareForegroundGateLock.unlock()
        DohDebugLog.record("foreground challenge gate cleared base=\(key)", subsystem: "CF")
    }

    static func markCloudflareForegroundGate(baseURL: String) {
        let key = normalizedCloudflareGateKey(baseURL)
        let until = Date().addingTimeInterval(cloudflareForegroundGateDuration)
        cloudflareForegroundGateLock.lock()
        cloudflareForegroundGateUntilByBaseURL[key] = until
        cloudflareForegroundGateLock.unlock()
        DohDebugLog.record(
            "foreground challenge gate armed base=\(key) duration=\(Int(cloudflareForegroundGateDuration))s",
            subsystem: "CF"
        )
    }

    static func isCloudflareForegroundGateActive(baseURL: String, now: Date = Date()) -> Bool {
        let key = normalizedCloudflareGateKey(baseURL)
        cloudflareForegroundGateLock.lock()
        defer { cloudflareForegroundGateLock.unlock() }
        guard let until = cloudflareForegroundGateUntilByBaseURL[key] else { return false }
        if now < until {
            return true
        }
        cloudflareForegroundGateUntilByBaseURL.removeValue(forKey: key)
        return false
    }

    static func normalizedCloudflareGateKey(_ baseURL: String) -> String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    nonisolated static func isCloudflareChallengeResponse(_ response: HTTPURLResponse?, data: Data?) -> Bool {
        cloudflareChallengeDetection(response, data: data) != nil
    }

    nonisolated static func cloudflareChallengeDetection(
        _ response: HTTPURLResponse?,
        data: Data?
    ) -> CloudflareChallengeDetection? {
        let cfMitigated = headerValue("cf-mitigated", in: response)
        if cfMitigated?.localizedCaseInsensitiveContains("challenge") == true {
            return CloudflareChallengeDetection(
                statusCode: response?.statusCode,
                responseURL: response?.url,
                server: headerValue("server", in: response),
                cfMitigated: cfMitigated,
                contentType: headerValue("content-type", in: response),
                reason: "header:cf-mitigated"
            )
        }

        let statusCode = response?.statusCode
        let server = headerValue("server", in: response)?.lowercased() ?? ""
        let contentType = headerValue("content-type", in: response)?.lowercased() ?? ""
        if (statusCode == 403 || statusCode == 429 || statusCode == 503),
           server.contains("cloudflare"),
           contentType.contains("text/html") {
            return CloudflareChallengeDetection(
                statusCode: statusCode,
                responseURL: response?.url,
                server: headerValue("server", in: response),
                cfMitigated: cfMitigated,
                contentType: headerValue("content-type", in: response),
                reason: "status-cloudflare-html"
            )
        }

        guard let body = data.flatMap({ String(data: $0, encoding: .utf8) }) else {
            return nil
        }
        let lowerBody = body.lowercased()
        let bodyMarker = cloudflareBodyMarker(in: lowerBody)

        guard let bodyMarker else { return nil }

        guard server.contains("cloudflare")
            || contentType.contains("text/html")
            || lowerBody.contains("cloudflare")
        else {
            return nil
        }

        return CloudflareChallengeDetection(
            statusCode: statusCode,
            responseURL: response?.url,
            server: headerValue("server", in: response),
            cfMitigated: cfMitigated,
            contentType: headerValue("content-type", in: response),
            reason: "body:\(bodyMarker)"
        )
    }

    nonisolated private static func cloudflareBodyMarker(in lowerBody: String) -> String? {
        if lowerBody.contains("cf_chl_opt") {
            return "cf_chl_opt"
        }
        if lowerBody.contains("challenge-platform") {
            return "challenge-platform"
        }
        if lowerBody.contains("cf-turnstile") {
            return "cf-turnstile"
        }
        if lowerBody.contains("challenge-running") {
            return "challenge-running"
        }
        if lowerBody.contains("just a moment") && lowerBody.contains("cloudflare") {
            return "just-a-moment"
        }
        return nil
    }

    nonisolated private static func headerValue(_ name: String, in response: HTTPURLResponse?) -> String? {
        guard let response else { return nil }
        for (key, value) in response.allHeaderFields {
            guard "\(key)".caseInsensitiveCompare(name) == .orderedSame else { continue }
            return "\(value)"
        }
        return nil
    }

    nonisolated static func bodyPreview(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let maxLength = 800
        let previewData = data.prefix(maxLength)
        guard var preview = String(data: previewData, encoding: .utf8) else { return nil }
        preview = preview.replacingOccurrences(of: "\n", with: " ")
        if data.count > maxLength {
            preview += "..."
        }
        return preview
    }
}
