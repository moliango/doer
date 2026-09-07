import Foundation
import SwiftSoup

/// Extracts inline nodes from a DOM element's children.
enum InlineExtractor {
    /// Extract inline nodes from the children of the given element.
    static func extract(from element: Element, options: ParseOptions, style: TextStyle = []) -> [InlineNode] {
        var nodes: [InlineNode] = []
        for child in element.getChildNodes() {
            nodes.append(contentsOf: extractNode(child, options: options, style: style))
        }
        return applyMarkdownEmphasis(mergeAdjacentText(nodes))
    }

    /// linux.do 公益推广 / checklist forms leave unpaired `**` in cooked HTML
    /// (`**项目：是` or `**<br>link<br>**`). Paired CommonMark already works;
    /// this pass also treats leftover `**` / `__` as a bold toggle across nodes.
    /// Leftover `` `code` `` spans are applied first so they win over emphasis.
    static func applyMarkdownEmphasis(_ nodes: [InlineNode]) -> [InlineNode] {
        applyMarkdownEmphasis(applyMarkdownCodeSpans(nodes), bold: false)
    }

    private static func applyMarkdownEmphasis(_ nodes: [InlineNode], bold initialBold: Bool) -> [InlineNode] {
        var bold = initialBold
        var result: [InlineNode] = []
        var justConsumedDelimiter = false

        func appendSplit(_ text: String, style: TextStyle) {
            let parts = splitBoldDelimiters(text)
            guard parts.count > 1 || text.contains("**") || text.contains("__") else {
                emit(text, style: style)
                justConsumedDelimiter = false
                return
            }
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    bold.toggle()
                    justConsumedDelimiter = true
                }
                if !part.isEmpty {
                    emit(part, style: style)
                    justConsumedDelimiter = false
                }
            }
        }

        func emit(_ text: String, style: TextStyle) {
            guard !text.isEmpty else { return }
            let resolved = bold ? style.union(.bold) : style
            result.append(resolved.isEmpty ? .text(text) : .styledText(text, resolved))
        }

        for (index, node) in nodes.enumerated() {
            switch node {
            case .text(let text):
                appendSplit(text, style: [])
            case .styledText(let text, let style):
                appendSplit(text, style: style)
            case .link(let href, let children):
                justConsumedDelimiter = false
                result.append(.link(
                    href: href,
                    children: applyMarkdownEmphasis(children, bold: bold)
                ))
            case .spoiler(let children):
                justConsumedDelimiter = false
                result.append(.spoiler(children: applyMarkdownEmphasis(children, bold: bold)))
            case .lineBreak:
                let nextIsDelimiter = nodes.dropFirst(index + 1).first.map(isDelimiterOnlyNode) ?? false
                if justConsumedDelimiter || nextIsDelimiter {
                    continue
                }
                result.append(.lineBreak)
            default:
                justConsumedDelimiter = false
                result.append(node)
            }
        }

        return mergeAdjacentText(result)
    }

    /// Discourse usually cooks `` `code` `` to `<code>`, but checklist / 公益推广
    /// HTML sometimes leaves the backticks as text — same class of leftover as `**`.
    private static func applyMarkdownCodeSpans(_ nodes: [InlineNode]) -> [InlineNode] {
        var result: [InlineNode] = []
        for node in nodes {
            switch node {
            case .text(let text):
                result.append(contentsOf: splitCodeSpans(text, style: []))
            case .styledText(let text, let style):
                result.append(contentsOf: splitCodeSpans(text, style: style))
            case .link(let href, let children):
                result.append(.link(href: href, children: applyMarkdownCodeSpans(children)))
            case .spoiler(let children):
                result.append(.spoiler(children: applyMarkdownCodeSpans(children)))
            default:
                result.append(node)
            }
        }
        return mergeAdjacentText(result)
    }

    private static func splitCodeSpans(_ text: String, style: TextStyle) -> [InlineNode] {
        guard text.contains("`") || text.contains("｀") else {
            return styledTextNodes(text, style: style)
        }

        var nodes: [InlineNode] = []
        var cursor = text.startIndex

        func flush(upTo end: String.Index) {
            guard cursor < end else { return }
            nodes.append(contentsOf: styledTextNodes(String(text[cursor..<end]), style: style))
            cursor = end
        }

        while cursor < text.endIndex {
            let character = text[cursor]
            guard character == "`" || character == "｀" else {
                let next = text[cursor...].firstIndex(where: { $0 == "`" || $0 == "｀" }) ?? text.endIndex
                flush(upTo: next)
                continue
            }

            var runEnd = cursor
            while runEnd < text.endIndex, text[runEnd] == character {
                runEnd = text.index(after: runEnd)
            }
            let runLength = text.distance(from: cursor, to: runEnd)
            if let closing = findClosingCodeDelimiter(
                in: text,
                from: runEnd,
                delimiter: character,
                count: runLength
            ) {
                let raw = String(text[runEnd..<closing.start])
                let content = stripCodeSpanPadding(raw)
                if !content.isEmpty {
                    nodes.append(.code(content))
                }
                cursor = closing.end
            } else {
                flush(upTo: runEnd)
            }
        }

        return nodes
    }

    private static func findClosingCodeDelimiter(
        in text: String,
        from start: String.Index,
        delimiter: Character,
        count: Int
    ) -> (start: String.Index, end: String.Index)? {
        var index = start
        while index < text.endIndex {
            if text[index] == delimiter {
                var runEnd = index
                while runEnd < text.endIndex, text[runEnd] == delimiter {
                    runEnd = text.index(after: runEnd)
                }
                if text.distance(from: index, to: runEnd) == count {
                    return (index, runEnd)
                }
                index = runEnd
            } else {
                index = text.index(after: index)
            }
        }
        return nil
    }

    private static func stripCodeSpanPadding(_ content: String) -> String {
        guard content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" ") else {
            return content
        }
        return String(content.dropFirst().dropLast())
    }

    private static func styledTextNodes(_ text: String, style: TextStyle) -> [InlineNode] {
        guard !text.isEmpty else { return [] }
        return [style.isEmpty ? .text(text) : .styledText(text, style)]
    }

    private static func isDelimiterOnlyNode(_ node: InlineNode) -> Bool {
        switch node {
        case .text(let text), .styledText(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "**" || trimmed == "__"
        default:
            return false
        }
    }

    private static func splitBoldDelimiters(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\*\*|__"#) else {
            return [text]
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return [text] }

        var parts: [String] = []
        var cursor = 0
        for match in matches {
            parts.append(nsText.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            )))
            cursor = match.range.location + match.range.length
        }
        parts.append(nsText.substring(from: cursor))
        return parts
    }

    /// Extract inline nodes from a single DOM node.
    static func extractNode(_ node: Node, options: ParseOptions, style: TextStyle = []) -> [InlineNode] {
        if let textNode = node as? TextNode {
            let text = textNode.getWholeText()
            if text.allSatisfy({ $0.isWhitespace }) && text.contains("\n") {
                // Collapse pure whitespace containing newlines to a single space
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [.text(" ")] : [.text(text)]
            }
            return style.isEmpty ? [.text(text)] : [.styledText(text, style)]
        }
        guard let element = node as? Element else { return [] }
        let tagName = element.tagName().lowercased()

        switch tagName {
        case "strong", "b":
            return extract(from: element, options: options, style: style.union(.bold))

        case "em", "i":
            return extract(from: element, options: options, style: style.union(.italic))

        case "s", "del":
            return extract(from: element, options: options, style: style.union(.strikethrough))

        case "a":
            let href = resolveURL((try? element.attr("href")) ?? "", options: options)
            let classAttr = (try? element.attr("class")) ?? ""
            if classAttr.contains("mention-group") {
                let text = (try? element.text()) ?? ""
                let name = text.hasPrefix("@") ? String(text.dropFirst()) : text
                return [.mentionGroup(name: name, href: href)]
            }
            if classAttr.contains("mention") {
                let text = (try? element.text()) ?? ""
                let username = text.hasPrefix("@") ? String(text.dropFirst()) : text
                return [.mention(username: username, href: href)]
            }
            if classAttr.contains("hashtag-cooked") || classAttr.contains("hashtag") {
                let text = (try? element.text()) ?? ""
                let displayText = text.hasPrefix("#") ? String(text.dropFirst()) : text
                let dataType = try? element.attr("data-type")
                let type = (dataType?.isEmpty == false) ? dataType : nil
                return [.hashtag(
                    text: displayText.trimmingCharacters(in: .whitespacesAndNewlines),
                    href: href,
                    type: type,
                    icon: extractHashtagIcon(from: element)
                )]
            }
            let children = extract(from: element, options: options, style: style)
            return [.link(href: href, children: children)]

        case "img":
            return extractImage(from: element, options: options)

        case "code":
            let text = (try? element.text()) ?? ""
            return [.code(text)]

        case "br":
            return [.lineBreak]

        case "span":
            let classAttr = (try? element.attr("class")) ?? ""
            if classAttr.contains("spoiler") {
                let children = extract(from: element, options: options, style: style)
                return [.spoiler(children: children)]
            }
            return extract(from: element, options: options, style: style)

        case "div":
            let classAttr = (try? element.attr("class")) ?? ""
            if classAttr.contains("lightbox-wrapper") {
                if let img = try? element.select("img").first() {
                    let imageNodes = extractImage(from: img, options: options)
                    if let anchor = try? element.select("a.lightbox").first(),
                       let href = try? anchor.attr("href"), !href.isEmpty {
                        let resolvedHref = resolveURL(href, options: options)
                        return [.link(href: resolvedHref, children: imageNodes)]
                    }
                    return imageNodes
                }
            }
            return extract(from: element, options: options, style: style)

        default:
            // For other inline elements, just recurse into children
            return extract(from: element, options: options, style: style)
        }
    }

    /// Extract an image inline node from an `<img>` element.
    private static func extractImage(from element: Element, options: ParseOptions) -> [InlineNode] {
        let rawSrc = ((try? element.attr("src")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSrc.isEmpty else { return [] }
        let src = resolveURL(rawSrc, options: options)
        guard !src.isEmpty else { return [] }
        let alt = try? element.attr("alt")
        let width = Int((try? element.attr("width")) ?? "")
        let height = Int((try? element.attr("height")) ?? "")

        let classAttr = (try? element.attr("class")) ?? ""
        let isEmoji = classAttr.contains("emoji")

        return [.image(src: src, alt: alt, width: width, height: height, isEmoji: isEmoji)]
    }

    /// Resolve a URL using the parse options.
    private static func resolveURL(_ url: String, options: ParseOptions) -> String {
        URLResolver.resolve(url, baseURL: options.baseURL)
    }

    /// Merge adjacent `.text` nodes and adjacent `.styledText` nodes with the same style.
    private static func mergeAdjacentText(_ nodes: [InlineNode]) -> [InlineNode] {
        guard !nodes.isEmpty else { return [] }
        var result: [InlineNode] = []

        for node in nodes {
            guard let last = result.last else {
                result.append(node)
                continue
            }
            switch (last, node) {
            case (.text(let a), .text(let b)):
                result[result.count - 1] = .text(a + b)
            case (.styledText(let a, let styleA), .styledText(let b, let styleB)) where styleA == styleB:
                result[result.count - 1] = .styledText(a + b, styleA)
            default:
                result.append(node)
            }
        }

        // Remove empty text nodes
        return result.filter { node in
            switch node {
            case .text(let t) where t.isEmpty: return false
            case .styledText(let t, _) where t.isEmpty: return false
            default: return true
            }
        }
    }

    /// Discourse 3 hashtag chips: `data-icon`, `d-icon-shuffle`, or `<use href="#shuffle">`.
    static func extractHashtagIcon(from element: Element) -> String? {
        if let value = nonEmptyIconAttr(element, "data-icon") {
            return value
        }
        let descendants = (try? element.getAllElements())?.array() ?? []
        for child in descendants {
            if let value = nonEmptyIconAttr(child, "data-icon") {
                return value
            }
            if let name = dIconName(fromClass: (try? child.attr("class")) ?? "") {
                return name
            }
            if child.tagName().lowercased() == "use" {
                let href = (try? child.attr("href"))
                    ?? (try? child.attr("xlink:href"))
                    ?? ""
                if href.hasPrefix("#"), href.count > 1 {
                    return normalizeIconName(String(href.dropFirst()))
                }
            }
        }
        return nil
    }

    private static func nonEmptyIconAttr(_ element: Element, _ name: String) -> String? {
        let value = (try? element.attr(name))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : normalizeIconName(value)
    }

    private static func dIconName(fromClass classAttr: String) -> String? {
        for part in classAttr.split(whereSeparator: \.isWhitespace).map(String.init) {
            guard part.hasPrefix("d-icon-") else { continue }
            let name = String(part.dropFirst("d-icon-".count))
            if !name.isEmpty { return normalizeIconName(name) }
        }
        return nil
    }

    private static func normalizeIconName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("fa-") {
            name = String(name.dropFirst(3))
        }
        return name
    }
}
