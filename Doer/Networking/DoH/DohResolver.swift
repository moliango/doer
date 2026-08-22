import DohProxy
import Foundation

nonisolated final class DohResolver: @unchecked Sendable {
    struct Answer {
        let addresses: [String]
        let ttl: TimeInterval
        let echConfig: Data?
        let echNegative: Bool
    }

    private let inner: DohBootstrapResolver

    init(config: DohProxyConfig = AppSettings.dohProxyConfig(from: .standard)) {
        inner = DohBootstrapResolver(config: config)
        DohDebugLog.record("Resolver engine: bootstrap DoH (no system DNS)")
    }

    func updateConfig(_ config: DohProxyConfig) {
        inner.updateConfig(config)
    }

    func resolve(host rawHost: String, completion: @escaping (Result<Answer, Error>) -> Void) {
        inner.resolve(host: rawHost) { result in
            completion(result.map { record in
                Answer(
                    addresses: record.addresses,
                    ttl: record.ttl,
                    echConfig: record.echConfig,
                    echNegative: record.echNegative
                )
            })
        }
    }

    func lookupEchConfig(host: String, completion: @escaping (Result<DohEchLookupResult, Error>) -> Void) {
        inner.lookupEchConfig(host: host, completion: completion)
    }

    func recordHostSuccess(host: String, ip: String) {
        inner.recordHostSuccess(host: host, ip: ip)
    }

    func recordHostFailure(host: String, ip: String) {
        inner.recordHostFailure(host: host, ip: ip)
    }

    func clearCache() {
        inner.clearCache()
    }

    func cacheStats() -> DohCacheStats {
        inner.cacheStats()
    }

    func cacheRecords() -> [DohHostRecord] {
        inner.cacheRecords()
    }
}

enum DohResolverError: LocalizedError {
    case invalidProviderURL(String)
    case emptyAnswer(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderURL(let url):
            return "Invalid DoH provider URL: \(url)"
        case .emptyAnswer(let host):
            return "DoH returned no address for \(host)"
        case .queryFailed(let host):
            return "DoH query failed for \(host)"
        }
    }
}

struct DohProviderConfiguration {
    let name: String
    let url: String

    @MainActor
    static func current(settings: AppSettings) -> DohProviderConfiguration {
        let provider = settings.dohProvider
        return DohProviderConfiguration(name: provider.title, url: settings.dohServerURL)
    }

    static func currentFromDefaults() -> DohProviderConfiguration {
        let defaults = UserDefaults.standard
        let raw = defaults.object(forKey: "dohProvider") as? Int
        let provider = AppSettings.DoHProvider(rawValue: raw ?? AppSettings.DoHProvider.dnspod.rawValue)
            ?? .dnspod
        let url: String
        if provider == .custom {
            url = defaults.string(forKey: "dohCustomURL") ?? ""
        } else {
            url = provider.url
        }
        return DohProviderConfiguration(name: provider.title, url: url)
    }

    var bootstrapIPs: [String] {
        DohServerCatalog.builtIn(url: url)?.bootstrapIPs ?? []
    }
}
