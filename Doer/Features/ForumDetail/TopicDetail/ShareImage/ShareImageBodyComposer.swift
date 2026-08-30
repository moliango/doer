import CookedHTML
import Foundation
import UIKit

/// Ordered body segments for share-image mixed media layout.
/// Text is always **readable post content** (from cooked HTML), never markdown source.
enum ShareImageBodySegment {
    /// Plain readable text (already extracted from cooked HTML / inlines).
    case text(String)
    /// Rich text with bold/italic/links — preferred for normal reading appearance.
    case richText(NSAttributedString)
    case image(URL)
    case moreImages(Int)
}

enum ShareImageBodyComposer {
    static let maxImages = 6

    /// Build share segments from Discourse **cooked HTML** (what the topic detail shows).
    /// Never pass `post.raw` markdown here. Uses shared Phase 4 pipeline for parse.
    static func segments(
        from cookedHTML: String,
        baseURL: String,
        textColor: UIColor = .label,
        font: UIFont = .systemFont(ofSize: 15)
    ) -> [ShareImageBodySegment] {
        let normalized = normalizeCookedInput(cookedHTML)
        // Shared preprocess + parse (same entry as export / AI context).
        let blocks = CookedContentPipeline.blocks(fromCooked: normalized, baseURL: baseURL)
        let built = segments(
            from: blocks,
            baseURL: baseURL,
            textColor: textColor,
            font: font
        )
        return sanitized(built)
    }

    /// Same pipeline using already-parsed detail blocks (on-screen content).
    static func segments(
        from blocks: [ContentBlock],
        baseURL: String,
        textColor: UIColor = .label,
        font: UIFont = .systemFont(ofSize: 15)
    ) -> [ShareImageBodySegment] {
        let config = AttributedStringConfig(
            baseFont: font,
            baseColor: textColor,
            linkColor: textColor.withAlphaComponent(0.85),
            codeFont: .monospacedSystemFont(ofSize: max(font.pointSize - 1, 12), weight: .regular),
            codeBackgroundColor: textColor.withAlphaComponent(0.08),
            mentionColor: textColor.withAlphaComponent(0.9),
            hashtagColor: textColor.withAlphaComponent(0.9),
            spoilerColor: textColor.withAlphaComponent(0.12)
        )

        var imageCount = 0
        var omittedImages = 0
        var built: [ShareImageBodySegment] = []

        for block in blocks {
            append(
                block: block,
                baseURL: baseURL,
                config: config,
                into: &built,
                imageCount: &imageCount,
                omittedImages: &omittedImages
            )
        }

        var merged: [ShareImageBodySegment] = []
        for segment in built {
            switch segment {
            case .text(let text):
                let trimmed = collapseWhitespace(text)
                guard !trimmed.isEmpty else { continue }
                if case .text(let previous)? = merged.last {
                    merged[merged.count - 1] = .text(previous + "\n\n" + trimmed)
                } else {
                    merged.append(.text(trimmed))
                }
            case .richText(let attr):
                let trimmed = trimmedAttributedString(attr)
                guard trimmed.length > 0 else { continue }
                if case .richText(let previous)? = merged.last {
                    let joined = NSMutableAttributedString(attributedString: previous)
                    joined.append(NSAttributedString(string: "\n\n", attributes: [
                        .font: config.baseFont,
                        .foregroundColor: config.baseColor,
                    ]))
                    joined.append(trimmed)
                    merged[merged.count - 1] = .richText(joined)
                } else {
                    merged.append(.richText(trimmed))
                }
            case .image, .moreImages:
                merged.append(segment)
            }
        }

        if omittedImages > 0 {
            merged.append(.moreImages(omittedImages))
        }
        return merged
    }

    static func imageURLs(in segments: [ShareImageBodySegment]) -> [URL] {
        segments.compactMap { segment in
            if case .image(let url) = segment { return url }
            return nil
        }
    }

    // MARK: - Input normalize + final sanitize

    /// Ensure we feed **HTML** into the parser. If a caller ever passes markdown/`raw`,
    /// convert it to simple readable paragraphs instead of painting MD source on the card.
    static func normalizeCookedInput(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Pure / dominant markdown source (even if it contains a stray `<`).
        if looksLikeMarkdownSource(trimmed), !looksLikeHTML(trimmed) {
            return markdownishToSimpleHTML(trimmed)
        }

        // Already cooked HTML from Discourse.
        if looksLikeHTML(trimmed) {
            return trimmed
        }

        // Plain / markdown-ish source → readable HTML paragraphs (not raw MD dump).
        return markdownishToSimpleHTML(trimmed)
    }

    static func looksLikeHTML(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("<p")
            || lower.contains("<div")
            || lower.contains("<br")
            || lower.contains("<img")
            || lower.contains("<a ")
            || lower.contains("<ul")
            || lower.contains("<ol")
            || lower.contains("<blockquote")
            || lower.contains("<aside")
            || lower.contains("<h1")
            || lower.contains("<h2")
            || lower.contains("<h3")
            || lower.contains("<pre")
            || lower.contains("<span")
            || lower.contains("<table")
            || lower.contains("<li")
            || lower.contains("<code")
    }

    /// Detect bare markdown that should never be painted on the share card.
    static func looksLikeMarkdownSource(_ value: String) -> Bool {
        if value.contains("**") || value.contains("__") || value.contains("](") || value.contains("![") {
            return true
        }
        if value.contains("```") { return true }
        if value.range(of: #"(?m)^#{1,6}\s+\S"#, options: .regularExpression) != nil {
            return true
        }
        if value.range(of: #"(?m)^>\s+\S"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Final pass: strip residual markdown markers from composed segments.
    /// Always runs on every text/richText segment — the public form on linux.do
    /// leaves unpaired `**` at the start of checklist lines (see share regression).
    static func sanitized(_ segments: [ShareImageBodySegment]) -> [ShareImageBodySegment] {
        segments.compactMap { segment in
            switch segment {
            case .text(let text):
                let cleaned = stripMarkdownArtifacts(text)
                return cleaned.isEmpty ? nil : .text(cleaned)
            case .richText(let attr):
                let plain = attr.string
                // Always strip if any MD glyphs remain (paired or not).
                guard plain.contains("*")
                    || plain.contains("_")
                    || plain.contains("`")
                    || plain.contains("](")
                    || plain.contains("#")
                    || plain.contains("＊") // fullwidth asterisk
                else { return segment }
                let cleaned = stripMarkdownArtifacts(plain)
                guard !cleaned.isEmpty else { return nil }
                let font = attr.length > 0
                    ? ((attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont) ?? .systemFont(ofSize: 15))
                    : .systemFont(ofSize: 15)
                let color = attr.length > 0
                    ? ((attr.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor) ?? .label)
                    : .label
                return .richText(NSAttributedString(string: cleaned, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]))
            case .image, .moreImages:
                return segment
            }
        }
    }

    /// Remove common markdown markers left in text nodes.
    /// Handles both paired (`**bold**`) and **unpaired** leading `**` (linux.do 公益推广 checklist).
    static func stripMarkdownArtifacts(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // Fullwidth asterisks sometimes pasted from forms.
            .replacingOccurrences(of: "＊", with: "*")

        if let imageRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = imageRegex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "$1"
            )
        }
        if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = linkRegex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "$1"
            )
        }

        // Paired emphasis first (non-greedy, multi-pass for nesting leftovers).
        for _ in 0..<3 {
            let before = result
            result = result
                .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"\*([^*\n]+)\*"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"_([^_\n]+)_"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            if result == before { break }
        }
        result = result.replacingOccurrences(of: "```", with: "")

        // Strip ANY remaining bold/italic marker runs (unpaired `**` / `*` / `__`).
        result = result
            .replacingOccurrences(of: #"\*{1,}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"_{2,}"#, with: "", options: .regularExpression)

        let lines = result.components(separatedBy: "\n").map { line -> String in
            var s = line
            if let heading = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#) {
                s = heading.stringByReplacingMatches(
                    in: s, options: [],
                    range: NSRange(s.startIndex..<s.endIndex, in: s),
                    withTemplate: ""
                )
            }
            // "• **text" / "- **text" after partial strips
            if let bulletMD = try? NSRegularExpression(pattern: #"^([•\-\*]\s*)\*+"#) {
                s = bulletMD.stringByReplacingMatches(
                    in: s, options: [],
                    range: NSRange(s.startIndex..<s.endIndex, in: s),
                    withTemplate: "$1"
                )
            }
            if s.hasPrefix("> ") { s = String(s.dropFirst(2)) }
            if s.hasPrefix("- ") || s.hasPrefix("* ") { s = "• " + String(s.dropFirst(2)) }
            if let ordered = try? NSRegularExpression(pattern: #"^\d+\.\s+"#) {
                s = ordered.stringByReplacingMatches(
                    in: s, options: [],
                    range: NSRange(s.startIndex..<s.endIndex, in: s),
                    withTemplate: "• "
                )
            }
            return s.trimmingCharacters(in: .whitespaces)
        }
        return collapseWhitespace(lines.joined(separator: "\n"))
    }

    /// Minimal markdown → plain readable HTML. Not a full MD engine — only enough
    /// so share cards never show `**bold**` / `[text](url)` source to users.
    static func markdownishToSimpleHTML(_ markdown: String) -> String {
        var text = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Images: ![alt](url) → <img>
        if let imageRegex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)\s]+)\)"#,
            options: []
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = imageRegex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: #"<img src="$2" alt="$1">"#
            )
        }

        // Links: [label](url) → label
        if let linkRegex = try? NSRegularExpression(
            pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#,
            options: []
        ) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = linkRegex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: "$1"
            )
        }

        // Bold / italic markers
        text = text
            .replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"_(.+?)_"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)

        // Headings / quotes / lists markers at line start
        let lines = text.components(separatedBy: "\n").map { line -> String in
            var s = line
            if let heading = try? NSRegularExpression(pattern: #"^#{1,6}\s+"#) {
                s = heading.stringByReplacingMatches(
                    in: s,
                    options: [],
                    range: NSRange(s.startIndex..<s.endIndex, in: s),
                    withTemplate: ""
                )
            }
            if s.hasPrefix("> ") { s = String(s.dropFirst(2)) }
            if s.hasPrefix("- ") || s.hasPrefix("* ") { s = "• " + String(s.dropFirst(2)) }
            if let ordered = try? NSRegularExpression(pattern: #"^\d+\.\s+"#) {
                s = ordered.stringByReplacingMatches(
                    in: s,
                    options: [],
                    range: NSRange(s.startIndex..<s.endIndex, in: s),
                    withTemplate: "• "
                )
            }
            return s
        }

        let paragraphs = lines
            .map { escapeHTML($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .map { "<p>\($0)</p>" }
        return paragraphs.isEmpty ? "<p></p>" : paragraphs.joined()
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Block walk

    private static func append(
        block: ContentBlock,
        baseURL: String,
        config: AttributedStringConfig,
        into segments: inout [ShareImageBodySegment],
        imageCount: inout Int,
        omittedImages: inout Int
    ) {
        switch block {
        case .paragraph(let inlines), .heading(_, let inlines):
            append(
                inlines: inlines,
                baseURL: baseURL,
                config: config,
                into: &segments,
                imageCount: &imageCount,
                omittedImages: &omittedImages
            )

        case .image(let src, _, _, _, let href):
            appendImage(src: href ?? src, baseURL: baseURL, into: &segments, imageCount: &imageCount, omittedImages: &omittedImages)

        case .imageGrid(let images, _, _):
            for item in images {
                appendImage(src: item.lightboxURL, baseURL: baseURL, into: &segments, imageCount: &imageCount, omittedImages: &omittedImages)
            }
        case .blockquote(let blocks), .spoiler(let blocks):
            for child in blocks {
                append(
                    block: child,
                    baseURL: baseURL,
                    config: config,
                    into: &segments,
                    imageCount: &imageCount,
                    omittedImages: &omittedImages
                )
            }

        case .discourseQuote(let username, _, _, _, _, _, _, let content):
            if let username, !username.isEmpty {
                let header = NSAttributedString(string: "@\(username):", attributes: [
                    .font: UIFont.systemFont(ofSize: config.baseFont.pointSize, weight: .semibold),
                    .foregroundColor: config.baseColor,
                ])
                segments.append(.richText(header))
            }
            for child in content {
                append(
                    block: child,
                    baseURL: baseURL,
                    config: config,
                    into: &segments,
                    imageCount: &imageCount,
                    omittedImages: &omittedImages
                )
            }

        case .list(_, _, let items):
            for item in items {
                // Flatten list item to plain text then strip residual MD (`**…`).
                // Attributed walk kept raw `**` for uncooked checklist forms on linux.do.
                let rawBody = item.content.attributedString(config: config).string
                let cleaned = stripMarkdownArtifacts(rawBody)
                if !cleaned.isEmpty {
                    let line = NSAttributedString(string: "• \(cleaned)", attributes: [
                        .font: config.baseFont,
                        .foregroundColor: config.baseColor,
                    ])
                    segments.append(.richText(line))
                }
                for child in item.children {
                    append(
                        block: child,
                        baseURL: baseURL,
                        config: config,
                        into: &segments,
                        imageCount: &imageCount,
                        omittedImages: &omittedImages
                    )
                }
            }

        case .codeBlock(_, let code):
            // Code is source by nature, but clip and show as monospaced readable block —
            // never the whole topic's markdown raw.
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let clipped = trimmed.count > 280 ? String(trimmed.prefix(280)) + "…" : trimmed
                let attr = NSAttributedString(string: clipped, attributes: [
                    .font: config.codeFont,
                    .foregroundColor: config.baseColor.withAlphaComponent(0.9),
                    .backgroundColor: config.codeBackgroundColor,
                ])
                segments.append(.richText(attr))
            }

        case .onebox(_, let title, let description, let imageURL, _, _, _):
            var lines: [String] = []
            if let title, !title.isEmpty { lines.append(title) }
            if let description, !description.isEmpty { lines.append(description) }
            if !lines.isEmpty {
                segments.append(.text(lines.joined(separator: "\n")))
            }
            if let imageURL {
                appendImage(src: imageURL, baseURL: baseURL, into: &segments, imageCount: &imageCount, omittedImages: &omittedImages)
            }

        case .video(_, let thumbnailURL, let title, _, _, _, _):
            if let title, !title.isEmpty {
                segments.append(.text(title))
            }
            if let thumbnailURL {
                appendImage(src: thumbnailURL, baseURL: baseURL, into: &segments, imageCount: &imageCount, omittedImages: &omittedImages)
            }

        case .details(let summary, let content):
            let summaryAttr = summary.attributedString(config: config)
            if summaryAttr.length > 0 {
                segments.append(.richText(summaryAttr))
            }
            for child in content {
                append(
                    block: child,
                    baseURL: baseURL,
                    config: config,
                    into: &segments,
                    imageCount: &imageCount,
                    omittedImages: &omittedImages
                )
            }

        case .table(let headers, let rows):
            let headerText = headers
                .map { plainText(fromBlocks: $0) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            if !headerText.isEmpty {
                segments.append(.text(headerText))
            }
            for row in rows.prefix(4) {
                let rowText = row
                    .map { plainText(fromBlocks: $0) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                if !rowText.isEmpty {
                    segments.append(.text(rowText))
                }
            }

        case .poll(let poll):
            let options = poll.options.map(\.text).filter { !$0.isEmpty }.prefix(6).joined(separator: " / ")
            if !options.isEmpty {
                segments.append(.text(options))
            }

        case .policy(let policy):
            for child in policy.content {
                append(
                    block: child,
                    baseURL: baseURL,
                    config: config,
                    into: &segments,
                    imageCount: &imageCount,
                    omittedImages: &omittedImages
                )
            }

        case .rawHTML(let html):
            // Re-parse raw HTML islands through the shared pipeline so we never
            // dump markdown/source leftovers onto the card.
            let nested = CookedContentPipeline.blocks(fromCooked: normalizeCookedInput(html), baseURL: baseURL)
            if nested.count == 1, case .rawHTML = nested[0] {
                // Still opaque after re-parse — pipeline plain text only (never raw MD dump).
                let plain = stripMarkdownArtifacts(
                    CookedContentPipeline.plainTextPreview(fromCooked: html, baseURL: baseURL)
                )
                if !plain.isEmpty {
                    segments.append(.text(plain))
                }
            } else {
                for child in nested {
                    append(
                        block: child,
                        baseURL: baseURL,
                        config: config,
                        into: &segments,
                        imageCount: &imageCount,
                        omittedImages: &omittedImages
                    )
                }
            }

        case .divider:
            break
        }
    }

    private static func append(
        inlines: [InlineNode],
        baseURL: String,
        config: AttributedStringConfig,
        into segments: inout [ShareImageBodySegment],
        imageCount: inout Int,
        omittedImages: inout Int
    ) {
        var textNodes: [InlineNode] = []
        func flushText() {
            guard !textNodes.isEmpty else { return }
            let attr = textNodes.attributedString(config: config)
            textNodes = []
            let trimmed = trimmedAttributedString(attr)
            if trimmed.length > 0 {
                segments.append(.richText(trimmed))
            }
        }

        for node in inlines {
            switch node {
            case .image(let src, let alt, _, _, let isEmoji):
                if isEmoji {
                    // Inline emoji: keep alt/shortcode text so meaning isn't dropped.
                    let label = (alt?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? " "
                    textNodes.append(.text(label))
                    continue
                }
                flushText()
                appendImage(src: src, baseURL: baseURL, into: &segments, imageCount: &imageCount, omittedImages: &omittedImages)
            default:
                textNodes.append(node)
            }
        }
        flushText()
    }

    private static func appendImage(
        src: String,
        baseURL: String,
        into segments: inout [ShareImageBodySegment],
        imageCount: inout Int,
        omittedImages: inout Int
    ) {
        guard let url = resolveURL(src, baseURL: baseURL) else { return }
        if imageCount >= maxImages {
            omittedImages += 1
            return
        }
        imageCount += 1
        segments.append(.image(url))
    }

    private static func plainText(fromBlocks blocks: [ContentBlock]) -> String {
        // Shared exporter keeps table/list/rawHTML cells aligned with export & AI.
        let exported = CookedTextExporter.plainText(from: blocks)
        let collapsed = collapseWhitespace(
            exported.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        )
        if !collapsed.isEmpty { return collapsed }

        var parts: [String] = []
        for block in blocks {
            switch block {
            case .paragraph(let inlines), .heading(_, let inlines):
                let text = inlines.attributedString().string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { parts.append(text) }
            case .rawHTML(let html):
                let stripped = CookedContentPipeline.plainTextPreview(fromCooked: html)
                if !stripped.isEmpty { parts.append(stripped) }
            default:
                break
            }
        }
        return parts.joined(separator: " ")
    }

    private static func trimmedAttributedString(_ attr: NSAttributedString) -> NSAttributedString {
        let ns = attr.string as NSString
        let length = ns.length
        guard length > 0 else { return NSAttributedString() }

        var start = 0
        while start < length,
              CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: start))!) {
            start += 1
        }
        var end = length
        while end > start,
              CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: end - 1))!) {
            end -= 1
        }
        guard end > start else { return NSAttributedString() }
        return attr.attributedSubstring(from: NSRange(location: start, length: end - start))
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveURL(_ raw: String, baseURL: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        let normalizedBase = baseURL.hasSuffix("/") ? baseURL : baseURL + "/"
        return URL(string: trimmed, relativeTo: URL(string: normalizedBase))?.absoluteURL
    }
}
