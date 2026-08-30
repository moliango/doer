import Foundation

struct AppVersion: Codable, Equatable, Hashable, Sendable {
    let marketingVersion: String
    let buildNumber: Int

    init(marketingVersion: String, buildNumber: Int) {
        precondition(Self.numericComponents(marketingVersion) != nil, "Invalid marketing version")
        precondition(buildNumber >= 0, "Invalid build number")
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    init?(releaseTag: String) {
        let pattern = #"^v([0-9]+(?:\.[0-9]+)*)-build\.([0-9]+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: releaseTag,
                range: NSRange(releaseTag.startIndex..., in: releaseTag)
              ),
              match.range.location != NSNotFound,
              let marketingRange = Range(match.range(at: 1), in: releaseTag),
              let buildRange = Range(match.range(at: 2), in: releaseTag),
              let buildNumber = Int(releaseTag[buildRange]),
              Self.numericComponents(String(releaseTag[marketingRange])) != nil
        else {
            return nil
        }
        self.init(
            marketingVersion: String(releaseTag[marketingRange]),
            buildNumber: buildNumber
        )
    }

    static func installed(in bundle: Bundle = .main) -> AppVersion {
        let rawMarketingVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        let marketingVersion = rawMarketingVersion.flatMap {
            numericComponents($0) == nil ? nil : $0
        } ?? "0"
        let rawBuildNumber = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap(Int.init)
        let buildNumber = max(0, rawBuildNumber ?? 0)
        return AppVersion(marketingVersion: marketingVersion, buildNumber: buildNumber)
    }

    var displayString: String {
        "\(marketingVersion) (\(buildNumber))"
    }

    var marketingDisplayString: String {
        "v\(marketingVersion)"
    }

    var releaseDisplayString: String {
        "v\(marketingVersion) · Build \(buildNumber)"
    }

    func isNewer(than other: AppVersion) -> Bool {
        let lhs = Self.numericComponents(marketingVersion) ?? []
        let rhs = Self.numericComponents(other.marketingVersion) ?? []
        let count = max(lhs.count, rhs.count)

        for index in 0..<count {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    func isOlder(than other: AppVersion) -> Bool {
        other.isNewer(than: self)
    }

    private static func numericComponents(_ value: String) -> [Int]? {
        let rawComponents = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else { return nil }
        var components: [Int] = []
        components.reserveCapacity(rawComponents.count)
        for component in rawComponents {
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  let number = Int(component)
            else {
                return nil
            }
            components.append(number)
        }
        return components
    }
}

struct AppReleaseAsset: Codable, Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let size: Int64

    private enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
    }
}

struct AppRelease: Codable, Equatable, Sendable {
    let tagName: String
    let name: String
    let releaseNotes: String
    let htmlURL: URL
    let isDraft: Bool
    let isPrerelease: Bool
    let publishedAt: Date?
    let assets: [AppReleaseAsset]
    let version: AppVersion

    var ipaAsset: AppReleaseAsset? {
        assets.first { asset in
            let name = asset.name.lowercased()
            return name == "doer-unsigned.ipa"
        }
    }

    func isUpdateAvailable(comparedTo installedVersion: AppVersion) -> Bool {
        !isDraft && !isPrerelease && version.isNewer(than: installedVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case releaseNotes = "body"
        case htmlURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case publishedAt = "published_at"
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        guard let parsedVersion = AppVersion(releaseTag: tagName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .tagName,
                in: container,
                debugDescription: "Unsupported Doer release tag: \(tagName)"
            )
        }
        version = parsedVersion
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        releaseNotes = try container.decodeIfPresent(String.self, forKey: .releaseNotes) ?? ""
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        assets = try container.decodeIfPresent([AppReleaseAsset].self, forKey: .assets) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tagName, forKey: .tagName)
        try container.encode(name, forKey: .name)
        try container.encode(releaseNotes, forKey: .releaseNotes)
        try container.encode(htmlURL, forKey: .htmlURL)
        try container.encode(isDraft, forKey: .isDraft)
        try container.encode(isPrerelease, forKey: .isPrerelease)
        try container.encodeIfPresent(publishedAt, forKey: .publishedAt)
        try container.encode(assets, forKey: .assets)
    }
}

enum AppUpdateCheckMode: Equatable, Sendable {
    case automatic
    case manual
}

enum AppUpdateError: Error, LocalizedError {
    case invalidResponse
    case unexpectedStatusCode(Int)
    case notModifiedWithoutCache
    case invalidRelease(Error)
    case network(URLError)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case let .unexpectedStatusCode(statusCode):
            return "GitHub returned HTTP \(statusCode)."
        case .notModifiedWithoutCache:
            return "GitHub returned 304, but no cached release is available."
        case let .invalidRelease(error):
            return "The GitHub Release could not be decoded: \(error.localizedDescription)"
        case let .network(error):
            return error.localizedDescription
        }
    }
}

extension JSONDecoder {
    static var githubReleaseDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

final class AppUpdateService {
    static let shared = AppUpdateService()

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/moliango/doer/releases/latest"
    )!
    private static let cacheKey = "doer.update.latest-release-cache.v1"
    private static let freshCacheInterval: TimeInterval = 60 * 60

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private let endpoint: URL

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        endpoint: URL = AppUpdateService.latestReleaseURL
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
        self.endpoint = endpoint
    }

    func check(mode: AppUpdateCheckMode) async throws -> AppRelease {
        let cached = loadCache()
        if mode == .automatic,
           let cached,
           isFresh(cached, at: now()) {
            return cached.release
        }

        var request = URLRequest(url: try GitHubProxy.applyIfValid(
            to: endpoint,
            prefix: defaults.string(forKey: "githubProxyPrefix") ?? ""
        ))
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Doer-iOS", forHTTPHeaderField: "User-Agent")
        if let etag = cached?.etag, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw AppUpdateError.invalidResponse
            }
            switch response.statusCode {
            case 200:
                let release: AppRelease
                do {
                    release = try JSONDecoder.githubReleaseDecoder.decode(AppRelease.self, from: data)
                } catch {
                    throw AppUpdateError.invalidRelease(error)
                }
                saveCache(
                    CachedRelease(
                        release: release,
                        etag: response.value(forHTTPHeaderField: "ETag"),
                        fetchedAt: now()
                    )
                )
                return release
            case 304:
                guard var cached else { throw AppUpdateError.notModifiedWithoutCache }
                cached.fetchedAt = now()
                saveCache(cached)
                return cached.release
            case 403, 429:
                if let cached { return cached.release }
                throw AppUpdateError.unexpectedStatusCode(response.statusCode)
            case 500...599:
                if let cached { return cached.release }
                throw AppUpdateError.unexpectedStatusCode(response.statusCode)
            default:
                throw AppUpdateError.unexpectedStatusCode(response.statusCode)
            }
        } catch let error as AppUpdateError {
            throw error
        } catch let error as URLError {
            if let cached { return cached.release }
            throw AppUpdateError.network(error)
        } catch {
            let urlError = URLError(.unknown, userInfo: [NSUnderlyingErrorKey: error])
            if let cached { return cached.release }
            throw AppUpdateError.network(urlError)
        }
    }

    func clearCache() {
        defaults.removeObject(forKey: Self.cacheKey)
    }

    private func isFresh(_ cache: CachedRelease, at date: Date) -> Bool {
        let age = date.timeIntervalSince(cache.fetchedAt)
        return age >= 0 && age < Self.freshCacheInterval
    }

    private func loadCache() -> CachedRelease? {
        guard let data = defaults.data(forKey: Self.cacheKey) else { return nil }
        do {
            return try JSONDecoder.githubReleaseDecoder.decode(CachedRelease.self, from: data)
        } catch {
            defaults.removeObject(forKey: Self.cacheKey)
            return nil
        }
    }

    private func saveCache(_ cache: CachedRelease) {
        guard let data = try? JSONEncoder.githubReleaseEncoder.encode(cache) else { return }
        defaults.set(data, forKey: Self.cacheKey)
    }
}

private struct CachedRelease: Codable {
    let release: AppRelease
    let etag: String?
    var fetchedAt: Date
}

private extension JSONEncoder {
    static var githubReleaseEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
