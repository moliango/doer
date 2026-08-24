import Foundation

enum ForumInternalLinkDestination: Equatable {
    case topic(id: Int, postNumber: Int?)
    case category(slug: String, id: Int)
    case tag(name: String)
    case user(username: String)
}

enum ForumInternalLinkParser {
    static func normalizedURL(from url: URL, baseURL: String) -> URL {
        if url.scheme == nil, url.absoluteString.hasPrefix("//") {
            return URL(string: "https:\(url.absoluteString)") ?? url
        }

        guard url.host == nil, url.scheme == nil,
              let base = URL(string: baseURL)
        else {
            return url
        }

        return URL(string: url.absoluteString, relativeTo: base)?.absoluteURL ?? url
    }

    static func isInternalURL(_ url: URL, baseURL: String) -> Bool {
        guard let baseHost = URL(string: baseURL)?.host,
              let linkHost = url.host
        else { return false }

        return normalizedHost(baseHost) == normalizedHost(linkHost)
    }

    static func destination(for url: URL) -> ForumInternalLinkDestination? {
        if let topic = parseTopicInfo(from: url) {
            return .topic(id: topic.id, postNumber: topic.postNumber)
        }
        if let (slug, categoryId) = parseCategoryInfo(from: url) {
            return .category(slug: slug, id: categoryId)
        }
        if let tagName = parseTagName(from: url) {
            return .tag(name: tagName)
        }
        if let username = parseUsername(from: url) {
            return .user(username: username)
        }
        return nil
    }

    private static func normalizedHost(_ host: String) -> String {
        var value = host.lowercased()
        while value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasPrefix("www.") {
            value.removeFirst(4)
        }
        return value
    }

    private static func parseTopicInfo(from url: URL) -> (id: Int, postNumber: Int?)? {
        let components = url.pathComponents
        guard let tIndex = components.firstIndex(of: "t") else { return nil }
        var numbers: [Int] = []
        for component in components.dropFirst(tIndex + 1) {
            let cleaned = component.replacingOccurrences(of: ".json", with: "")
            if let id = Int(cleaned) {
                numbers.append(id)
            }
        }
        guard let topicId = numbers.first else { return nil }
        return (topicId, numbers.dropFirst().first)
    }

    private static func parseCategoryInfo(from url: URL) -> (slug: String, id: Int)? {
        let components = url.pathComponents
        guard let cIndex = components.firstIndex(of: "c"),
              cIndex + 2 < components.count else { return nil }
        let remaining = Array(components[(cIndex + 1)...])
        for i in remaining.indices.reversed() {
            let cleaned = remaining[i].replacingOccurrences(of: ".json", with: "")
            if let id = Int(cleaned), i > 0 {
                return (remaining[i - 1], id)
            }
        }
        return nil
    }

    static func categoryURL(slug: String, id: Int, baseURL: String) -> URL? {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/c/\(encoded)/\(id)")
    }

    static func tagURL(name: String, baseURL: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/tag/\(encoded)")
    }

    private static func parseTagName(from url: URL) -> String? {
        let components = url.pathComponents
        guard let tagIndex = components.firstIndex(where: { $0 == "tag" || $0 == "tags" }),
              tagIndex + 1 < components.count
        else { return nil }
        let raw = components[tagIndex + 1]
        let decoded = raw.removingPercentEncoding ?? raw
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "l", !trimmed.hasSuffix(".json") else { return nil }
        return trimmed.replacingOccurrences(of: ".json", with: "")
    }

    /// Mention and profile links: `/u/username`, `/u/username/summary`, `/users/username`.
    /// Skips Discourse utility routes such as `/u/search/users`.
    private static func parseUsername(from url: URL) -> String? {
        let components = url.pathComponents
        if let usersIndex = components.firstIndex(of: "users"),
           usersIndex + 3 < components.count,
           components[usersIndex + 1] == "by-id" {
            return sanitizedUsername(components[usersIndex + 3])
        }

        guard let userIndex = components.firstIndex(where: { $0 == "u" || $0 == "users" }),
              userIndex + 1 < components.count
        else { return nil }

        if components[userIndex] == "users", components[userIndex + 1] == "by-id" {
            return nil
        }

        return sanitizedUsername(components[userIndex + 1])
    }

    private static let reservedUserPathComponents: Set<String> = [
        "account-created",
        "admin",
        "confirm-new-email",
        "confirm-old-email",
        "hp",
        "login",
        "password-reset",
        "preferences",
        "recent-searches",
        "search",
        "signup",
        "toggle-anon",
        "user-menu",
    ]

    private static func sanitizedUsername(_ raw: String) -> String? {
        var value = (raw.removingPercentEncoding ?? raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.lowercased().hasSuffix(".json") {
            value = String(value.dropLast(5))
        }
        if value.hasPrefix("@") {
            value.removeFirst()
        }
        guard !value.isEmpty,
              value.count <= 60,
              !reservedUserPathComponents.contains(value.lowercased())
        else { return nil }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return value
    }
}

enum ForumAttachmentLinkParser {
    private static let mediaExtensions: Set<String> = [
        "apng", "avif", "gif", "heic", "heif", "jpeg", "jpg", "mov", "mp3", "mp4", "mpeg", "ogg", "png", "svg",
        "wav", "webm", "webp",
    ]

    /// Extensions that almost always mean a downloadable file (not a browsable page).
    /// Deliberately excludes web documents like `html` / `php` — those open in Safari.
    private static let fileExtensions: Set<String> = [
        "7z", "apk", "bz2", "c", "conf", "cpp", "csv", "dart", "db", "diff", "dmg", "doc", "docx", "gz",
        "h", "hpp", "ipa", "java", "js", "json", "key", "kt", "log", "md", "msi", "numbers", "otf",
        "pages", "patch", "pdf", "pkg", "ppt", "pptx", "py", "rar", "rb", "rs", "sh", "sql", "sqlite",
        "swift", "tar", "toml", "ts", "ttf", "txt", "woff", "woff2", "xls", "xlsx", "xml", "xz", "yaml", "yml",
        "zip",
    ]

    static func isAttachmentURL(_ url: URL) -> Bool {
        let path = url.path.removingPercentEncoding?.lowercased() ?? url.path.lowercased()
        let ext = url.pathExtension.lowercased()
        let wantsDownload = hasDownloadQuery(url)

        // Media opens in the image/video viewer unless the server explicitly asks to download.
        if mediaExtensions.contains(ext) {
            return wantsDownload
        }

        if wantsDownload {
            return true
        }

        let isUploadPath = path.contains("/uploads/") || path.contains("/secure-uploads/")
        if isUploadPath {
            // Real Discourse attachments: short-url / secure-uploads, or original path with a file ext.
            // Bare `/uploads/` without a downloadable extension is not an attachment
            // (avoids treating random upload-ish paths as downloads).
            if fileExtensions.contains(ext) {
                return true
            }
            if path.contains("/uploads/short-url/") || path.contains("/secure-uploads/") {
                return !ext.isEmpty
            }
            return false
        }

        // External links: only clear binary/document extensions. Never `.html` webpages.
        return fileExtensions.contains(ext)
    }

    private static func hasDownloadQuery(_ url: URL) -> Bool {
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.contains { item in
            let name = item.name.lowercased()
            if name == "download" { return true }
            if name == "dl", item.value == "1" { return true }
            return false
        }
    }
}

enum ForumAttachmentDownloadError: LocalizedError {
    case invalidFile
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return String(localized: "attachment.download_failed")
        case let .httpStatus(statusCode):
            return "\(String(localized: "attachment.download_failed")) (\(statusCode))"
        }
    }
}

enum ForumAttachmentDownloader {
    static func download(url: URL, baseURL: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let cookieHeader = WebCookieStore.shared.cookieHeader(for: url)
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let userAgent = WebCookieStore.shared.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        LightweightDohProxyService.shared.apply(
            to: config,
            hostURL: proxyBaseURL(for: url, fallback: baseURL)
        )

        let session = URLSession(configuration: config)
        defer {
            session.finishTasksAndInvalidate()
        }

        let (temporaryURL, response) = try await session.download(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 300).contains(httpResponse.statusCode) {
            throw ForumAttachmentDownloadError.httpStatus(httpResponse.statusCode)
        }

        let filename = sanitizedFilename(response.suggestedFilename, fallbackURL: url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoerAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: temporaryURL, to: destination)
        return destination
    }

    static func cleanupDownloadedFile(_ url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func proxyBaseURL(for url: URL, fallback: String) -> String {
        guard let scheme = url.scheme, let host = url.host else {
            return fallback
        }
        return "\(scheme)://\(host)"
    }

    private static func sanitizedFilename(_ suggestedName: String?, fallbackURL: URL) -> String {
        let fallback = fallbackURL.lastPathComponent.removingPercentEncoding
        let rawName = [suggestedName, fallback, "attachment"]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "attachment"

        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let clean = rawName.components(separatedBy: forbidden).joined(separator: "_")
        return clean.isEmpty ? "attachment" : clean
    }
}
