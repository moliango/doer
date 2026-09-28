import Foundation
import WidgetKit

enum TrustLevelWidgetRefresher {
    static func persist(report: ConnectTrustReport, trustLevel: Int?) {
        let items = report.rings.map {
            TrustLevelWidgetItem(
                label: $0.label,
                current: $0.current,
                target: max($0.max, 1),
                isMet: $0.isMet,
                isReverse: false
            )
        } + report.bars.compactMap { bar -> TrustLevelWidgetItem? in
            guard let nums = parseBarCurrentAndTarget(bar.currentText) else { return nil }
            return TrustLevelWidgetItem(
                label: bar.label,
                current: nums.current,
                target: nums.target,
                isMet: bar.isMet,
                isReverse: false
            )
        }
        let snapshot = TrustLevelWidgetSnapshot(
            title: report.title.isEmpty
                ? String(localized: "trust.widget.title", defaultValue: "信任等级")
                : report.title,
            badgeText: report.badgeText,
            subtitle: report.subtitle,
            items: items,
            updatedAt: Date(),
            trustLevel: trustLevel
        )
        TrustLevelWidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: TrustLevelWidgetIDs.widgetKind)
    }

    static func persist(fallback items: [TrustFallbackRequirement], trustLevel: Int?, note: String) {
        let snapshot = TrustLevelWidgetSnapshot(
            title: String(localized: "trust.widget.title", defaultValue: "信任等级"),
            badgeText: trustLevel.map { "TL\($0)" } ?? "",
            subtitle: note,
            items: items.map {
                TrustLevelWidgetItem(
                    label: $0.label,
                    current: $0.current ?? 0,
                    target: max($0.target, 0),
                    isMet: $0.isMet,
                    isReverse: $0.isReverse
                )
            },
            updatedAt: Date(),
            trustLevel: trustLevel
        )
        TrustLevelWidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: TrustLevelWidgetIDs.widgetKind)
    }

    static func refreshIfPossible(
        executionContext: DiscourseAPIExecutionContext = .foreground
    ) async {
        let forum = DatabaseManager.shared.defaultForum()
        let api = DiscourseAPI(baseURL: forum.baseURL, executionContext: executionContext)
        let username = AuthManager.shared.username(for: forum.baseURL) ?? forum.username
        let cached = username.flatMap {
            MeProfileCacheStore.cachedProfile(baseURL: forum.baseURL, username: $0)
        }
        let trustLevel = cached?.userProfile.trustLevel
        if isLinuxDoForum(forum.baseURL),
           let html = await fetchConnectHTML(),
           let report = try? ConnectTrustParser.parse(html: html),
           !report.isEmptyState {
            persist(report: report, trustLevel: trustLevel)
            return
        }
        guard let username else { return }
        guard let summary = try? await api.fetchUserSummary(username: username) else { return }
        let items = TrustFallbackCatalog.requirements(level: trustLevel ?? 2, summary: summary)
        persist(
            fallback: items,
            trustLevel: trustLevel,
            note: String(localized: "trust.widget.summary", defaultValue: "距离下一级的进度")
        )
    }

    /// Connect bar copy is often `"5,000 / 20,000"`; strip grouping marks before taking the pair.
    static func parseBarCurrentAndTarget(_ currentText: String) -> (current: Int, target: Int)? {
        let normalized = currentText
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
        let nums = normalized.split { !$0.isNumber }.compactMap { Int($0) }
        guard nums.count >= 2 else { return nil }
        return (nums[0], max(nums[1], 1))
    }

    private static func isLinuxDoForum(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "linux.do" || host.hasSuffix(".linux.do")
    }

    private static func fetchConnectHTML() async -> String? {
        guard let url = URL(string: "https://connect.linux.do/") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let cookieHeader = WebCookieStore.shared.cookieHeader(for: url)
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let userAgent = WebCookieStore.shared.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
