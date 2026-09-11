import SDWebImage
import UIKit

/// FluxDo-aligned image download path for topic body / external beds.
///
/// Designed to **avoid SDWebImage's process-local failed-URL blacklist**, which was the
/// root cause of "tap retry does nothing until force-quit": one CF/timeout miss permanently
/// blocked the URL for the rest of the process.
///
/// Behavior:
/// - Process + SD disk cache first (warm paint, no network)
/// - Network via URLSession with forum cookies for main host + upload CDN
/// - Explicit `forceRetry` bypasses CF gate, URLCache, and inflight coalescing
enum ExternalImageFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 35
        config.httpMaximumConnectionsPerHost = 6
        // Do NOT use a custom URLCache that can pin CF challenge HTML across retries.
        // Protocol cache is enough for 304/ETag; failures must not poison later attempts.
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024,
            diskPath: "doer.external-image-urlcache-v2"
        )
        LightweightDohProxyService.shared.apply(to: config)
        return URLSession(configuration: config)
    }()

    private static let inflightLock = NSLock()
    private static var inflight: [String: [(UIImage?) -> Void]] = [:]
    /// Wall-clock when each inflight key was created — used to reap stuck batches.
    private static var inflightStartedAt: [String: Date] = [:]

    private static let maxConcurrentNetwork = 6
    private static let networkSemaphore = DispatchSemaphore(value: maxConcurrentNetwork)
    private static let networkQueue = DispatchQueue(label: "com.naine.doer.external-image", qos: .userInitiated)

    /// If an inflight batch is older than this, drop it so later loads are not wedged forever.
    private static let inflightStaleInterval: TimeInterval = 40

    static func fetch(
        url: URL,
        refererBaseURL: String?,
        forceRetry: Bool = false,
        completion: @escaping (UIImage?) -> Void
    ) {
        let cacheKey = url.absoluteString

        if !forceRetry, let cached = AvatarImageLoader.cachedImageIfAvailable(for: url) {
            completion(cached)
            return
        }

        // CF gate is checked on the IO queue after a disk lookup so a paused
        // forum can still paint images already on disk.

        // Reap stale inflight so a hung request cannot block the same URL forever
        // (force-quit was the only previous recovery for this class of bug).
        reapStaleInflightIfNeeded()

        let coalescedKey: String
        if forceRetry {
            coalescedKey = cacheKey + "#retry-\(UUID().uuidString)"
        } else {
            coalescedKey = cacheKey
        }

        inflightLock.lock()
        if !forceRetry, inflight[cacheKey] != nil {
            inflight[cacheKey]?.append(completion)
            inflightLock.unlock()
            return
        }
        inflight[coalescedKey] = [completion]
        inflightStartedAt[coalescedKey] = Date()
        inflightLock.unlock()

        networkQueue.async {
            if !forceRetry, let cached = AvatarImageLoader.imageFromDiskCacheIfAvailable(for: url) {
                finish(cacheKey: coalescedKey, image: cached)
                return
            }
            if !forceRetry,
               CloudflareImageGate.shouldBlockNetworkLoad(url: url, cloudflareBaseURL: refererBaseURL) {
                finish(cacheKey: coalescedKey, image: nil)
                return
            }

            // Bounded wait: never block this queue forever if slots are wedged.
            let gotSlot = networkSemaphore.wait(timeout: .now() + 25) == .success
            guard gotSlot else {
                finish(cacheKey: coalescedKey, image: nil)
                return
            }

            defer {
                // signal happens in task completion; if we return before creating a task, signal here.
            }

            if !forceRetry, let cached = AvatarImageLoader.imageFromDiskCacheIfAvailable(for: url) {
                networkSemaphore.signal()
                finish(cacheKey: coalescedKey, image: cached)
                return
            }
            if !forceRetry,
               CloudflareImageGate.shouldBlockNetworkLoad(url: url, cloudflareBaseURL: refererBaseURL) {
                networkSemaphore.signal()
                finish(cacheKey: coalescedKey, image: nil)
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20
            request.cachePolicy = forceRetry
                ? .reloadIgnoringLocalCacheData
                : .useProtocolCachePolicy
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

            let userAgent = WebCookieStore.shared.userAgent
                ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            if let referer = refererHeader(baseURL: refererBaseURL) {
                // Always send forum Referer for body images (CDN + beds + even main uploads).
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }

            if AvatarImageLoader.needsForumCookies(url, baseURL: refererBaseURL) {
                let cookieProbe = AvatarImageLoader.forumCookieURL(for: url, baseURL: refererBaseURL) ?? url
                let cookie = WebCookieStore.shared.cookieHeader(for: cookieProbe)
                if !cookie.isEmpty {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
            }

            let task = session.dataTask(with: request) { data, response, _ in
                defer { networkSemaphore.signal() }

                if let http = response as? HTTPURLResponse,
                   let detection = DiscourseAPI.cloudflareChallengeDetection(http, data: data) {
                    let base = refererBaseURL
                        ?? CloudflareImageGate.originString(for: url)
                        ?? url.absoluteString
                    Task { @MainActor in
                        CloudflareImageGate.reportImageChallenge(
                            baseURL: base,
                            responseURL: http.url,
                            source: "image.content",
                            detection: detection
                        )
                    }
                    finish(cacheKey: coalescedKey, image: nil)
                    return
                }

                let image: UIImage? = decodeImage(data: data, response: response)
                if let image {
                    AvatarImageLoader.storeProcessCache(image, for: url)
                    SDImageCache.shared.store(image, forKey: cacheKey, completion: nil)
                    // Success: make sure SD's failed-URL set cannot block avatar/other paths.
                    AvatarImageLoader.clearFailedLoad(for: url)
                }

                finish(cacheKey: coalescedKey, image: image)
            }
            task.resume()
        }
    }

    private static func decodeImage(data: Data?, response: URLResponse?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            return nil
        }
        // Reject obvious non-image payloads (CF HTML challenge pages).
        if let http = response as? HTTPURLResponse {
            let mime = (http.mimeType ?? "").lowercased()
            if mime.contains("text/html") || mime.contains("application/json") {
                return nil
            }
        }
        if let prefix = String(data: data.prefix(64), encoding: .utf8)?.lowercased(),
           prefix.contains("<!doctype html") || prefix.contains("<html") {
            return nil
        }
        if let animated = SDAnimatedImage(data: data) {
            return animated
        }
        return UIImage(data: data)
    }

    private static func finish(cacheKey: String, image: UIImage?) {
        let callbacks: [(UIImage?) -> Void]
        inflightLock.lock()
        callbacks = inflight.removeValue(forKey: cacheKey) ?? []
        inflightStartedAt.removeValue(forKey: cacheKey)
        inflightLock.unlock()

        Task { @MainActor in
            for callback in callbacks {
                callback(image)
            }
        }
    }

    private static func reapStaleInflightIfNeeded() {
        let now = Date()
        var staleKeys: [String] = []
        inflightLock.lock()
        for (key, started) in inflightStartedAt where now.timeIntervalSince(started) > inflightStaleInterval {
            staleKeys.append(key)
        }
        var staleCallbacks: [(UIImage?) -> Void] = []
        for key in staleKeys {
            if let cbs = inflight.removeValue(forKey: key) {
                staleCallbacks.append(contentsOf: cbs)
            }
            inflightStartedAt.removeValue(forKey: key)
        }
        inflightLock.unlock()
        guard !staleCallbacks.isEmpty else { return }
        DohDebugLog.record(
            "external image reaped \(staleKeys.count) stale inflight key(s)",
            subsystem: "Avatar"
        )
        Task { @MainActor in
            for callback in staleCallbacks {
                callback(nil)
            }
        }
    }

    private static func refererHeader(baseURL: String?) -> String? {
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
