import Foundation
import Network

/// DoH wire GET over bootstrap IPs. TLS SNI is the DoH hostname. Never uses URLSession.
enum DohBootstrapTransport {
    static func query(
        endpoint: DohEndpoint,
        dnsQuery: Data,
        queue: DispatchQueue,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard endpoint.isReady,
              let path = DohDNSMessage.wireGETPath(url: endpoint.url, query: dnsQuery)
        else {
            completion(.failure(DohProxyError.bootstrapUnavailable(endpoint.url)))
            return
        }
        query(
            addresses: endpoint.bootstrapIPs,
            index: 0,
            serverHost: endpoint.host,
            serverPort: endpoint.port,
            requestPath: path,
            queue: queue,
            lastError: nil,
            completion: completion
        )
    }

    private static func query(
        addresses: [String],
        index: Int,
        serverHost: String,
        serverPort: UInt16,
        requestPath: String,
        queue: DispatchQueue,
        lastError: Error?,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard index < addresses.count, let port = NWEndpoint.Port(rawValue: serverPort) else {
            completion(.failure(lastError ?? DohProxyError.bootstrapUnavailable(serverHost)))
            return
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverHost)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(addresses[index]), port: port, using: parameters)
        let timeout = DispatchWorkItem {
            connection.cancel()
            query(
                addresses: addresses,
                index: index + 1,
                serverHost: serverHost,
                serverPort: serverPort,
                requestPath: requestPath,
                queue: queue,
                lastError: DohProxyError.queryFailed(serverHost),
                completion: completion
            )
        }

        var buffer = Data()
        var finished = false

        func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            timeout.cancel()
            connection.cancel()
            completion(result)
        }

        func tryNext(_ error: Error) {
            guard !finished else { return }
            finished = true
            timeout.cancel()
            connection.cancel()
            query(
                addresses: addresses,
                index: index + 1,
                serverHost: serverHost,
                serverPort: serverPort,
                requestPath: requestPath,
                queue: queue,
                lastError: error,
                completion: completion
            )
        }

        func parseBuffered(requireComplete: Bool) -> Bool {
            do {
                guard let body = try DohHTTPWire.extractBody(from: buffer, requireComplete: requireComplete) else {
                    return false
                }
                finish(.success(body))
                return true
            } catch {
                tryNext(error)
                return true
            }
        }

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if parseBuffered(requireComplete: false) { return }
                }
                if let error {
                    tryNext(error)
                    return
                }
                if isComplete {
                    _ = parseBuffered(requireComplete: true)
                    if !finished {
                        tryNext(DohProxyError.queryFailed(serverHost))
                    }
                    return
                }
                receiveMore()
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = [
                    "GET \(requestPath) HTTP/1.1",
                    "Host: \(serverHost)",
                    "Accept: application/dns-message",
                    "Connection: close",
                    "",
                    "",
                ].joined(separator: "\r\n")
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error {
                        tryNext(error)
                        return
                    }
                    receiveMore()
                })
            case .failed(let error):
                tryNext(error)
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.start(queue: queue)
    }
}
