import Alamofire
import Foundation
import UniformTypeIdentifiers


extension KeyedDecodingContainer {
    func decodeLossyAPIInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

// MARK: - Error Handling

struct DiscourseDecodingError: LocalizedError {
    let route: DiscourseRouter
    let url: String
    let statusCode: Int?
    let underlying: Error
    let bodyPreview: String?

    var errorDescription: String? {
        var parts = [
            "Response could not be decoded.",
            "Route: \(route)",
            "URL: \(url)",
        ]
        if let statusCode {
            parts.append("HTTP: \(statusCode)")
        }
        parts.append("Decode: \(Self.describe(underlying))")
        if let bodyPreview {
            parts.append("Body: \(bodyPreview)")
        }
        return parts.joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .typeMismatch(let type, let context):
            return "typeMismatch(\(type)) at \(path(context.codingPath)): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "valueNotFound(\(type)) at \(path(context.codingPath)): \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            let fullPath = path(context.codingPath + [key])
            return "keyNotFound(\(fullPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "dataCorrupted at \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        let value = codingPath.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }
}

struct DiscourseErrorResponse: Decodable {
    let errors: [String]
    let errorType: String?

    enum CodingKeys: String, CodingKey {
        case errors
        case errorType = "error_type"
    }
}

struct DiscourseFailedResponse: Decodable {
    let failed: String?
    let message: String?
}

struct RawDiscourseResponse {
    let data: Data
    let url: String
    let statusCode: Int?
}

struct DiscourseAPIError: LocalizedError {
    let messages: [String]
    let errorType: String?

    var isNotLoggedIn: Bool {
        errorType == "not_logged_in"
    }

    var isForbidden: Bool {
        errorType == "forbidden"
    }

    var isRateLimited: Bool {
        errorType == "rate_limited"
    }

    var isCloudflareChallenge: Bool {
        errorType == "cloudflare_challenge"
    }

    var errorDescription: String? {
        messages.joined(separator: "\n")
    }
}

// MARK: - Auth Interceptor

final class DiscourseAuthInterceptor: RequestInterceptor {
    let baseURL: String
    nonisolated(unsafe) private var csrfToken: String?
    nonisolated(unsafe) private var isFetchingCSRF = false
    nonisolated(unsafe) private var csrfWaiters: [(String?) -> Void] = []
    private let csrfLock = NSLock()
    private let authLogLock = NSLock()
    nonisolated(unsafe) private var loggedAuthSignatures = Set<String>()

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    func adapt(_ urlRequest: URLRequest, for session: Session, completion: @escaping (Result<URLRequest, Error>) -> Void) {
        var request = urlRequest
        if let url = request.url {
            let authMode = discourseRequestAuthMode(baseURL: baseURL, url: url)
            switch authMode {
            case .webCookie:
                applyWebCookieHeaders(to: &request, url: url)
                logAuthMode(authMode, url: url, request: request)
                if isMutating(request) {
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    if request.value(forHTTPHeaderField: "Content-Type") == nil {
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    getOrFetchCSRFToken(session: session) { token in
                        if let token {
                            request.setValue(token, forHTTPHeaderField: "X-CSRF-Token")
                        }
                        completion(.success(request))
                    }
                    return
                }
            case .cloudflareOnly:
                applyCloudflareCookieHeaders(to: &request, url: url)
                logAuthMode(authMode, url: url, request: request)
            case .none:
                logAuthMode(authMode, url: url, request: request)
            }
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        completion(.success(request))
    }

    func retry(_ request: Request, for session: Session, dueTo error: any Error, completion: @escaping (RetryResult) -> Void) {
        guard request.retryCount == 0,
              let httpMethod = request.request?.httpMethod,
              (httpMethod == "POST" || httpMethod == "PUT" || httpMethod == "DELETE"),
              let url = request.request?.url,
              discourseRequestAuthMode(baseURL: baseURL, url: url) == .webCookie
        else {
            completion(.doNotRetry)
            return
        }
        // Retry on 403/422 (CSRF token invalid or expired)
        let statusCode = request.response?.statusCode
        guard statusCode == 403 || statusCode == 422 || statusCode == nil else {
            completion(.doNotRetry)
            return
        }
        // Invalidate token so next getOrFetchCSRFToken will fetch fresh one.
        // If another retry already reset and is fetching, we just join the waiters.
        csrfLock.lock()
        let wasAlreadyInvalidated = csrfToken == nil
        csrfToken = nil
        if wasAlreadyInvalidated {
            // Another retry already invalidated — just wait for its fetch
            csrfLock.unlock()
        } else {
            // We are the first to invalidate — reset fetch state so a fresh fetch starts
            isFetchingCSRF = false
            csrfWaiters = []
            csrfLock.unlock()
        }
        getOrFetchCSRFToken(session: session) { token in
            completion(token != nil ? .retry : .doNotRetry)
        }
    }

    func isMutating(_ request: URLRequest) -> Bool {
        request.httpMethod == "POST" || request.httpMethod == "PUT" || request.httpMethod == "DELETE"
    }

    func applyWebCookieHeaders(to request: inout URLRequest, url: URL) {
        let header = WebCookieStore.shared.cookieHeader(for: url)
        if !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        if let userAgent = WebCookieStore.shared.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
    }

    func applyCloudflareCookieHeaders(to request: inout URLRequest, url: URL) {
        let cfCookieHeader = WebCookieStore.shared.cookieHeader(for: url, names: ["cf_clearance"])
        if !cfCookieHeader.isEmpty {
            request.setValue(cfCookieHeader, forHTTPHeaderField: "Cookie")
            if let userAgent = WebCookieStore.shared.userAgent {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
        }
    }

    func logAuthMode(
        _ authMode: DiscourseRequestAuthMode,
        url: URL,
        request: URLRequest
    ) {
        let method = request.httpMethod ?? "GET"
        let path = url.path.isEmpty ? "/" : url.path
        let cookieNames = WebCookieStore.shared.cookieNames(for: url)
        let cookiesText = cookieNames.isEmpty ? "none" : cookieNames.joined(separator: ",")
        let signature = "\(method) \(path) \(authMode.rawValue) \(cookiesText)"

        authLogLock.lock()
        if loggedAuthSignatures.count > 120 {
            loggedAuthSignatures.removeAll()
        }
        let shouldLog = loggedAuthSignatures.insert(signature).inserted
        authLogLock.unlock()

        guard shouldLog else { return }
        DohDebugLog.record(
            "request \(method) \(path) authMode=\(authMode.rawValue) cookies=\(cookiesText)",
            subsystem: "Auth"
        )
    }

    /// Returns cached CSRF token if available, otherwise fetches one.
    /// Concurrent callers wait for a single in-flight fetch to complete.
    func getOrFetchCSRFToken(session: Session, completion: @escaping (String?) -> Void) {
        csrfLock.lock()
        if let token = csrfToken {
            csrfLock.unlock()
            completion(token)
            return
        }
        csrfWaiters.append(completion)
        let alreadyFetching = isFetchingCSRF
        isFetchingCSRF = true
        csrfLock.unlock()
        guard !alreadyFetching else { return }
        fetchCSRFToken(session: session) { [weak self] token in
            guard let self else { return }
            self.csrfLock.lock()
            self.csrfToken = token
            self.isFetchingCSRF = false
            let waiters = self.csrfWaiters
            self.csrfWaiters = []
            self.csrfLock.unlock()
            waiters.forEach { $0(token) }
        }
    }

    func invalidateCSRFToken() {
        csrfLock.lock()
        csrfToken = nil
        csrfLock.unlock()
    }

    func updateCSRFToken(_ token: String) {
        csrfLock.lock()
        csrfToken = token
        csrfLock.unlock()
    }

    var hasCSRFToken: Bool {
        csrfLock.lock()
        defer { csrfLock.unlock() }
        return csrfToken?.isEmpty == false
    }

    func fetchCSRFToken(session: Session, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(baseURL)/session/csrf.json") else {
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let cookieHeader = WebCookieStore.shared.cookieHeader(for: url)
        if !cookieHeader.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if let ua = WebCookieStore.shared.userAgent { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        session.request(req).responseData { response in
            guard let data = response.data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["csrf"] as? String
            else {
                completion(nil)
                return
            }
            completion(token)
        }
    }
}
