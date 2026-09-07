import Foundation

/// Lossy Discourse `custom_fields` map. Plugin keys (warden, discourse-reply-cost)
/// arrive as int, string, or bool; only positive integers are kept.
struct DiscourseCustomFields: Equatable, Sendable {
    static let empty = DiscourseCustomFields()

    private var ints: [String: Int] = [:]

    init(values: [String: Int] = [:]) {
        var normalized: [String: Int] = [:]
        for (key, value) in values where value > 0 {
            normalized[key.lowercased()] = value
        }
        ints = normalized
    }

    func int(forKeys keys: [String]) -> Int? {
        for key in keys {
            if let value = ints[key.lowercased()], value > 0 {
                return value
            }
        }
        return nil
    }
}

extension DiscourseCustomFields: Decodable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var values: [String: Int] = [:]
        for key in container.allKeys {
            guard let value = container.decodeLossyInt(forKey: key), value > 0 else { continue }
            values[key.stringValue.lowercased()] = value
        }
        ints = values
    }
}
