import Foundation

/// Resolves relative URLs against a base URL.
public enum URLResolver {
    /// Resolve a potentially relative URL string against a base URL.
    /// Returns the original string if resolution is not possible.
    public static func resolve(_ urlString: String, baseURL: String?) -> String {
        // Empty src must stay empty — never collapse to the forum origin as a fake image URL.
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let baseURL, !baseURL.isEmpty else { return trimmed }

        // Already absolute
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("data:") {
            return preferLinuxDoImageCDN(trimmed)
        }

        // Protocol-relative
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }

        guard let base = URL(string: baseURL) else { return trimmed }

        if trimmed.hasPrefix("/") {
            // Absolute path — resolve against scheme + host
            var components = URLComponents()
            components.scheme = base.scheme
            components.host = base.host
            components.port = base.port
            components.path = trimmed
            return preferLinuxDoImageCDN(components.url?.absoluteString ?? trimmed)
        }

        // Relative path
        return preferLinuxDoImageCDN(base.appendingPathComponent(trimmed).absoluteString)
    }

    /// linux.do public images are served from the static CDN. Uploads stay on the forum.
    public static func preferLinuxDoImageCDN(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString),
              let host = components.host?.lowercased(),
              host == "linux.do" || host == "www.linux.do",
              isLinuxDoPublicImagePath(components.percentEncodedPath)
        else { return urlString }
        components.host = "cdn.ldstatic.com"
        return components.url?.absoluteString ?? urlString
    }

    public static func isLinuxDoPublicImagePath(_ path: String) -> Bool {
        path.hasPrefix("/user_avatar/")
            || path.hasPrefix("/letter_avatar")
            || path.hasPrefix("/images/")
    }
}
