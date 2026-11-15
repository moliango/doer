import Foundation

nonisolated enum DohDebugLog {
    private static let lock = NSLock()
    private static let maxLines = 500
    private static var entries: [String] = []
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    /// `DateFormatter.string(from:)` 是微秒级开销，而隧道热路径（每条连接、
    /// 每段数据）都会记一行。同一毫秒内复用上一次的字符串。
    private static var lastStampAt: Date?
    private static var lastStamp = ""

    static func record(_ message: String, subsystem: String = "DoH") {
        lock.lock()
        let stamp = timestamp(for: Date())
        let line = "\(stamp) [\(subsystem)] \(message)"
        entries.append(line)
        if entries.count > maxLines {
            entries.removeFirst(entries.count - maxLines)
        }
        lock.unlock()

        #if DEBUG
        print(line)
        #endif
    }

    /// 仅锁内调用。
    private static func timestamp(for date: Date) -> String {
        if let lastStampAt, date.timeIntervalSince(lastStampAt) < 0.001 {
            return lastStamp
        }
        lastStamp = formatter.string(from: date)
        lastStampAt = date
        return lastStamp
    }

    static func snapshot() -> String {
        lock.lock()
        let text = entries.joined(separator: "\n")
        lock.unlock()
        return text
    }

    static func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
