import Foundation

/// Block document for the experimental WYSIWYG composer.
/// Import/export is always raw Markdown; unmatched Discourse islands stay `.literal`.
enum ExperimentalComposerBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case quote(String)
    case listItem(ordered: Bool, text: String)
    case code(language: String, code: String)
    case image(alt: String, url: String, title: String?)
    case quoteCard(
        username: String,
        displayName: String?,
        postNumber: Int?,
        topicId: Int?,
        full: Bool,
        inner: String
    )
    case literal(String)
}

struct ExperimentalComposerDocument: Equatable {
    var blocks: [ExperimentalComposerBlock]

    var markdown: String {
        Self.serialize(blocks)
    }

    static func parse(_ markdown: String) -> ExperimentalComposerDocument {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [ExperimentalComposerBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = consumeFence(lines: lines, start: index) {
                blocks.append(.code(language: fence.language, code: fence.code))
                index = fence.nextIndex
                continue
            }

            if let card = consumeQuoteCard(lines: lines, start: index) {
                blocks.append(card.block)
                index = card.nextIndex
                continue
            }

            if let island = consumeTaggedIsland(lines: lines, start: index) {
                blocks.append(.literal(island.raw))
                index = island.nextIndex
                continue
            }

            if let image = imageLineMatch(trimmed) {
                blocks.append(.image(alt: image.alt, url: image.url, title: image.title))
                index += 1
                continue
            }

            if let table = consumePipeTable(lines: lines, start: index) {
                blocks.append(.literal(table.raw))
                index = table.nextIndex
                continue
            }

            if let heading = headingMatch(trimmed) {
                blocks.append(.heading(heading.level, heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    var content = String(candidate.dropFirst())
                    if content.hasPrefix(" ") {
                        content = String(content.dropFirst())
                    }
                    quoteLines.append(content)
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = listItemMatch(line) {
                blocks.append(.listItem(ordered: item.ordered, text: item.text))
                index += 1
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let next = lines[index]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if isBlockBoundary(next) { break }
                paragraphLines.append(next)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        if blocks.isEmpty {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks = [.paragraph("")]
            } else {
                blocks = [.literal(markdown)]
            }
        }

        return ExperimentalComposerDocument(blocks: blocks)
    }

    static func serialize(_ blocks: [ExperimentalComposerBlock]) -> String {
        var chunks: [String] = []
        var previousWasList = false
        var orderedIndex = 0

        for block in blocks {
            let piece: String
            let isList: Bool
            switch block {
            case .listItem(let ordered, let text):
                isList = true
                if ordered {
                    orderedIndex += 1
                    piece = "\(orderedIndex). \(text)"
                } else {
                    orderedIndex = 0
                    piece = "- \(text)"
                }
            default:
                isList = false
                orderedIndex = 0
                piece = serializeBlock(block)
            }
            if piece.isEmpty { continue }
            if chunks.isEmpty {
                chunks.append(piece)
            } else if previousWasList && isList {
                chunks[chunks.count - 1] += "\n" + piece
            } else {
                chunks.append(piece)
            }
            previousWasList = isList
        }

        return chunks.joined(separator: "\n\n")
    }

    /// 1-based index inside a consecutive ordered-list run, or nil if this block is not an ordered item.
    static func orderedOrdinal(in blocks: [ExperimentalComposerBlock], at index: Int) -> Int? {
        guard index >= 0, index < blocks.count,
              case .listItem(ordered: true, _) = blocks[index]
        else { return nil }
        var ordinal = 0
        var cursor = index
        while cursor >= 0 {
            if case .listItem(ordered: true, _) = blocks[cursor] {
                ordinal += 1
                cursor -= 1
            } else {
                break
            }
        }
        return ordinal
    }

    static func listLineMatch(_ line: String) -> (ordered: Bool, text: String)? {
        listItemMatch(line)
    }

    /// Resolve Discourse `upload://`, site-relative, and protocol-relative URLs for preview.
    static func previewImageURL(from raw: String, baseURL: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasPrefix("upload://") {
            let token = String(trimmed.dropFirst("upload://".count))
            guard !token.isEmpty else { return nil }
            return URL(string: "\(base)/uploads/short-url/\(token)")
        }
        if trimmed.hasPrefix("//") {
            return URL(string: "https:\(trimmed)")
        }
        if trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") {
            return URL(string: base + trimmed)
        }
        return URL(string: trimmed)
    }

    private static func serializeBlock(_ block: ExperimentalComposerBlock) -> String {
        switch block {
        case .paragraph(let text):
            return text
        case .heading(let level, let text):
            let marks = String(repeating: "#", count: min(max(level, 1), 6))
            return "\(marks) \(text)"
        case .quote(let text):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return lines.map { line in
                line.isEmpty ? ">" : "> \(line)"
            }.joined(separator: "\n")
        case .listItem:
            return ""
        case .code(let language, let code):
            var body = code
            if !body.isEmpty && !body.hasSuffix("\n") {
                body += "\n"
            }
            return "```\(language)\n\(body)```"
        case .image(let alt, let url, let title):
            if let title, !title.isEmpty {
                return "![\(alt)](\(url) \"\(title)\")"
            }
            return "![\(alt)](\(url))"
        case .quoteCard(let username, let displayName, let postNumber, let topicId, let full, let inner):
            return serializeQuoteCard(
                username: username,
                displayName: displayName,
                postNumber: postNumber,
                topicId: topicId,
                full: full,
                inner: inner
            )
        case .literal(let raw):
            return raw
        }
    }

    private static func isBlockBoundary(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return true }
        if trimmed.hasPrefix(">") { return true }
        if headingMatch(trimmed) != nil { return true }
        if listItemMatch(line) != nil { return true }
        if taggedIslandOpener(trimmed) != nil { return true }
        if quoteCardOpener(trimmed) { return true }
        if imageLineMatch(trimmed) != nil { return true }
        if looksLikeTableRow(trimmed) { return true }
        return false
    }

    private static func headingMatch(_ trimmed: String) -> (level: Int, text: String)? {
        guard let range = trimmed.range(of: #"^(#{1,6})\s+"#, options: .regularExpression) else {
            return nil
        }
        let marks = trimmed[range].filter { $0 == "#" }.count
        let text = String(trimmed[range.upperBound...])
        return (marks, text)
    }

    private static func listItemMatch(_ line: String) -> (ordered: Bool, text: String)? {
        if let range = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) {
            return (false, String(line[range.upperBound...]))
        }
        if let range = line.range(of: #"^\s*\d+\.\s+"#, options: .regularExpression) {
            return (true, String(line[range.upperBound...]))
        }
        return nil
    }

    private static func consumeFence(
        lines: [String],
        start: Int
    ) -> (language: String, code: String, nextIndex: Int)? {
        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") else { return nil }
        let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        var codeLines: [String] = []
        var index = start + 1
        while index < lines.count {
            let candidate = lines[index]
            if candidate.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                index += 1
                break
            }
            codeLines.append(candidate)
            index += 1
        }
        return (language, codeLines.joined(separator: "\n"), index)
    }

    private static func taggedIslandOpener(_ trimmed: String) -> String? {
        let lower = trimmed.lowercased()
        if lower.hasPrefix("[poll") { return "[/poll]" }
        if lower.hasPrefix("[wrap=") { return "[/wrap]" }
        if lower.hasPrefix("[policy") { return "[/policy]" }
        if lower.hasPrefix("[grid") { return "[/grid]" }
        return nil
    }

    private static func quoteCardOpener(_ trimmed: String) -> Bool {
        let lower = trimmed.lowercased()
        return lower.hasPrefix("[quote") && !lower.hasPrefix("[/quote")
    }

    private static func consumeQuoteCard(
        lines: [String],
        start: Int
    ) -> (block: ExperimentalComposerBlock, nextIndex: Int)? {
        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
        guard quoteCardOpener(trimmed) else { return nil }
        let header = parseQuoteHeader(trimmed)
        var innerLines: [String] = []
        var index = start + 1
        var depth = 1
        while index < lines.count {
            let candidate = lines[index].trimmingCharacters(in: .whitespaces)
            let lower = candidate.lowercased()
            if quoteCardOpener(candidate) {
                depth += 1
                innerLines.append(lines[index])
            } else if lower == "[/quote]" {
                depth -= 1
                if depth == 0 {
                    index += 1
                    break
                }
                innerLines.append(lines[index])
            } else {
                innerLines.append(lines[index])
            }
            index += 1
        }
        let inner = innerLines.joined(separator: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        return (
            .quoteCard(
                username: header.username,
                displayName: header.displayName,
                postNumber: header.postNumber,
                topicId: header.topicId,
                full: header.full,
                inner: inner
            ),
            index
        )
    }

    private static func parseQuoteHeader(_ opener: String) -> (
        username: String,
        displayName: String?,
        postNumber: Int?,
        topicId: Int?,
        full: Bool
    ) {
        var username = ""
        var displayName: String?
        var postNumber: Int?
        var topicId: Int?
        var full = false
        guard let start = opener.firstIndex(of: "\""),
              let end = opener.lastIndex(of: "\""),
              start < end
        else {
            return ("", nil, nil, nil, false)
        }
        let body = String(opener[opener.index(after: start)..<end])
        let parts = body.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (offset, part) in parts.enumerated() {
            let lower = part.lowercased()
            if lower.hasPrefix("post:") {
                postNumber = Int(part.dropFirst(5).trimmingCharacters(in: .whitespaces))
            } else if lower.hasPrefix("topic:") {
                topicId = Int(part.dropFirst(6).trimmingCharacters(in: .whitespaces))
            } else if lower.hasPrefix("username:") {
                username = String(part.dropFirst(9).trimmingCharacters(in: .whitespaces))
            } else if lower == "full:true" || lower == "full" {
                full = true
            } else if offset == 0 {
                displayName = part
            }
        }
        if username.isEmpty, let displayName, !displayName.isEmpty {
            username = displayName
        }
        if displayName == username {
            displayName = nil
        }
        return (username, displayName, postNumber, topicId, full)
    }

    private static func serializeQuoteCard(
        username: String,
        displayName: String?,
        postNumber: Int?,
        topicId: Int?,
        full: Bool,
        inner: String
    ) -> String {
        var parts: [String] = []
        if let displayName, !displayName.isEmpty {
            parts.append(displayName)
        } else if !username.isEmpty {
            parts.append(username)
        }
        if let postNumber {
            parts.append("post:\(postNumber)")
        }
        if let topicId {
            parts.append("topic:\(topicId)")
        }
        if let displayName, !displayName.isEmpty, !username.isEmpty, displayName != username {
            parts.append("username:\(username)")
        }
        if full {
            parts.append("full:true")
        }
        let open = parts.isEmpty ? "[quote]" : "[quote=\"\(parts.joined(separator: ", "))\"]"
        if inner.isEmpty {
            return "\(open)\n[/quote]"
        }
        return "\(open)\n\(inner)\n[/quote]"
    }

    private static func imageLineMatch(_ trimmed: String) -> (alt: String, url: String, title: String?)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^!\[(.*?)\]\((\S+?)(?:\s+\"([^\"]*)\")?\)$"#
        ) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 3,
              let altRange = Range(match.range(at: 1), in: trimmed),
              let urlRange = Range(match.range(at: 2), in: trimmed)
        else {
            return nil
        }
        let alt = String(trimmed[altRange])
        let url = String(trimmed[urlRange])
        guard !url.isEmpty else { return nil }
        var title: String?
        if match.numberOfRanges >= 4, match.range(at: 3).location != NSNotFound,
           let titleRange = Range(match.range(at: 3), in: trimmed) {
            title = String(trimmed[titleRange])
        }
        return (alt, url, title)
    }

    private static func consumeTaggedIsland(
        lines: [String],
        start: Int
    ) -> (raw: String, nextIndex: Int)? {
        let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
        guard let closer = taggedIslandOpener(trimmed) else { return nil }
        var chunk = [lines[start]]
        var index = start + 1
        let closeNeedle = closer.lowercased()
        while index < lines.count {
            chunk.append(lines[index])
            if lines[index].trimmingCharacters(in: .whitespaces).lowercased() == closeNeedle {
                index += 1
                break
            }
            index += 1
        }
        return (chunk.joined(separator: "\n"), index)
    }

    private static func looksLikeTableRow(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.contains("|")
    }

    private static func consumePipeTable(
        lines: [String],
        start: Int
    ) -> (raw: String, nextIndex: Int)? {
        guard looksLikeTableRow(lines[start].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        var chunk: [String] = []
        var index = start
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { break }
            guard looksLikeTableRow(trimmed) || trimmed.contains("---") else { break }
            chunk.append(lines[index])
            index += 1
        }
        guard chunk.count >= 2 else { return nil }
        return (chunk.joined(separator: "\n"), index)
    }
}
