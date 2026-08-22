import Foundation

/// DNS HTTPS/SVCB (type 65). SvcParamKey `ech` = 5, matching FluxDo lookupEchConfig.
public enum DohHttpsRecord {
    public static let qtype: UInt16 = 65
    public static let echParamKey: UInt16 = 5

    public struct Parsed: Equatable, Sendable {
        public var priority: UInt16
        public var target: String
        public var echConfig: Data?

        public init(priority: UInt16, target: String, echConfig: Data?) {
            self.priority = priority
            self.target = target
            self.echConfig = echConfig
        }
    }

    public static func parseResourceData(_ rdata: Data) throws -> Parsed {
        guard rdata.count >= 3 else { throw DohProxyError.malformedDNSResponse }
        var offset = 0
        let priority = readUInt16(rdata, at: offset)
        offset += 2
        let target = try readName(rdata, offset: &offset)
        var ech: Data?
        while offset + 4 <= rdata.count {
            let key = readUInt16(rdata, at: offset)
            offset += 2
            let length = Int(readUInt16(rdata, at: offset))
            offset += 2
            guard offset + length <= rdata.count else { throw DohProxyError.malformedDNSResponse }
            let value = rdata.subdata(in: offset ..< offset + length)
            offset += length
            if key == echParamKey, !value.isEmpty {
                ech = value
            }
        }
        return Parsed(priority: priority, target: target, echConfig: ech)
    }

    public static func firstECHConfig(from answers: [Data]) -> Data? {
        for rdata in answers {
            if let parsed = try? parseResourceData(rdata), let ech = parsed.echConfig, !ech.isEmpty {
                return ech
            }
        }
        return nil
    }

    private static func readName(_ data: Data, offset: inout Int) throws -> String {
        var labels: [String] = []
        var jumped = false
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
                jumped = true
                break
            }
            local += 1
            let end = local + Int(length)
            guard end <= data.count,
                  let label = String(data: data.subdata(in: local ..< end), encoding: .utf8)
            else { throw DohProxyError.malformedDNSResponse }
            labels.append(label)
            local = end
        }
        if !jumped {
            offset = local
        }
        return labels.joined(separator: ".")
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
