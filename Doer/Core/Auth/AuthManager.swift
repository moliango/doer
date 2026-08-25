import Foundation

final class AuthManager: DoerObservableObject, @unchecked Sendable {
    static let shared = AuthManager()

    // Per-baseURL username cache (populated from DB or after login)
    private var usernameCache: [String: String] = [:]

    private override init() {
        super.init()
    }

    // MARK: - Public API

    func isAuthenticated(for baseURL: String) -> Bool {
        let baseURL = normalizedBaseURL(baseURL)
        guard let url = URL(string: baseURL) else { return false }
        if WebCookieStore.shared.hasCookie(named: "_t", for: url) {
            return true
        }
        return usernameCache[baseURL] != nil
            && WebCookieStore.shared.hasDiscourseWebSessionCookie(for: url)
    }

    func hasWebSession(for baseURL: String) -> Bool {
        hasRecoverableWebSession(for: normalizedBaseURL(baseURL))
    }

    private func hasRecoverableWebSession(for baseURL: String) -> Bool {
        guard let url = URL(string: baseURL) else { return false }
        return WebCookieStore.shared.hasDiscourseWebSessionCookie(for: url)
    }

    func username(for baseURL: String) -> String? {
        usernameCache[normalizedBaseURL(baseURL)]
    }

    func refreshWebSessionUserIfPossible(forum: ForumInstance) async -> Bool {
        let baseURL = normalizedBaseURL(forum.baseURL)
        guard hasRecoverableWebSession(for: baseURL) else { return false }
        let previousUsername = usernameCache[baseURL] ?? forum.username

        _ = await WebSessionRefreshService.shared.ensureSynced(forum: forum, reason: "refresh_user")

        let api = DiscourseAPI(baseURL: baseURL)
        do {
            let currentUser = try await api.fetchCurrentUser()
            if let previousUsername,
               previousUsername.caseInsensitiveCompare(currentUser.username) != .orderedSame {
                MeProfileCacheStore.clear(baseURL: baseURL)
            }
            usernameCache[baseURL] = currentUser.username
            var forumToUpdate = forum
            forumToUpdate.username = currentUser.username
            _ = try? DatabaseManager.shared.saveForum(&forumToUpdate)
            notifyChanged()
            return true
        } catch {
            if AuthSessionInvalidationPolicy.shouldInvalidateWebSession(error: error, baseURL: baseURL) {
                invalidateWebSession(for: baseURL)
                return false
            }
            notifyChanged()
            return false
        }
    }

    /// Called after WebLoginViewController successfully captures cookies.
    /// Returns true only when a real Discourse web session cookie is available.
    func loginViaWeb(forum: ForumInstance, cookies: [HTTPCookie], userAgent: String?) async -> Bool {
        let baseURL = normalizedBaseURL(forum.baseURL)
        WebCookieStore.shared.setCookies(cookies)
        WebCookieStore.shared.userAgent = userAgent
        KeychainHelper.deleteLegacyCredential(for: baseURL)
        KeychainHelper.deleteLegacyRSAKeyPair(for: baseURL)

        guard let url = URL(string: baseURL),
              WebCookieStore.shared.hasDiscourseWebSessionCookie(for: url)
        else {
            notifyChanged()
            return false
        }

        // The WebView already proved the login by issuing `_t`; do not block the UI
        // on profile/session enrichment, which can take several seconds behind CF.
        if WebCookieStore.shared.hasCookie(named: "_t", for: url) {
            if usernameCache[baseURL] == nil,
               let existing = forum.username?.trimmingCharacters(in: .whitespacesAndNewlines),
               !existing.isEmpty {
                usernameCache[baseURL] = existing
            }
            notifyChanged()
            Task { @MainActor [weak self] in
                _ = await WebSessionRefreshService.shared.ensureSynced(
                    forum: forum,
                    reason: "web_login_background",
                    force: true
                )
                _ = await self?.refreshWebSessionUserIfPossible(forum: forum)
            }
            return true
        }

        _ = await WebSessionRefreshService.shared.ensureSynced(forum: forum, reason: "web_login", force: true)

        if await refreshWebSessionUserIfPossible(forum: forum) {
            return true
        }

        guard WebCookieStore.shared.hasCookie(named: "_t", for: url) else {
            notifyChanged()
            return false
        }
        // `_t` is enough to prove a Discourse login; username refresh is best-effort.
        notifyChanged()
        return true
    }

    func logout(forum: ForumInstance) {
        let baseURL = normalizedBaseURL(forum.baseURL)

        if let username = usernameCache[baseURL] {
            let api = DiscourseAPI(baseURL: baseURL)
            Task { await api.deleteSession(username: username) }
        }

        KeychainHelper.deleteLegacyCredential(for: baseURL)
        KeychainHelper.deleteLegacyRSAKeyPair(for: baseURL)
        WebCookieStore.shared.clearCookies(for: baseURL)
        MeProfileCacheStore.clear(baseURL: baseURL)
        ForumLocalNotificationPresenter.shared.removeApplicationBadge(baseURL: baseURL)
        BackgroundTopicUpdateStore.shared.clear(baseURL: baseURL)
        usernameCache.removeValue(forKey: baseURL)

        // Clear username from DB
        var forumToUpdate = forum
        forumToUpdate.username = nil
        _ = try? DatabaseManager.shared.saveForum(&forumToUpdate)
        notifyChanged()
    }

    func invalidateWebSession(for baseURL: String) {
        let baseURL = normalizedBaseURL(baseURL)
        DohDebugLog.record("invalidate web session base=\(baseURL)", subsystem: "Auth")
        KeychainHelper.deleteLegacyCredential(for: baseURL)
        KeychainHelper.deleteLegacyRSAKeyPair(for: baseURL)
        WebCookieStore.shared.clearCookies(for: baseURL)
        MeProfileCacheStore.clear(baseURL: baseURL)
        ForumLocalNotificationPresenter.shared.removeApplicationBadge(baseURL: baseURL)
        BackgroundTopicUpdateStore.shared.clear(baseURL: baseURL)
        usernameCache.removeValue(forKey: baseURL)
        notifyChanged()
    }

    func restoreAuthState(for forum: ForumInstance) {
        let baseURL = normalizedBaseURL(forum.baseURL)
        if let username = forum.username, hasRecoverableWebSession(for: baseURL) {
            usernameCache[baseURL] = username
            WebSessionRefreshService.shared.ensureInBackground(forum: forum, reason: "restore_auth_state")
            notifyChanged()
        }
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
