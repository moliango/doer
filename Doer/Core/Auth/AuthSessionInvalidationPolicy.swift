import Foundation

/// When a Discourse request fails, UI layers used to treat every 403 / `forbidden`
/// as logout and call `AuthManager.invalidateWebSession`, which deletes `_t` and
/// `cf_clearance`. Transient Cloudflare, permission, and CSRF 403s then looked
/// like being kicked off the server.
enum AuthSessionInvalidationPolicy {
    /// Clear the local web session when Discourse authoritatively reported
    /// `not_logged_in`. A leftover `_t` must not keep the UI logged in after
    /// the server invalidated the session (log out everywhere / ticket revoked).
    /// Cloudflare and generic 403s stay out of this path.
    static func shouldInvalidateWebSession(error: Error, baseURL: String) -> Bool {
        guard let apiError = error as? DiscourseAPIError, apiError.isNotLoggedIn else {
            return false
        }
        let normalized = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let url = URL(string: normalized), WebCookieStore.shared.hasCookie(named: "_t", for: url) {
            DohDebugLog.record(
                "invalidating stale _t after server not_logged_in type=\(apiError.errorType ?? "nil")",
                subsystem: "Auth"
            )
        }
        return true
    }

    /// Dead sessions must not go through WK cookie refresh — that reuses `_t`
    /// and trips Cloudflare instead of showing signed-out UI.
    static func shouldSkipWebSessionRefresh(
        isCurrentUserRoute: Bool,
        statusCode: Int?,
        data: Data?
    ) -> Bool {
        if isCurrentUserRoute {
            if statusCode == 401 || statusCode == 403 { return true }
            if statusCode == 200, data?.isEmpty != false { return true }
        }
        return isNotLoggedInResponseBody(data)
    }

    static func isNotLoggedInResponseBody(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        return DiscourseAPI.errorFromForbiddenStatus(data: data).isNotLoggedIn
    }
}
