import Foundation

/// External sticker market (FluxDO-compatible), not Discourse-authenticated.
final class StickerMarketStore {
    static let shared = StickerMarketStore()
    static let defaultBaseURL = "https://s.pwsh.us.kg"

    private let defaults: UserDefaults
    private let session: URLSession
    private let cacheDuration: TimeInterval = 24 * 60 * 60
    private let maxRecent = 30

    private let baseURLKey = "sticker_market_base_url"
    private let cachePrefix = "sticker_market_cache_"
    private let subscribedKey = "sticker_subscribed_groups"
    private let recentKey = "sticker_recent_items"
    private let fileManager: FileManager
    private let storageDirectory: URL

    init(
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        storageDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.session = session
        self.fileManager = fileManager
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else {
            self.storageDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("StickerMarket", isDirectory: true)
        }
        try? fileManager.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true)
    }

    var baseURL: String {
        let stored = defaults.string(forKey: baseURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty {
            return stored.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return Self.defaultBaseURL
    }

    func setBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        defaults.set(trimmed, forKey: baseURLKey)
        clearMarketCache()
    }

    func resetBaseURL() {
        defaults.removeObject(forKey: baseURLKey)
        clearMarketCache()
    }

    // MARK: - Subscribe / recent

    func subscribedGroupIds() -> [String] {
        defaults.stringArray(forKey: subscribedKey) ?? []
    }

    func isSubscribed(_ groupId: String) -> Bool {
        subscribedGroupIds().contains(groupId)
    }

    func subscribe(_ groupId: String) {
        var ids = subscribedGroupIds()
        guard !ids.contains(groupId) else { return }
        ids.append(groupId)
        defaults.set(ids, forKey: subscribedKey)
        Task {
            _ = try? await refreshAndPersistDetail(groupId)
        }
    }

    func unsubscribe(_ groupId: String) {
        var ids = subscribedGroupIds()
        ids.removeAll { $0 == groupId }
        defaults.set(ids, forKey: subscribedKey)
        removePersistedDetail(groupId)
    }

    func recentStickers() -> [StickerItem] {
        guard let raw = defaults.stringArray(forKey: recentKey) else { return [] }
        return raw.compactMap { item in
            guard let data = item.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(StickerItem.self, from: data)
        }
    }

    func addRecent(_ sticker: StickerItem) {
        var list = defaults.stringArray(forKey: recentKey) ?? []
        if let data = try? JSONEncoder().encode(sticker),
           let encoded = String(data: data, encoding: .utf8) {
            list.removeAll { existing in
                guard let d = existing.data(using: .utf8),
                      let item = try? JSONDecoder().decode(StickerItem.self, from: d)
                else { return false }
                return item.id == sticker.id
            }
            list.insert(encoded, at: 0)
            if list.count > maxRecent {
                list = Array(list.prefix(maxRecent))
            }
            defaults.set(list, forKey: recentKey)
        }
    }

    // MARK: - Network

    func fetchIndex() async throws -> StickerMarketIndex {
        let data = try await fetchJSON(cacheKey: "index", path: "/assets/market/index/index.json")
        return try JSONDecoder().decode(StickerMarketIndex.self, from: data)
    }

    func fetchAllGroups() async throws -> [StickerGroup] {
        let index = try await fetchIndex()
        var groups: [StickerGroup] = []
        if index.totalPages <= 0 {
            return groups
        }
        for page in 1...index.totalPages {
            groups.append(contentsOf: try await fetchGroupsPage(page))
        }
        return groups
            .filter { !$0.isArchived && !$0.id.isEmpty }
            .sorted { $0.order < $1.order }
    }

    func fetchGroupsPage(_ page: Int) async throws -> [StickerGroup] {
        let data = try await fetchJSON(cacheKey: "page_\(page)", path: "/assets/market/index/page-\(page).json")
        if let pagePayload = try? JSONDecoder().decode(StickerGroupsPageDTO.self, from: data) {
            return pagePayload.groups
        }
        // Some deployments return a bare array.
        return (try? JSONDecoder().decode([StickerGroup].self, from: data)) ?? []
    }

    func fetchGroupDetail(_ groupId: String) async throws -> StickerGroupDetail {
        let data = try await fetchJSON(cacheKey: "group_\(groupId)", path: "/assets/market/group-\(groupId).json")
        return try JSONDecoder().decode(StickerGroupDetail.self, from: data)
    }

    func loadSubscribedDetails() async throws -> [StickerGroupDetail] {
        let ids = subscribedGroupIds()
        var byId = Dictionary(uniqueKeysWithValues: loadPersistedDetails().map { ($0.id, $0) })
        for id in ids {
            if let remote = try? await fetchGroupDetail(id) {
                byId[id] = remote
                persistDetail(remote)
            }
        }
        prunePersistedDetails(keeping: Set(ids))
        return ids.compactMap { byId[$0] }
    }

    @discardableResult
    func refreshAndPersistDetail(_ groupId: String) async throws -> StickerGroupDetail {
        let detail = try await fetchGroupDetail(groupId)
        persistDetail(detail)
        return detail
    }

    // MARK: - Cache helpers

    private struct StickerGroupsPageDTO: Codable {
        let groups: [StickerGroup]
    }

    private func fetchJSON(cacheKey: String, path: String) async throws -> Data {
        let fullKey = cachePrefix + cacheKey
        let tsKey = fullKey + "_ts"
        if let cached = defaults.string(forKey: fullKey),
           let ts = defaults.object(forKey: tsKey) as? TimeInterval {
            let age = Date().timeIntervalSince1970 - ts
            if age < cacheDuration, let data = cached.data(using: .utf8) {
                return data
            }
        }

        guard let url = URL(string: baseURL + path) else {
            throw URLError(.badURL)
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            if let text = String(data: data, encoding: .utf8) {
                defaults.set(text, forKey: fullKey)
                defaults.set(Date().timeIntervalSince1970, forKey: tsKey)
            }
            return data
        } catch {
            if let cached = defaults.string(forKey: fullKey),
               let data = cached.data(using: .utf8) {
                return data
            }
            throw error
        }
    }

    private func clearMarketCache() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(cachePrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Local subscribed packs

    private var subscribedDetailsURL: URL {
        storageDirectory.appendingPathComponent("subscribed-details.json")
    }

    func loadPersistedDetails() -> [StickerGroupDetail] {
        guard let data = try? Data(contentsOf: subscribedDetailsURL) else { return [] }
        return (try? JSONDecoder().decode([StickerGroupDetail].self, from: data)) ?? []
    }

    private func persistDetail(_ detail: StickerGroupDetail) {
        var details = loadPersistedDetails()
        details.removeAll { $0.id == detail.id }
        details.append(detail)
        savePersistedDetails(details)
    }

    private func removePersistedDetail(_ groupId: String) {
        var details = loadPersistedDetails()
        details.removeAll { $0.id == groupId }
        savePersistedDetails(details)
    }

    private func prunePersistedDetails(keeping ids: Set<String>) {
        let details = loadPersistedDetails().filter { ids.contains($0.id) }
        savePersistedDetails(details)
    }

    private func savePersistedDetails(_ details: [StickerGroupDetail]) {
        guard let data = try? JSONEncoder().encode(details) else { return }
        try? data.write(to: subscribedDetailsURL, options: .atomic)
    }
}
