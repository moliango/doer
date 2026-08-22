import Foundation
import Network

nonisolated final class DohResolver: @unchecked Sendable {
    struct Answer {
        let addresses: [String]
        let ttl: TimeInterval
    }

    private struct CacheEntry {
        let addresses: [String]
        let expiresAt: Date

        var isValid: Bool {
            expiresAt > Date()
        }
    }

    nonisolated private struct JsonResponse: Decodable {
        let status: Int?
        let answer: [JsonAnswer]?

        enum CodingKeys: String, CodingKey {
            case status = "Status"
            case answer = "Answer"
        }
    }

    nonisolated private struct JsonAnswer: Decodable {
        let type: Int?
        let ttl: Int?
        let data: String

        enum CodingKeys: String, CodingKey {
            case type
            case ttl = "TTL"
            case data
        }
    }

    private let queue = DispatchQueue(label: "doer.doh.resolver")
    private var cache: [String: CacheEntry] = [:]
    private var inflight: [String: [(Result<Answer, Error>) -> Void]] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        DohDebugLog.record("Resolver engine: \(SwiftDnsResolverBackend.engineName)")
    }

    func resolve(host rawHost: String, completion: @escaping (Result<Answer, Error>) -> Void) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isAllowedHost(host) else {
            completion(.failure(DohResolverError.disallowedHost(host)))
            return
        }

        queue.async {
            if let cached = self.cache[host], cached.isValid {
                completion(.success(Answer(addresses: cached.addresses, ttl: cached.expiresAt.timeIntervalSinceNow)))
                return
            }
            if self.inflight[host] != nil {
                self.inflight[host]?.append(completion)
                return
            }
            self.inflight[host] = [completion]
            self.load(host: host)
        }
    }

    func clearCache() {
        queue.async {
            self.cache.removeAll()
        }
    }

    static func isAllowedHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "linux.do" || normalized.hasSuffix(".linux.do")
    }

    private func load(host: String) {
        let provider = DohProviderConfiguration.currentFromDefaults()
        let types = ["A", "AAAA"]
        let group = DispatchGroup()
        let resultLock = NSLock()
        var addresses: [String] = []
        var ttlValues: [Int] = []
        var errors: [Error] = []

        for type in types {
            group.enter()
            query(host: host, type: type, provider: provider) { result in
                resultLock.lock()
                switch result {
                case .success(let answer):
                    addresses.append(contentsOf: answer.addresses)
                    ttlValues.append(Int(answer.ttl))
                case .failure(let error):
                    errors.append(error)
                }
                resultLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: queue) {
            let uniqueAddresses = Self.unique(addresses)
            if uniqueAddresses.isEmpty {
                let errorText = errors.map(\.localizedDescription).joined(separator: " | ")
                DohDebugLog.record("Resolve failed for \(host): \(errorText)")
                self.finish(host: host, result: .failure(errors.first ?? DohResolverError.emptyAnswer(host)))
                return
            }

            let ttl = TimeInterval(max(30, min(ttlValues.min() ?? 300, 3600)))
            self.cache[host] = CacheEntry(
                addresses: uniqueAddresses,
                expiresAt: Date().addingTimeInterval(ttl)
            )
            self.finish(host: host, result: .success(Answer(addresses: uniqueAddresses, ttl: ttl)))
        }
    }

    private func finish(host: String, result: Result<Answer, Error>) {
        let completions = inflight.removeValue(forKey: host) ?? []
        completions.forEach { $0(result) }
    }

    private func query(
        host: String,
        type: String,
        provider: DohProviderConfiguration,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        if provider.prefersJSONFormat {
            queryJSON(host: host, type: type, provider: provider, completion: completion)
        } else {
            queryWireFormat(host: host, type: type, provider: provider, completion: completion)
        }
    }

    private func queryJSON(
        host: String,
        type: String,
        provider: DohProviderConfiguration,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        guard let url = provider.jsonQueryURL(host: host, type: type) else {
            completion(.failure(DohResolverError.invalidProviderURL(provider.url)))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data else {
                completion(.failure(DohResolverError.emptyAnswer(host)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(JsonResponse.self, from: data)
                guard decoded.status == nil || decoded.status == 0 else {
                    completion(.failure(DohResolverError.queryFailed(host)))
                    return
                }
                let answers = decoded.answer ?? []
                let expectedType = type == "AAAA" ? 28 : 1
                let filtered = answers.filter { item in
                    (item.type == nil || item.type == expectedType) && Self.looksLikeIPAddress(item.data)
                }
                let ttl = TimeInterval(max(30, min(filtered.compactMap(\.ttl).min() ?? 300, 3600)))
                completion(.success(Answer(addresses: filtered.map(\.data), ttl: ttl)))
            } catch {
                DohDebugLog.record("JSON query failed for \(host) \(type): \(error.localizedDescription), fallback to wire-format")
                self.queryWireFormat(host: host, type: type, provider: provider, completion: completion)
            }
        }.resume()
    }

    private func queryWireFormat(
        host: String,
        type: String,
        provider: DohProviderConfiguration,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        guard let body = Self.makeDNSQuery(host: host, type: type) else {
            completion(.failure(DohResolverError.invalidProviderURL(provider.url)))
            return
        }

        if !provider.bootstrapIPs.isEmpty {
            queryWireFormatWithBootstrap(
                host: host,
                type: type,
                provider: provider,
                queryBody: body,
                completion: { [weak self] result in
                    switch result {
                    case .success:
                        completion(result)
                    case .failure(let error):
                        DohDebugLog.record("Bootstrap query failed for \(host) \(type): \(error.localizedDescription), fallback to URLSession")
                        self?.queryWireFormatWithURLSession(
                            host: host,
                            type: type,
                            provider: provider,
                            queryBody: body,
                            completion: completion
                        )
                    }
                }
            )
            return
        }

        queryWireFormatWithURLSession(
            host: host,
            type: type,
            provider: provider,
            queryBody: body,
            completion: completion
        )
    }

    private func queryWireFormatWithURLSession(
        host: String,
        type: String,
        provider: DohProviderConfiguration,
        queryBody: Data,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        guard let url = provider.wireQueryURL else {
            completion(.failure(DohResolverError.invalidProviderURL(provider.url)))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.httpBody = queryBody
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")

        session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200 ..< 300).contains(httpResponse.statusCode) {
                let preview = data.flatMap { String(data: $0.prefix(160), encoding: .utf8) } ?? ""
                DohDebugLog.record("Wire query HTTP \(httpResponse.statusCode) for \(host) \(type): \(preview)")
                completion(.failure(DohResolverError.queryFailed(host)))
                return
            }
            guard let data else {
                completion(.failure(DohResolverError.emptyAnswer(host)))
                return
            }
            do {
                let parsed = try Self.parseDNSResponse(data, expectedType: type)
                guard !parsed.addresses.isEmpty else {
                    completion(.failure(DohResolverError.emptyAnswer(host)))
                    return
                }
                completion(.success(parsed))
            } catch {
                let preview = String(data: data.prefix(160), encoding: .utf8) ?? ""
                DohDebugLog.record("Wire parse failed for \(host) \(type): \(error.localizedDescription). Body: \(preview)")
                completion(.failure(error))
            }
        }.resume()
    }

    private func queryWireFormatWithBootstrap(
        host: String,
        type: String,
        provider: DohProviderConfiguration,
        queryBody: Data,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        guard let serverHost = provider.serverHost,
              let serverPort = provider.serverPort,
              let requestPath = provider.wireGETPath(queryBody: queryBody)
        else {
            completion(.failure(DohResolverError.invalidProviderURL(provider.url)))
            return
        }

        let addresses = Self.sortedBootstrapIPs(provider.bootstrapIPs)
        queryWireFormatWithBootstrap(
            addresses: addresses,
            addressIndex: 0,
            serverHost: serverHost,
            serverPort: serverPort,
            requestPath: requestPath,
            expectedHost: host,
            expectedType: type,
            lastError: nil,
            completion: completion
        )
    }

    private func queryWireFormatWithBootstrap(
        addresses: [String],
        addressIndex: Int,
        serverHost: String,
        serverPort: UInt16,
        requestPath: String,
        expectedHost: String,
        expectedType: String,
        lastError: Error?,
        completion: @escaping (Result<Answer, Error>) -> Void
    ) {
        guard addressIndex < addresses.count,
              let port = NWEndpoint.Port(rawValue: serverPort)
        else {
            completion(.failure(lastError ?? DohResolverError.emptyAnswer(expectedHost)))
            return
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverHost)
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(addresses[addressIndex]), port: port, using: parameters)
        let timeout = DispatchWorkItem {
            connection.cancel()
            self.queryWireFormatWithBootstrap(
                addresses: addresses,
                addressIndex: addressIndex + 1,
                serverHost: serverHost,
                serverPort: serverPort,
                requestPath: requestPath,
                expectedHost: expectedHost,
                expectedType: expectedType,
                lastError: DohResolverError.queryFailed(expectedHost),
                completion: completion
            )
        }

        var buffer = Data()
        var finished = false

        func finish(_ result: Result<Answer, Error>) {
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
            self.queryWireFormatWithBootstrap(
                addresses: addresses,
                addressIndex: addressIndex + 1,
                serverHost: serverHost,
                serverPort: serverPort,
                requestPath: requestPath,
                expectedHost: expectedHost,
                expectedType: expectedType,
                lastError: error,
                completion: completion
            )
        }

        func parseBufferedResponse(requireComplete: Bool) -> Bool {
            do {
                guard let body = try Self.extractHTTPBody(from: buffer, requireComplete: requireComplete) else {
                    return false
                }
                let parsed = try Self.parseDNSResponse(body, expectedType: expectedType)
                guard !parsed.addresses.isEmpty else {
                    throw DohResolverError.emptyAnswer(expectedHost)
                }
                finish(.success(parsed))
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
                    if parseBufferedResponse(requireComplete: false) {
                        return
                    }
                }
                if let error {
                    tryNext(error)
                    return
                }
                if isComplete {
                    _ = parseBufferedResponse(requireComplete: true)
                    if !finished {
                        tryNext(DohResolverError.queryFailed(expectedHost))
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
            case .cancelled:
                break
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.start(queue: queue)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func sortedBootstrapIPs(_ values: [String]) -> [String] {
        unique(values).sorted { lhs, rhs in
            !lhs.contains(":") && rhs.contains(":")
        }
    }

    private static func looksLikeIPAddress(_ value: String) -> Bool {
        if value.contains(":") {
            return true
        }
        let parts = value.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy { part in
            guard let number = Int(part) else { return false }
            return (0 ... 255).contains(number)
        }
    }

    private static func makeDNSQuery(host: String, type: String) -> Data? {
        let qtype: UInt16 = type == "AAAA" ? 28 : 1
        var data = Data()
        let queryId = UInt16.random(in: 0 ... UInt16.max)
        appendUInt16(queryId, to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)

        for label in host.split(separator: ".") {
            guard let labelData = String(label).data(using: .utf8), labelData.count <= 63 else { return nil }
            data.append(UInt8(labelData.count))
            data.append(labelData)
        }
        data.append(0)
        appendUInt16(qtype, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    private static func extractHTTPBody(from data: Data, requireComplete: Bool) throws -> Data? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: separator) else {
            return nil
        }

        let headerData = data.subdata(in: data.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .ascii) else {
            throw DohResolverError.malformedHTTPResponse
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first,
              statusLine.contains(" 200 ")
        else {
            throw DohResolverError.queryFailed("DoH server")
        }

        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let separatorIndex = line.firstIndex(of: ":") else { return }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[name] = value
        }

        let bodyStart = headerRange.upperBound
        let body = data.subdata(in: bodyStart ..< data.endIndex)

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return try decodeChunkedBody(body, requireComplete: requireComplete)
        }

        if let contentLengthText = headers["content-length"],
           let contentLength = Int(contentLengthText) {
            guard body.count >= contentLength else { return nil }
            return body.subdata(in: body.startIndex ..< body.startIndex + contentLength)
        }

        return requireComplete ? body : nil
    }

    private static func decodeChunkedBody(_ data: Data, requireComplete: Bool) throws -> Data? {
        var offset = data.startIndex
        var decoded = Data()

        while true {
            guard let lineEnd = data.range(of: Data([13, 10]), in: offset ..< data.endIndex) else {
                return requireComplete ? nil : nil
            }
            guard let sizeLine = String(data: data.subdata(in: offset ..< lineEnd.lowerBound), encoding: .ascii),
                  let chunkSize = Int(sizeLine.split(separator: ";").first ?? "", radix: 16)
            else {
                throw DohResolverError.malformedHTTPResponse
            }

            offset = lineEnd.upperBound
            if chunkSize == 0 {
                return decoded
            }

            guard offset + chunkSize + 2 <= data.endIndex else {
                return nil
            }
            decoded.append(data.subdata(in: offset ..< offset + chunkSize))
            offset += chunkSize
            guard offset + 2 <= data.endIndex,
                  data[offset] == 13,
                  data[offset + 1] == 10
            else {
                throw DohResolverError.malformedHTTPResponse
            }
            offset += 2
        }
    }

    private static func parseDNSResponse(_ data: Data, expectedType: String) throws -> Answer {
        guard data.count >= 12 else { throw DohResolverError.malformedDNSResponse }
        var offset = 4
        let qdCount = Int(readUInt16(data, at: offset))
        offset += 2
        let anCount = Int(readUInt16(data, at: offset))
        offset = 12

        for _ in 0 ..< qdCount {
            try skipName(data, offset: &offset)
            guard offset + 4 <= data.count else { throw DohResolverError.malformedDNSResponse }
            offset += 4
        }

        let expectedQType: UInt16 = expectedType == "AAAA" ? 28 : 1
        var addresses: [String] = []
        var ttls: [Int] = []

        for _ in 0 ..< anCount {
            try skipName(data, offset: &offset)
            guard offset + 10 <= data.count else { throw DohResolverError.malformedDNSResponse }
            let answerType = readUInt16(data, at: offset)
            offset += 2
            let answerClass = readUInt16(data, at: offset)
            offset += 2
            let ttl = Int(readUInt32(data, at: offset))
            offset += 4
            let rdLength = Int(readUInt16(data, at: offset))
            offset += 2
            guard offset + rdLength <= data.count else { throw DohResolverError.malformedDNSResponse }

            if answerClass == 1, answerType == expectedQType {
                let rdata = data.subdata(in: offset ..< offset + rdLength)
                if expectedQType == 1, rdLength == 4 {
                    addresses.append(rdata.map(String.init).joined(separator: "."))
                    ttls.append(ttl)
                } else if expectedQType == 28, rdLength == 16 {
                    addresses.append(ipv6String(from: rdata))
                    ttls.append(ttl)
                }
            }
            offset += rdLength
        }

        let ttl = TimeInterval(max(30, min(ttls.min() ?? 300, 3600)))
        return Answer(addresses: addresses, ttl: ttl)
    }

    private static func skipName(_ data: Data, offset: inout Int) throws {
        var jumped = false
        var localOffset = offset

        while true {
            guard localOffset < data.count else { throw DohResolverError.malformedDNSResponse }
            let length = data[localOffset]
            if length == 0 {
                localOffset += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard localOffset + 1 < data.count else { throw DohResolverError.malformedDNSResponse }
                localOffset += 2
                jumped = true
                break
            }
            localOffset += 1 + Int(length)
        }

        offset = localOffset
        _ = jumped
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func ipv6String(from data: Data) -> String {
        stride(from: 0, to: data.count, by: 2)
            .map { index in
                String(format: "%x", readUInt16(data, at: index))
            }
            .joined(separator: ":")
    }
}

enum DohResolverError: LocalizedError {
    case disallowedHost(String)
    case invalidProviderURL(String)
    case emptyAnswer(String)
    case queryFailed(String)
    case malformedDNSResponse
    case malformedHTTPResponse

    var errorDescription: String? {
        switch self {
        case .disallowedHost(let host):
            return "DoH proxy does not allow host: \(host)"
        case .invalidProviderURL(let url):
            return "Invalid DoH provider URL: \(url)"
        case .emptyAnswer(let host):
            return "DoH returned no address for \(host)"
        case .queryFailed(let host):
            return "DoH query failed for \(host)"
        case .malformedDNSResponse:
            return "DoH returned a malformed DNS response"
        case .malformedHTTPResponse:
            return "DoH returned a malformed HTTP response"
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

    var prefersJSONFormat: Bool {
        guard let path = URL(string: normalizedURL)?.path.lowercased() else {
            return false
        }
        return path.contains("/resolve")
    }

    var wireQueryURL: URL? {
        URL(string: normalizedURL)
    }

    var serverHost: String? {
        URL(string: normalizedURL)?.host
    }

    var serverPort: UInt16? {
        guard let url = URL(string: normalizedURL) else { return nil }
        let port = url.port ?? 443
        guard (1 ... Int(UInt16.max)).contains(port) else { return nil }
        return UInt16(port)
    }

    var bootstrapIPs: [String] {
        guard let host = serverHost?.lowercased() else { return [] }
        switch host {
        case "doh.pub":
            return ["1.12.12.12", "120.53.53.53"]
        case "dns.pub":
            return ["119.29.29.29", "119.28.28.28"]
        case "cloudflare-dns.com":
            return ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
        case "dns.alidns.com":
            return ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"]
        case "dns.quad9.net":
            return ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
        case "dns.google":
            return ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
        default:
            return []
        }
    }

    func wireGETPath(queryBody: Data) -> String? {
        guard let url = URL(string: normalizedURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return nil
        }

        let encodedQuery = queryBody.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        components.scheme = nil
        components.host = nil
        components.port = nil
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { item in item.name == "dns" }
        queryItems.append(URLQueryItem(name: "dns", value: encodedQuery))
        components.queryItems = queryItems
        return components.string
    }

    func jsonQueryURL(host: String, type: String) -> URL? {
        guard var components = URLComponents(string: normalizedURL) else { return nil }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { item in
            item.name == "name" || item.name == "type"
        }
        queryItems.append(URLQueryItem(name: "name", value: host))
        queryItems.append(URLQueryItem(name: "type", value: type))
        components.queryItems = queryItems
        return components.url
    }

    private var normalizedURL: String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://dns.alidns.com/dns-query" }
        if trimmed.contains("://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }
}
