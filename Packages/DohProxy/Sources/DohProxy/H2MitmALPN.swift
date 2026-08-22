import Foundation

public enum H2MitmALPN {
    public static func protocols(h2Enabled: Bool) -> [String] {
        h2Enabled ? ["h2", "http/1.1"] : ["http/1.1"]
    }

    public static func locksHTTP1(_ protocols: [String]) -> Bool {
        protocols == ["http/1.1"]
    }
}
