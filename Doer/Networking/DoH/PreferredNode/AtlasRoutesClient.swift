import Foundation

/// atlas 节点表 `GET /v1/routes` 里本模块关心的部分。
nonisolated struct AtlasRoutesTable: Sendable {
    var ttl: TimeInterval
    var candidates: [String]
    var fetchedAt: Date
    /// 表里带的 ECH 钥匙（base64 解码后），可省掉一次公共 DoH 查询。
    var echConfig: Data?
}

/// atlas 拉取失败的原因。
nonisolated enum AtlasRoutesError: Error, Sendable {
    case unreachable(PreferredNodeHTTPFailure)
    case status(Int, retryAfter: Int?)
    case unparsable

    var description: String {
        switch self {
        case .unreachable(let failure): return failure.description
        case .status(let status, let retryAfter): return "http \(status)\(retryAfter.map { " retry-after \($0)s" } ?? "")"
        case .unparsable: return "atlas table unparsable"
        }
    }
}

/// 拉取社区维护的 atlas 节点表。
///
/// atlas 跑在 Cloudflare 上，所以先经公共 DoH 解析它自己的 IP（投毒检查），
/// 再用**普通 TLS**（不加 ECH）请求——atlas 不在被 SNI 阻断的名单里。
nonisolated final class AtlasRoutesClient: @unchecked Sendable {
    static let defaultURL = "https://atlas.1molchuan.top/v1/routes"

    /// 正文上限 256 KB（对齐 `select.rs:66`）。
    private static let maxBody = 256 * 1024
    private static let maxCandidates = 10

    private let client = PreferredNodeHTTPSClient(
        echConfig: nil,
        timeouts: PreferredNodeHTTPSClient.Timeouts(tcp: 2, tls: 3, http: 3)
    )

    struct Endpoint {
        var host: String
        var path: String

        init?(url: String) {
            guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty else { return nil }
            self.host = host
            let path = parsed.path.isEmpty ? "/v1/routes" : parsed.path
            self.path = parsed.query.map { "\(path)?\($0)" } ?? path
        }
    }

    func fetch(
        endpoint: Endpoint,
        bootstrapIPs: [String],
        family: CloudflareRanges.FamilySupport,
        completion: @escaping (Result<AtlasRoutesTable, AtlasRoutesError>) -> Void
    ) {
        guard !bootstrapIPs.isEmpty else {
            completion(.failure(.unreachable(.tcpConnect)))
            return
        }

        func attempt(_ index: Int, lastFailure: PreferredNodeHTTPFailure?) {
            guard index < bootstrapIPs.count else {
                completion(.failure(.unreachable(lastFailure ?? .tcpConnect)))
                return
            }
            client.request(
                ip: bootstrapIPs[index],
                host: endpoint.host,
                path: endpoint.path,
                headers: [("accept", "application/json")],
                maxBody: Self.maxBody
            ) { result in
                switch result {
                case .success(let reply):
                    guard reply.status == 200 else {
                        completion(.failure(.status(reply.status, retryAfter: reply.retryAfterSeconds)))
                        return
                    }
                    guard let table = Self.parse(reply.body, family: family) else {
                        completion(.failure(.unparsable))
                        return
                    }
                    completion(.success(table))
                case .failure(let failure):
                    attempt(index + 1, lastFailure: failure)
                }
            }
        }
        attempt(0, lastFailure: nil)
    }

    /// 解析 atlas 表：所有 IP 必须落在 CF 网段且不在抽样跳过表里。
    static func parse(_ body: Data, family: CloudflareRanges.FamilySupport) -> AtlasRoutesTable? {
        guard let json = try? JSONDecoder().decode(RoutesJSON.self, from: body) else { return nil }
        var candidates: [String] = []
        var seen = Set<String>()
        var echConfig: Data?
        for route in json.routes {
            for ip in route.v4 + route.v6 {
                let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
                guard CloudflareRanges.isCloudflare(trimmed),
                      !CloudflareRanges.isSkipped(trimmed),
                      seen.insert(trimmed).inserted
                else { continue }
                let isV6 = trimmed.contains(":")
                guard (isV6 && family.v6) || (!isV6 && family.v4) else { continue }
                candidates.append(trimmed)
            }
            // 目标站那一条的钥匙最可信；没有就用第一条能解出来的。
            let name = (route.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isTarget = name == PreferredNodeSelector.probeHost
            if echConfig == nil || isTarget {
                if let decoded = route.ech.flatMap(decodeBase64Lenient) {
                    echConfig = decoded
                }
            }
        }
        return AtlasRoutesTable(
            ttl: TimeInterval(max(0, json.ttl ?? 0)),
            candidates: Array(candidates.prefix(maxCandidates)),
            fetchedAt: Date(),
            echConfig: echConfig
        )
    }

    /// atlas 表里的 `ech` 是 base64，可能 URL-safe、可能缺 padding。
    static func decodeBase64Lenient(_ text: String) -> Data? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        value = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }

    private struct RoutesJSON: Decodable {
        var ttl: Int?
        var routes: [Route]

        struct Route: Decodable {
            var name: String?
            var v4: [String]
            var v6: [String]
            var ech: String?

            private enum CodingKeys: String, CodingKey {
                case name, v4, v6, ech
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decodeIfPresent(String.self, forKey: .name)
                v4 = (try? container.decode([String].self, forKey: .v4)) ?? []
                v6 = (try? container.decode([String].self, forKey: .v6)) ?? []
                ech = try container.decodeIfPresent(String.self, forKey: .ech)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case ttl, routes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ttl = try container.decodeIfPresent(Int.self, forKey: .ttl)
            routes = (try? container.decode([Route].self, forKey: .routes)) ?? []
        }
    }
}
