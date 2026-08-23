import Foundation

enum DohHTTPWire {
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
