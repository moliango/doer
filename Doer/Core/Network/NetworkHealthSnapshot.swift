import Foundation

struct NetworkHealthSnapshot: Equatable {
    let engineTitle: String
    let engineDetail: String
    let shieldTitle: String
    let shieldDetail: String
    let csrfTitle: String
    let csrfDetail: String
    let concurrencyTitle: String
    let concurrencyDetail: String

    static func capture(
        settings: AppSettings = .shared,
        api: DiscourseAPI? = nil,
        now: Date = Date()
    ) -> NetworkHealthSnapshot {
        let doh = LightweightDohProxyService.shared
        let engineTitle: String
        let engineDetail: String
        if settings.dohEnabled {
            engineTitle = String(localized: "network.health.engine.doh", defaultValue: "DoH 引擎")
            engineDetail = doh.statusDescription + " · " + settings.dohProvider.title
        } else {
            engineTitle = String(localized: "network.health.engine.system", defaultValue: "系统 DNS")
            engineDetail = String(
                localized: "network.health.engine.system.detail",
                defaultValue: "未开启 App 内 DoH"
            )
        }

        let linuxDo = URL(string: ForumInstance.linuxDoBaseURL)
        let hasClearance = linuxDo.map { WebCookieStore.shared.hasCookie(named: "cf_clearance", for: $0) } ?? false
        let cooling = linuxDo.map {
            DiscourseAPI.isCloudflareForegroundGateActive(baseURL: $0.absoluteString, now: now)
        } ?? false
        let shieldTitle = String(localized: "network.health.shield", defaultValue: "Cloudflare 盾")
        let shieldDetail: String
        if cooling {
            shieldDetail = String(
                localized: "network.health.shield.cooling",
                defaultValue: "验证冷却中，暂不自动弹出"
            )
        } else if hasClearance {
            shieldDetail = String(localized: "settings.network.cloudflare_ready")
        } else {
            shieldDetail = String(localized: "settings.network.cloudflare_required")
        }

        let hasCSRF = api?.interceptor.hasCSRFToken == true
        let csrfTitle = String(localized: "network.health.csrf", defaultValue: "CSRF")
        let csrfDetail = hasCSRF
            ? String(localized: "network.health.csrf.present", defaultValue: "当前会话已缓存令牌")
            : String(localized: "network.health.csrf.missing", defaultValue: "尚未缓存令牌（写操作时会现取）")

        let profile = settings.avatarLoadingProfile
        let concurrencyTitle = String(localized: "network.health.concurrency", defaultValue: "并发窗口")
        let concurrencyDetail = String(
            format: String(
                localized: "network.health.concurrency.format %d %d",
                defaultValue: "下载 %d · 预取 %d（头像档位：%@）"
            ),
            profile.maxConcurrentDownloads,
            profile.maxConcurrentPrefetchCount,
            profile.title
        )

        return NetworkHealthSnapshot(
            engineTitle: engineTitle,
            engineDetail: engineDetail,
            shieldTitle: shieldTitle,
            shieldDetail: shieldDetail,
            csrfTitle: csrfTitle,
            csrfDetail: csrfDetail,
            concurrencyTitle: concurrencyTitle,
            concurrencyDetail: concurrencyDetail
        )
    }
}
