import Foundation

/// 一次候选节点探测的结果。
nonisolated struct PreferredNodeProbeOutcome: Sendable {
    nonisolated enum Failure: Equatable, Sendable {
        case tcpConnect
        case tcpTimeout
        case tlsTimeout
        case tls(String)
        /// 服务端拒绝了 ECH；带 retry_configs 时可当场换钥匙重试。
        case echRejected(retryConfigs: Data?)
        case httpTimeout
        case httpStatus(Int)
        /// 200 但 trace 正文里的 `h=` 不是目标站
        case bodyMismatch
        case http(String)

        var description: String {
            switch self {
            case .tcpConnect: return "tcp connect failed"
            case .tcpTimeout: return "tcp timeout"
            case .tlsTimeout: return "tls timeout"
            case .tls(let detail): return "tls: \(detail)"
            case .echRejected(let retryConfigs):
                return "ech rejected (\(retryConfigs.map { "retry_configs \($0.count) bytes" } ?? "no retry_configs"))"
            case .httpTimeout: return "http timeout"
            case .httpStatus(let status): return "http \(status)"
            case .bodyMismatch: return "trace host mismatch"
            case .http(let detail): return "http: \(detail)"
            }
        }

        /// 服务端给出的新 ECH 钥匙（若有）。
        var retryConfigs: Data? {
            guard case .echRejected(let retryConfigs) = self else { return nil }
            return retryConfigs
        }
    }

    var ip: String
    /// 从 TCP 发起到拿到状态行的墙钟时间（毫秒）
    var latencyMs: Int
    var ok: Bool
    var failure: Failure?
    var echAccepted: Bool
}

/// 单个 Cloudflare 边缘 IP 的可用性探测。
///
/// 链路：TCP → TLS 1.3 + ECH（内层 SNI = linux.do）→ `GET /cdn-cgi/trace`。
/// 通过判定不是裸 200，而是 trace 正文里 `h=` 行等于目标站：Enterprise 专用边缘会回 403/1034，
/// 共享池里也有不服务该 zone 的节点。
///
/// 移植自 cfluxdo `core/doh_proxy/src/probe.rs`。
nonisolated final class CloudflareNodeProbe: @unchecked Sendable {

    static let tracePath = "/cdn-cgi/trace"

    /// trace 正文是否声明了目标站：逐行找 `h=`，必须整行相等（只裁行尾空白）。
    ///
    /// 按字节切 `\n`：Swift 把 `\r\n` 当作单个 `Character`，
    /// `String.split(separator: "\n")` 切不开 CRLF 行。
    static func traceMatches(_ body: Data, expect: String) -> Bool {
        let target = Array(("h=" + expect).utf8)
        for rawLine in body.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = rawLine
            while let last = line.last, last == 0x0D || last == 0x20 || last == 0x09 {
                line = line.dropLast()
            }
            if line.elementsEqual(target) { return true }
        }
        return false
    }

    private let client: PreferredNodeHTTPSClient

    /// 这轮探测用的 ECH 钥匙。赢家落盘时一并记下，之后连 linux.do 就不必再解析。
    let echConfig: Data?

    init(echConfig: Data?, timeouts: PreferredNodeHTTPSClient.Timeouts = .default) {
        self.echConfig = echConfig
        client = PreferredNodeHTTPSClient(echConfig: echConfig, timeouts: timeouts)
    }

    /// 探测一个 IP：TCP → TLS+ECH（内层 SNI `sni`）→ `GET /cdn-cgi/trace`，
    /// 200 且 `h=` 等于 `sni` 才算通过。
    func probe(
        ip: String,
        sni: String,
        completion: @escaping (PreferredNodeProbeOutcome) -> Void
    ) {
        client.request(ip: ip, host: sni, path: Self.tracePath, maxBody: 4096) { result in
            switch result {
            case .success(let reply):
                if reply.status != 200 {
                    completion(Self.outcome(ip: ip, reply: reply, failure: .httpStatus(reply.status)))
                } else if Self.traceMatches(reply.body, expect: sni) {
                    completion(PreferredNodeProbeOutcome(
                        ip: ip,
                        latencyMs: reply.latencyMs,
                        ok: true,
                        failure: nil,
                        echAccepted: reply.echAccepted
                    ))
                } else {
                    completion(Self.outcome(ip: ip, reply: reply, failure: .bodyMismatch))
                }
            case .failure(let failure):
                completion(PreferredNodeProbeOutcome(
                    ip: ip,
                    latencyMs: 0,
                    ok: false,
                    failure: Self.map(failure),
                    echAccepted: false
                ))
            }
        }
    }

    private static func outcome(
        ip: String,
        reply: PreferredNodeHTTPReply,
        failure: PreferredNodeProbeOutcome.Failure
    ) -> PreferredNodeProbeOutcome {
        PreferredNodeProbeOutcome(
            ip: ip,
            latencyMs: reply.latencyMs,
            ok: false,
            failure: failure,
            echAccepted: reply.echAccepted
        )
    }

    private static func map(_ failure: PreferredNodeHTTPFailure) -> PreferredNodeProbeOutcome.Failure {
        switch failure {
        case .tcpConnect: return .tcpConnect
        case .tcpTimeout: return .tcpTimeout
        case .tlsTimeout: return .tlsTimeout
        case .tls(let detail): return .tls(detail)
        case .echRejected(let retryConfigs): return .echRejected(retryConfigs: retryConfigs)
        case .httpTimeout: return .httpTimeout
        case .http(let detail): return .http(detail)
        }
    }
}
