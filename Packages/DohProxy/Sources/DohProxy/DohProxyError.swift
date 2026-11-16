import Foundation

public enum DohProxyError: Error, Equatable, LocalizedError {
    case bootstrapUnavailable(String)
    case emptyAnswer(String)
    case queryFailed(String)
    /// 单次 resolve 超过总预算仍没等到回调。现场表现为 CONNECT / WKWebView
    /// 请求一起挂死，所以必须给出可诊断的错误而不是无限等待。
    case resolveTimeout(String)
    case malformedDNSResponse
    case malformedHTTPResponse
    case echRequiredButUnavailable
    case rustlsNotLinked

    public var errorDescription: String? {
        switch self {
        case .bootstrapUnavailable(let url):
            return "DoH server has no bootstrap IPs: \(url)"
        case .emptyAnswer(let host):
            return "DoH returned no address for \(host)"
        case .queryFailed(let host):
            return "DoH query failed for \(host)"
        case .resolveTimeout(let host):
            return "DoH resolve timed out for \(host)"
        case .malformedDNSResponse:
            return "DoH returned a malformed DNS response"
        case .malformedHTTPResponse:
            return "DoH returned a malformed HTTP response"
        case .echRequiredButUnavailable:
            return "ECH config present but rustls origin TLS is not linked"
        case .rustlsNotLinked:
            return "rustls ECH client is not linked"
        }
    }
}
