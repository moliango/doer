import CookedHTML
import UIKit

/// Shared shortcode → attributed title rendering for topic list/detail surfaces.
enum TitleEmojiRenderer {
    /// FluxDo parity: `:([^\s:]+(?:\:t[1-6])?):`
    static let shortcodePattern = try! NSRegularExpression(pattern: #":([^\s:]+(?:\:t[1-6])?):"#)

    /// Build display title for list/detail.
    ///
    /// FluxDo uses raw `topic.title`. Discourse `fancy_title` often keeps HTML entities
    /// (`&hellip;`) and can introduce cook-time punctuation artifacts (extra `.` etc).
    /// Prefer raw title; only fall back to fancy HTML when we need emoji shortcodes from `<img>`.
    static func plainTitle(fancyTitle: String?, title: String) -> String {
        let fancy = fancyTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if !raw.isEmpty {
            let result = decodeHTMLEntities(raw)
            // Raw title has no shortcodes, but fancy HTML may carry emoji <img alt=":code:">.
            if !containsShortcode(result), fancy.contains("<img") || fancy.contains("<IMG") {
                let recovered = decodeHTMLEntities(recoverShortcodesFromHTML(fancy))
                if containsShortcode(recovered) {
                    return recovered
                }
            }
            return result
        }

        if fancy.isEmpty {
            return ""
        }
        if fancy.contains("<"), fancy.contains(">") {
            return decodeHTMLEntities(recoverShortcodesFromHTML(fancy))
        }
        return decodeHTMLEntities(fancy)
    }

    static func containsShortcode(_ title: String) -> Bool {
        let range = NSRange(title.startIndex..., in: title)
        return shortcodePattern.firstMatch(in: title, range: range) != nil
    }

    /// Builds an attributed title, replacing shortcodes with image attachments.
    static func attributedTitle(
        _ title: String,
        font: UIFont,
        textColor: UIColor? = nil,
        baseURL: String?
    ) -> NSAttributedString {
        var working = title.contains("<") ? recoverShortcodesFromHTML(title) : title
        working = decodeHTMLEntities(working)
        guard containsShortcode(working) else {
            return plainString(working, font: font, textColor: textColor)
        }

        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let textColor {
            attributes[.foregroundColor] = textColor
        }

        let matches = shortcodePattern.matches(
            in: working,
            range: NSRange(working.startIndex..., in: working)
        )
        guard !matches.isEmpty else {
            return plainString(working, font: font, textColor: textColor)
        }

        let result = NSMutableAttributedString()
        var lastEnd = working.startIndex
        var replacedAny = false

        for match in matches {
            guard let fullRange = Range(match.range, in: working),
                  let codeRange = Range(match.range(at: 1), in: working)
            else { continue }

            if lastEnd < fullRange.lowerBound {
                result.append(
                    NSAttributedString(
                        string: String(working[lastEnd..<fullRange.lowerBound]),
                        attributes: attributes
                    )
                )
            }

            let code = String(working[codeRange])
            if let emoji = emojiAttachmentString(code: code, font: font, baseURL: baseURL) {
                result.append(emoji)
                replacedAny = true
            } else {
                result.append(
                    NSAttributedString(string: String(working[fullRange]), attributes: attributes)
                )
            }

            lastEnd = fullRange.upperBound
        }

        if lastEnd < working.endIndex {
            result.append(
                NSAttributedString(string: String(working[lastEnd...]), attributes: attributes)
            )
        }

        return replacedAny ? result : plainString(working, font: font, textColor: textColor)
    }

    /// Replace leftover `:shortcode:` runs with emoji attachments.
    ///
    /// Cooked HTML usually already turned these into `<img class="emoji">`. Callout
    /// titles, poll option labels, and uncooked body text still keep the English
    /// shortcode — never leave that visible when a forum `baseURL` is known.
    static func replacingShortcodes(
        in attributed: NSAttributedString,
        font fallbackFont: UIFont,
        baseURL: String?,
        skippingFont: UIFont? = nil
    ) -> NSAttributedString {
        let text = attributed.string
        guard containsShortcode(text) else { return attributed }

        let matches = shortcodePattern.matches(
            in: text,
            range: NSRange(location: 0, length: attributed.length)
        )
        guard !matches.isEmpty else { return attributed }

        let result = NSMutableAttributedString(attributedString: attributed)
        let skipName = skippingFont?.fontName
        var replacedAny = false

        for match in matches.reversed() {
            guard match.range.location != NSNotFound,
                  match.range.length > 0,
                  match.range.location < result.length
            else { continue }

            if result.attribute(.attachment, at: match.range.location, effectiveRange: nil) != nil {
                continue
            }
            if let skipName,
               let font = result.attribute(.font, at: match.range.location, effectiveRange: nil) as? UIFont,
               font.fontName == skipName {
                continue
            }

            guard match.numberOfRanges > 1,
                  let codeRange = Range(match.range(at: 1), in: text)
            else { continue }

            let font = (result.attribute(.font, at: match.range.location, effectiveRange: nil) as? UIFont)
                ?? fallbackFont
            let code = String(text[codeRange])
            guard let emoji = emojiAttachmentString(code: code, font: font, baseURL: baseURL) else {
                continue
            }
            result.replaceCharacters(in: match.range, with: emoji)
            replacedAny = true
        }

        return replacedAny ? result : attributed
    }

    static func apply(
        _ title: String,
        to label: UILabel,
        font: UIFont,
        textColor: UIColor? = nil,
        baseURL: String?
    ) {
        if let textColor {
            label.textColor = textColor
        }

        var working = title.contains("<") ? recoverShortcodesFromHTML(title) : title
        working = decodeHTMLEntities(working)
        guard containsShortcode(working) else {
            label.attributedText = nil
            label.text = working
            return
        }

        let rendered = attributedTitle(working, font: font, textColor: textColor, baseURL: baseURL)
        guard containsAttachment(rendered) else {
            label.attributedText = nil
            label.text = working
            return
        }

        label.text = nil
        label.attributedText = rendered
        loadImages(in: rendered, cloudflareBaseURL: baseURL) { [weak label] updated in
            guard let label else { return }
            label.attributedText = updated
            label.setNeedsDisplay()
            label.invalidateIntrinsicContentSize()
        }
    }

    static func loadImages(
        in attributedString: NSAttributedString,
        cloudflareBaseURL: String? = nil,
        onImageLoaded: @escaping (NSAttributedString) -> Void
    ) {
        let mutable = NSMutableAttributedString(attributedString: attributedString)
        var entries: [(attachment: EmojiTextAttachment, url: URL)] = []
        mutable.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: mutable.length)
        ) { value, _, _ in
            guard let attachment = value as? EmojiTextAttachment, let url = attachment.emojiURL else { return }
            entries.append((attachment, url))
        }
        guard !entries.isEmpty else { return }

        for entry in entries {
            ForumImageLoader.loadImage(with: entry.url, cloudflareBaseURL: cloudflareBaseURL) { image in
                guard let image else { return }
                Task { @MainActor in
                    entry.attachment.image = image
                    onImageLoaded(mutable)
                }
            }
        }
    }

    private static func emojiAttachmentString(
        code: String,
        font: UIFont,
        baseURL: String?
    ) -> NSAttributedString? {
        guard let urlString = EmojiStore.resolvedURLString(for: code, baseURL: baseURL),
              let url = URL(string: urlString)
        else { return nil }

        let attachment = EmojiTextAttachment()
        attachment.emojiURL = url
        attachment.shortcode = ":\(code):"
        // Transparent placeholder reserves layout; nil/empty UIImage leaves a blank chip.
        attachment.image = transparentPlaceholderImage()
        attachment.bounds = CGRect(
            x: 0,
            y: (font.capHeight - font.pointSize) / 2,
            width: font.pointSize,
            height: font.pointSize
        )
        let result = NSMutableAttributedString(attachment: attachment)
        let range = NSRange(location: 0, length: result.length)
        result.addAttribute(.cookedHTMLImageURL, value: urlString, range: range)
        result.addAttribute(.font, value: font, range: range)
        return result
    }

    private static func transparentPlaceholderImage() -> UIImage {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Recover `:shortcode:` from Discourse HTML img tags and strip markup.
    /// Handles alt/title=":name:" and src paths like `/images/emoji/twitter/name.png`.
    static func recoverShortcodesFromHTML(_ html: String) -> String {
        var result = html

                // 1) emoji <img> alt/title → :shortcode: (bare name or :name: / :name:t2:)
        let altTitlePattern = try! NSRegularExpression(
            pattern: #"<img\b([^>]+)>"#,
            options: [.caseInsensitive]
        )
        let altNS = result as NSString
        let altMatches = altTitlePattern.matches(in: result, range: NSRange(location: 0, length: altNS.length))
        for match in altMatches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let attrs = altNS.substring(with: match.range(at: 1))
            let isEmoji = attrs.localizedCaseInsensitiveContains("emoji")
                || attrs.localizedCaseInsensitiveContains("/emoji/")
            guard isEmoji else { continue }

            // Extract title/alt manually
            var rawName = ""
            for key in ["title", "alt"] {
                let p = try! NSRegularExpression(
                    pattern: key + #"\s*=\s*[\"']([^\"']+)[\"']"#,
                    options: [.caseInsensitive]
                )
                if let m = p.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
                   m.numberOfRanges > 1 {
                    rawName = (attrs as NSString).substring(with: m.range(at: 1))
                    break
                }
            }
            var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if name.isEmpty {
                let srcPattern = try! NSRegularExpression(
                    pattern: #"src\s*=\s*[\"']([^\"']+)[\"']"#,
                    options: [.caseInsensitive]
                )
                if let m = srcPattern.firstMatch(in: attrs, range: NSRange(location: 0, length: (attrs as NSString).length)),
                   m.numberOfRanges > 1 {
                    let src = (attrs as NSString).substring(with: m.range(at: 1))
                    name = emojiName(fromSrc: src)
                }
            }
            guard !name.isEmpty, let full = Range(match.range, in: result) else { continue }
            result.replaceSubrange(full, with: ":\(name):")
        }

// 2) Remaining <img class="emoji" src=".../emoji/set/name.png"> → :name:
        //    (custom boost stickers often only have src, not a colon-wrapped alt)
        let srcPattern = try! NSRegularExpression(
            pattern: #"<img\b[^>]*class\s*=\s*[\"'][^\"']*emoji[^\"']*[\"'][^>]*src\s*=\s*[\"']([^\"']+)[\"'][^>]*>|<img\b[^>]*src\s*=\s*[\"']([^\"']+)[\"'][^>]*class\s*=\s*[\"'][^\"']*emoji[^\"']*[\"'][^>]*>"#,
            options: [.caseInsensitive]
        )
        let ns = result as NSString
        let matches = srcPattern.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            var src = ""
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                src = ns.substring(with: match.range(at: 1))
            } else if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                src = ns.substring(with: match.range(at: 2))
            }
            let name = emojiName(fromSrc: src)
            let replacement = name.isEmpty ? "" : ":\(name):"
            if let full = Range(match.range, in: result) {
                result.replaceSubrange(full, with: replacement)
            }
        }

        let tagPattern = try! NSRegularExpression(pattern: #"<[^>]+>"#, options: [])
        result = tagPattern.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        return result
    }

    /// Public wrapper for boost chip shortcode recovery from cooked img src.
    static func emojiNameForBoost(fromSrc src: String) -> String {
        emojiName(fromSrc: src)
    }

    /// `/images/emoji/twitter/foo.png` or `.../foo/t2.png` → `foo` / `foo:t2`
    private static func emojiName(fromSrc src: String) -> String {
        let decoded = src.removingPercentEncoding ?? src
        guard let regex = try? NSRegularExpression(
            pattern: #"/emoji/[^/]+/([^/?#]+?)(?:/(t\d))?\.png"#,
            options: [.caseInsensitive]
        ) else { return "" }
        let ns = decoded as NSString
        guard let match = regex.firstMatch(in: decoded, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2,
              match.range(at: 1).location != NSNotFound
        else { return "" }
        let base = ns.substring(with: match.range(at: 1))
        if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
            let tone = ns.substring(with: match.range(at: 2))
            return "\(base):\(tone)"
        }
        return base
    }

    /// Decode HTML entities commonly present in Discourse `fancy_title`.
    /// Example: `服务不崩&hellip;&hellip;` → `服务不崩……`
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }

        var result = text

        // Numeric entities: &#8230; and &#x2026;
        let numericPattern = try! NSRegularExpression(
            pattern: #"&#(x?[0-9a-fA-F]+);"#
        )
        let ns = result as NSString
        let matches = numericPattern.matches(in: result, range: NSRange(location: 0, length: ns.length))
        // Replace from end to keep ranges valid.
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let full = Range(match.range, in: result),
                  let body = Range(match.range(at: 1), in: result)
            else { continue }
            let token = String(result[body])
            let scalarValue: UInt32?
            if token.lowercased().hasPrefix("x") {
                scalarValue = UInt32(token.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(token)
            }
            if let scalarValue, let scalar = UnicodeScalar(scalarValue) {
                result.replaceSubrange(full, with: String(Character(scalar)))
            }
        }

        // Named entities (amp last).
        let named: [(String, String)] = [
            ("&hellip;", "…"),
            ("&mdash;", "—"),
            ("&ndash;", "–"),
            ("&nbsp;", " "),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&amp;", "&"),
        ]
        for (entity, value) in named {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        return result
    }

    private static func plainString(_ title: String, font: UIFont, textColor: UIColor?) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if let textColor {
            attributes[.foregroundColor] = textColor
        }
        return NSAttributedString(string: title, attributes: attributes)
    }

    private static func containsAttachment(_ attributedString: NSAttributedString) -> Bool {
        var found = false
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, stop in
            if value is NSTextAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
