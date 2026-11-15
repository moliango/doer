import Foundation
import UIKit

struct DiscourseTopicLinkInfo: Equatable {
    let topicId: Int
    let postNumber: Int?
    let slug: String?
    let normalizedURL: String
}

enum DiscourseTopicLinkParser {
    private static let topicIdOnly = try! NSRegularExpression(
        pattern: #"/t/(\d+)(?:/(\d+))?(?:[/?#]|$)"#,
        options: [.caseInsensitive]
    )
    private static let topicWithSlug = try! NSRegularExpression(
        pattern: #"/t/([^/]+)/(\d+)(?:/(\d+))?"#,
        options: [.caseInsensitive]
    )

    /// Parse first topic link in free text for a given forum base URL host.
    static func firstTopicLink(in text: String, forumBaseURL: String) -> DiscourseTopicLinkInfo? {
        guard let forumHost = host(from: forumBaseURL) else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Prefer explicit URLs containing /t/
        let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        if let detector = urlDetector {
            let matches = detector.matches(in: text, range: full)
            for match in matches {
                guard let url = match.url else { continue }
                if let info = parse(url: url, allowedHost: forumHost) {
                    return info
                }
            }
        }

        // Fallback: raw path-like snippets for same host text
        if let info = parse(pathOrURL: text, allowedHost: forumHost) {
            return info
        }
        return nil
    }

    static func parse(url: URL, allowedHost: String) -> DiscourseTopicLinkInfo? {
        guard let host = url.host?.lowercased() else { return nil }
        guard host == allowedHost || host == "www." + allowedHost || allowedHost == "www." + host else {
            return nil
        }
        return parse(path: url.path, query: url.query, fragment: url.fragment, absoluteString: url.absoluteString)
    }

    static func parse(pathOrURL raw: String, allowedHost: String) -> DiscourseTopicLinkInfo? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") {
            value = "https:" + value
        } else if value.hasPrefix("/t/") {
            value = "https://\(allowedHost)" + value
        } else if !value.contains("://") && value.lowercased().contains(allowedHost) {
            value = "https://" + value
        }
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return nil }
        guard host == allowedHost || host == "www." + allowedHost || allowedHost == "www." + host else {
            return nil
        }
        return parse(path: url.path, query: url.query, fragment: url.fragment, absoluteString: url.absoluteString)
    }

    private static func parse(path: String, query: String?, fragment: String?, absoluteString: String) -> DiscourseTopicLinkInfo? {
        let nsPath = path as NSString
        let range = NSRange(location: 0, length: nsPath.length)

        if let match = topicIdOnly.firstMatch(in: path, range: range),
           match.numberOfRanges >= 2,
           let topicRange = Range(match.range(at: 1), in: path),
           let topicId = Int(path[topicRange]), topicId > 0 {
            var postNumber: Int?
            if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound,
               let postRange = Range(match.range(at: 2), in: path) {
                postNumber = Int(path[postRange])
            }
            return DiscourseTopicLinkInfo(
                topicId: topicId,
                postNumber: postNumber,
                slug: nil,
                normalizedURL: normalize(absoluteString)
            )
        }

        if let match = topicWithSlug.firstMatch(in: path, range: range),
           match.numberOfRanges >= 3,
           let slugRange = Range(match.range(at: 1), in: path),
           let topicRange = Range(match.range(at: 2), in: path),
           let topicId = Int(path[topicRange]), topicId > 0 {
            let slug = String(path[slugRange])
            // Avoid treating pure numeric first segment as slug when id-only already failed
            if Int(slug) != nil { return nil }
            var postNumber: Int?
            if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound,
               let postRange = Range(match.range(at: 3), in: path) {
                postNumber = Int(path[postRange])
            }
            return DiscourseTopicLinkInfo(
                topicId: topicId,
                postNumber: postNumber,
                slug: slug == "topic" ? nil : slug,
                normalizedURL: normalize(absoluteString)
            )
        }
        return nil
    }

    static func host(from baseURL: String) -> String? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: raw), let host = url.host?.lowercased() {
            return host
        }
        if let url = URL(string: "https://\(raw)"), let host = url.host?.lowercased() {
            return host
        }
        return nil
    }

    /// Cheap "does this look like a link" probe for the pre-iOS 16 fallback path.
    static func containsLikelyURL(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text.contains("://")
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.firstMatch(in: text, range: range) != nil
    }

    private static func normalize(_ absolute: String) -> String {
        absolute.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Detects and resolves a copied forum topic link without triggering the system paste
/// alert on launch. `changeCount` identifies the clipboard contents without reading
/// them, and `detectPatterns` (iOS 16+) reports whether a link is present — only an
/// explicit user tap reads the pasteboard, which is when iOS shows its paste prompt.
final class ClipboardTopicLinkService {
    static let shared = ClipboardTopicLinkService()

    private let defaults: UserDefaults
    private let lastHandledChangeCountKey = "clipboard_topic_link_last_handled_change_count"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True when the clipboard holds an unhandled link-like value. Never reads the
    /// contents on iOS 16+, so no paste alert is shown just for checking.
    func hasUnhandledClipboardLink() async -> Bool {
        let board = UIPasteboard.general
        let changeCount = board.changeCount
        guard changeCount != (defaults.object(forKey: lastHandledChangeCountKey) as? Int) else {
            return false
        }

        if #available(iOS 16.0, *) {
            let keyPath = \UIPasteboard.DetectedValues.probableWebURL
            let detected = try? await board.detectedPatterns(for: [keyPath])
            return detected?.contains(keyPath) ?? false
        }
        // iOS 15 predates the paste alert, so reading here is silent.
        guard let text = board.string, !text.isEmpty else { return false }
        return DiscourseTopicLinkParser.containsLikelyURL(text)
    }

    /// Reads the clipboard (this is what raises the system paste prompt) and parses a
    /// topic link. Marks the clipboard handled either way so we do not nag again.
    func takeClipboardTopicLink(forumBaseURL: String) -> DiscourseTopicLinkInfo? {
        defer { markHandled() }
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return nil }
        return DiscourseTopicLinkParser.firstTopicLink(in: text, forumBaseURL: forumBaseURL)
    }

    func markHandled() {
        defaults.set(UIPasteboard.general.changeCount, forKey: lastHandledChangeCountKey)
    }
}

