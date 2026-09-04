import UIKit

enum ComposerMentionQuery {
    /// `RegExp(r'@([\w_-]*)$')` with `@` at start or after whitespace/newline.
    static func activeMentionQuery(in displayText: String, cursor: Int) -> (term: String, range: NSRange)? {
        let ns = displayText as NSString
        let length = ns.length
        guard cursor > 0, cursor <= length else { return nil }
        let before = ns.substring(to: cursor) as NSString
        guard let regex = try? NSRegularExpression(pattern: #"@([A-Za-z0-9_-]*)$"#, options: []) else {
            return nil
        }
        let full = NSRange(location: 0, length: before.length)
        guard let match = regex.firstMatch(in: before as String, options: [], range: full),
              match.numberOfRanges >= 2
        else { return nil }
        let atIndex = match.range.location
        if atIndex > 0 {
            let prev = before.character(at: atIndex - 1)
            guard let prevScalar = UnicodeScalar(prev),
                  CharacterSet.whitespacesAndNewlines.contains(prevScalar)
            else { return nil }
        }
        let termRange = match.range(at: 1)
        let term = before.substring(with: termRange)
        return (term, NSRange(location: atIndex, length: match.range.length))
    }

    static func filterSeeds(_ seeds: [DiscourseMentionUser], term: String) -> [DiscourseMentionUser] {
        var seen = Set<String>()
        let unique = seeds.filter { user in
            let key = user.username.lowercased()
            guard !key.isEmpty else { return false }
            return seen.insert(key).inserted
        }
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return Array(unique.prefix(8)) }
        return unique.filter {
            $0.username.lowercased().hasPrefix(needle)
                || ($0.name?.lowercased().contains(needle) ?? false)
        }
    }

    static func merge(seed: [DiscourseMentionUser], remote: [DiscourseMentionUser]) -> [DiscourseMentionUser] {
        var seen = Set<String>()
        var result: [DiscourseMentionUser] = []
        for user in seed + remote {
            let key = user.username.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(user)
            if result.count >= 12 { break }
        }
        return result
    }
}

/// Shared @ picker for reply / new-topic / PM composers.
@MainActor
final class ComposerMentionController {
    let picker = ComposerMentionPickerView()
    var onInsert: ((DiscourseMentionUser, NSRange) -> Void)?

    private let api: DiscourseAPI
    private let topicId: Int?
    private var seedUsers: [DiscourseMentionUser]
    private weak var host: UIView?
    private weak var editor: UIView?
    private var leadingConstraint: NSLayoutConstraint?
    private var topConstraint: NSLayoutConstraint?
    private var activeRange: NSRange?
    private var searchTask: Task<Void, Never>?
    private var generation = 0

    init(api: DiscourseAPI, topicId: Int?, seedUsers: [DiscourseMentionUser] = []) {
        self.api = api
        self.topicId = topicId
        self.seedUsers = seedUsers
        picker.onSelect = { [weak self] user in
            guard let self, let range = self.activeRange else { return }
            self.onInsert?(user, range)
            self.hide()
        }
    }

    func install(in host: UIView, editor: UIView, baseURL: String) {
        self.host = host
        self.editor = editor
        picker.configure(baseURL: baseURL)
        host.addSubview(picker)
        let leading = picker.leadingAnchor.constraint(equalTo: editor.leadingAnchor, constant: 16)
        let top = picker.topAnchor.constraint(equalTo: editor.topAnchor, constant: 56)
        leadingConstraint = leading
        topConstraint = top
        NSLayoutConstraint.activate([
            leading,
            top,
            picker.trailingAnchor.constraint(lessThanOrEqualTo: editor.trailingAnchor, constant: -16),
        ])
    }

    func hide() {
        activeRange = nil
        searchTask?.cancel()
        searchTask = nil
        picker.hide(animated: true)
    }

    func refresh(displayText: String, cursor: Int, caretView: UITextView, isPreviewing: Bool) {
        guard !isPreviewing else {
            hide()
            return
        }
        guard let query = ComposerMentionQuery.activeMentionQuery(in: displayText, cursor: cursor) else {
            hide()
            return
        }
        activeRange = query.range
        reposition(caretView: caretView)
        scheduleSearch(term: query.term)
    }

    private func scheduleSearch(term: String) {
        searchTask?.cancel()
        generation += 1
        let generation = self.generation
        let seed = ComposerMentionQuery.filterSeeds(seedUsers, term: term)
        host?.bringSubviewToFront(picker)
        if !seed.isEmpty {
            picker.update(users: seed, animated: true)
            host?.layoutIfNeeded()
        }
        searchTask = Task { [weak self] in
            let delay: UInt64 = term.isEmpty ? 80_000_000 : 300_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            do {
                let remote = try await self?.api.searchUsersForMention(term: term, topicId: self?.topicId) ?? []
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                let merged = ComposerMentionQuery.merge(seed: seed, remote: remote)
                await MainActor.run {
                    guard generation == self.generation, self.activeRange != nil else { return }
                    self.host?.bringSubviewToFront(self.picker)
                    self.picker.update(users: merged, animated: true)
                    self.host?.layoutIfNeeded()
                }
            } catch {
                guard !Task.isCancelled, let self, generation == self.generation else { return }
                await MainActor.run {
                    if seed.isEmpty {
                        self.picker.hide(animated: true)
                    }
                }
            }
        }
    }

    private func reposition(caretView: UITextView) {
        guard let range = activeRange, range.location != NSNotFound, caretView.bounds.height > 0 else { return }
        let caretRange = NSRange(
            location: min(range.location, max((caretView.attributedText?.length ?? 0) - 1, 0)),
            length: 0
        )
        var caretRect = caretView.caretRect(for: caretView.position(
            from: caretView.beginningOfDocument,
            offset: caretRange.location
        ) ?? caretView.endOfDocument)
        if caretRect.isNull || caretRect.origin.x.isInfinite || caretRect.origin.y.isInfinite {
            caretRect = CGRect(x: 16, y: 16, width: 2, height: 28)
        }
        guard let editor else { return }
        let converted = caretView.convert(caretRect, to: editor)
        topConstraint?.constant = max(12, min(converted.maxY + 8, editor.bounds.height - 80))
        leadingConstraint?.constant = max(16, min(converted.minX, editor.bounds.width - 220))
    }
}
