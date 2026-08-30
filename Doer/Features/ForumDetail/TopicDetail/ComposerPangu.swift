import Foundation

/// Inserts spaces at CJK ↔ Latin/digit boundaries without touching fenced code, inline code, or URLs.
enum ComposerPangu {
    private static let placeholderBase: UInt32 = 0xE000
    private static let placeholderMax: UInt32 = 0xF8FF

    private static let cjk: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0x2E80)!...Unicode.Scalar(0x2EFF)!)
        set.insert(charactersIn: Unicode.Scalar(0x2F00)!...Unicode.Scalar(0x2FDF)!)
        set.insert(charactersIn: Unicode.Scalar(0x3040)!...Unicode.Scalar(0x30FF)!)
        set.insert(charactersIn: Unicode.Scalar(0x3100)!...Unicode.Scalar(0x312F)!)
        set.insert(charactersIn: Unicode.Scalar(0x3400)!...Unicode.Scalar(0x4DBF)!)
        set.insert(charactersIn: Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!)
        set.insert(charactersIn: Unicode.Scalar(0xF900)!...Unicode.Scalar(0xFAFF)!)
        return set
    }()

    private static let latinDigit: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0x30)!...Unicode.Scalar(0x39)!)
        set.insert(charactersIn: Unicode.Scalar(0x41)!...Unicode.Scalar(0x5A)!)
        set.insert(charactersIn: Unicode.Scalar(0x61)!...Unicode.Scalar(0x7A)!)
        return set
    }()

    private enum ScalarKind {
        case cjk
        case latin
        case other
    }

    static func spacing(_ text: String) -> String {
        guard text.contains(where: { $0.unicodeScalars.contains(where: { cjk.contains($0) }) }) else {
            return text
        }

        var tokens: [String] = []
        var working = text
        working = extract(working, pattern: "```.*?```", options: .dotMatchesLineSeparators, into: &tokens)
        working = extract(working, pattern: "~~~.*?~~~", options: .dotMatchesLineSeparators, into: &tokens)
        working = extract(working, pattern: "`[^`]+`", into: &tokens)
        working = extract(working, pattern: #"https?://[A-Za-z0-9._~:/?#@!$&'*+,;=%\-\[\]]+"#, into: &tokens)
        working = insertBoundarySpaces(working)

        for (index, token) in tokens.enumerated().reversed() {
            guard let scalar = Unicode.Scalar(placeholderBase + UInt32(index)) else { continue }
            working = working.replacingOccurrences(of: String(scalar), with: token)
        }
        return working
    }

    @MainActor
    static func applyToOutgoing(_ text: String) -> String {
        AppSettings.shared.autoPanguSpacing ? spacing(text) : text
    }

    private static func extract(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        into tokens: inout [String]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var cursor = 0
        for match in matches {
            let maxIndex = Int(placeholderMax - placeholderBase)
            guard tokens.count <= maxIndex else { break }
            if match.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            guard let scalar = Unicode.Scalar(placeholderBase + UInt32(tokens.count)) else { break }
            tokens.append(ns.substring(with: match.range))
            result += String(scalar)
            cursor = NSMaxRange(match.range)
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    private static func insertBoundarySpaces(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count + 8)
        var previousKind: ScalarKind?
        for scalar in text.unicodeScalars {
            let kind = scalarKind(scalar)
            if let previousKind, needsSpace(between: previousKind, and: kind) {
                output.append(" ")
            }
            output.unicodeScalars.append(scalar)
            previousKind = kind
        }
        return output
    }

    private static func scalarKind(_ scalar: Unicode.Scalar) -> ScalarKind {
        if scalar.value >= placeholderBase && scalar.value <= placeholderMax {
            return .latin
        }
        if cjk.contains(scalar) { return .cjk }
        if latinDigit.contains(scalar) { return .latin }
        return .other
    }

    private static func needsSpace(between previous: ScalarKind, and current: ScalarKind) -> Bool {
        (previous == .cjk && current == .latin) || (previous == .latin && current == .cjk)
    }
}
