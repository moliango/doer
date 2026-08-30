import Foundation

/// Discourse `[poll]` BBCode used by the composer builder.
struct ComposerPollSpec: Equatable {
    enum Kind: String, CaseIterable {
        case regular
        case multiple
        case number
    }

    enum ResultsVisibility: String, CaseIterable {
        case always
        case onVote = "on_vote"
        case onClose = "on_close"
        case staffOnly = "staff_only"
    }

    enum ChartKind: String, CaseIterable {
        case bar
        case pie
    }

    var kind: Kind
    var options: [String]
    var results: ResultsVisibility
    var isPublic: Bool
    var chart: ChartKind
    var closeISO8601: String?
    var minValue: Int
    var maxValue: Int
    var step: Int
    var name: String?

    static let defaultOptions = [
        String(localized: "reply.tool.poll.option_a", defaultValue: "选项 A"),
        String(localized: "reply.tool.poll.option_b", defaultValue: "选项 B"),
    ]

    static func blank() -> ComposerPollSpec {
        ComposerPollSpec(
            kind: .regular,
            options: defaultOptions,
            results: .always,
            isPublic: true,
            chart: .bar,
            closeISO8601: nil,
            minValue: 1,
            maxValue: 10,
            step: 1,
            name: nil
        )
    }

    var bbcode: String {
        var attrs = ["type=\(kind.rawValue)", "results=\(results.rawValue)"]
        if isPublic {
            attrs.append("public=true")
        }
        if kind != .number {
            attrs.append("chartType=\(chart.rawValue)")
        }
        if kind == .number {
            attrs.append("min=\(minValue)")
            attrs.append("max=\(max(minValue, maxValue))")
            attrs.append("step=\(max(1, step))")
        }
        if let closeISO8601, !closeISO8601.isEmpty {
            attrs.append("close=\(closeISO8601)")
        }
        if let name, !name.isEmpty {
            attrs.append("name=\(name)")
        }
        let header = "[poll \(attrs.joined(separator: " "))]"
        if kind == .number {
            return "\(header)\n[/poll]\n"
        }
        let lines = normalizedOptions().map { "- \($0)" }.joined(separator: "\n")
        return "\(header)\n\(lines)\n[/poll]\n"
    }

    func normalizedOptions() -> [String] {
        let trimmed = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return trimmed.count >= 2 ? trimmed : Self.defaultOptions
    }

    static func parse(from markdown: String) -> ComposerPollSpec? {
        let pattern = #"\[poll([^\]]*)\](.*?)\[/poll\]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return nil
        }
        let ns = markdown as NSString
        guard let match = regex.firstMatch(in: markdown, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 3
        else {
            return nil
        }
        let attrText = ns.substring(with: match.range(at: 1))
        let body = ns.substring(with: match.range(at: 2))
        let attributes = parseAttributes(attrText)

        let kind = Kind(rawValue: attributes["type"] ?? Kind.regular.rawValue) ?? .regular
        let results = ResultsVisibility(rawValue: attributes["results"] ?? ResultsVisibility.always.rawValue)
            ?? .always
        let chart = ChartKind(rawValue: attributes["charttype"] ?? attributes["chartType"] ?? ChartKind.bar.rawValue)
            ?? .bar
        let isPublic = (attributes["public"] ?? "true").lowercased() != "false"
        let options = body
            .components(separatedBy: .newlines)
            .map { line -> String in
                var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("-") || value.hasPrefix("*") {
                    value = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if value.hasPrefix("[ ]") || value.hasPrefix("[x]") || value.hasPrefix("[X]") {
                    value = String(value.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value
            }
            .filter { !$0.isEmpty }

        return ComposerPollSpec(
            kind: kind,
            options: kind == .number ? [] : (options.count >= 2 ? options : defaultOptions),
            results: results,
            isPublic: isPublic,
            chart: chart,
            closeISO8601: attributes["close"],
            minValue: Int(attributes["min"] ?? "") ?? 1,
            maxValue: Int(attributes["max"] ?? "") ?? 10,
            step: Int(attributes["step"] ?? "") ?? 1,
            name: attributes["name"]
        )
    }

    static func replacingPoll(in markdown: String, with spec: ComposerPollSpec) -> String {
        let pattern = #"\[poll([^\]]*)\](.*?)\[/poll\]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return spec.bbcode
        }
        let ns = markdown as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard regex.firstMatch(in: markdown, range: full) != nil else {
            return spec.bbcode
        }
        return regex.stringByReplacingMatches(
            in: markdown,
            options: [],
            range: full,
            withTemplate: NSRegularExpression.escapedTemplate(for: spec.bbcode.trimmingCharacters(in: .newlines))
        )
    }

    private static func parseAttributes(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"(\w+)\s*=\s*([^\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        for match in matches where match.numberOfRanges >= 3 {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            var value = ns.substring(with: match.range(at: 2))
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
