import UIKit

/// List chrome shared by Home-adjacent screens (notifications, chat, bookmarks, history, read-later).
enum TopicListLayoutKind: Hashable {
    case standard
    case weChat
    case telegram
    case xiaohongshu

    static var current: TopicListLayoutKind {
        switch AppSettings.shared.themeStyle {
        case .weChat: return .weChat
        case .telegram: return .telegram
        case .xiaohongshu: return .xiaohongshu
        case .systemDefault, .eyeCare, .oled, .kraftPaper: return .standard
        }
    }

    var usesChatSessionRows: Bool {
        switch self {
        case .weChat, .telegram: return true
        case .standard, .xiaohongshu: return false
        }
    }

    var estimatedRowHeight: CGFloat {
        switch self {
        case .weChat: return WeChatTopicListCell.estimatedHeight
        case .telegram: return TelegramTopicListCell.estimatedHeight
        case .xiaohongshu: return XiaohongshuTopicGridCell.estimatedHeight
        case .standard: return TopicCell.estimatedHeight
        }
    }
}

/// Generic session-list row payload (notifications / bookmarks / channels).
struct TopicListSessionItem {
    var title: String
    var subtitle: String?
    var timeText: String?
    var avatarURL: URL?
    var avatarTemplate: String?
    var isEmphasized: Bool
    var badgeText: String?
    var baseURL: String?
    /// Letter-tile fallback when the session has no avatar or category logo.
    var monogramText: String?
    var monogramColor: UIColor?
    var monogramForegroundColor: UIColor?

    init(
        title: String,
        subtitle: String? = nil,
        timeText: String? = nil,
        avatarURL: URL? = nil,
        avatarTemplate: String? = nil,
        isEmphasized: Bool = false,
        badgeText: String? = nil,
        baseURL: String? = nil,
        monogramText: String? = nil,
        monogramColor: UIColor? = nil,
        monogramForegroundColor: UIColor? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.timeText = timeText
        self.avatarURL = avatarURL
        self.avatarTemplate = avatarTemplate
        self.isEmphasized = isEmphasized
        self.badgeText = badgeText
        self.baseURL = baseURL
        self.monogramText = monogramText
        self.monogramColor = monogramColor
        self.monogramForegroundColor = monogramForegroundColor
    }
}

/// Topic-row payload for history / read-later style lists.
struct TopicListTopicContext {
    var topic: DiscourseTopicList.Topic
    var avatarURL: URL?
    var avatarUserId: Int?
    var categoryName: String?
    var categoryColor: UIColor?
    var tags: [String]
    var categoryPresentation: TopicCategoryBadgePresentation?
    var categoryBaseURL: String?

    init(
        topic: DiscourseTopicList.Topic,
        avatarURL: URL?,
        avatarUserId: Int? = nil,
        categoryName: String?,
        categoryColor: UIColor?,
        tags: [String] = [],
        categoryPresentation: TopicCategoryBadgePresentation? = nil,
        categoryBaseURL: String? = nil
    ) {
        self.topic = topic
        self.avatarURL = avatarURL
        self.avatarUserId = avatarUserId
        self.categoryName = categoryName
        self.categoryColor = categoryColor
        self.tags = tags
        self.categoryPresentation = categoryPresentation
        self.categoryBaseURL = categoryBaseURL
    }
}

enum TopicListCellFactory {
    static var layoutKind: TopicListLayoutKind { .current }

    static var estimatedRowHeight: CGFloat { TopicListLayoutKind.current.estimatedRowHeight }

    static func registerCells(on tableView: UITableView) {
        tableView.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        tableView.register(CompactPinnedTopicCell.self, forCellReuseIdentifier: CompactPinnedTopicCell.reuseIdentifier)
        tableView.register(WeChatTopicListCell.self, forCellReuseIdentifier: WeChatTopicListCell.reuseIdentifier)
        tableView.register(TelegramTopicListCell.self, forCellReuseIdentifier: TelegramTopicListCell.reuseIdentifier)
    }

    static func makeSessionCell(
        tableView: UITableView,
        indexPath: IndexPath,
        item: TopicListSessionItem,
        layout: TopicListLayoutKind = .current
    ) -> UITableViewCell {
        switch layout {
        case .telegram:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: TelegramTopicListCell.reuseIdentifier,
                for: indexPath
            ) as? TelegramTopicListCell else {
                return UITableViewCell()
            }
            cell.configure(session: item)
            return cell
        case .weChat, .standard, .xiaohongshu:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: WeChatTopicListCell.reuseIdentifier,
                for: indexPath
            ) as? WeChatTopicListCell else {
                return UITableViewCell()
            }
            cell.configure(session: item)
            return cell
        }
    }

    static func makeTopicCell(
        tableView: UITableView,
        indexPath: IndexPath,
        context: TopicListTopicContext,
        layout: TopicListLayoutKind = .current
    ) -> UITableViewCell {
        switch layout {
        case .telegram:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: TelegramTopicListCell.reuseIdentifier,
                for: indexPath
            ) as? TelegramTopicListCell else {
                return UITableViewCell()
            }
            cell.configure(
                with: context.topic,
                avatarURL: context.avatarURL,
                avatarUserId: context.avatarUserId,
                categoryName: context.categoryName,
                tags: context.tags,
                categoryBaseURL: context.categoryBaseURL
            )
            return cell
        case .weChat:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: WeChatTopicListCell.reuseIdentifier,
                for: indexPath
            ) as? WeChatTopicListCell else {
                return UITableViewCell()
            }
            cell.configure(
                with: context.topic,
                avatarURL: context.avatarURL,
                avatarUserId: context.avatarUserId,
                categoryName: context.categoryName,
                categoryColor: context.categoryColor,
                tags: context.tags,
                categoryPresentation: context.categoryPresentation,
                categoryBaseURL: context.categoryBaseURL
            )
            return cell
        case .standard, .xiaohongshu:
            if context.topic.pinned == true {
                return makePinnedCell(tableView: tableView, indexPath: indexPath, context: context)
            }
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: TopicCell.reuseIdentifier,
                for: indexPath
            ) as? TopicCell else {
                return UITableViewCell()
            }
            cell.configure(
                with: context.topic,
                avatarURL: context.avatarURL,
                avatarUserId: context.avatarUserId,
                categoryName: context.categoryName,
                categoryColor: context.categoryColor,
                tags: context.tags,
                categoryPresentation: context.categoryPresentation,
                categoryBaseURL: context.categoryBaseURL
            )
            return cell
        }
    }

    /// Same Home topic-row chrome, allocated outside a table (related-topic footer).
    static func makeStandaloneTopicCell(context: TopicListTopicContext) -> UITableViewCell {
        let cell: UITableViewCell
        switch TopicListLayoutKind.current {
        case .telegram:
            let row = TelegramTopicListCell(style: .default, reuseIdentifier: nil)
            row.configure(
                with: context.topic,
                avatarURL: context.avatarURL,
                avatarUserId: context.avatarUserId,
                categoryName: context.categoryName,
                tags: context.tags,
                categoryBaseURL: context.categoryBaseURL
            )
            cell = row
        case .weChat:
            let row = WeChatTopicListCell(style: .default, reuseIdentifier: nil)
            row.configure(
                with: context.topic,
                avatarURL: context.avatarURL,
                avatarUserId: context.avatarUserId,
                categoryName: context.categoryName,
                categoryColor: context.categoryColor,
                tags: context.tags,
                categoryPresentation: context.categoryPresentation,
                categoryBaseURL: context.categoryBaseURL
            )
            cell = row
        case .standard, .xiaohongshu:
            let row = TopicCell(style: .default, reuseIdentifier: nil)
            row.configure(
                with: context.topic,
                avatarURL: context.avatarURL,
                avatarUserId: context.avatarUserId,
                categoryName: context.categoryName,
                categoryColor: context.categoryColor,
                tags: context.tags,
                categoryPresentation: context.categoryPresentation,
                categoryBaseURL: context.categoryBaseURL
            )
            cell = row
        }
        cell.selectionStyle = .none
        cell.isUserInteractionEnabled = false
        return cell
    }

    private static func makePinnedCell(
        tableView: UITableView,
        indexPath: IndexPath,
        context: TopicListTopicContext
    ) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: CompactPinnedTopicCell.reuseIdentifier,
            for: indexPath
        ) as? CompactPinnedTopicCell else {
            return UITableViewCell()
        }
        cell.configure(
            with: context.topic,
            categoryColor: context.categoryColor,
            categoryPresentation: context.categoryPresentation,
            categoryBaseURL: context.categoryBaseURL
        )
        return cell
    }
}
