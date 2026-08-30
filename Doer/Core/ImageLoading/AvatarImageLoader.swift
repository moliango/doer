import SDWebImage
import UIKit

enum AvatarImageLoader {
    static let defaultPlaceholder = UIImage(systemName: "person.crop.circle.fill")
    /// Shared pixel size for home / history / bookmarks so URL keys hit the same cache entries.
    static let primaryAvatarPixelSize = 120

    /// Process-wide entry cap for shared avatar reuse across tabs.
    private static let maxInProcessEntryCount = 100_000

    /// Resolved from `AppSettings.avatarCacheSizeLimit` (500MB … 2GB).
    private static var maxInProcessMemoryBytes: Int {
        AppSettings.shared.avatarCacheSizeLimit.byteCount
    }

    private static var maxDiskCacheBytes: Int {
        AppSettings.shared.avatarCacheSizeLimit.byteCount
    }

    /// 内存缓存：快速二级缓存，避免反复解码同一头像。
    /// 设置大小限制防止内存爆炸。
    private static let inMemoryCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 100  // 最多缓存 100 个头像
        cache.totalCostLimit = 50 * 1024 * 1024  // 50MB
        return cache
    }()
    private static let userAvatarCacheLock = NSLock()
    private static var userAvatarCache: [String: UserAvatarCacheEntry] = [:]
    private static var userAvatarCacheStatsByBaseURL: [String: UserAvatarCacheStats] = [:]
    private static let prefetchLock = NSLock()
    private static var prefetchedURLStrings = Set<String>()
    private static let userAvatarStatsLogEveryLookupCount = 20

    struct UserAvatarCacheEntry {
        let image: UIImage
        let url: URL
    }

    private struct UserAvatarCacheStats {
        var lookups = 0
        var hits = 0
        var misses = 0
        var stores = 0
    }

    /// Serial IO queue for SD disk probes. Never read the disk cache on the main thread.
    private static let diskIOQueue = DispatchQueue(
        label: "com.naine.doer.image-disk-cache",
        qos: .userInitiated
    )

    /// Shared SD load options for avatars / list chrome.
    /// No `.retryFailed` here: a CF challenge HTML response must not be hammered by every
    /// avatar cell. Topic body images use `contentOptions` / user tap uses `forceRetryOptions`.
    /// Memory hits stay sync so scrolling does not flash a placeholder; disk stays async.
    /// `.delayPlaceholder` keeps the current bitmap (or empty theme fill) until the
    /// decode finishes — never stamp a gray glyph for one frame.
    static let options: SDWebImageOptions = [
        .continueInBackground,
        .scaleDownLargeImages,
        .highPriority,
        .queryMemoryDataSync,
        .delayPlaceholder,
    ]

    /// Topic cooked images (visible content). Allow one automatic retry after a transient
    /// failure so a single CF blip / timeout does not leave a permanent blank tile for the
    /// rest of the process (killing the app was the only previous recovery).
    static let contentOptions: SDWebImageOptions = [
        .retryFailed,
        .continueInBackground,
        .scaleDownLargeImages,
        .highPriority,
        .queryMemoryDataSync,
        .delayPlaceholder,
    ]

    /// Explicit user tap-to-retry: clear failed-URL blacklist + skip stale cache entry.
    static let forceRetryOptions: SDWebImageOptions = [
        .retryFailed,
        .refreshCached,
        .continueInBackground,
        .scaleDownLargeImages,
        .highPriority,
        .delayPlaceholder,
    ]

    /// Prefetch options: cache-first, lower priority so visible cells win the downloader slots.
    static let prefetchOptions: SDWebImageOptions = [
        .continueInBackground,
        .scaleDownLargeImages,
        .lowPriority,
        .queryMemoryDataSync,
    ]

    /// Drop SDWebImage's process-local failed-URL entry so a later load can try again.
    static func clearFailedLoad(for url: URL) {
        SDWebImageManager.shared.removeFailedURL(url)
    }

    /// Clear failed-URL entries whose host matches this forum (after CF resume / re-login).
    static func clearFailedLoads(matchingBaseURL baseURL: String) {
        guard let host = URL(string: baseURL)?.host?.lowercased(), !host.isEmpty else { return }
        // SDWebImage only exposes remove-one / remove-all; wipe all failed URLs after
        // clearance recovery so every host can recover without tracking the full set.
        _ = host
        SDWebImageManager.shared.removeAllFailedURLs()
        DohDebugLog.record("cleared SD failed image URLs after recovery base=\(baseURL)", subsystem: "Avatar")
    }

    static func configureGlobalImageLoading() {
        // Ensure Caches is a real directory and SD disk root is pinned before shared init.
        AppStorageBootstrap.prepareAtLaunch()

        let profile = AppSettings.shared.avatarLoadingProfile
        let cacheLimit = AppSettings.shared.avatarCacheSizeLimit
        let memoryBytes = cacheLimit.byteCount
        let diskBytes = cacheLimit.byteCount
        let imageSession = SDWebImageDownloader.shared.config.sessionConfiguration
            ?? URLSessionConfiguration.default
        LightweightDohProxyService.shared.apply(to: imageSession)
        imageSession.httpMaximumConnectionsPerHost = max(6, profile.maxConcurrentDownloads)
        imageSession.waitsForConnectivity = false
        imageSession.timeoutIntervalForRequest = 15
        SDWebImageDownloader.shared.config.sessionConfiguration = imageSession
        SDWebImageDownloader.shared.config.maxConcurrentDownloads = profile.maxConcurrentDownloads
        SDWebImagePrefetcher.shared.maxConcurrentPrefetchCount = UInt(profile.maxConcurrentPrefetchCount)

        let cacheConfig = SDImageCache.shared.config
        cacheConfig.shouldCacheImagesInMemory = true
        // Keep strong memory entries so history/bookmarks reuse home-loaded avatars.
        cacheConfig.shouldUseWeakMemoryCache = false
        cacheConfig.maxMemoryCost = UInt(memoryBytes)
        cacheConfig.maxMemoryCount = UInt(maxInProcessEntryCount)
        cacheConfig.maxDiskSize = UInt(diskBytes)
        // Do not age-expire disk avatars; only user-triggered clear (or size pressure) removes them.
        cacheConfig.maxDiskAge = -1

        inMemoryCache.countLimit = maxInProcessEntryCount
        inMemoryCache.totalCostLimit = memoryBytes
        DohDebugLog.record(
            "avatar cache limit applied memory=\(cacheLimit.title) disk=\(cacheLimit.title)",
            subsystem: "Avatar"
        )
    }

    /// Clears process + SD image caches. Only call when the user opts into clearing
    /// (settings action or `clearImageCacheOnLaunch`).
    static func clearAllCaches(completion: (() -> Void)? = nil) {
        inMemoryCache.removeAllObjects()
        userAvatarCacheLock.lock()
        userAvatarCache.removeAll(keepingCapacity: true)
        userAvatarCacheStatsByBaseURL.removeAll(keepingCapacity: true)
        userAvatarCacheLock.unlock()
        prefetchLock.lock()
        prefetchedURLStrings.removeAll(keepingCapacity: true)
        prefetchLock.unlock()
        SDImageCache.shared.clearMemory()
        SDImageCache.shared.clearDisk {
            Task { @MainActor in
                completion?()
            }
        }
        DohDebugLog.record("avatar caches cleared (user-requested)", subsystem: "Avatar")
    }

    static func url(from template: String?, baseURL: String, size: Int = 96) -> URL? {
        guard let template else { return nil }
        let sized = template
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "{size}", with: "\(size)")
        guard !sized.isEmpty else { return nil }

        if sized.hasPrefix("//") {
            return URL(string: "https:\(sized)")
        }

        if let absoluteURL = URL(string: sized), absoluteURL.scheme != nil {
            return absoluteURL
        }

        let normalizedBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        guard let base = URL(string: normalizedBase) else { return URL(string: sized) }
        return URL(string: sized, relativeTo: base)?.absoluteURL
    }

    static func setImage(
        on imageView: UIImageView,
        template: String?,
        baseURL: String,
        userId: Int? = nil,
        size: Int = 96,
        placeholder: UIImage? = defaultPlaceholder
    ) {
        let url = url(from: template, baseURL: baseURL, size: size)
        setImage(
            on: imageView,
            url: url,
            placeholder: placeholder,
            cloudflareBaseURL: baseURL,
            avatarBaseURL: baseURL,
            userId: userId
        )
    }

    static func setImage(
        on imageView: UIImageView,
        url: URL?,
        placeholder: UIImage? = defaultPlaceholder,
        cloudflareBaseURL: String? = nil,
        avatarBaseURL: String? = nil,
        userId: Int? = nil
    ) {
        imageView.tintColor = .tertiaryLabel
        guard let url else {
            imageView.sd_cancelCurrentImageLoad()
            ImagePaintPolicy.prepareForLoad(on: imageView)
            if let cached = cachedUserAvatar(baseURL: avatarBaseURL ?? cloudflareBaseURL, userId: userId) {
                imageView.image = cached.image
            } else {
                imageView.image = placeholder
            }
            return
        }

        let cacheKey = url as NSURL
        if let cachedImage = cachedImage(for: url) {
            imageView.sd_cancelCurrentImageLoad()
            ImagePaintPolicy.paint(cachedImage, on: imageView, source: .memory)
            storeUserAvatarIfPossible(
                cachedImage,
                url: url,
                baseURL: avatarBaseURL ?? cloudflareBaseURL,
                userId: userId
            )
            return
        }

        ImagePaintPolicy.prepareForLoad(on: imageView)

        let cachedUserAvatar = cachedUserAvatar(baseURL: avatarBaseURL ?? cloudflareBaseURL, userId: userId)
        if let cachedUserAvatar {
            imageView.image = cachedUserAvatar.image
        }
        ImagePaintPolicy.applyWaitingFillIfNeeded(on: imageView)

        // CF recovery in flight: memory/disk only; don't hammer main-domain images.
        // Disk query is async (no `.queryDiskDataSync`) so the main thread is not blocked.
        var loadOptions: SDWebImageOptions
        if CloudflareImageGate.shouldBlockNetworkLoad(url: url, cloudflareBaseURL: cloudflareBaseURL) {
            loadOptions = options.union(.fromCacheOnly)
        } else {
            loadOptions = options
        }
        loadOptions.insert(.avoidAutoSetImage)

        imageView.sd_setImage(
            with: url,
            placeholderImage: ImagePaintPolicy.placeholderForAsyncLoad(
                currentImage: imageView.image,
                memoryHit: false
            ),
            options: loadOptions,
            context: context(for: url, cloudflareBaseURL: cloudflareBaseURL),
            progress: nil,
            completed: { image, _, cacheType, _ in
                if let image {
                    ImagePaintPolicy.paint(image, on: imageView, source: ImagePaintCacheSource(cacheType))
                    inMemoryCache.setObject(image, forKey: cacheKey, cost: image.avatarCacheCost)
                    storeUserAvatarIfPossible(
                        image,
                        url: url,
                        baseURL: avatarBaseURL ?? cloudflareBaseURL,
                        userId: userId
                    )
                } else if imageView.image == nil {
                    imageView.image = placeholder
                    imageView.tintColor = .tertiaryLabel
                }
            }
        )
    }

    static func prefetch(urls: [URL], cloudflareBaseURL: String? = nil, maxUncached: Int? = nil) {
        guard !urls.isEmpty else { return }
        diskIOQueue.async {
            var seen = Set<String>()
            var uncached: [URL] = []
            for url in urls {
                let key = url.absoluteString
                guard seen.insert(key).inserted else { continue }
                if isImageCached(for: url) { continue }
                uncached.append(url)
                if let maxUncached, uncached.count >= maxUncached { break }
            }
            guard !uncached.isEmpty else { return }
            Task { @MainActor in
                startNetworkPrefetch(urls: uncached, cloudflareBaseURL: cloudflareBaseURL)
            }
        }
    }

    /// 1) Already in memory/disk → skipped before this runs (zero network, zero CF risk).
    /// 2) CF gate / missing clearance on main host → cache-only.
    /// 3) Cap main-domain prefetch so avatar storms don't trip the shield.
    private static func startNetworkPrefetch(urls: [URL], cloudflareBaseURL: String?) {
        let networkURLs = urls.filter {
            !CloudflareImageGate.shouldBlockNetworkLoad(url: $0, cloudflareBaseURL: cloudflareBaseURL)
                && !CloudflareImageGate.shouldSkipPrefetchWithoutClearance(
                    url: $0,
                    cloudflareBaseURL: cloudflareBaseURL
                )
        }
        let uniqueURLs = uniqueUnprefetchedURLs(networkURLs)
        guard !uniqueURLs.isEmpty else { return }

        let mainDomain = uniqueURLs.filter {
            CloudflareImageGate.isMainDomain($0, cloudflareBaseURL: cloudflareBaseURL)
                || isForumCDN($0)
        }
        let external = uniqueURLs.filter { url in
            !CloudflareImageGate.isMainDomain(url, cloudflareBaseURL: cloudflareBaseURL) && !isForumCDN(url)
        }

        // Main host + forum CDN share CF risk — keep prefetch burst small.
        let mainCap = max(AppSettings.shared.avatarLoadingProfile.maxConcurrentPrefetchCount * 3, 4)
        let externalCap = 12
        let cappedMain = Array(mainDomain.prefix(mainCap))
        let cappedExternal = Array(external.prefix(externalCap))
        let batch = cappedMain + cappedExternal

        let grouped = Dictionary(grouping: batch) {
            requestHeaderSignature(for: $0, cloudflareBaseURL: cloudflareBaseURL)
        }
        for urls in grouped.values {
            let requestContext: [SDWebImageContextOption: Any]?
            if let firstURL = urls.first {
                requestContext = context(
                    for: firstURL,
                    cloudflareBaseURL: cloudflareBaseURL
                )
            } else {
                requestContext = nil
            }

            SDWebImagePrefetcher.shared.prefetchURLs(
                urls,
                options: prefetchOptions,
                context: requestContext,
                progress: nil,
                completed: nil
            )
        }
    }

    /// True when process memory or SD disk already has this URL (no network needed).
    /// Disk probe is IO — only call from `diskIOQueue`.
    private static func isImageCached(for url: URL) -> Bool {
        if cachedImage(for: url) != nil {
            return true
        }
        assert(
            !Thread.isMainThread,
            "SD disk cache probe must not run on the main thread"
        )
        return SDImageCache.shared.diskImageDataExists(withKey: url.absoluteString)
    }

    /// Write a successful network decode into the process cache so later cells
    /// and CF-gated loads paint without another disk hit.
    static func storeProcessCache(_ image: UIImage, for url: URL) {
        inMemoryCache.setObject(image, forKey: url as NSURL, cost: image.avatarCacheCost)
    }

    /// linux.do upload CDN — treat like main host for prefetch caps / cookie path.
    static func isForumCDN(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.contains("ldstatic.com") || host.contains("linuxdo-uploads")
    }

    static func credentialsDidChange(for baseURL: String, retrying retryURLs: [URL] = []) {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return }
        let retryURLStrings = Set(retryURLs.map(\.absoluteString))
        prefetchLock.lock()
        prefetchedURLStrings = prefetchedURLStrings.filter { value in
            if retryURLStrings.contains(value) { return false }
            guard let urlHost = URL(string: value)?.host?.lowercased() else { return true }
            return urlHost != host && !urlHost.hasSuffix(".\(host)")
        }
        prefetchLock.unlock()
        // New cookies / CF clearance: drop SD failed-URL blacklist so content can recover
        // without force-quitting the app.
        clearFailedLoads(matchingBaseURL: baseURL)
        CloudflareImageGate.resume(baseURL: baseURL)
    }

    private static func uniqueUnprefetchedURLs(_ urls: [URL]) -> [URL] {
        let uniqueStrings = Array(Set(urls.map(\.absoluteString))).sorted()
        prefetchLock.lock()
        defer { prefetchLock.unlock() }

        if prefetchedURLStrings.count > 1_500 {
            prefetchedURLStrings.removeAll(keepingCapacity: true)
        }

        var result: [URL] = []
        for urlString in uniqueStrings where !prefetchedURLStrings.contains(urlString) {
            prefetchedURLStrings.insert(urlString)
            if let url = URL(string: urlString) {
                result.append(url)
            }
        }
        return result
    }

    static func context(
        for url: URL,
        cloudflareBaseURL: String? = nil
    ) -> [SDWebImageContextOption: Any]? {
        var context: [SDWebImageContextOption: Any] = [:]
        let headers = requestHeaders(for: url, cloudflareBaseURL: cloudflareBaseURL)
        if !headers.isEmpty {
            context[SDWebImageContextOption.downloadRequestModifier] = SDWebImageDownloaderRequestModifier(
                headers: headers
            )
        }

        let responseModifier = SDWebImageDownloaderResponseModifier(block: { response in
            guard let httpResponse = response as? HTTPURLResponse,
                  let detection = DiscourseAPI.cloudflareChallengeDetection(httpResponse, data: nil)
            else { return response }

            let detectedBaseURL = cloudflareBaseURL
                ?? httpResponse.url.flatMap(Self.originString(for:))
                ?? Self.originString(for: url)
            if let detectedBaseURL {
                Task { @MainActor in
                    // Coalesce + pause: one shield per cooldown, not one per avatar.
                    CloudflareImageGate.reportImageChallenge(
                        baseURL: detectedBaseURL,
                        responseURL: httpResponse.url,
                        source: "image.avatar",
                        detection: detection
                    )
                }
            }
            return response
        })
        context[SDWebImageContextOption.downloadResponseModifier] = responseModifier
        return context
    }

    /// Process + SD memory only. Safe on the main thread; does not touch disk.
    static func cachedImageIfAvailable(for url: URL) -> UIImage? {
        cachedImage(for: url)
    }

    /// Decode from cache without network (nil if miss). Memory only — safe on main.
    static func imageFromLocalCache(for url: URL) -> UIImage? {
        cachedImage(for: url)
    }

    /// Memory then SD disk. May decode from disk — call only from a background queue.
    static func imageFromDiskCacheIfAvailable(for url: URL) -> UIImage? {
        if let memory = cachedImage(for: url) {
            return memory
        }
        assert(
            !Thread.isMainThread,
            "SD disk cache decode must not run on the main thread"
        )
        let key = url.absoluteString
        guard let disk = SDImageCache.shared.imageFromCache(forKey: key) else {
            return nil
        }
        inMemoryCache.setObject(disk, forKey: url as NSURL, cost: disk.avatarCacheCost)
        return disk
    }

    static func cachedUserAvatar(baseURL: String?, userId: Int?) -> UserAvatarCacheEntry? {
        guard let cacheKey = userAvatarCacheKey(baseURL: baseURL, userId: userId),
              let statsKey = normalizedUserAvatarStatsKey(baseURL: baseURL)
        else { return nil }
        userAvatarCacheLock.lock()
        let entry = userAvatarCache[cacheKey]
        recordUserAvatarCacheLookupLocked(baseURL: statsKey, hit: entry != nil)
        userAvatarCacheLock.unlock()
        return entry
    }

    private static func cachedImage(for url: URL) -> UIImage? {
        let cacheKey = url as NSURL
        if let memory = inMemoryCache.object(forKey: cacheKey) {
            return memory
        }
        // SD memory only — `imageFromCache` would synchronously decode from disk.
        if let sdMemory = SDImageCache.shared.imageFromMemoryCache(forKey: url.absoluteString) {
            inMemoryCache.setObject(sdMemory, forKey: cacheKey, cost: sdMemory.avatarCacheCost)
            return sdMemory
        }
        return nil
    }

    private static func storeUserAvatarIfPossible(
        _ image: UIImage,
        url: URL,
        baseURL: String?,
        userId: Int?
    ) {
        guard let key = userAvatarCacheKey(baseURL: baseURL, userId: userId),
              let statsKey = normalizedUserAvatarStatsKey(baseURL: baseURL)
        else { return }
        userAvatarCacheLock.lock()
        userAvatarCache[key] = UserAvatarCacheEntry(image: image, url: url)
        recordUserAvatarCacheStoreLocked(baseURL: statsKey)
        // Soft trim: drop ~10% oldest-iteration keys when over cap (keeps recent hot set).
        if userAvatarCache.count > maxInProcessEntryCount {
            let overflow = userAvatarCache.count - maxInProcessEntryCount
            let trimCount = max(overflow, maxInProcessEntryCount / 10)
            let keysToDrop = Array(userAvatarCache.keys.prefix(trimCount))
            for dropKey in keysToDrop where dropKey != key {
                userAvatarCache.removeValue(forKey: dropKey)
            }
        }
        userAvatarCacheLock.unlock()
    }

    private static func userAvatarCacheKey(baseURL: String?, userId: Int?) -> String? {
        guard let baseURL, let userId, userId > 0 else { return nil }
        let normalizedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard !normalizedBaseURL.isEmpty else { return nil }
        return "\(normalizedBaseURL)#\(userId)"
    }

    private static func normalizedUserAvatarStatsKey(baseURL: String?) -> String? {
        guard let baseURL else { return nil }
        let normalizedBaseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return normalizedBaseURL.isEmpty ? nil : normalizedBaseURL
    }

    private static func recordUserAvatarCacheLookupLocked(baseURL: String, hit: Bool) {
        var stats = userAvatarCacheStatsByBaseURL[baseURL] ?? UserAvatarCacheStats()
        stats.lookups += 1
        if hit {
            stats.hits += 1
        } else {
            stats.misses += 1
        }
        userAvatarCacheStatsByBaseURL[baseURL] = stats
        logUserAvatarCacheStatsIfNeeded(baseURL: baseURL, stats: stats)
    }

    private static func recordUserAvatarCacheStoreLocked(baseURL: String) {
        var stats = userAvatarCacheStatsByBaseURL[baseURL] ?? UserAvatarCacheStats()
        stats.stores += 1
        userAvatarCacheStatsByBaseURL[baseURL] = stats
    }

    private static func logUserAvatarCacheStatsIfNeeded(baseURL: String, stats: UserAvatarCacheStats) {
        guard stats.lookups > 0,
              stats.lookups % userAvatarStatsLogEveryLookupCount == 0
        else { return }
        let hitRate = Int((Double(stats.hits) / Double(stats.lookups) * 100).rounded())
        DohDebugLog.record(
            "avatar user cache stats base=\(baseURL) lookups=\(stats.lookups) hits=\(stats.hits) misses=\(stats.misses) hitRate=\(hitRate)% stores=\(stats.stores)",
            subsystem: "Avatar"
        )
    }

    static func storeUserAvatarForTesting(
        _ image: UIImage,
        url: URL,
        baseURL: String?,
        userId: Int?
    ) {
        storeUserAvatarIfPossible(image, url: url, baseURL: baseURL, userId: userId)
    }

    static func cachedUserAvatarForTesting(baseURL: String?, userId: Int?) -> UserAvatarCacheEntry? {
        cachedUserAvatar(baseURL: baseURL, userId: userId)
    }

    static func clearUserAvatarCacheForTesting() {
        userAvatarCacheLock.lock()
        userAvatarCache.removeAll(keepingCapacity: true)
        userAvatarCacheStatsByBaseURL.removeAll(keepingCapacity: true)
        userAvatarCacheLock.unlock()
    }

    static func usesSynchronousDiskCacheQueryForTesting() -> Bool {
        options.contains(.queryDiskDataSync)
            || contentOptions.contains(.queryDiskDataSync)
            || prefetchOptions.contains(.queryDiskDataSync)
            || forceRetryOptions.contains(.queryDiskDataSync)
    }

    static func usesSynchronousMemoryCacheQueryForTesting() -> Bool {
        options.contains(.queryMemoryDataSync)
            && contentOptions.contains(.queryMemoryDataSync)
            && prefetchOptions.contains(.queryMemoryDataSync)
    }

    static func delaysPlaceholderUntilLoadFinishesForTesting() -> Bool {
        options.contains(.delayPlaceholder)
            && contentOptions.contains(.delayPlaceholder)
            && forceRetryOptions.contains(.delayPlaceholder)
    }

    nonisolated private static func originString(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    private static func requestHeaderSignature(for url: URL, cloudflareBaseURL: String? = nil) -> String {
        let headers = requestHeaders(for: url, cloudflareBaseURL: cloudflareBaseURL)
        return headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
    }

    private static func requestHeaders(
        for url: URL,
        cloudflareBaseURL: String? = nil
    ) -> [String: String] {
        // Align with FluxDo DioHttpClient image headers:
        // Accept */* + Accept-Language; main domain may need cookies;
        // third-party hosts must not send cookies (and often need forum Referer).
        var headers: [String: String] = [
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        ]

        let userAgent = WebCookieStore.shared.userAgent
        if let userAgent, !userAgent.isEmpty {
            headers["User-Agent"] = userAgent
        } else {
            headers["User-Agent"] =
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }

        // Main host + forum upload CDN both need the forum session/CF cookies.
        // Cookie jar is keyed by forum origin — never by ldstatic.com itself.
        if needsForumCookies(url, baseURL: cloudflareBaseURL) {
            let cookieURL = forumCookieURL(for: url, baseURL: cloudflareBaseURL) ?? url
            let cookieHeader = WebCookieStore.shared.cookieHeader(for: cookieURL)
            if !cookieHeader.isEmpty {
                headers["Cookie"] = cookieHeader
            }
        }

        if let referer = refererHeader(for: url, baseURL: cloudflareBaseURL) {
            headers["Referer"] = referer
        }

        return headers
    }

    /// Main forum host (and subdomains) need session cookies for secure-uploads.
    /// External image hosts must stay cookieless — same split as FluxDo.
    private static func isMainDomain(_ url: URL, baseURL: String?) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if let baseURL,
           let baseHost = URL(string: baseURL)?.host?.lowercased(),
           !baseHost.isEmpty {
            if host == baseHost || host.hasSuffix("." + baseHost) {
                return true
            }
        }
        // Fallback for linux.do family when baseURL is temporarily unavailable.
        if host == "linux.do" || host.hasSuffix(".linux.do") {
            return true
        }
        return false
    }

    /// Forum origin or upload CDN — both share CF clearance from the forum jar.
    static func needsForumCookies(_ url: URL, baseURL: String?) -> Bool {
        isMainDomain(url, baseURL: baseURL) || isForumCDN(url)
    }

    /// Prefer the forum base URL when asking the cookie store (CDN host has no jar entries).
    static func forumCookieURL(for url: URL, baseURL: String?) -> URL? {
        if let baseURL, let base = URL(string: baseURL), base.host != nil {
            return base
        }
        if isMainDomain(url, baseURL: nil) {
            return url
        }
        // CDN without explicit base — fall back to linux.do origin.
        if isForumCDN(url) {
            return URL(string: "https://linux.do")
        }
        return url
    }

    private static func refererHeader(for url: URL, baseURL: String?) -> String? {
        // Main host: browser-like same-origin requests omit Referer.
        // CDN + external beds: send forum origin (required by many upload CDNs / image beds).
        if isMainDomain(url, baseURL: baseURL) { return nil }
        guard let baseURL, let base = URL(string: baseURL), base.scheme != nil, base.host != nil else {
            return "https://linux.do/"
        }
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        components.path = "/"
        return components.string
    }
}

enum ForumImageLoader {
    @discardableResult
    static func loadImage(
        with url: URL,
        cloudflareBaseURL: String? = nil,
        forceRetry: Bool = false,
        completed: @escaping (UIImage?) -> Void
    ) -> SDWebImageOperation? {
        if !forceRetry, let cached = AvatarImageLoader.cachedImageIfAvailable(for: url) {
            completed(cached)
            return nil
        }
        if forceRetry {
            AvatarImageLoader.clearFailedLoad(for: url)
        }
        // User tap may proceed even while CF gate is paused — explicit intent.
        // Otherwise serve memory/disk asynchronously and skip the network.
        var options = forceRetry ? AvatarImageLoader.forceRetryOptions : AvatarImageLoader.contentOptions
        if !forceRetry,
           CloudflareImageGate.shouldBlockNetworkLoad(url: url, cloudflareBaseURL: cloudflareBaseURL) {
            options.insert(.fromCacheOnly)
        }
        return SDWebImageManager.shared.loadImage(
            with: url,
            options: options,
            context: AvatarImageLoader.context(for: url, cloudflareBaseURL: cloudflareBaseURL),
            progress: nil
        ) { image, _, _, _, _, finishedURL in
            if let image, let finishedURL {
                AvatarImageLoader.storeProcessCache(image, for: finishedURL)
            } else if let image {
                AvatarImageLoader.storeProcessCache(image, for: url)
            }
            completed(image)
        }
    }

    static func setImage(
        on imageView: UIImageView,
        url: URL?,
        placeholder: UIImage? = nil,
        cloudflareBaseURL: String? = nil,
        forceRetry: Bool = false,
        completed: SDExternalCompletionBlock? = nil
    ) {
        guard let url else {
            imageView.sd_cancelCurrentImageLoad()
            ImagePaintPolicy.prepareForLoad(on: imageView)
            imageView.image = placeholder
            return
        }

        if !forceRetry, let cached = AvatarImageLoader.cachedImageIfAvailable(for: url) {
            imageView.sd_cancelCurrentImageLoad()
            ImagePaintPolicy.paint(cached, on: imageView, source: .memory)
            completed?(cached, nil, .memory, url)
            return
        }

        ImagePaintPolicy.prepareForLoad(on: imageView)

        if forceRetry {
            imageView.sd_cancelCurrentImageLoad()
            AvatarImageLoader.clearFailedLoad(for: url)
        }

        ImagePaintPolicy.applyWaitingFillIfNeeded(on: imageView)

        var options = forceRetry ? AvatarImageLoader.forceRetryOptions : AvatarImageLoader.contentOptions
        if !forceRetry,
           CloudflareImageGate.shouldBlockNetworkLoad(url: url, cloudflareBaseURL: cloudflareBaseURL) {
            // Disk may still have the image; query it off the main thread via SD.
            options.insert(.fromCacheOnly)
        }
        options.insert(.avoidAutoSetImage)

        imageView.sd_setImage(
            with: url,
            placeholderImage: ImagePaintPolicy.placeholderForAsyncLoad(
                currentImage: imageView.image,
                memoryHit: false
            ),
            options: options,
            context: AvatarImageLoader.context(for: url, cloudflareBaseURL: cloudflareBaseURL),
            progress: nil,
            completed: { image, error, cacheType, imageURL in
                if let image {
                    ImagePaintPolicy.paint(image, on: imageView, source: ImagePaintCacheSource(cacheType))
                    if let imageURL {
                        AvatarImageLoader.storeProcessCache(image, for: imageURL)
                    }
                } else if imageView.image == nil {
                    imageView.image = placeholder
                }
                completed?(image, error, cacheType, imageURL)
            }
        )
    }

    static func prefetch(urls: [URL], cloudflareBaseURL: String? = nil, maxUncached: Int? = nil) {
        AvatarImageLoader.prefetch(
            urls: urls,
            cloudflareBaseURL: cloudflareBaseURL,
            maxUncached: maxUncached
        )
    }
}

private extension UIImage {
    var avatarCacheCost: Int {
        guard let cgImage else { return 1 }
        return max(cgImage.bytesPerRow * cgImage.height, 1)
    }
}


/// Coalesces image-pipeline Cloudflare challenges and pauses main-domain image
/// network loads while clearance is being recovered.
///
/// Why: a single expired `cf_clearance` turns a home-feed avatar storm into N
/// challenge notifications and keeps the shield flashing. Cache still serves
/// hits; only uncached main-host downloads are gated.
enum CloudflareImageGate {
    private static let lock = NSLock()
    private static var pausedUntilByBase: [String: Date] = [:]
    private static var lastPostedAtByBase: [String: Date] = [:]

    /// Don't re-post challenge from images more often than this.
    private static let imagePostCooldown: TimeInterval = 20
    /// Safety auto-resume if verification-completed never arrives.
    private static let defaultPauseDuration: TimeInterval = 60

    static func normalizedKey(_ baseURL: String) -> String {
        CloudflareVerificationPolicy.normalizedBaseKey(baseURL)
    }

    /// Pause main-domain image downloads for this forum base.
    static func pause(baseURL: String, duration: TimeInterval = defaultPauseDuration) {
        let key = normalizedKey(baseURL)
        let until = Date().addingTimeInterval(duration)
        lock.lock()
        if let existing = pausedUntilByBase[key] {
            pausedUntilByBase[key] = max(existing, until)
        } else {
            pausedUntilByBase[key] = until
        }
        lock.unlock()
        DohDebugLog.record("image gate pause base=\(key) duration=\(Int(duration))s", subsystem: "CF")
    }

    static func pause(baseURL: URL, duration: TimeInterval = defaultPauseDuration) {
        pause(baseURL: baseURL.absoluteString, duration: duration)
    }

    /// Posted on the main queue when a forum base leaves the image-download pause.
    /// Topic image cells observe this to auto-retry blank / failed tiles.
    static let didResumeNotification = Notification.Name("CloudflareImageGate.didResume")
    static let resumedBaseURLKey = "baseURL"

    /// Clear pause so uncached avatars/uploads can hit the network again.
    static func resume(baseURL: String) {
        let key = normalizedKey(baseURL)
        lock.lock()
        let hadPause = pausedUntilByBase[key] != nil
        pausedUntilByBase[key] = nil
        lock.unlock()
        if hadPause {
            DohDebugLog.record("image gate resume base=\(key)", subsystem: "CF")
            // Failed URL blacklist often holds CF-challenge misses from the pause window.
            AvatarImageLoader.clearFailedLoads(matchingBaseURL: baseURL)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: didResumeNotification,
                    object: nil,
                    userInfo: [resumedBaseURLKey: baseURL]
                )
            }
        }
    }

    static func resume(baseURL: URL) {
        resume(baseURL: baseURL.absoluteString)
    }

    static func isPaused(baseURL: String, now: Date = Date()) -> Bool {
        let key = normalizedKey(baseURL)
        lock.lock()
        let expiredBase: String?
        if let until = pausedUntilByBase[key] {
            if now < until {
                lock.unlock()
                return true
            }
            pausedUntilByBase[key] = nil
            expiredBase = key
        } else {
            expiredBase = nil
        }
        lock.unlock()
        // Auto-expiry must mirror explicit resume: clear failed URLs + wake blank tiles.
        if let expiredBase {
            DohDebugLog.record("image gate auto-expired base=\(expiredBase)", subsystem: "CF")
            AvatarImageLoader.clearFailedLoads(matchingBaseURL: baseURL)
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: didResumeNotification,
                    object: nil,
                    userInfo: [resumedBaseURLKey: baseURL]
                )
            }
        }
        return false
    }

    static func isPaused(baseURL: URL, now: Date = Date()) -> Bool {
        isPaused(baseURL: baseURL.absoluteString, now: now)
    }

    /// True when network load would be wasteful or likely to trip CF.
    /// - Main host while gate paused
    /// - Forum CDN while matching forum gate paused
    static func shouldBlockNetworkLoad(url: URL, cloudflareBaseURL: String?, now: Date = Date()) -> Bool {
        let main = isMainDomain(url, cloudflareBaseURL: cloudflareBaseURL)
        let cdn = AvatarImageLoader.isForumCDN(url)
        guard main || cdn else { return false }

        if let cloudflareBaseURL, isPaused(baseURL: cloudflareBaseURL, now: now) {
            return true
        }
        if let origin = originString(for: url), isPaused(baseURL: origin, now: now) {
            return true
        }
        if let host = url.host?.lowercased(), !host.isEmpty {
            if isPaused(baseURL: "https://\(host)", now: now) { return true }
            if isPaused(baseURL: "http://\(host)", now: now) { return true }
            // CDN pause often keys off forum base — also check linux.do family.
            if cdn, host.contains("ldstatic") || host.contains("linuxdo") {
                if isPaused(baseURL: "https://linux.do", now: now) { return true }
            }
        }
        return false
    }

    /// Prefetch-only: skip speculative main-host downloads when we have no CF/session
    /// cookie yet. Visible cells still load (user needs the image); background warm-up waits.
    static func shouldSkipPrefetchWithoutClearance(url: URL, cloudflareBaseURL: String?) -> Bool {
        let main = isMainDomain(url, cloudflareBaseURL: cloudflareBaseURL)
        let cdn = AvatarImageLoader.isForumCDN(url)
        guard main || cdn else { return false }
        let probe: URL = {
            if let cloudflareBaseURL, let base = URL(string: cloudflareBaseURL) { return base }
            return originString(for: url).flatMap(URL.init(string:)) ?? url
        }()
        if WebCookieStore.shared.hasCookie(named: "cf_clearance", for: probe) {
            return false
        }
        if WebCookieStore.shared.hasDiscourseWebSessionCookie(for: probe) {
            return false
        }
        let host = (probe.host ?? url.host)?.lowercased() ?? ""
        return host == "linux.do" || host.hasSuffix(".linux.do")
    }

    /// Image response hit a CF challenge: pause downloads and notify recovery at most once per cooldown.
    ///
    /// Avatar/content storms are coalesced by `imagePostCooldown` so we still only arm one
    /// recovery cycle (shield + background verify → user sheet if needed), not one per tile.
    /// `shouldNotify: true` is required — silent pause alone left images blank with no UI.
    static func reportImageChallenge(
        baseURL: String,
        responseURL: URL?,
        source: String = "image",
        detection: CloudflareChallengeDetection? = nil
    ) {
        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: baseURL) {
            DohDebugLog.record(
                "image CF challenge ignored during grace source=\(source) base=\(baseURL) \(detection?.logSummary ?? "response=\(responseURL?.absoluteString ?? "none")")",
                subsystem: "CF"
            )
            return
        }

        pause(baseURL: baseURL)

        let key = normalizedKey(baseURL)
        let now = Date()
        lock.lock()
        let shouldPost: Bool
        if let last = lastPostedAtByBase[key], now.timeIntervalSince(last) < imagePostCooldown {
            shouldPost = false
        } else {
            lastPostedAtByBase[key] = now
            shouldPost = true
        }
        lock.unlock()

        guard shouldPost else {
            DohDebugLog.record(
                "image CF challenge coalesced source=\(source) base=\(key) \(detection?.logSummary ?? "response=\(responseURL?.absoluteString ?? "none")")",
                subsystem: "CF"
            )
            return
        }

        DiscourseAPI.handleCloudflareChallengeDetected(
            baseURL: baseURL,
            responseURL: responseURL,
            source: source,
            routePath: nil,
            method: nil,
            detection: detection,
            shouldNotify: true
        )
    }

    // MARK: - Host helpers (same split as AvatarImageLoader / FluxDo)

    static func isMainDomain(_ url: URL, cloudflareBaseURL: String?) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if let cloudflareBaseURL,
           let baseHost = URL(string: cloudflareBaseURL)?.host?.lowercased(),
           !baseHost.isEmpty {
            if host == baseHost || host.hasSuffix("." + baseHost) {
                return true
            }
        }
        if host == "linux.do" || host.hasSuffix(".linux.do") {
            return true
        }
        return false
    }

    static func originString(for url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Test hook: wipe gate state between unit tests.
    static func resetForTests() {
        lock.lock()
        pausedUntilByBase.removeAll()
        lastPostedAtByBase.removeAll()
        lock.unlock()
    }
}
