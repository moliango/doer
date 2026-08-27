import Foundation

/// Detects URLs that should be rendered as images when Discourse leaves them as bare auto-links.
public enum ImageURLDetector {
    private static let imageExtensions: Set<String> = [
        "apng", "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "webp",
    ]

    /// Whether `value` looks like a direct image resource URL.
    public static func isImageURL(_ value: String) -> Bool {
        let trimmed = normalizeURLString(value)
        guard !trimmed.isEmpty else { return false }

        // Prefer URLComponents, but fall back to lightweight parsing when the string is messy.
        if let components = URLComponents(string: trimmed) {
            return isImageURL(components: components)
        }

        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }
        if isHtmlFilePage(host: url.host, path: url.path.lowercased()) {
            return false
        }
        return isImagePath(url.path.lowercased(), query: url.query)
    }

    /// Fetch / lightbox URL. Discourse lightbox `href` is the original image
    /// on the same CDN. GitHub/GitLab file links (`/blob`, `/raw`,
    /// `raw.githubusercontent.com`) must not replace a CDN `src` that already
    /// loaded in the post — those remotes often 404 or return HTML in-app.
    public static func preferredResourceURL(src: String, href: String?) -> String {
        guard let href, !href.isEmpty, isImageURL(href) else { return src }
        if shouldKeepDisplayedSource(src: src, href: href) {
            return src
        }
        return href
    }

    /// GitHub/GitLab hosts whose "file" URLs are source links, not Discourse originals.
    private static func isGitHostingHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host == "raw.githubusercontent.com"
            || host == "gitlab.com"
            || host.hasSuffix(".gitlab.com")
            || host == "bitbucket.org"
            || host.hasSuffix(".bitbucket.org")
            || host == "gitee.com"
    }

    /// When Discourse already mirrored the file onto a CDN, keep that copy.
    private static func shouldKeepDisplayedSource(src: String, href: String) -> Bool {
        guard isImageURL(src) else { return false }
        let srcURL = URL(string: normalizeURLString(src))
        let hrefURL = URL(string: normalizeURLString(href))
        guard let srcHost = srcURL?.host?.lowercased(),
              let hrefHost = hrefURL?.host?.lowercased(),
              srcHost != hrefHost
        else {
            return false
        }
        return isGitHostingHost(hrefHost)
    }

    /// Whether a link whose children render as `label` should be promoted to an image block.
    ///
    /// Discourse may:
    /// - keep full auto-linked text equal to href
    /// - truncate long display text
    /// - insert soft line breaks / whitespace into the visible label
    ///
    /// Explicit markdown links like `[click](image.jpg)` stay as links unless the paragraph
    /// is a sole image link (handled by the caller).
    public static func shouldPromoteLink(href: String, label: String) -> Bool {
        guard isImageURL(href) else { return false }

        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedLabel.isEmpty {
            return true
        }

        if labelsRepresentSameURL(normalizedLabel, href) {
            return true
        }

        // Auto-linked / truncated URL labels almost always still look like URLs.
        if looksLikeURLLabel(normalizedLabel) {
            return true
        }

        return false
    }

    /// Reconstruct a possible image URL from paragraph inlines that are only text/line breaks.
    public static func soleImageURL(fromPlainInlines inlines: [InlineNode]) -> String? {
        var parts: [String] = []
        for inline in inlines {
            switch inline {
            case .text(let text), .styledText(let text, _):
                parts.append(text)
            case .lineBreak:
                continue
            default:
                return nil
            }
        }

        let joined = parts.joined()
        let compact = normalizeURLString(joined)
        guard isImageURL(compact) else { return nil }
        return compact
    }

    // MARK: - Helpers

    private static func isImageURL(components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return false
        }
        if isHtmlFilePage(host: components.host, path: components.path.lowercased()) {
            return false
        }
        return isImagePath(components.path.lowercased(), query: components.percentEncodedQuery)
    }

    /// GitHub/GitLab blob and tree pages are HTML even when the path ends in `.png`.
    private static func isHtmlFilePage(host: String?, path: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let isGitHost = host == "github.com" || host.hasSuffix(".github.com")
            || host == "gitlab.com" || host.hasSuffix(".gitlab.com")
        guard isGitHost else { return false }
        return path.contains("/blob/") || path.contains("/tree/")
    }

    private static func isImagePath(_ path: String, query: String?) -> Bool {
        let ext = (path as NSString).pathExtension
        if imageExtensions.contains(ext) {
            return true
        }

        // Image beds often serve binaries under /raw/...
        if path.contains("/raw/") {
            return true
        }

        // Community badge/card image endpoints (e.g. prompt.iwooji.com/badge?...).
        if path == "/badge" || path.hasSuffix("/badge") || path.contains("/badge/") {
            return true
        }

        // Common image path segments.
        if path.contains("/images/") || path.contains("/image/") || path.contains("/img/") {
            // Avoid promoting whole site homepages like /images without a file-ish tail.
            if path != "/images", path != "/images/", path != "/image", path != "/image/", path != "/img", path != "/img/" {
                let last = (path as NSString).lastPathComponent
                if last.contains(".") || last.count >= 8 {
                    return true
                }
            }
        }

        if let query, !query.isEmpty {
            let items = query
                .split(separator: "&")
                .map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
            for item in items {
                guard let name = item.first?.lowercased() else { continue }
                let value = item.count > 1 ? item[1].lowercased() : ""
                if name == "format" || name == "fm" || name == "type", imageExtensions.contains(value) {
                    return true
                }
            }
        }

        return false
    }

    private static func labelsRepresentSameURL(_ label: String, _ href: String) -> Bool {
        let compactLabel = normalizeURLString(label)
        let compactHref = normalizeURLString(href)
        if compactLabel == compactHref {
            return true
        }

        let decodedLabel = compactLabel.removingPercentEncoding ?? compactLabel
        let decodedHref = compactHref.removingPercentEncoding ?? compactHref
        if decodedLabel == decodedHref {
            return true
        }

        if let labelURL = URL(string: compactLabel),
           let hrefURL = URL(string: compactHref),
           labelURL.scheme?.lowercased() == hrefURL.scheme?.lowercased(),
           labelURL.host?.lowercased() == hrefURL.host?.lowercased(),
           labelURL.path == hrefURL.path,
           (labelURL.query ?? "") == (hrefURL.query ?? "")
        {
            return true
        }

        // Truncated display text: "https://host/path?......." or prefix + "..."
        if isTruncatedURLLabel(compactLabel, of: compactHref) {
            return true
        }

        return false
    }

    private static func isTruncatedURLLabel(_ label: String, of href: String) -> Bool {
        var candidate = label
        while candidate.hasSuffix("...") || candidate.hasSuffix("…") {
            if candidate.hasSuffix("...") {
                candidate = String(candidate.dropLast(3))
            } else {
                candidate = String(candidate.dropLast())
            }
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.count >= 12 else { return false }
        return href.hasPrefix(candidate) || normalizeURLString(href).hasPrefix(normalizeURLString(candidate))
    }

    private static func looksLikeURLLabel(_ label: String) -> Bool {
        let compact = normalizeURLString(label)
        if compact.hasPrefix("http://") || compact.hasPrefix("https://") {
            return true
        }
        // domain/path style labels used by some onebox-ish displays
        if compact.contains("://") {
            return true
        }
        return false
    }

    /// Strip whitespace/newlines that Discourse or copy-paste may inject into long URLs.
    public static func normalizeURLString(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
