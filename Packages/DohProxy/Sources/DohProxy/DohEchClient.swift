import Foundation

/// FluxDo `lookupEchConfig` contract: raw ECH config bytes or nil + negative cache.
public struct DohEchLookupResult: Equatable, Sendable {
    public var host: String
    public var echConfig: Data?
    public var negative: Bool

    public init(host: String, echConfig: Data?, negative: Bool) {
        self.host = host
        self.echConfig = echConfig
        self.negative = negative
    }

    public var isAvailable: Bool {
        if let echConfig, !echConfig.isEmpty { return true }
        return false
    }
}

/// Origin TLS must inject DNS HTTPS ECH config bytes. Network.framework cannot.
public protocol DohOriginTLS: Sendable {
    func connect(
        host: String,
        address: String,
        port: UInt16,
        echConfig: Data?
    ) async throws
}

/// Lookup is DNS HTTPS; origin inject is BoringSSL `SSL_set1_ech_config_list`.
public struct DohEchClient: Sendable {
    public init() {}

    public func result(host: String, httpsAnswers: [Data]) -> DohEchLookupResult {
        if let ech = DohHttpsRecord.firstECHConfig(from: httpsAnswers) {
            return DohEchLookupResult(host: host, echConfig: ech, negative: false)
        }
        return DohEchLookupResult(host: host, echConfig: nil, negative: true)
    }
}
