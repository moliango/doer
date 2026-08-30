import Foundation

/// Local list of usernames whose activity is aggregated on the Seeking page.
enum SeekingStore {
    private static let defaultsKey = "seeking.monitoredUsernames"

    static func usernames(for baseURL: String) -> [String] {
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        return normalized(raw[key(for: baseURL)] ?? [])
    }

    static func setUsernames(_ names: [String], for baseURL: String) {
        var raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        raw[key(for: baseURL)] = normalized(names)
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }

    static func add(_ username: String, for baseURL: String) -> [String] {
        var names = usernames(for: baseURL)
        let value = normalize(username)
        guard !value.isEmpty else { return names }
        if !names.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            names.append(value)
            setUsernames(names, for: baseURL)
        }
        return names
    }

    static func remove(_ username: String, for baseURL: String) -> [String] {
        let names = usernames(for: baseURL).filter {
            $0.caseInsensitiveCompare(normalize(username)) != .orderedSame
        }
        setUsernames(names, for: baseURL)
        return names
    }

    static func normalize(_ username: String) -> String {
        username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
    }

    private static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let value = normalize(name)
            let key = value.lowercased()
            guard !value.isEmpty, seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func key(for baseURL: String) -> String {
        baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}
