import Foundation
import SwiftSoup

/// Extracts a `[ContentBlock]` array from the children of a DOM element.
enum BlockExtractor {
    /// Tags treated as block-level elements.
    private static let blockTags: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6",
        "pre", "blockquote", "aside",
        "ul", "ol",
        "table",
        "details",
        "hr",
        "div", "figure",
    ]

    /// Extract content blocks from a parent element's children.
    static func extract(from parent: Element, options: ParseOptions) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        for child in parent.getChildNodes() {
            blocks.append(contentsOf: extractNode(child, options: options))
        }
        return finalizeBlocks(mergeInlineImageBlocks(blocks))
    }

    /// Extract blocks treating `element` itself as the root node (not only its children).
    ///
    /// Used by list-item parsing so wrappers like `div.lightbox-wrapper` run through
    /// `extractDiv` / `extractParagraph` and become real `.image` blocks.
    static func extractBlocks(for element: Element, options: ParseOptions) -> [ContentBlock] {
        finalizeBlocks(mergeInlineImageBlocks(extractNode(element, options: options)))
    }

    /// Extract annotated blocks (block + source HTML) from a parent element's children.
    static func extractAnnotated(from parent: Element, options: ParseOptions) -> [AnnotatedBlock] {
        var raw: [AnnotatedBlock] = []
        for child in parent.getChildNodes() {
            let blocks = extractNode(child, options: options).compactMap { trimBlock($0) }
            guard !blocks.isEmpty else { continue }
            let sourceHTML: String
            if let element = child as? Element {
                sourceHTML = (try? element.outerHtml()) ?? ""
            } else if let textNode = child as? TextNode {
                sourceHTML = textNode.getWholeText()
            } else {
                sourceHTML = ""
            }
            for block in blocks {
                raw.append(AnnotatedBlock(block: block, sourceHTML: sourceHTML))
            }
        }
        // Apply the same inline-image merging as extract(), preserving sourceHTML by
        // concatenating the HTML of merged siblings.
        guard raw.count > 1 else {
            return finalizeAnnotatedBlocks(raw)
        }
        var result: [AnnotatedBlock] = []
        for annotated in raw {
            guard let lastIndex = result.indices.last else {
                result.append(annotated)
                continue
            }
            let prev = result[lastIndex]
            // Case 1: small image → inline emoji in preceding paragraph
            if case .image(let src, let alt, let w, let h, _) = annotated.block,
               let w, let h, w <= 80, h <= 80,
               case .paragraph(let inlines) = prev.block
            {
                let merged = ContentBlock.paragraph(inlines + [.image(src: src, alt: alt, width: w, height: h, isEmoji: true)])
                result[lastIndex] = AnnotatedBlock(block: merged, sourceHTML: prev.sourceHTML + annotated.sourceHTML)
                continue
            }
            // Case 2: paragraph following a paragraph that ends with inline emoji → merge
            if case .paragraph(let newInlines) = annotated.block,
               case .paragraph(let prevInlines) = prev.block,
               case .image(_, _, _, _, let isEmoji) = prevInlines.last, isEmoji
            {
                let merged = ContentBlock.paragraph(prevInlines + newInlines)
                result[lastIndex] = AnnotatedBlock(block: merged, sourceHTML: prev.sourceHTML + annotated.sourceHTML)
                continue
            }
            result.append(annotated)
        }
        return finalizeAnnotatedBlocks(result)
    }

    /// Extract content blocks from a single DOM node.
    private static func extractNode(_ node: Node, options: ParseOptions) -> [ContentBlock] {
        if let textNode = node as? TextNode {
            let raw = textNode.getWholeText()
            // Trim leading whitespace/newlines but preserve meaningful trailing spaces
            // (they serve as word separators when adjacent inline elements are merged).
            let text = raw.replacingOccurrences(of: "^[\\s]+", with: "", options: .regularExpression)
            if text.isEmpty { return [] }
            return [.paragraph([.text(text)])]
        }

        guard let element = node as? Element else { return [] }
        let tagName = element.tagName().lowercased()

        switch tagName {
        case "p":
            return extractParagraph(from: element, options: options)

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tagName.last!))!
            let inlines = InlineExtractor.extract(from: element, options: options)
            if inlines.isEmpty { return [] }
            return [.heading(level: level, content: inlines)]

        case "pre":
            return extractCodeBlock(from: element)

        case "blockquote":
            let inner = extract(from: element, options: options)
            if inner.isEmpty { return [] }
            return [.blockquote(blocks: inner)]

        case "aside":
            return extractAside(from: element, options: options)

        case "ul":
            return [ListExtractor.extract(from: element, ordered: false, options: options)]

        case "ol":
            return [ListExtractor.extract(from: element, ordered: true, options: options)]

        case "table":
            if isHighlightJSLineNumberTable(element) {
                return extractCodeBlock(from: element)
            }
            return [TableExtractor.extract(from: element, options: options)]

        case "details":
            return extractDetails(from: element, options: options)

        case "br":
            // Bare <br> at block level is a DOM artifact from SwiftSoup splitting block-in-inline;
            // ignore it rather than emitting a lineBreak paragraph.
            return []

        case "hr":
            return [.divider]

        case "img":
            return extractBlockImage(from: element, options: options)

        case "a":
            // Table cells and unwrapped markdown often emit `<a href="..."><img></a>`
            // at block level. Keep the CDN `src`; the href may be a GitHub blob page.
            if let img = soleChildImage(in: element) {
                let href = URLResolver.resolve((try? element.attr("href")) ?? "", baseURL: options.baseURL)
                return extractBlockImage(from: img, options: options, href: href.isEmpty ? nil : href)
            }
            let inlines = InlineExtractor.extractNode(element, options: options)
            if inlines.isEmpty { return [] }
            return [.paragraph(inlines)]
        case "div", "figure", "section", "article":
            // Check for specific div patterns first, otherwise recurse
            return extractDiv(from: element, options: options)

        default:
            // Unknown block-level or inline elements at top level
            if isBlockElement(element) {
                return extract(from: element, options: options)
            }
            // Inline spoiler at block level (e.g. <span class="spoiler"> wrapping block children in a <td>)
            let classAttr = (try? element.attr("class")) ?? ""
            if classAttr.contains("spoiler") {
                let inner = extract(from: element, options: options)
                if inner.isEmpty { return [] }
                return [.spoiler(blocks: inner)]
            }
            // Inline element at block level — extract as inline node preserving tag semantics (bold, link, etc.)
            let inlines = InlineExtractor.extractNode(element, options: options)
            if inlines.isEmpty { return [] }
            return [.paragraph(inlines)]
        }
    }

    // MARK: - Specific extractors

    private static func extractParagraph(from element: Element, options: ParseOptions) -> [ContentBlock] {
        // Check if paragraph only contains a single image
        let children = element.children()
        if children.size() == 1,
           let onlyChild = children.first(),
           element.textNodes().allSatisfy({ $0.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        {
            let childTag = onlyChild.tagName().lowercased()

            // <p><img></p>
            if childTag == "img" {
                return extractBlockImage(from: onlyChild, options: options)
            }

            // <p><a><img></a></p>
            if childTag == "a",
               onlyChild.children().size() == 1,
               let innerImg = onlyChild.children().first(),
               innerImg.tagName().lowercased() == "img"
            {
                let href = URLResolver.resolve((try? onlyChild.attr("href")) ?? "", baseURL: options.baseURL)
                return extractBlockImage(from: innerImg, options: options, href: href.isEmpty ? nil : href)
            }

            // <p><div class="lightbox-wrapper">...</div></p>
            if childTag == "div" || childTag == "figure" {
                return extractDiv(from: onlyChild, options: options)
            }

            // Invalid HTML some themes emit: <p><pre><code>…</code></pre></p>
            if childTag == "pre" {
                return extractCodeBlock(from: onlyChild)
            }
        }

        let inlines = InlineExtractor.extract(from: element, options: options)
        if inlines.isEmpty { return [] }
        return [.paragraph(inlines)]
    }

    private static func extractCodeBlock(from element: Element) -> [ContentBlock] {
        let codeElement = element.children().first { $0.tagName().lowercased() == "code" }
            ?? element
        let language = codeLanguage(from: element, codeElement: codeElement)
        let code = codeText(from: codeElement)
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        return [.codeBlock(language: language, code: code)]
    }

    private static func extractAside(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let classAttr = (try? element.attr("class")) ?? ""
        if classAttr.contains("quote") {
            return [QuoteExtractor.extract(from: element, options: options)]
        }
        if classAttr.contains("onebox") {
            // FluxDo keeps OneboxNode.rawHtml and the app's GitHub/gist builder
            // renders nested <pre><code>. CookedHTML only stores title/description,
            // so lift those nested code fences into sibling `.codeBlock`s.
            let onebox = OneboxExtractor.extract(from: element, options: options)
            return [onebox] + nestedCodeBlocks(from: element)
        }
        // Generic aside — recurse
        return extract(from: element, options: options)
    }

    /// GitHub blob/gist (and pastebin) oneboxes embed file contents in `<pre>`.
    private static func nestedCodeBlocks(from element: Element) -> [ContentBlock] {
        let pres = (try? element.select("pre")) ?? Elements()
        return pres.array().flatMap { extractCodeBlock(from: $0) }
    }

    private static func extractDetails(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let summaryEl = element.children().first { $0.tagName().lowercased() == "summary" }
        let summaryInlines: [InlineNode]
        if let summaryEl {
            summaryInlines = InlineExtractor.extract(from: summaryEl, options: options).trimmedWhitespace()
        } else {
            summaryInlines = [.text("Details")]
        }

        // Content is everything except the summary element
        var contentBlocks: [ContentBlock] = []
        for child in element.getChildNodes() {
            if let el = child as? Element, el.tagName().lowercased() == "summary" { continue }
            contentBlocks.append(contentsOf: extractNode(child, options: options))
        }

        return [.details(summary: summaryInlines, content: contentBlocks)]
    }

    private static func extractBlockImage(from element: Element, options: ParseOptions, href: String? = nil) -> [ContentBlock] {
        let rawSrc = ((try? element.attr("src")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSrc.isEmpty else { return [] }
        let src = URLResolver.resolve(rawSrc, baseURL: options.baseURL)
        guard !src.isEmpty else { return [] }
        let alt = try? element.attr("alt")
        let width = Int((try? element.attr("width")) ?? "")
        let height = Int((try? element.attr("height")) ?? "")
        return [.image(src: src, alt: alt, width: width, height: height, href: href)]
    }

    /// Single `<img>` child, ignoring whitespace-only text nodes.
    private static func soleChildImage(in element: Element) -> Element? {
        let children = element.children()
        guard children.size() == 1,
              let img = children.first(),
              img.tagName().lowercased() == "img"
        else { return nil }
        let hasExtraText = element.textNodes().contains {
            !$0.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return hasExtraText ? nil : img
    }

    private static func extractImageGrid(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let classAttr = (try? element.attr("class")) ?? ""
        let dataMode = ((try? element.attr("data-mode")) ?? "").lowercased()
        let mode: ImageGridMode =
            dataMode == "carousel" || hasClassToken("d-image-grid--carousel", in: classAttr)
            ? .carousel
            : .grid
        let columns = max(Int((try? element.attr("data-columns")) ?? "") ?? 2, 1)

        var images: [ImageGridItem] = []
        for child in element.children() {
            let childClass = (try? child.attr("class")) ?? ""
            if childClass.contains("lightbox-wrapper") {
                guard let img = try? child.select("img").first(),
                      let item = imageGridItem(from: img, wrapper: child, options: options)
                else { continue }
                images.append(item)
                continue
            }
            if child.tagName().lowercased() == "img" {
                guard let item = imageGridItem(from: child, wrapper: nil, options: options) else { continue }
                images.append(item)
            }
        }

        guard !images.isEmpty else { return [] }
        return [.imageGrid(images: images, columns: columns, mode: mode)]
    }

    private static func imageGridItem(
        from img: Element,
        wrapper: Element?,
        options: ParseOptions
    ) -> ImageGridItem? {
        let imgClass = (try? img.attr("class")) ?? ""
        if hasClassToken("emoji", in: imgClass) || hasClassToken("avatar", in: imgClass) {
            return nil
        }
        let rawSrc = ((try? img.attr("src")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawSrc.isEmpty else { return nil }
        let src = URLResolver.resolve(rawSrc, baseURL: options.baseURL)
        guard !src.isEmpty else { return nil }

        let href: String? = {
            let anchor = wrapper.flatMap { try? $0.select("a").first() } ?? (try? img.parent()?.select("a").first())
            guard let anchor else { return nil }
            let resolved = URLResolver.resolve((try? anchor.attr("href")) ?? "", baseURL: options.baseURL)
            return resolved.isEmpty ? nil : resolved
        }()
        return ImageGridItem(
            src: src,
            alt: try? img.attr("alt"),
            width: Int((try? img.attr("width")) ?? ""),
            height: Int((try? img.attr("height")) ?? ""),
            href: href
        )
    }

    private static func extractDiv(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let classAttr = (try? element.attr("class")) ?? ""
        let idAttr = (try? element.attr("id")) ?? ""

        if hasClassToken("mermaid", in: classAttr) || idAttr.lowercased().hasPrefix("flowchart") {
            let code = rawText(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                return [.codeBlock(language: "mermaid", code: code)]
            }
        }

        if let wrap = mermaidWrapName(from: element) {
            let nested = nestedCodeBlocks(from: element)
            if !nested.isEmpty {
                return nested
            }
            let code = rawText(from: element).trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty {
                return [.codeBlock(language: wrap, code: code)]
            }
        }

        // Discourse / highlight.js wrappers that are not a bare `<pre>`.
        if isHighlightedCodeWrapper(classAttr) || hasClassToken("mermaid-wrapper", in: classAttr) {
            let nested = nestedCodeBlocks(from: element)
            if !nested.isEmpty {
                return nested
            }
            if let table = try? element.select("table.hljs-ln").first() {
                return extractCodeBlock(from: table)
            }
        }

        if hasClassToken("poll", in: classAttr), let poll = extractPoll(from: element) {
            return [.poll(poll)]
        }

        // Lightbox wrapper
        if classAttr.contains("lightbox-wrapper") {
            if let img = try? element.select("img").first() {
                let href: String? = {
                    guard let anchor = try? element.select("a").first() else { return nil }
                    let h = URLResolver.resolve((try? anchor.attr("href")) ?? "", baseURL: options.baseURL)
                    return h.isEmpty ? nil : h
                }()
                return extractBlockImage(from: img, options: options, href: href)
            }
        }

        if hasClassToken("d-image-grid", in: classAttr) {
            return extractImageGrid(from: element, options: options)
        }

        // Video embed (youtube-onebox, lazy-video-container, etc.)
        if classAttr.contains("lazy-video-container") || classAttr.contains("video-container") {
            return extractVideo(from: element, options: options)
        }

        // Block-level spoiler: wrap all child blocks in a single .spoiler container
        if classAttr.contains("spoiler") {
            let inner = extract(from: element, options: options)
            if inner.isEmpty { return [] }
            return [.spoiler(blocks: inner)]
        }

        // Generic div — recurse into children
        let inner = extract(from: element, options: options)
        if inner.isEmpty { return [] }
        return inner
    }

    private static func extractPoll(from element: Element) -> PollBlock? {
        let options = pollOptions(from: element)
        guard !options.isEmpty else { return nil }

        let name = nonEmptyAttribute("data-poll-name", from: element)
        let status = nonEmptyAttribute("data-poll-status", from: element)
        let type = nonEmptyAttribute("data-poll-type", from: element)
        let votersText = (try? element.select(".poll-info").first()?.text())
            .flatMap(normalizedNonEmptyText)
        let votersCount = pollVotersCount(from: element, votersText: votersText)

        return PollBlock(
            name: name,
            status: status,
            type: type,
            options: options,
            votersText: votersText,
            votersCount: votersCount,
            minSelections: lossyIntAttribute("data-poll-min", from: element),
            maxSelections: lossyIntAttribute("data-poll-max", from: element),
            resultsMode: nonEmptyAttribute("data-poll-results", from: element),
            isPublic: boolAttribute("data-poll-public", from: element)
        )
    }

    private static func pollOptions(from element: Element) -> [PollOption] {
        let optionElements = (try? element.select("li[data-poll-option-id]")) ?? Elements()
        return optionElements.array().compactMap { optionElement in
            let text = pollOptionText(from: optionElement)
            guard !text.isEmpty else { return nil }
            return PollOption(
                id: nonEmptyAttribute("data-poll-option-id", from: optionElement),
                text: text,
                voteCount: pollOptionVoteCount(from: optionElement),
                percentageText: pollOptionPercentageText(from: optionElement),
                isSelected: pollOptionIsSelected(optionElement)
            )
        }
    }

    private static func pollOptionVoteCount(from element: Element) -> Int? {
        for name in ["data-poll-option-votes", "data-votes", "data-poll-votes"] {
            if let value = lossyIntAttribute(name, from: element) {
                return value
            }
        }
        let selectors = [".poll-option-votes", ".option-votes", ".votes"]
        for selector in selectors {
            if let text = (try? element.select(selector).first()?.text()).flatMap(normalizedNonEmptyText),
               let value = firstInteger(in: text) {
                return value
            }
        }
        return nil
    }

    private static func pollOptionPercentageText(from element: Element) -> String? {
        for name in ["data-poll-option-percentage", "data-percentage"] {
            if let text = nonEmptyAttribute(name, from: element) {
                return normalizedPercentageText(text)
            }
        }
        let selectors = [".percentage", ".poll-option-percentage", ".option-percentage"]
        for selector in selectors {
            if let text = (try? element.select(selector).first()?.text()).flatMap(normalizedNonEmptyText) {
                return normalizedPercentageText(text)
            }
        }
        return nil
    }

    private static func pollOptionIsSelected(_ element: Element) -> Bool {
        let classAttr = (try? element.attr("class")) ?? ""
        let selectedTokens = ["chosen", "selected", "voted", "is-selected", "is-chosen"]
        if selectedTokens.contains(where: { hasClassToken($0, in: classAttr) }) {
            return true
        }
        for name in ["data-poll-option-selected", "data-selected", "aria-checked"] {
            if boolAttribute(name, from: element) {
                return true
            }
        }
        if (try? element.select("input[checked]").first()) != nil {
            return true
        }
        return false
    }

    private static func pollVotersCount(from element: Element, votersText: String?) -> Int? {
        if let value = lossyIntAttribute("data-poll-voters", from: element) {
            return value
        }
        if let text = (try? element.select(".poll-info .info-number").first()?.text()).flatMap(normalizedNonEmptyText),
           let value = firstInteger(in: text) {
            return value
        }
        if let votersText {
            return firstInteger(in: votersText)
        }
        return nil
    }

    private static func pollOptionText(from element: Element) -> String {
        if let paragraph = try? element.select("p").first(),
           let text = normalizedNonEmptyText(try? paragraph.text()) {
            return text
        }
        if let label = try? element.select("label").first(),
           let text = normalizedNonEmptyText(try? label.text()) {
            return text
        }
        return normalizedNonEmptyText(try? element.text()) ?? ""
    }

    private static func normalizedPercentageText(_ text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.contains("%") ? normalized : "\(normalized)%"
    }

    private static func extractVideo(from element: Element, options: ParseOptions) -> [ContentBlock] {
        let videoId = (try? element.attr("data-video-id")) ?? ""
        let title: String? = {
            let t = (try? element.attr("data-video-title")) ?? ""
            return t.isEmpty ? nil : t
        }()
        let provider: String? = {
            let p = (try? element.attr("data-provider-name")) ?? ""
            return p.isEmpty ? nil : p
        }()

        // URL from <a> href
        let url: String = {
            if let anchor = try? element.select("a").first() {
                let href = (try? anchor.attr("href")) ?? ""
                if !href.isEmpty { return href }
            }
            return ""
        }()

        // Thumbnail from <img>
        var thumbnailURL: String?
        var width: Int?
        var height: Int?
        if let img = try? element.select("img").first() {
            let src = (try? img.attr("src")) ?? ""
            if !src.isEmpty {
                thumbnailURL = URLResolver.resolve(src, baseURL: options.baseURL)
            }
            if let w = try? img.attr("width"), let wInt = Int(w) { width = wInt }
            if let h = try? img.attr("height"), let hInt = Int(h) { height = hInt }
        }

        return [.video(
            url: url,
            thumbnailURL: thumbnailURL,
            title: title,
            width: width,
            height: height,
            videoId: videoId.isEmpty ? nil : videoId,
            provider: provider
        )]
    }

    // MARK: - Helpers

    private static func isBlockElement(_ element: Element) -> Bool {
        blockTags.contains(element.tagName().lowercased())
    }

    private static func hasClassToken(_ token: String, in classAttr: String) -> Bool {
        classAttr
            .split(whereSeparator: { $0.isWhitespace })
            .contains { $0 == token }
    }

    private static func nonEmptyAttribute(_ name: String, from element: Element) -> String? {
        normalizedNonEmptyText(try? element.attr(name))
    }

    private static func lossyIntAttribute(_ name: String, from element: Element) -> Int? {
        nonEmptyAttribute(name, from: element).flatMap(firstInteger(in:))
    }

    private static func boolAttribute(_ name: String, from element: Element) -> Bool {
        guard let raw = nonEmptyAttribute(name, from: element)?.lowercased() else {
            return false
        }
        return raw == "true" || raw == "1" || raw == "yes" || raw == "checked"
    }

    private static func rawText(from element: Element) -> String {
        var result = ""
        for child in element.getChildNodes() {
            if let textNode = child as? TextNode {
                result += textNode.getWholeText()
            } else if let childElement = child as? Element {
                if childElement.tagName().lowercased() == "br" {
                    result += "<br>"
                } else {
                    result += rawText(from: childElement)
                }
            }
        }
        return result
    }

    /// Discourse uses `lang-xxx` / `language-xxx` on `<code>` or `<pre>`.
    private static func codeLanguage(from element: Element, codeElement: Element) -> String? {
        languageClass(from: codeElement) ?? languageClass(from: element)
    }

    private static func languageClass(from element: Element) -> String? {
        let cls = (try? element.attr("class")) ?? ""
        for part in cls.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(part)
            if token.hasPrefix("lang-") {
                return String(token.dropFirst(5)).lowercased()
            }
            if token.hasPrefix("language-") {
                return String(token.dropFirst(9)).lowercased()
            }
        }
        return nil
    }

    /// Preserve newlines. SwiftSoup `.text()` flattens highlight.js spans/tables.
    private static func codeText(from element: Element) -> String {
        if let table = highlightJSLineNumberTable(in: element) {
            let cells = (try? table.select("td.hljs-ln-code")) ?? Elements()
            let lines = cells.array().map { cell in
                rawText(from: cell).replacingOccurrences(of: "<br>", with: "\n")
            }
            if !lines.isEmpty {
                return trimCodeFenceNewlines(lines.joined(separator: "\n"))
            }
        }
        return trimCodeFenceNewlines(
            rawText(from: element).replacingOccurrences(of: "<br>", with: "\n")
        )
    }

    private static func trimCodeFenceNewlines(_ code: String) -> String {
        var result = code
        while result.hasPrefix("\n") {
            result.removeFirst()
        }
        while result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }

    private static func isHighlightJSLineNumberTable(_ element: Element) -> Bool {
        let classAttr = (try? element.attr("class")) ?? ""
        return hasClassToken("hljs-ln", in: classAttr)
    }

    private static func highlightJSLineNumberTable(in element: Element) -> Element? {
        if isHighlightJSLineNumberTable(element) {
            return element
        }
        return try? element.select("table.hljs-ln").first()
    }

    /// Discourse / highlight.js wrappers that are not a bare `<pre>`.
    private static func isHighlightedCodeWrapper(_ classAttr: String) -> Bool {
        ["highlighted", "codeblock", "d-code", "hljs"].contains { token in
            hasClassToken(token, in: classAttr)
        }
    }

    private static func mermaidWrapName(from element: Element) -> String? {
        let attributes = ["data-code-wrap", "data-wrap"]
        for name in attributes {
            let value = ((try? element.attr(name)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if value == "mermaid" {
                return "mermaid"
            }
        }
        let classAttr = (try? element.attr("class")) ?? ""
        if hasClassToken("mermaid-wrapper", in: classAttr) {
            return "mermaid"
        }
        return nil
    }

    private static func firstInteger(in text: String) -> Int? {
        let pattern = #"-?\d+"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return Int(text[range])
    }

    private static func normalizedNonEmptyText(_ text: String?) -> String? {
        guard let normalized = text?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !normalized.isEmpty
        else { return nil }
        return normalized
    }

    /// Trim whitespace-only paragraphs.
    private static func trimBlock(_ block: ContentBlock) -> ContentBlock? {
        switch block {
        case .paragraph(let inlines):
            let trimmed = normalizeParagraphInlines(inlines)
            return trimmed.isEmpty ? nil : .paragraph(trimmed)
        default:
            return block
        }
    }

    private static func normalizeParagraphInlines(_ inlines: [InlineNode]) -> [InlineNode] {
        var result: [InlineNode] = []
        var previousWasLineBreak = false

        for node in inlines {
            switch node {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(node)
                previousWasLineBreak = false
            case .styledText(let text, _):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(node)
                previousWasLineBreak = false
            case .lineBreak:
                guard !result.isEmpty, !previousWasLineBreak else { continue }
                result.append(node)
                previousWasLineBreak = true
            default:
                result.append(node)
                previousWasLineBreak = false
            }
        }

        while let last = result.last {
            if case .lineBreak = last {
                result.removeLast()
            } else {
                break
            }
        }

        return result
    }

    /// Promote bare auto-linked image URLs and recurse into nested containers.
    private static func finalizeBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        continueOrderedListNumbering(
            blocks
                .flatMap { promoteImageLinks(in: $0) }
                .compactMap { trimBlock($0) }
        )
    }

    private static func finalizeAnnotatedBlocks(_ blocks: [AnnotatedBlock]) -> [AnnotatedBlock] {
        var promoted: [AnnotatedBlock] = []
        for annotated in blocks {
            for block in promoteImageLinks(in: annotated.block) {
                guard let trimmed = trimBlock(block) else { continue }
                promoted.append(AnnotatedBlock(block: trimmed, sourceHTML: annotated.sourceHTML))
            }
        }
        return continueOrderedListNumbering(annotated: promoted)
    }

    /// FluxDo parity: Discourse often splits one logical numbered list into many
    /// single-item `<ol>` fragments separated by `<details>` (screenshot collapsibles).
    /// Each fragment restarts at 1 in the HTML unless `start` is set — continue the
    /// visible sequence across transparent interrupters so users see 1, 2, 3… not 1, 1, 1.
    private static func continueOrderedListNumbering(_ blocks: [ContentBlock]) -> [ContentBlock] {
        var result: [ContentBlock] = []
        var nextNumber: Int?

        for block in blocks {
            let normalized = normalizeNestedOrderedLists(block)
            switch normalized {
            case .list(let ordered, let start, let items) where ordered:
                let effectiveStart: Int
                if start > 1 {
                    // Explicit `<ol start="N">` from Discourse — trust it.
                    effectiveStart = start
                } else if let nextNumber {
                    effectiveStart = nextNumber
                } else {
                    effectiveStart = max(start, 1)
                }
                result.append(.list(ordered: true, start: effectiveStart, items: items))
                nextNumber = effectiveStart + items.count

            case .details:
                // Screenshot collapsibles sit between product rows without ending the list.
                result.append(normalized)

            case .spoiler, .divider:
                // Decorative / hidden wrappers — keep the sequence alive.
                result.append(normalized)

            default:
                if breaksOrderedListSequence(normalized) {
                    nextNumber = nil
                }
                result.append(normalized)
            }
        }

        return result
    }

    private static func continueOrderedListNumbering(annotated blocks: [AnnotatedBlock]) -> [AnnotatedBlock] {
        var result: [AnnotatedBlock] = []
        var nextNumber: Int?

        for annotated in blocks {
            let normalized = normalizeNestedOrderedLists(annotated.block)
            switch normalized {
            case .list(let ordered, let start, let items) where ordered:
                let effectiveStart: Int
                if start > 1 {
                    effectiveStart = start
                } else if let nextNumber {
                    effectiveStart = nextNumber
                } else {
                    effectiveStart = max(start, 1)
                }
                result.append(AnnotatedBlock(
                    block: .list(ordered: true, start: effectiveStart, items: items),
                    sourceHTML: annotated.sourceHTML
                ))
                nextNumber = effectiveStart + items.count

            case .details:
                result.append(AnnotatedBlock(block: normalized, sourceHTML: annotated.sourceHTML))

            case .spoiler, .divider:
                result.append(AnnotatedBlock(block: normalized, sourceHTML: annotated.sourceHTML))

            default:
                if breaksOrderedListSequence(normalized) {
                    nextNumber = nil
                }
                result.append(AnnotatedBlock(block: normalized, sourceHTML: annotated.sourceHTML))
            }
        }

        return result
    }

    /// Recurse into nested containers so continued numbering also works inside quotes etc.
    private static func normalizeNestedOrderedLists(_ block: ContentBlock) -> ContentBlock {
        switch block {
        case .details(let summary, let content):
            return .details(summary: summary, content: continueOrderedListNumbering(content))
        case .spoiler(let blocks):
            return .spoiler(blocks: continueOrderedListNumbering(blocks))
        case .blockquote(let blocks):
            return .blockquote(blocks: continueOrderedListNumbering(blocks))
        case .discourseQuote(
            let username,
            let avatarURL,
            let topicTitle,
            let topicURL,
            let categoryName,
            let categoryURL,
            let quotePostNumber,
            let content
        ):
            return .discourseQuote(
                username: username,
                avatarURL: avatarURL,
                topicTitle: topicTitle,
                topicURL: topicURL,
                categoryName: categoryName,
                categoryURL: categoryURL,
                quotePostNumber: quotePostNumber,
                content: continueOrderedListNumbering(content)
            )
        case .list(let ordered, let start, let items):
            let nestedItems = items.map { item in
                ListItem(
                    content: item.content,
                    children: continueOrderedListNumbering(item.children)
                )
            }
            return .list(ordered: ordered, start: start, items: nestedItems)
        case .table(let headers, let rows):
            return .table(
                headers: headers.map { continueOrderedListNumbering($0) },
                rows: rows.map { row in row.map { continueOrderedListNumbering($0) } }
            )
        default:
            return block
        }
    }

    /// Blocks that end a continued ordered-list sequence (FluxDo restarts after these).
    private static func breaksOrderedListSequence(_ block: ContentBlock) -> Bool {
        switch block {
        case .list(let ordered, _, _) where !ordered:
            return true
        case .list:
            return false
        case .details, .spoiler, .divider:
            return false
        case .paragraph, .heading, .codeBlock, .blockquote, .discourseQuote,
             .image, .imageGrid, .onebox, .video, .poll, .table, .rawHTML:
            return true
        }
    }

    /// Discourse leaves failed image oneboxes as auto-linked URLs. Promote those to image blocks
    /// so native rendering matches FluxDo-style clients.
    private static func promoteImageLinks(in block: ContentBlock) -> [ContentBlock] {
        switch block {
        case .paragraph(let inlines):
            return splitParagraphPromotingImageLinks(inlines)

        case .blockquote(let blocks):
            return [.blockquote(blocks: blocks.flatMap { promoteImageLinks(in: $0) })]

        case .discourseQuote(
            let username,
            let avatarURL,
            let topicTitle,
            let topicURL,
            let categoryName,
            let categoryURL,
            let quotePostNumber,
            let content
        ):
            return [
                .discourseQuote(
                    username: username,
                    avatarURL: avatarURL,
                    topicTitle: topicTitle,
                    topicURL: topicURL,
                    categoryName: categoryName,
                    categoryURL: categoryURL,
                    quotePostNumber: quotePostNumber,
                    content: content.flatMap { promoteImageLinks(in: $0) }
                )
            ]

        case .details(let summary, let content):
            return [.details(summary: summary, content: content.flatMap { promoteImageLinks(in: $0) })]

        case .spoiler(let blocks):
            return [.spoiler(blocks: blocks.flatMap { promoteImageLinks(in: $0) })]

        case .list(let ordered, let start, let items):
            // Promote bare image URLs / non-emoji imgs out of item text into children
            // so native list rendering can show full-size TappableImageContainers.
            let promotedItems = items.map { item -> ListItem in
                var textContent: [InlineNode] = []
                var childBlocks: [ContentBlock] = []
                for block in promoteImageLinks(in: .paragraph(item.content)) {
                    switch block {
                    case .paragraph(let inlines):
                        let trimmed = inlines.trimmedWhitespace()
                        guard !trimmed.isEmpty else { continue }
                        if !textContent.isEmpty {
                            textContent.append(.lineBreak)
                        }
                        textContent.append(contentsOf: trimmed)
                    default:
                        childBlocks.append(contentsOf: promoteImageLinks(in: block))
                    }
                }
                childBlocks.append(contentsOf: item.children.flatMap { promoteImageLinks(in: $0) })
                return ListItem(content: textContent, children: childBlocks)
            }
            return [.list(ordered: ordered, start: start, items: promotedItems)]

        case .table(let headers, let rows):
            let promotedHeaders = headers.map { cell in cell.flatMap { promoteImageLinks(in: $0) } }
            let promotedRows = rows.map { row in
                row.map { cell in cell.flatMap { promoteImageLinks(in: $0) } }
            }
            return [.table(headers: promotedHeaders, rows: promotedRows)]

        case .onebox(let sourceURL, let title, let description, let imageURL, let imageWidth, let imageHeight, _):
            // Image-only onebox (or source/title itself is an image URL) → full image block like FluxDo.
            // linux.do may emit minimal asides where the body h3 anchor text IS the URL and there
            // is no header, so title/description count as "empty" when they are just URL text.
            let titleText = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let descriptionText = (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let titleURL = ImageURLDetector.normalizeURLString(titleText.replacingOccurrences(of: "&amp;", with: "&"))
            let candidate = [imageURL, sourceURL, ImageURLDetector.isImageURL(titleURL) ? titleURL : nil]
                .compactMap { $0 }
                .first { ImageURLDetector.isImageURL($0) }
            if let candidate,
               titleText.isEmpty || ImageURLDetector.shouldPromoteLink(href: candidate, label: titleText),
               descriptionText.isEmpty || ImageURLDetector.shouldPromoteLink(href: candidate, label: descriptionText) {
                return [.image(src: candidate, alt: nil, width: imageWidth, height: imageHeight, href: sourceURL ?? candidate)]
            }
            if let sourceURL, ImageURLDetector.isImageURL(sourceURL), imageURL == nil {
                return [.image(src: sourceURL, alt: title, width: nil, height: nil, href: sourceURL)]
            }
            return [block]

        default:
            return [block]
        }
    }

    private static func splitParagraphPromotingImageLinks(_ inlines: [InlineNode]) -> [ContentBlock] {
        let trimmedAll = inlines.trimmedWhitespace()
        let substantial = trimmedAll.filter { inline in
            switch inline {
            case .lineBreak:
                return false
            case .text(let text), .styledText(let text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        }

        // Whole-paragraph sole bare image (non-emoji) → block image.
        if substantial.count == 1,
           case .image(let src, let alt, let width, let height, let isEmoji) = substantial[0],
           !isEmoji {
            return [.image(src: src, alt: alt, width: width, height: height, href: nil)]
        }

        // Whole-paragraph sole link: wrapped <img> wins over an image-like href
        // (GitHub `/blob/*.png` pages look like images but are HTML).
        if substantial.count == 1, case .link = substantial[0] {
            if let imageBlock = imageBlock(from: substantial[0], soleInParagraph: true) {
                return [imageBlock]
            }
        }

        // Whole-paragraph bare text URL, including text split by <br>/whitespace.
        if let plainURL = ImageURLDetector.soleImageURL(fromPlainInlines: trimmedAll) {
            return [.image(src: plainURL, alt: nil, width: nil, height: nil, href: plainURL)]
        }

        var result: [ContentBlock] = []
        var textInlines: [InlineNode] = []

        func flushText() {
            let trimmed = textInlines.trimmedWhitespace()
            if trimmed.isEmpty { return }
            if let plainURL = ImageURLDetector.soleImageURL(fromPlainInlines: trimmed) {
                result.append(.image(src: plainURL, alt: nil, width: nil, height: nil, href: plainURL))
            } else {
                result.append(.paragraph(trimmed))
            }
            textInlines.removeAll(keepingCapacity: true)
        }

        for inline in inlines {
            // Promote auto-linked image URLs (label is the URL itself); keep custom-labeled
            // links like [click here](a.jpg) inline unless they are the sole paragraph content.
            if let imageBlock = imageBlock(from: inline, soleInParagraph: false) {
                flushText()
                result.append(imageBlock)
            } else {
                textInlines.append(inline)
            }
        }
        flushText()
        return result.isEmpty ? [] : result
    }

    private static func imageBlock(from inline: InlineNode, soleInParagraph: Bool) -> ContentBlock? {
        switch inline {
        case .image(let src, let alt, let width, let height, let isEmoji):
            // Bare <img> mixed into paragraph text. Promote real content images to
            // block media so clients render TappableImageContainer instead of a blank
            // NSTextAttachment placeholder. Keep emoji / tiny decorative imgs inline.
            guard !isEmoji else { return nil }
            if let width, let height, width <= 80, height <= 80 {
                return nil
            }
            return .image(src: src, alt: alt, width: width, height: height, href: nil)

        case .link(let href, let children):
            // <a href="..."><img></a> with a non-emoji image becomes a tappable block image.
            let substantialChildren = children.filter { child in
                switch child {
                case .lineBreak:
                    return false
                case .text(let text), .styledText(let text, _):
                    return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                default:
                    return true
                }
            }
            if substantialChildren.count == 1,
               case .image(let src, let alt, let width, let height, let isEmoji) = substantialChildren[0],
               !isEmoji {
                return .image(src: src, alt: alt, width: width, height: height, href: href)
            }

            let cleaned = ImageURLDetector.normalizeURLString(href.replacingOccurrences(of: "&amp;", with: "&"))
            // Prefer promoting any image-like href. Custom markdown labels like
            // [click here](a.jpg) mid-sentence are uncommon on linux.do; sole
            // image embeds are the dominant failure mode.
            if ImageURLDetector.isImageURL(cleaned) {
                if soleInParagraph {
                    return .image(src: cleaned, alt: nil, width: nil, height: nil, href: cleaned)
                }
                let label = plainText(from: children)
                if ImageURLDetector.shouldPromoteLink(href: cleaned, label: label) {
                    return .image(src: cleaned, alt: nil, width: nil, height: nil, href: cleaned)
                }
                // Even custom labels: if the link is image-like and label looks empty/URL-ish, promote.
                let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedLabel.isEmpty || trimmedLabel.lowercased().hasPrefix("http") {
                    return .image(src: cleaned, alt: nil, width: nil, height: nil, href: cleaned)
                }
            }
            return nil

        default:
            return nil
        }
    }

    private static func plainText(from inlines: [InlineNode]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .styledText(let text, _), .code(let text):
                return text
            case .link(_, let children), .spoiler(let children):
                return plainText(from: children)
            case .mention(let username, _):
                return "@\(username)"
            case .mentionGroup(let name, _):
                return "@\(name)"
            case .hashtag(let text, _, _):
                return "#\(text)"
            case .image(_, let alt, _, _, _):
                return alt ?? ""
            case .lineBreak:
                return "\n"
            }
        }.joined()
    }

    /// Merge blocks that result from SwiftSoup splitting inline content into separate top-level nodes.
    /// Handles two cases:
    /// 1. Small (emoji-sized) `.image` blocks following a `.paragraph` → merged as inline image.
    /// 2. Consecutive `.paragraph` blocks that are bare siblings (no intervening block) → merged.
    private static func mergeInlineImageBlocks(_ blocks: [ContentBlock]) -> [ContentBlock] {
        guard blocks.count > 1 else { return blocks }
        var result: [ContentBlock] = []
        for block in blocks {
            guard let lastIndex = result.indices.last else {
                result.append(block)
                continue
            }
            // Case 1: small image following a paragraph → inline emoji
            if case .image(let src, let alt, let w, let h, _) = block,
               let w, let h, w <= 80, h <= 80,
               case .paragraph(let inlines) = result[lastIndex]
            {
                result[lastIndex] = .paragraph(inlines + [.image(src: src, alt: alt, width: w, height: h, isEmoji: true)])
                continue
            }
            // Case 2: bare text/inline paragraph following a paragraph that ends with an inline image
            // (handles SwiftSoup splitting "text<img>text" into separate top-level nodes)
            if case .paragraph(let newInlines) = block,
               case .paragraph(let prevInlines) = result[lastIndex],
               case .image(_, _, _, _, let isEmoji) = prevInlines.last, isEmoji
            {
                result[lastIndex] = .paragraph(prevInlines + newInlines)
                continue
            }
            result.append(block)
        }
        return result
    }
}
