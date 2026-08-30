import Foundation

enum GitHubProxy {
    static func normalize(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return "" }
        if !url.hasSuffix("/") {
            url += "/"
        }
        return url
    }

    static func isValid(_ raw: String) -> Bool {
        let normalized = normalize(raw)
        if normalized.isEmpty { return true }
        guard let uri = URL(string: normalized),
              let scheme = uri.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = uri.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }

    static func apply(to url: URL, prefix rawPrefix: String) -> URL {
        let prefix = normalize(rawPrefix)
        guard !prefix.isEmpty else { return url }
        let absolute = url.absoluteString
        if absolute.hasPrefix(prefix) { return url }
        guard let rewritten = URL(string: prefix + absolute) else { return url }
        return rewritten
    }

    static func applyIfValid(to url: URL, prefix rawPrefix: String) throws -> URL {
        let prefix = normalize(rawPrefix)
        if prefix.isEmpty { return url }
        guard isValid(prefix) else {
            throw GitHubProxyError.invalidPrefix
        }
        let rewritten = apply(to: url, prefix: prefix)
        guard rewritten.scheme == "http" || rewritten.scheme == "https" else {
            throw GitHubProxyError.invalidPrefix
        }
        return rewritten
    }
}

enum GitHubProxyError: Error, LocalizedError, Equatable {
    case invalidPrefix

    var errorDescription: String? {
        String(localized: "update.github_proxy.invalid", defaultValue: "GitHub 镜像前缀不是合法的 http(s) 地址")
    }
}
