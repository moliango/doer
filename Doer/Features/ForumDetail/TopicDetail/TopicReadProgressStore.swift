import Foundation

/// Local highest-seen floor cache. Merges with Discourse `last_read_post_number`
/// so list styling and resume-reading stay correct when timings lag or offline.
///
/// Supports FluxDo-style mark-unread: step back one floor or clear all progress.
/// Explicit overrides can go below the server watermark for list/resume UX.
final class TopicReadProgressStore {
    static let shared = TopicReadProgressStore()

    private let defaults: UserDefaults
    private let storageKey = "topic.read_progress.v1"
    /// Explicit mark-unread overrides (may be 0 or lower than server last_read).
    private let overrideKey = "topic.read_progress.override.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func highestSeen(topicId: Int, baseURL: String, username: String?) -> Int {
        let k = key(topicId: topicId, baseURL: baseURL, username: username)
        if let override = loadOverrides()[k] {
            return override
        }
        return loadMap()[k] ?? 0
    }

    /// Records a new high-water mark (monotonic). Clears any mark-unread override.
    func record(topicId: Int, highestSeen: Int, baseURL: String, username: String?) {
        guard topicId > 0, highestSeen > 0 else { return }
        let k = key(topicId: topicId, baseURL: baseURL, username: username)
        clearOverride(for: k, notify: false)

        var map = loadMap()
        let previous = map[k] ?? 0
        guard highestSeen > previous else { return }
        map[k] = highestSeen
        // Cap growth — drop oldest by rewriting only current map (fine for typical use).
        if map.count > 2_000 {
            let trimmed = map.sorted { $0.value > $1.value }.prefix(1_500)
            map = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        defaults.set(map, forKey: storageKey)
        notifyChanged(topicId: topicId, baseURL: baseURL, highestSeen: highestSeen)
    }

    /// FluxDo: roll last-read back by one floor (min 0).
    @discardableResult
    func stepBack(topicId: Int, baseURL: String, username: String?, serverLastRead: Int?) -> Int {
        let current = mergedLastRead(
            serverLastRead: serverLastRead,
            topicId: topicId,
            baseURL: baseURL,
            username: username
        )
        let next = max(0, current - 1)
        forceSet(topicId: topicId, highestSeen: next, baseURL: baseURL, username: username)
        return next
    }

    /// FluxDo: clear all local progress so the topic looks fully unread.
    func clear(topicId: Int, baseURL: String, username: String?) {
        forceSet(topicId: topicId, highestSeen: 0, baseURL: baseURL, username: username)
    }

    /// Force an absolute watermark (used by mark-unread). `0` means unread from the start.
    func forceSet(topicId: Int, highestSeen: Int, baseURL: String, username: String?) {
        guard topicId > 0 else { return }
        let k = key(topicId: topicId, baseURL: baseURL, username: username)
        var overrides = loadOverrides()
        overrides[k] = max(0, highestSeen)
        if overrides.count > 2_000 {
            let trimmed = overrides.sorted { $0.value > $1.value }.prefix(1_500)
            overrides = Dictionary(uniqueKeysWithValues: trimmed.map { ($0.key, $0.value) })
        }
        defaults.set(overrides, forKey: overrideKey)

        // Keep monotonic map coherent when stepping back.
        var map = loadMap()
        if highestSeen <= 0 {
            map.removeValue(forKey: k)
        } else {
            map[k] = highestSeen
        }
        defaults.set(map, forKey: storageKey)
        notifyChanged(topicId: topicId, baseURL: baseURL, highestSeen: max(0, highestSeen))
    }

    /// Effective last-read = override ?? max(server, local).
    func mergedLastRead(
        serverLastRead: Int?,
        topicId: Int,
        baseURL: String,
        username: String?
    ) -> Int {
        let k = key(topicId: topicId, baseURL: baseURL, username: username)
        if let override = loadOverrides()[k] {
            return override
        }
        return max(serverLastRead ?? 0, loadMap()[k] ?? 0)
    }

    func applyLocalProgress(
        to topic: DiscourseTopicList.Topic,
        baseURL: String,
        username: String?
    ) -> DiscourseTopicList.Topic {
        let k = key(topicId: topic.id, baseURL: baseURL, username: username)
        if let override = loadOverrides()[k] {
            return topic.forcingReadProgress(highestSeen: override)
        }
        let local = loadMap()[k] ?? 0
        guard local > 0 else { return topic }
        let server = topic.lastReadPostNumber ?? 0
        guard local > server || topic.unseen else { return topic }
        return topic.updatingReadProgress(highestSeen: max(local, server))
    }

    private func clearOverride(for key: String, notify: Bool) {
        var overrides = loadOverrides()
        guard overrides.removeValue(forKey: key) != nil else { return }
        defaults.set(overrides, forKey: overrideKey)
    }

    private func notifyChanged(topicId: Int, baseURL: String, highestSeen: Int) {
        NotificationCenter.default.post(
            name: .topicReadProgressDidChange,
            object: nil,
            userInfo: [
                TopicReadProgressUserInfoKey.topicId: topicId,
                TopicReadProgressUserInfoKey.baseURL: baseURL,
                TopicReadProgressUserInfoKey.highestSeen: highestSeen,
            ]
        )
    }

    private func loadOverrides() -> [String: Int] {
        (defaults.dictionary(forKey: overrideKey) as? [String: Int]) ?? [:]
    }

    private func loadMap() -> [String: Int] {
        (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
    }

    private func key(topicId: Int, baseURL: String, username: String?) -> String {
        let normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let account = username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "guest"
        return "\(normalizedBase)|\(account)|\(topicId)"
    }
}

/// Where Topic Detail should land after the first load.
enum TopicDetailOpenAnchor: Equatable {
    case top
    case floor(Int)
    case postId(Int)

    static func resolve(
        initialPostId: Int?,
        initialFloor: Int?,
        lastRead: Int,
        totalFloors: Int,
        pinLatestWhenFullyRead: Bool,
        openingPostId: Int? = nil
    ) -> TopicDetailOpenAnchor {
        // Floor 1 is the document start after first paint. Check it before post id so
        // `/t/:id/1` and search/notification OP hits do not animate a jump onto the OP.
        if let initialFloor, initialFloor <= 1 {
            return .top
        }
        if let initialPostId {
            if let openingPostId, initialPostId == openingPostId {
                return .top
            }
            return .postId(initialPostId)
        }
        if lastRead > 1, totalFloors > lastRead {
            return collapseOpeningFloor(.floor(min(lastRead + 1, totalFloors)))
        }
        if pinLatestWhenFullyRead, totalFloors > 0, lastRead >= totalFloors {
            return collapseOpeningFloor(.floor(totalFloors))
        }
        return .top
    }

    static func isOpeningPostTarget(floor: Int?, postNumber: Int?, postId: Int?, openingPostId: Int?) -> Bool {
        if let floor, floor <= 1 { return true }
        if let postNumber, postNumber <= 1 { return true }
        if let postId, let openingPostId, postId == openingPostId { return true }
        return false
    }

    /// Already showing the OP at the top — skip overlay / animated scrollToRow.
    static func shouldStayAtOpeningPost(isOpeningPostTarget: Bool, contentOffsetY: CGFloat) -> Bool {
        isOpeningPostTarget && contentOffsetY <= 24
    }

    /// Floor 1 is already the default viewport after first paint. Jumping there
    /// flashes the overlay / animated scroll even though the OP is on screen.
    private static func collapseOpeningFloor(_ anchor: TopicDetailOpenAnchor) -> TopicDetailOpenAnchor {
        if case .floor(let floor) = anchor, floor <= 1 {
            return .top
        }
        return anchor
    }
}
