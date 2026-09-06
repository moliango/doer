import Foundation

/// Local autosave for composers. Survives process kill; cleared on successful send.
/// Server drafts (Me → Drafts cloud section) are separate but can be dual-written via
/// `ComposerServerDraftSync`.
enum ComposerLocalDraftStore {
    private static let defaults = UserDefaults.standard
    private static let prefix = "composer.local_draft."
    private static let sequencePrefix = "composer.draft_sequence."

    // MARK: - Listed item (Me → Drafts)

    enum ListedKind: String, Codable {
        case reply
        case newTopic
        case privateMessage
    }

    struct ListedDraft: Identifiable, Equatable {
        var id: String { storageKey }
        let storageKey: String
        /// Discourse `draft_key` used for server upsert / delete.
        let draftKey: String
        let kind: ListedKind
        let title: String?
        let preview: String
        let updatedAt: Date
        let topicId: Int?
        let replyToPostNumber: Int?
        let recipient: String?
        let categoryId: Int?
        let tags: [String]
        let raw: String
        let rawTitle: String
    }

    /// All non-empty local drafts for a forum host, newest first.
    static func listedDrafts(baseURL: String) -> [ListedDraft] {
        let host = normalizedHost(baseURL)
        let needle = "\(prefix)"
        var items: [ListedDraft] = []
        for (key, value) in defaults.dictionaryRepresentation() {
            guard key.hasPrefix(needle), key.contains(".\(host).") || key.hasSuffix(".\(host)") else { continue }
            if let item = listedDraft(storageKey: key, value: value, host: host) {
                items.append(item)
            }
        }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func removeListedDraft(_ draft: ListedDraft) {
        defaults.removeObject(forKey: draft.storageKey)
        clearSequence(baseURLHost: normalizedHostFromStorageKey(draft.storageKey), draftKey: draft.draftKey)
    }

    // MARK: - Reply

    static func replyKey(baseURL: String, topicId: Int, replyToPostNumber: Int?) -> String {
        let host = normalizedHost(baseURL)
        if let replyToPostNumber {
            return "\(prefix)reply.\(host).t\(topicId).p\(replyToPostNumber)"
        }
        return "\(prefix)reply.\(host).t\(topicId)"
    }

    static func discourseReplyDraftKey(topicId: Int, replyToPostNumber: Int?) -> String {
        if let replyToPostNumber {
            return "topic_\(topicId)_post_\(replyToPostNumber)"
        }
        return "topic_\(topicId)"
    }

    static func loadReply(baseURL: String, topicId: Int, replyToPostNumber: Int?) -> String? {
        let key = replyKey(baseURL: baseURL, topicId: topicId, replyToPostNumber: replyToPostNumber)
        if let data = defaults.data(forKey: key),
           let envelope = try? JSONDecoder().decode(ReplyEnvelope.self, from: data) {
            let text = envelope.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : envelope.raw
        }
        // Legacy plain string
        let text = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    static func saveReply(baseURL: String, topicId: Int, replyToPostNumber: Int?, raw: String) {
        let key = replyKey(baseURL: baseURL, topicId: topicId, replyToPostNumber: replyToPostNumber)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }
        let envelope = ReplyEnvelope(
            raw: raw,
            updatedAt: Date(),
            topicId: topicId,
            replyToPostNumber: replyToPostNumber
        )
        if let data = try? JSONEncoder().encode(envelope) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set(raw, forKey: key)
        }
    }

    static func clearReply(baseURL: String, topicId: Int, replyToPostNumber: Int?) {
        defaults.removeObject(
            forKey: replyKey(baseURL: baseURL, topicId: topicId, replyToPostNumber: replyToPostNumber)
        )
        clearSequence(
            baseURL: baseURL,
            draftKey: discourseReplyDraftKey(topicId: topicId, replyToPostNumber: replyToPostNumber)
        )
    }

    // MARK: - New topic

    static func newTopicKey(baseURL: String) -> String {
        "\(prefix)new_topic.\(normalizedHost(baseURL))"
    }

    struct NewTopicDraft: Codable, Equatable {
        var title: String
        var raw: String
        var categoryId: Int?
        var tags: [String]
        var updatedAt: Date?

        var resolvedUpdatedAt: Date { updatedAt ?? Date(timeIntervalSince1970: 0) }
    }

    static func loadNewTopic(baseURL: String) -> NewTopicDraft? {
        guard let data = defaults.data(forKey: newTopicKey(baseURL: baseURL)),
              let draft = try? JSONDecoder().decode(NewTopicDraft.self, from: data)
        else { return nil }
        let hasContent = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasContent ? draft : nil
    }

    static func saveNewTopic(baseURL: String, title: String, raw: String, categoryId: Int?, tags: [String]) {
        let draft = NewTopicDraft(
            title: title,
            raw: raw,
            categoryId: categoryId,
            tags: tags,
            updatedAt: Date()
        )
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || categoryId != nil
            || !tags.isEmpty
        let key = newTopicKey(baseURL: baseURL)
        if !hasContent {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(draft) {
            defaults.set(data, forKey: key)
        }
    }

    static func clearNewTopic(baseURL: String) {
        defaults.removeObject(forKey: newTopicKey(baseURL: baseURL))
        clearSequence(baseURL: baseURL, draftKey: "new_topic")
    }

    // MARK: - Private message

    static func privateMessageKey(baseURL: String, recipient: String) -> String {
        "\(prefix)pm.\(normalizedHost(baseURL)).\(recipient.lowercased())"
    }

    struct PrivateMessageDraft: Codable, Equatable {
        var title: String
        var raw: String
        var updatedAt: Date?

        var resolvedUpdatedAt: Date { updatedAt ?? Date(timeIntervalSince1970: 0) }
    }

    static func loadPrivateMessage(baseURL: String, recipient: String) -> PrivateMessageDraft? {
        guard let data = defaults.data(forKey: privateMessageKey(baseURL: baseURL, recipient: recipient)),
              let draft = try? JSONDecoder().decode(PrivateMessageDraft.self, from: data)
        else { return nil }
        let hasContent = !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasContent ? draft : nil
    }

    static func savePrivateMessage(baseURL: String, recipient: String, title: String, raw: String) {
        let draft = PrivateMessageDraft(title: title, raw: raw, updatedAt: Date())
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let key = privateMessageKey(baseURL: baseURL, recipient: recipient)
        if !hasContent {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(draft) {
            defaults.set(data, forKey: key)
        }
    }

    static func clearPrivateMessage(baseURL: String, recipient: String) {
        defaults.removeObject(forKey: privateMessageKey(baseURL: baseURL, recipient: recipient))
        clearSequence(baseURL: baseURL, draftKey: "new_private_message")
    }

    // MARK: - Server sequence cache

    static func loadSequence(baseURL: String, draftKey: String) -> Int {
        defaults.integer(forKey: sequenceStorageKey(baseURL: baseURL, draftKey: draftKey))
    }

    static func saveSequence(baseURL: String, draftKey: String, sequence: Int) {
        defaults.set(sequence, forKey: sequenceStorageKey(baseURL: baseURL, draftKey: draftKey))
    }

    static func clearSequence(baseURL: String, draftKey: String) {
        defaults.removeObject(forKey: sequenceStorageKey(baseURL: baseURL, draftKey: draftKey))
    }

    private static func clearSequence(baseURLHost host: String, draftKey: String) {
        defaults.removeObject(forKey: "\(sequencePrefix)\(host).\(draftKey)")
    }

    private static func sequenceStorageKey(baseURL: String, draftKey: String) -> String {
        "\(sequencePrefix)\(normalizedHost(baseURL)).\(draftKey)"
    }

    // MARK: - Helpers

    private struct ReplyEnvelope: Codable {
        var raw: String
        var updatedAt: Date
        var topicId: Int
        var replyToPostNumber: Int?
    }

    private static func normalizedHost(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let host = URL(string: trimmed)?.host?.lowercased(), !host.isEmpty {
            return host
        }
        return trimmed.lowercased()
    }

    private static func normalizedHostFromStorageKey(_ key: String) -> String {
        // composer.local_draft.reply.host.t123 or new_topic.host or pm.host.user
        let rest = key.replacingOccurrences(of: prefix, with: "")
        let parts = rest.split(separator: ".")
        guard parts.count >= 2 else { return rest }
        if parts[0] == "reply" || parts[0] == "pm" {
            return String(parts[1])
        }
        if parts[0] == "new_topic" {
            return String(parts[1])
        }
        return String(parts[0])
    }

    private static func listedDraft(storageKey: String, value: Any, host: String) -> ListedDraft? {
        let rest = storageKey.replacingOccurrences(of: prefix, with: "")
        if rest.hasPrefix("reply.\(host).") {
            return listedReply(storageKey: storageKey, value: value, host: host, rest: rest)
        }
        if rest == "new_topic.\(host)" || rest.hasPrefix("new_topic.\(host)") {
            guard let data = value as? Data,
                  let draft = try? JSONDecoder().decode(NewTopicDraft.self, from: data)
            else { return nil }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = draft.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !raw.isEmpty else { return nil }
            return ListedDraft(
                storageKey: storageKey,
                draftKey: "new_topic",
                kind: .newTopic,
                title: title.isEmpty ? nil : title,
                preview: raw.isEmpty ? title : raw,
                updatedAt: draft.resolvedUpdatedAt,
                topicId: nil,
                replyToPostNumber: nil,
                recipient: nil,
                categoryId: draft.categoryId,
                tags: draft.tags,
                raw: draft.raw,
                rawTitle: draft.title
            )
        }
        if rest.hasPrefix("pm.\(host).") {
            guard let data = value as? Data,
                  let draft = try? JSONDecoder().decode(PrivateMessageDraft.self, from: data)
            else { return nil }
            let recipient = String(rest.dropFirst("pm.\(host).".count))
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = draft.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !raw.isEmpty else { return nil }
            return ListedDraft(
                storageKey: storageKey,
                draftKey: "new_private_message",
                kind: .privateMessage,
                title: title.isEmpty ? "私信 @\(recipient)" : title,
                preview: raw.isEmpty ? title : raw,
                updatedAt: draft.resolvedUpdatedAt,
                topicId: nil,
                replyToPostNumber: nil,
                recipient: recipient,
                categoryId: nil,
                tags: [],
                raw: draft.raw,
                rawTitle: draft.title
            )
        }
        return nil
    }

    private static func listedReply(storageKey: String, value: Any, host: String, rest: String) -> ListedDraft? {
        // reply.host.t123 or reply.host.t123.p4
        let suffix = String(rest.dropFirst("reply.\(host).".count))
        var topicId: Int?
        var postNumber: Int?
        let parts = suffix.split(separator: ".")
        if let tPart = parts.first, tPart.hasPrefix("t"), let tid = Int(tPart.dropFirst()) {
            topicId = tid
            if parts.count > 1 {
                let pPart = parts[1]
                if pPart.hasPrefix("p") {
                    postNumber = Int(pPart.dropFirst())
                }
            }
        }
        guard let topicId else { return nil }

        let raw: String
        let updatedAt: Date
        if let data = value as? Data,
           let envelope = try? JSONDecoder().decode(ReplyEnvelope.self, from: data) {
            raw = envelope.raw
            updatedAt = envelope.updatedAt
        } else if let string = value as? String {
            raw = string
            updatedAt = Date(timeIntervalSince1970: 0)
        } else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let title: String
        if let postNumber {
            title = String(
                format: String(localized: "draft.reply.topic_floor", defaultValue: "回复话题 #%1$lld · 楼层 %2$lld"),
                locale: .current,
                topicId,
                postNumber
            )
        } else {
            title = String(
                format: String(localized: "draft.reply.topic", defaultValue: "回复话题 #%lld"),
                locale: .current,
                topicId
            )
        }
        return ListedDraft(
            storageKey: storageKey,
            draftKey: discourseReplyDraftKey(topicId: topicId, replyToPostNumber: postNumber),
            kind: .reply,
            title: title,
            preview: trimmed,
            updatedAt: updatedAt,
            topicId: topicId,
            replyToPostNumber: postNumber,
            recipient: nil,
            categoryId: nil,
            tags: [],
            raw: raw,
            rawTitle: ""
        )
    }

}

// MARK: - Server draft sync

/// Dual-writes composer text to Discourse `/drafts.json` so web / FluxDo can resume.
enum ComposerServerDraftSync {
    static func dataJSON(for data: DiscourseDraftData) -> String? {
        let encoder = JSONEncoder()
        guard let encoded = try? encoder.encode(data),
              let string = String(data: encoded, encoding: .utf8)
        else { return nil }
        return string
    }

    static func syncReply(
        api: DiscourseAPI,
        topicId: Int,
        replyToPostNumber: Int?,
        raw: String,
        draftKey: String? = nil
    ) async -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftKey = draftKey ?? ComposerLocalDraftStore.discourseReplyDraftKey(
            topicId: topicId,
            replyToPostNumber: replyToPostNumber
        )
        guard !trimmed.isEmpty else {
            await clearServerDraft(api: api, draftKey: draftKey)
            return true
        }
        let payload = DiscourseDraftData(
            reply: raw,
            action: "reply",
            archetypeId: "regular",
            replyToPostNumber: replyToPostNumber
        )
        return await upsert(api: api, draftKey: draftKey, data: payload)
    }

    static func syncNewTopic(
        api: DiscourseAPI,
        title: String,
        raw: String,
        categoryId: Int?,
        tags: [String],
        draftKey: String = "new_topic"
    ) async -> Bool {
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || categoryId != nil
            || !tags.isEmpty
        guard hasContent else {
            await clearServerDraft(api: api, draftKey: draftKey)
            return true
        }
        let payload = DiscourseDraftData(
            title: title,
            reply: raw,
            categoryId: categoryId,
            tags: tags,
            action: "create_topic",
            archetypeId: "regular"
        )
        return await upsert(api: api, draftKey: draftKey, data: payload)
    }

    static func syncPrivateMessage(
        api: DiscourseAPI,
        recipient: String,
        title: String,
        raw: String,
        draftKey: String = "new_private_message"
    ) async -> Bool {
        let hasContent = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent else {
            await clearServerDraft(api: api, draftKey: draftKey)
            return true
        }
        let recipients = recipient
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let payload = DiscourseDraftData(
            title: title,
            reply: raw,
            action: "private_message",
            archetypeId: "private_message",
            recipients: recipients,
            targetRecipients: recipient
        )
        return await upsert(api: api, draftKey: draftKey, data: payload)
    }

    static func clearServerDraft(api: DiscourseAPI, draftKey: String) async {
        var sequence = ComposerLocalDraftStore.loadSequence(baseURL: api.baseURL, draftKey: draftKey)
        var shouldDelete = sequence > 0
        if let server = try? await api.fetchDraft(key: draftKey) {
            sequence = server.sequence
            shouldDelete = true
        }
        if shouldDelete {
            do {
                try await api.deleteDraft(key: draftKey, sequence: sequence)
            } catch {
                // Refresh once when a stale sequence was cached by another client.
                if let current = try? await api.fetchDraft(key: draftKey),
                   current.sequence != sequence {
                    try? await api.deleteDraft(key: draftKey, sequence: current.sequence)
                }
            }
        }
        ComposerLocalDraftStore.clearSequence(baseURL: api.baseURL, draftKey: draftKey)
    }

    private static func upsert(api: DiscourseAPI, draftKey: String, data: DiscourseDraftData) async -> Bool {
        guard let dataJSON = dataJSON(for: data) else { return false }
        var sequence = ComposerLocalDraftStore.loadSequence(baseURL: api.baseURL, draftKey: draftKey)
        do {
            let next = try await api.saveDraft(key: draftKey, sequence: sequence, dataJSON: dataJSON)
            ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draftKey, sequence: next)
            return true
        } catch {
            // FluxDo: 409 sequence conflict → retry once with force_save.
            let isConflict: Bool = {
                if let apiError = error as? DiscourseAPIError {
                    return apiError.errorType == "http_409"
                }
                return false
            }()
            if isConflict {
                if let next = try? await api.saveDraft(
                    key: draftKey,
                    sequence: sequence,
                    dataJSON: dataJSON,
                    forceSave: true
                ) {
                    ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draftKey, sequence: next)
                    return true
                }
            }
            // Generic desync — bump sequence and retry once.
            sequence += 1
            if let next = try? await api.saveDraft(key: draftKey, sequence: sequence, dataJSON: dataJSON) {
                ComposerLocalDraftStore.saveSequence(baseURL: api.baseURL, draftKey: draftKey, sequence: next)
                return true
            }
        }
        return false
    }
}
