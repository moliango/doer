import UIKit

/// Visual chrome for chat-style surfaces (WeChat / Telegram).
/// Shared by Home session list + Topic Detail chat VC/cells; encodes look & metrics only.
enum ChatTopicStyle: Equatable {
    case weChat
    case telegram

    static var current: ChatTopicStyle? {
        switch AppSettings.shared.themeStyle {
        case .weChat: return .weChat
        case .telegram: return .telegram
        default: return nil
        }
    }

    // MARK: - Topic Detail bubbles

    var avatarSize: CGFloat {
        switch self {
        case .weChat: return 40
        case .telegram: return 32 // TG group chat compact circle
        }
    }

    var avatarCornerRadius: CGFloat {
        switch self {
        case .weChat: return 4
        case .telegram: return avatarSize / 2 // circular
        }
    }

    var bubbleCornerRadius: CGFloat {
        switch self {
        case .weChat: return 8
        case .telegram: return 18
        }
    }

    var bubblePadding: CGFloat {
        switch self {
        case .weChat: return 10
        case .telegram: return 9
        }
    }

    /// Max fraction of row width the bubble may occupy.
    var maxBubbleFraction: CGFloat {
        switch self {
        case .weChat: return 0.92
        case .telegram: return 0.90
        }
    }

    var chatBackgroundColor: UIColor {
        switch self {
        case .weChat:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
                    : UIColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1) // #EDEDED
            }
        case .telegram:
            // Telegram default chat wallpaper stand-in — softer neutral gray that matches real Telegram mobile app canvas (not blue-tinted).
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.055, green: 0.086, blue: 0.129, alpha: 1) // #0E1621
                    : UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1) // softer TG gray
            }
        }
    }

    func outgoingBubbleColor(isDark: Bool) -> UIColor {
        switch self {
        case .weChat:
            return UIColor(red: 0.58, green: 0.91, blue: 0.45, alpha: 1)
        case .telegram:
            // Official-ish outgoing mint (#EEFFDE) / dark blue (#2B5278)
            return isDark
                ? UIColor(red: 0.17, green: 0.32, blue: 0.47, alpha: 1)
                : UIColor(red: 0.933, green: 1.0, blue: 0.871, alpha: 1) // #EEFFDE
        }
    }

    func incomingBubbleColor(isDark: Bool) -> UIColor {
        switch self {
        case .weChat:
            return isDark
                ? UIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)
                : UIColor.white
        case .telegram:
            return isDark
                ? UIColor(red: 0.094, green: 0.145, blue: 0.20, alpha: 1) // #182533
                : UIColor.white
        }
    }

    /// In-bubble timestamp color.
    func bubbleTimeColor(isMine: Bool, isDark: Bool) -> UIColor {
        switch self {
        case .weChat:
            return .tertiaryLabel
        case .telegram:
            if isMine {
                return isDark
                    ? UIColor.white.withAlphaComponent(0.55)
                    : UIColor(red: 0.40, green: 0.62, blue: 0.38, alpha: 1)
            }
            return isDark
                ? UIColor.white.withAlphaComponent(0.45)
                : UIColor(red: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        }
    }

    /// Text color on outgoing (own) bubbles.
    func outgoingTextColor(isDark: Bool) -> UIColor {
        switch self {
        case .weChat:
            return UIColor.black.withAlphaComponent(0.9)
        case .telegram:
            return isDark ? UIColor.white.withAlphaComponent(0.95) : UIColor.black.withAlphaComponent(0.9)
        }
    }

    /// Link color inside outgoing bubbles.
    func outgoingLinkColor(isDark: Bool) -> UIColor {
        switch self {
        case .weChat:
            return UIColor(red: 0.05, green: 0.35, blue: 0.75, alpha: 1)
        case .telegram:
            return isDark
                ? UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)
                : UIColor(red: 0.10, green: 0.45, blue: 0.85, alpha: 1)
        }
    }

    var accentColor: UIColor {
        switch self {
        case .weChat:
            return UIColor(red: 0.027, green: 0.757, blue: 0.376, alpha: 1)
        case .telegram:
            return UIColor(red: 0.20, green: 0.56, blue: 0.93, alpha: 1) // #3390EC
        }
    }

    /// Like / bookmark (and other toggles) idle vs active. Active follows theme accent.
    func actionTintColor(isActive: Bool) -> UIColor {
        isActive ? accentColor : .secondaryLabel
    }

    /// Telegram group-chat style: stable color per username seed.
    func nameColor(for seed: String) -> UIColor {
        switch self {
        case .weChat:
            return .secondaryLabel
        case .telegram:
            let palette: [UIColor] = [
                UIColor(red: 0.86, green: 0.34, blue: 0.34, alpha: 1), // red
                UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1), // orange
                UIColor(red: 0.55, green: 0.70, blue: 0.15, alpha: 1), // olive
                UIColor(red: 0.20, green: 0.70, blue: 0.45, alpha: 1), // green
                UIColor(red: 0.20, green: 0.62, blue: 0.86, alpha: 1), // blue
                UIColor(red: 0.45, green: 0.45, blue: 0.90, alpha: 1), // indigo
                UIColor(red: 0.75, green: 0.35, blue: 0.75, alpha: 1), // purple
            ]
            var hash: UInt64 = 5381
            for byte in seed.utf8 {
                hash = ((hash << 5) &+ hash) &+ UInt64(byte)
            }
            return palette[Int(hash % UInt64(palette.count))]
        }
    }

    /// Own-message avatar is hidden in Telegram (group-chat look); WeChat keeps it.
    var showsOutgoingAvatar: Bool {
        switch self {
        case .weChat: return true
        case .telegram: return false
        }
    }

    var inputBarBackgroundColor: UIColor {
        switch self {
        case .weChat:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.11, alpha: 1)
                    : UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
            }
        case .telegram:
            // Matches chat canvas so the bar feels flush with wallpaper.
            return chatBackgroundColor
        }
    }

    var inputFieldBackgroundColor: UIColor {
        switch self {
        case .weChat:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(white: 0.18, alpha: 1)
                    : UIColor.white
            }
        case .telegram:
            return UIColor { trait in
                trait.userInterfaceStyle == .dark
                    ? UIColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1)
                    : UIColor.white
            }
        }
    }

    var inputFieldCornerRadius: CGFloat {
        switch self {
        case .weChat: return 10
        case .telegram: return 20
        }
    }

    var inputPlaceholder: String {
        switch self {
        case .weChat:
            return String(localized: "wechat_chat.input_placeholder", defaultValue: "回复…")
        case .telegram:
            return String(localized: "telegram_chat.input_placeholder", defaultValue: "Message")
        }
    }

    /// SF Symbol for trailing WeChat plus / Telegram empty-state mic.
    var trailingActionSystemName: String {
        switch self {
        case .weChat: return "plus.circle"
        case .telegram: return "mic"
        }
    }

    /// SF Symbol for Telegram attach (leading).
    var leadingActionSystemName: String {
        switch self {
        case .weChat: return "plus.circle"
        case .telegram: return "paperclip"
        }
    }

    /// SF Symbol for Telegram circular send.
    var sendActionSystemName: String {
        "arrow.up.circle.fill"
    }

    // MARK: - Home session list

    var listAvatarCornerRadius: CGFloat {
        switch self {
        case .weChat: return 6
        case .telegram: return 30 // 60pt circle — matches TelegramTopicListCell
        }
    }

    var listAvatarSize: CGFloat {
        switch self {
        case .weChat: return 48
        case .telegram: return 60
        }
    }

    var listEstimatedRowHeight: CGFloat {
        switch self {
        case .weChat: return 76
        case .telegram: return 78
        }
    }
}

/// Compact date+time under WeChat / Telegram avatars so a scrolled-to message still shows the calendar day.
enum ChatAvatarTimestamp {
    /// Two-line stamp: `M/d` (or `yyyy/M/d` across years) + `HH:mm`.
    static func text(forCreatedAt iso: String?, now: Date = Date()) -> String {
        guard let parts = dateAndTime(iso: iso, now: now) else { return "" }
        return parts.date + "\n" + parts.time
    }

    /// Single-line stamp when there is no avatar gutter (Telegram outgoing).
    static func compactText(forCreatedAt iso: String?, now: Date = Date()) -> String {
        guard let parts = dateAndTime(iso: iso, now: now) else { return "" }
        return parts.date + " " + parts.time
    }

    private static func dateAndTime(iso: String?, now: Date) -> (date: String, time: String)? {
        guard let iso, let date = parseISODate(iso) else { return nil }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = .current
        timeFormatter.dateFormat = "HH:mm"
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .current
        dateFormatter.dateFormat = Calendar.current.component(.year, from: date)
            == Calendar.current.component(.year, from: now)
            ? "M/d"
            : "yyyy/M/d"
        return (dateFormatter.string(from: date), timeFormatter.string(from: date))
    }

    fileprivate static func parseISODate(_ iso: String) -> Date? {
        let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        // ISO8601DateFormatter rejects 1/2/6-digit fractional seconds; strip them and retry.
        if let dot = trimmed.firstIndex(of: ".") {
            var suffix = trimmed[trimmed.index(after: dot)...]
            while let first = suffix.first, first.isNumber {
                suffix = suffix.dropFirst()
            }
            let stripped = String(trimmed[..<dot]) + suffix
            if let date = plain.date(from: stripped) { return date }
            if let date = withFraction.date(from: stripped) { return date }
        }
        return nil
    }
}

enum ChatDateSeparator {
    static func text(forCreatedAt current: String, previousCreatedAt: String?) -> String? {
        let currentDay = dayKey(fromISO: current)
        guard let currentDay else { return nil }
        if let previousCreatedAt, dayKey(fromISO: previousCreatedAt) == currentDay {
            return nil
        }
        return friendlyDayLabel(fromISO: current)
    }

    private static func dayKey(fromISO iso: String) -> String? {
        guard let date = parseISODate(iso) else { return nil }
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day else { return nil }
        return "\(y)-\(m)-\(d)"
    }

    private static func friendlyDayLabel(fromISO iso: String) -> String? {
        guard let date = parseISODate(iso) else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return String(localized: "telegram_chat.today", defaultValue: "今天")
        }
        if cal.isDateInYesterday(date) {
            return String(localized: "telegram_chat.yesterday", defaultValue: "昨天")
        }
        let df = DateFormatter()
        df.locale = .current
        df.setLocalizedDateFormatFromTemplate("MMMd")
        return df.string(from: date)
    }

    private static func parseISODate(_ iso: String) -> Date? {
        ChatAvatarTimestamp.parseISODate(iso)
    }
}


