import Foundation

/// Shared cooked → plain / markdown text (Phase 4 content pipeline).
/// Used by export, AI context, and any caller that needs readable text without bare MD source.
public enum CookedTextExporter {
    /// Parse cooked HTML and flatten to readable plain text.
    public static func plainText(fromHTML html: String, baseURL: String? = nil) -> String {
        let blocks = CookedHTMLParser.parse(html: html, baseURL: baseURL)
        return plainText(from: blocks)
    }

    /// Flatten content blocks to plain text (no HTML tags).
    public static func plainText(from blocks: [ContentBlock]) -> String {
        let parts = blocks.compactMap { plainText(for: $0) }
        return normalizeWhitespace(parts.joined(separator: "\n\n"))
    }

    /// Flatten to lightweight markdown (lists, code fences, images as `![]()`).
    public static func markdown(fromHTML html: String, baseURL: String? = nil) -> String {
        let blocks = CookedHTMLParser.parse(html: html, baseURL: baseURL)
        return markdown(from: blocks)
    }

    public static func markdown(from blocks: [ContentBlock]) -> String {
        let parts = blocks.compactMap { markdown(for: $0) }
        return normalizeWhitespace(parts.joined(separator: "\n\n"))
    }

    // MARK: - Plain

    private static func plainText(for block: ContentBlock) -> String? {
        switch block {
        case .paragraph(let inlines):
            let text = inlinePlain(inlines)
            return text.isEmpty ? nil : text
        case .heading(_, let inlines):
            let text = inlinePlain(inlines)
            return text.isEmpty ? nil : text
        case .codeBlock(_, let code):
            return code.trimmingCharacters(in: .whitespacesAndNewlines)
        case .blockquote(let blocks), .spoiler(let blocks):
            return plainText(from: blocks)
        case .discourseQuote(let username, _, _, _, _, _, _, let content):
            let body = plainText(from: content)
            if let username, !username.isEmpty {
                return "@\(username):\n\(body)"
            }
            return body
        case .image(_, let alt, _, _, _):
            let label = alt?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (label?.isEmpty == false) ? "[\(label!)]" : "[image]"
        case .imageGrid(let images, _, _):
            let labels = images.map { item -> String in
                let label = item.alt?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (label?.isEmpty == false) ? "[\(label!)]" : "[image]"
            }
            return labels.joined(separator: " ")
        case .onebox(_, let title, let description, _, _, _, _):
            return [title, description]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
        case .video(_, _, let title, _, _, _, _):
            return title?.isEmpty == false ? title! : "[video]"
        case .list(let ordered, let start, let items):
            let first = max(start, 1)
            return items.enumerated().compactMap { index, item in
                let prefix = ordered ? "\(first + index). " : "• "
                let line = inlinePlain(item.content)
                let nested = plainText(from: item.children)
                if nested.isEmpty { return prefix + line }
                return prefix + line + "\n" + nested
            }.joined(separator: "\n")
        case .poll(let poll):
            let options = poll.options.map(\.text).filter { !$0.isEmpty }.joined(separator: " | ")
            return options.isEmpty ? "[poll]" : "[poll] \(options)"
        case .policy(let policy):
            return plainText(from: policy.content)
        case .table(let headers, let rows):
            var lines: [String] = []
            if !headers.isEmpty {
                lines.append(headers.map { plainText(from: $0) }.joined(separator: " | "))
            }
            for row in rows {
                lines.append(row.map { plainText(from: $0) }.joined(separator: " | "))
            }
            return lines.joined(separator: "\n")
        case .details(let summary, let content):
            let head = inlinePlain(summary)
            let body = plainText(from: content)
            return [head, body].filter { !$0.isEmpty }.joined(separator: "\n")
        case .divider:
            return "---"
        case .rawHTML(let html):
            // Last resort: strip tags rather than emit source.
            return stripTags(html)
        }
    }

    // MARK: - Markdown

    private static func markdown(for block: ContentBlock) -> String? {
        switch block {
        case .paragraph(let inlines):
            let text = inlinePlain(inlines)
            return text.isEmpty ? nil : text
        case .heading(let level, let inlines):
            let text = inlinePlain(inlines)
            guard !text.isEmpty else { return nil }
            let marks = String(repeating: "#", count: min(max(level, 1), 6))
            return "\(marks) \(text)"
        case .codeBlock(let language, let code):
            let lang = language ?? ""
            return "```\(lang)\n\(code)\n```"
        case .blockquote(let blocks):
            return markdown(from: blocks)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
        case .spoiler(let blocks):
            return "[spoiler]\n\(markdown(from: blocks))\n[/spoiler]"
        case .discourseQuote(let username, _, _, _, _, _, _, let content):
            let body = markdown(from: content)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }
                .joined(separator: "\n")
            if let username, !username.isEmpty {
                return "> @\(username)\n\(body)"
            }
            return body
        case .image(let src, let alt, _, _, _):
            return "![\(alt ?? "")](\(src))"
        case .imageGrid(let images, _, let mode):
            let body = images.map { "![\($0.alt ?? "")](\($0.src))" }.joined(separator: "\n")
            return mode == .carousel ? "[grid mode=carousel]\n\(body)" : "[grid]\n\(body)"
        case .onebox(let sourceURL, let title, let description, _, _, _, _):
            let label = title ?? description ?? sourceURL ?? "link"
            if let sourceURL, !sourceURL.isEmpty {
                return "[\(label)](\(sourceURL))"
            }
            return label
        case .video(let url, _, let title, _, _, _, _):
            return "[\(title ?? "video")](\(url))"
        case .list(let ordered, let start, let items):
            let first = max(start, 1)
            return items.enumerated().map { index, item in
                let prefix = ordered ? "\(first + index). " : "- "
                let line = inlinePlain(item.content)
                let nested = markdown(from: item.children)
                if nested.isEmpty { return prefix + line }
                let indented = nested.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n")
                return prefix + line + "\n" + indented
            }.joined(separator: "\n")
        case .poll(let poll):
            let options = poll.options.map { "- [ ] \($0.text)" }.joined(separator: "\n")
            return options.isEmpty ? nil : options
        case .policy(let policy):
            return markdown(from: policy.content)
        case .table(let headers, let rows):
            var lines: [String] = []
            if !headers.isEmpty {
                let cells = headers.map { plainText(from: $0) }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                lines.append("| " + cells.map { _ in "---" }.joined(separator: " | ") + " |")
            }
            for row in rows {
                let cells = row.map { plainText(from: $0) }
                lines.append("| " + cells.joined(separator: " | ") + " |")
            }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .details(let summary, let content):
            let head = inlinePlain(summary)
            return "[details=\"\(head)\"]\n\(markdown(from: content))\n[/details]"
        case .divider:
            return "---"
        case .rawHTML(let html):
            return stripTags(html)
        }
    }

    // MARK: - Inlines

    private static func inlinePlain(_ nodes: [InlineNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let t), .styledText(let t, _), .code(let t):
                return t
            case .link(_, let children), .spoiler(let children):
                return inlinePlain(children)
            case .image(_, let alt, _, _, _):
                return alt ?? ""
            case .lineBreak:
                return "\n"
            case .mention(let username, _):
                return "@\(username)"
            case .mentionGroup(let name, _):
                return "@\(name)"
            case .hashtag(let text, _, _):
                return text.hasPrefix("#") ? text : "#\(text)"
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
