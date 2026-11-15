import Foundation

enum DohHTTPWire {
    /// 一条完整响应的正文，以及它在缓冲区里占了多少字节。
    struct Message {
        var body: Data
        /// 从缓冲区起点算起，这条响应（头 + 正文 + 分块尾巴）的总长度。
        var consumed: Int
        /// 服务端要求关闭连接（`Connection: close`），不能放回连接池。
        var closeConnection: Bool
    }

    /// 按 Content-Length / chunked 精确切出一条响应。
    ///
    /// keep-alive 复用连接需要知道「这条响应到哪结束」，`extractBody` 做不到
    /// 这一点（无长度信息时它只能等连接关闭）。返回 nil 表示还没收全。
    static func parseMessage(_ data: Data) throws -> Message? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: data.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .ascii) else {
            throw DohProxyError.malformedHTTPResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw DohProxyError.queryFailed("DoH empty status")
        }
        guard statusLine.contains(" 200 ") else {
            throw DohProxyError.queryFailed(statusLine)
        }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let separatorIndex = line.firstIndex(of: ":") else { return }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[name] = value
        }
        let closeConnection = headers["connection"]?.lowercased().contains("close") == true
        let bodyStart = data.distance(from: data.startIndex, to: headerRange.upperBound)
        let bodyBytes = data.count - bodyStart

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let chunked = try decodeChunked(data, bodyOffset: bodyStart) else { return nil }
            return Message(body: chunked.body, consumed: chunked.consumed, closeConnection: closeConnection)
        }
        if let contentLengthText = headers["content-length"], let contentLength = Int(contentLengthText) {
            guard bodyBytes >= contentLength else { return nil }
            let start = data.startIndex + bodyStart
            return Message(
                body: data.subdata(in: start ..< start + contentLength),
                consumed: bodyStart + contentLength,
                closeConnection: closeConnection
            )
        }
        // 没有长度信息就只能等对端关连接，这种响应不放进池子。
        return nil
    }

    /// 从 `bodyOffset` 开始解分块，返回解码正文和整条响应的消耗长度。
    private static func decodeChunked(
        _ data: Data,
        bodyOffset: Int
    ) throws -> (body: Data, consumed: Int)? {
        var offset = data.startIndex + bodyOffset
        var decoded = Data()
        while true {
            guard let lineEnd = data.range(of: Data([13, 10]), in: offset ..< data.endIndex) else {
                return nil
            }
            guard let sizeLine = String(data: data.subdata(in: offset ..< lineEnd.lowerBound), encoding: .ascii),
                  let chunkSize = Int(sizeLine.split(separator: ";").first ?? "", radix: 16)
            else {
                throw DohProxyError.malformedHTTPResponse
            }
            offset = lineEnd.upperBound
            if chunkSize == 0 {
                // 收尾的 CRLF 也吃掉，这样 consumed 才能和缓冲区长度对上，
                // 连接才放得回池子。带 trailer 的响应会少算，代价只是不复用。
                if offset + 2 <= data.endIndex, data[offset] == 13, data[offset + 1] == 10 {
                    offset += 2
                }
                return (decoded, data.distance(from: data.startIndex, to: offset))
            }
            guard offset + chunkSize + 2 <= data.endIndex else { return nil }
            decoded.append(data.subdata(in: offset ..< offset + chunkSize))
            offset += chunkSize
            guard offset + 2 <= data.endIndex, data[offset] == 13, data[offset + 1] == 10 else {
                throw DohProxyError.malformedHTTPResponse
            }
            offset += 2
        }
    }

    static func extractBody(from data: Data, requireComplete: Bool) throws -> Data? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: data.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .ascii) else {
            throw DohProxyError.malformedHTTPResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw DohProxyError.queryFailed("DoH empty status")
        }
        guard statusLine.contains(" 200 ") else {
            throw DohProxyError.queryFailed(statusLine)
        }
        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let separatorIndex = line.firstIndex(of: ":") else { return }
            let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            result[name] = value
        }
        let body = data.subdata(in: headerRange.upperBound ..< data.endIndex)
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return try decodeChunked(body, requireComplete: requireComplete)
        }
        if let contentLengthText = headers["content-length"], let contentLength = Int(contentLengthText) {
            guard body.count >= contentLength else { return nil }
            return body.subdata(in: body.startIndex ..< body.startIndex + contentLength)
        }
        return requireComplete ? body : nil
    }

    private static func decodeChunked(_ data: Data, requireComplete: Bool) throws -> Data? {
        var offset = data.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = data.range(of: Data([13, 10]), in: offset ..< data.endIndex) else {
                return nil
            }
            guard let sizeLine = String(data: data.subdata(in: offset ..< lineEnd.lowerBound), encoding: .ascii),
                  let chunkSize = Int(sizeLine.split(separator: ";").first ?? "", radix: 16)
            else {
                throw DohProxyError.malformedHTTPResponse
            }
            offset = lineEnd.upperBound
            if chunkSize == 0 { return decoded }
            guard offset + chunkSize + 2 <= data.endIndex else { return requireComplete ? nil : nil }
            decoded.append(data.subdata(in: offset ..< offset + chunkSize))
            offset += chunkSize
            guard offset + 2 <= data.endIndex, data[offset] == 13, data[offset + 1] == 10 else {
                throw DohProxyError.malformedHTTPResponse
            }
            offset += 2
        }
    }
}
