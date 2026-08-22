import Foundation

public enum DohDNSMessage {
    public static let typeA: UInt16 = 1
    public static let typeAAAA: UInt16 = 28
    public static let typeHTTPS: UInt16 = 65

    public struct Resource: Equatable, Sendable {
        public var type: UInt16
        public var ttl: Int
        public var rdata: Data
    }

    public static func clampTTL(_ seconds: Int) -> TimeInterval {
        TimeInterval(max(60, min(seconds == 0 ? 300 : seconds, 1800)))
    }

    public static func makeQuery(host: String, type: UInt16) -> Data? {
        var data = Data()
        appendUInt16(UInt16.random(in: 0 ... .max), to: &data)
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
        appendUInt16(type, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    public static func parseResources(_ data: Data, expectedType: UInt16) throws -> [Resource] {
        guard data.count >= 12 else { throw DohProxyError.malformedDNSResponse }
        var offset = 4
        let qdCount = Int(readUInt16(data, at: offset))
        offset += 2
        let anCount = Int(readUInt16(data, at: offset))
        offset = 12
        for _ in 0 ..< qdCount {
            try skipName(data, offset: &offset)
            guard offset + 4 <= data.count else { throw DohProxyError.malformedDNSResponse }
            offset += 4
        }
        var records: [Resource] = []
        for _ in 0 ..< anCount {
            try skipName(data, offset: &offset)
            guard offset + 10 <= data.count else { throw DohProxyError.malformedDNSResponse }
            let answerType = readUInt16(data, at: offset)
            offset += 2
            let answerClass = readUInt16(data, at: offset)
            offset += 2
            let ttl = Int(readUInt32(data, at: offset))
            offset += 4
            let rdLength = Int(readUInt16(data, at: offset))
            offset += 2
            guard offset + rdLength <= data.count else { throw DohProxyError.malformedDNSResponse }
            let rdata = data.subdata(in: offset ..< offset + rdLength)
            offset += rdLength
            if answerClass == 1, answerType == expectedType {
                records.append(Resource(type: answerType, ttl: ttl, rdata: rdata))
            }
        }
        return records
    }

    public static func ipv4String(from rdata: Data) -> String? {
        guard rdata.count == 4 else { return nil }
        return rdata.map(String.init).joined(separator: ".")
    }

    public static func ipv6String(from rdata: Data) -> String? {
        guard rdata.count == 16 else { return nil }
        return stride(from: 0, to: 16, by: 2)
            .map { String(format: "%x", readUInt16(rdata, at: $0)) }
            .joined(separator: ":")
    }

    public static func wireGETPath(url: String, query: Data) -> String? {
        guard let parsed = URL(string: url),
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
        else { return nil }
        let encoded = query.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.scheme = nil
        components.host = nil
        components.port = nil
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "dns" }
        items.append(URLQueryItem(name: "dns", value: encoded))
        components.queryItems = items
        return components.string
    }

    static func skipName(_ data: Data, offset: inout Int) throws {
        var local = offset
        var hops = 0
        while true {
            guard local < data.count, hops < 16 else { throw DohProxyError.malformedDNSResponse }
            hops += 1
            let length = data[local]
            if length == 0 {
                local += 1
                break
            }
            if length & 0xC0 == 0xC0 {
                guard local + 1 < data.count else { throw DohProxyError.malformedDNSResponse }
                local += 2
                offset = local
                return
            }
            local += 1 + Int(length)
        }
        offset = local
    }

    static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
