import Alamofire
import DohProxy
import Foundation

/// Rewrites https://host/path to http://127.0.0.1:port/path while keeping Host
/// and Cookie on the original URL — FluxDo `_GatewayAdapterWrapper`.
enum DohGatewayRewrite {
    static func applyIfNeeded(_ urlRequest: URLRequest) -> URLRequest {
        let config = AppSettings.dohProxyConfig(from: .standard)
        guard config.isGatewayMode,
              LocalConnectProxy.originECHReady,
              let port = LightweightDohProxyService.shared.ensureRunning()
        else {
            return urlRequest
        }
        return rewrite(urlRequest, port: port) ?? urlRequest
    }

    static func rewrite(_ urlRequest: URLRequest, port: UInt16) -> URLRequest? {
        guard let url = urlRequest.url,
              url.scheme?.lowercased() == "https",
              let host = url.host
        else {
            return nil
        }
        var request = urlRequest
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.percentEncodedPath = url.path.isEmpty ? "/" : url.path
        if let query = url.query { components.percentEncodedQuery = query }
        request.url = components.url
        request.setValue(host, forHTTPHeaderField: "Host")
        return request
    }
}

final class DohGatewayInterceptor: RequestInterceptor {
    func adapt(
        _ urlRequest: URLRequest,
        for session: Session,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    ) {
        completion(.success(DohGatewayRewrite.applyIfNeeded(urlRequest)))
    }
}
