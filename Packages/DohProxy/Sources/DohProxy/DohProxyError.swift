import Foundation

public enum DohProxyError: Error, Equatable, LocalizedError {
    case bootstrapUnavailable(String)
    case emptyAnswer(String)
    case queryFailed(String)
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
