import Foundation

/// Block document for the experimental WYSIWYG composer.
/// Import/export is always raw Markdown; unmatched Discourse islands stay `.literal`.
enum ExperimentalComposerBlock: Equatable {
    case paragraph(String)
    case heading(Int, String)
    case quote(String)
    case listItem(ordered: Bool, text: String)
    case code(language: String, code: String)
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

            if let island = consumeTaggedIsland(lines: lines, start: index) {
                blocks.append(.literal(island.raw))
                index = island.nextIndex
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
        if lower.hasPrefix("[quote") && !lower.hasPrefix("[/quote") { return "[/quote]" }
        if lower.hasPrefix("[wrap=") { return "[/wrap]" }
        return nil
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
