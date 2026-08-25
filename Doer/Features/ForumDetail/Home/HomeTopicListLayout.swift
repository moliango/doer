import UIKit

/// Home topic-row contract. Theme implementations own Cell class, snapshot ids, and detail entry.
/// UIKit calls stay on the main actor; layouts only rearrange existing Home work.
protocol HomeTopicListLayout {
    var kind: HomeViewController.HomeListLayoutKind { get }
    var estimatedRowHeight: CGFloat { get }

    func registerCells(in tableView: UITableView)
    func snapshotItemIdentifiers(
        topics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) -> [Int]
    func cell(
        tableView: UITableView,
        indexPath: IndexPath,
        itemId: Int,
        context: HomeTopicListCellContext
    ) -> UITableViewCell
    func makeTopicDetail(
        api: DiscourseAPI,
        topicId: Int,
        initialFloor: Int?,
        initialPostId: Int?,
        lastReadPostNumber: Int?
    ) -> UIViewController
}

struct HomeTopicListCellContext {
    let viewModel: HomeViewModel
    let api: DiscourseAPI
    let colorFromHex: (String) -> UIColor?
    let onOpenTopic: (Int) -> Void
}

enum HomeTopicListLayoutFactory {
    static func make(style: AppSettings.ThemeStyle) -> any HomeTopicListLayout {
        switch style {
        case .xiaohongshu:
            return XiaohongshuHomeTopicListLayout()
        case .weChat:
            return WeChatHomeTopicListLayout()
        case .telegram:
            return TelegramHomeTopicListLayout()
        case .systemDefault, .eyeCare, .oled:
            return StandardHomeTopicListLayout()
        }
    }
}

enum HomeTopicListLayoutSupport {
    static func registerAllCells(in tableView: UITableView) {
        tableView.register(TopicCell.self, forCellReuseIdentifier: TopicCell.reuseIdentifier)
        tableView.register(CompactPinnedTopicCell.self, forCellReuseIdentifier: CompactPinnedTopicCell.reuseIdentifier)
        tableView.register(XiaohongshuTopicGridCell.self, forCellReuseIdentifier: XiaohongshuTopicGridCell.reuseIdentifier)
        tableView.register(WeChatTopicListCell.self, forCellReuseIdentifier: WeChatTopicListCell.reuseIdentifier)
        tableView.register(TelegramTopicListCell.self, forCellReuseIdentifier: TelegramTopicListCell.reuseIdentifier)
    }

    static func uniqueOrderedIds(
        topics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) -> [Int] {
        let orderedTopics = HomeTopicListOrdering.withPinnedFirst(topics, pinnedIds: pinnedIds)
        var seen = Set<Int>()
        return orderedTopics.compactMap { topic in
            guard seen.insert(topic.id).inserted else { return nil }
            return topic.id
        }
    }

    static func makeTopicDetail(
        api: DiscourseAPI,
        topicId: Int,
        initialFloor: Int?,
        initialPostId: Int?,
        lastReadPostNumber: Int?
    ) -> UIViewController {
        TopicDetailFactory.make(
            api: api,
            topicId: topicId,
            initialFloor: initialFloor,
            initialPostId: initialPostId,
            lastReadPostNumber: lastReadPostNumber
        )
    }

    static func pinnedCell(
        tableView: UITableView,
        indexPath: IndexPath,
        topic: DiscourseTopicList.Topic,
        context: HomeTopicListCellContext
    ) -> UITableViewCell? {
        guard HomeTopicListOrdering.isPinned(topic, pinnedIds: context.viewModel.pinnedTopicIds) else {
            return nil
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: CompactPinnedTopicCell.reuseIdentifier,
            for: indexPath
        ) as? CompactPinnedTopicCell else {
            return UITableViewCell()
        }
        let category = context.viewModel.category(for: topic)
        cell.configure(
            with: topic,
            categoryColor: category.flatMap { context.colorFromHex($0.color) },
            categoryPresentation: context.viewModel.categoryBadgePresentation(for: topic),
            categoryBaseURL: context.api.baseURL
        )
        return cell
    }

    static func avatarURL(for topic: DiscourseTopicList.Topic, context: HomeTopicListCellContext) -> URL? {
        AvatarImageLoader.url(
            from: context.viewModel.avatarTemplate(for: topic),
            baseURL: context.api.baseURL,
            size: AvatarImageLoader.primaryAvatarPixelSize
        )
    }
}

extension HomeTopicListLayout {
    func registerCells(in tableView: UITableView) {
        HomeTopicListLayoutSupport.registerAllCells(in: tableView)
    }

    func makeTopicDetail(
        api: DiscourseAPI,
        topicId: Int,
        initialFloor: Int?,
        initialPostId: Int?,
        lastReadPostNumber: Int?
    ) -> UIViewController {
        HomeTopicListLayoutSupport.makeTopicDetail(
            api: api,
            topicId: topicId,
            initialFloor: initialFloor,
            initialPostId: initialPostId,
            lastReadPostNumber: lastReadPostNumber
        )
    }
}

struct StandardHomeTopicListLayout: HomeTopicListLayout {
    let kind: HomeViewController.HomeListLayoutKind = .standard
    var estimatedRowHeight: CGFloat { TopicCell.estimatedHeight }

    func snapshotItemIdentifiers(
        topics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) -> [Int] {
        HomeTopicListLayoutSupport.uniqueOrderedIds(topics: topics, pinnedIds: pinnedIds)
    }

    func cell(
        tableView: UITableView,
        indexPath: IndexPath,
        itemId: Int,
        context: HomeTopicListCellContext
    ) -> UITableViewCell {
        guard let topic = context.viewModel.topic(id: itemId) else {
            return UITableViewCell()
        }
        if let pinned = HomeTopicListLayoutSupport.pinnedCell(
            tableView: tableView,
            indexPath: indexPath,
            topic: topic,
            context: context
        ) {
            return pinned
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: TopicCell.reuseIdentifier,
            for: indexPath
        ) as? TopicCell else {
            return UITableViewCell()
        }
        let category = context.viewModel.category(for: topic)
        cell.configure(
            with: topic,
            avatarURL: HomeTopicListLayoutSupport.avatarURL(for: topic, context: context),
            avatarUserId: context.viewModel.avatarUserId(for: topic),
            categoryName: context.viewModel.categoryDisplayName(for: category),
            categoryColor: category.flatMap { context.colorFromHex($0.color) },
            tags: topic.tags ?? [],
            categoryPresentation: context.viewModel.categoryBadgePresentation(for: topic),
            categoryBaseURL: context.api.baseURL
        )
        return cell
    }
}

final class XiaohongshuHomeTopicListLayout: HomeTopicListLayout {
    let kind: HomeViewController.HomeListLayoutKind = .xiaohongshu
    private var unpinnedPairs: [(left: DiscourseTopicList.Topic?, right: DiscourseTopicList.Topic?)] = []

    var estimatedRowHeight: CGFloat {
        AppSettings.shared.xiaohongshuCardsStaggered
            ? XiaohongshuTopicGridCell.staggeredEstimatedHeight
            : XiaohongshuTopicGridCell.estimatedHeight
    }

    static func rowIdentifier(for rowIndex: Int) -> Int {
        -(rowIndex + 1)
    }

    static func rowIndex(from identifier: Int) -> Int? {
        guard identifier < 0 else { return nil }
        return abs(identifier) - 1
    }

    func snapshotItemIdentifiers(
        topics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) -> [Int] {
        let orderedTopics = HomeTopicListOrdering.withPinnedFirst(topics, pinnedIds: pinnedIds)
        let pinnedTopicIds = orderedTopics.compactMap { topic -> Int? in
            HomeTopicListOrdering.isPinned(topic, pinnedIds: pinnedIds) ? topic.id : nil
        }
        rebuildUnpinnedPairs(from: orderedTopics, pinnedIds: pinnedIds)
        return pinnedTopicIds + unpinnedPairs.indices.map(Self.rowIdentifier(for:))
    }

    func cell(
        tableView: UITableView,
        indexPath: IndexPath,
        itemId: Int,
        context: HomeTopicListCellContext
    ) -> UITableViewCell {
        if let rowIndex = Self.rowIndex(from: itemId) {
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: XiaohongshuTopicGridCell.reuseIdentifier,
                for: indexPath
            ) as? XiaohongshuTopicGridCell else {
                return UITableViewCell()
            }
            let pair = topicPair(at: rowIndex)
            cell.configure(
                left: pair.left.map { cardModel(for: $0, context: context) },
                right: pair.right.map { cardModel(for: $0, context: context) },
                staggered: AppSettings.shared.xiaohongshuCardsStaggered,
                rowIndex: rowIndex
            )
            cell.onTopicSelected = { topicId in
                context.onOpenTopic(topicId)
            }
            return cell
        }

        guard let topic = context.viewModel.topic(id: itemId) else {
            return UITableViewCell()
        }
        return HomeTopicListLayoutSupport.pinnedCell(
            tableView: tableView,
            indexPath: indexPath,
            topic: topic,
            context: context
        ) ?? UITableViewCell()
    }

    private func topicPair(at rowIndex: Int) -> (left: DiscourseTopicList.Topic?, right: DiscourseTopicList.Topic?) {
        guard unpinnedPairs.indices.contains(rowIndex) else {
            return (nil, nil)
        }
        return unpinnedPairs[rowIndex]
    }

    private func rebuildUnpinnedPairs(
        from orderedTopics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) {
        let unpinned = orderedTopics.filter {
            !HomeTopicListOrdering.isPinned($0, pinnedIds: pinnedIds)
        }
        var pairs: [(left: DiscourseTopicList.Topic?, right: DiscourseTopicList.Topic?)] = []
        pairs.reserveCapacity((unpinned.count + 1) / 2)
        var index = 0
        while index < unpinned.count {
            let left = unpinned[index]
            let right = index + 1 < unpinned.count ? unpinned[index + 1] : nil
            pairs.append((left, right))
            index += 2
        }
        unpinnedPairs = pairs
    }

    private func cardModel(
        for topic: DiscourseTopicList.Topic,
        context: HomeTopicListCellContext
    ) -> XiaohongshuTopicCardModel {
        let category = context.viewModel.category(for: topic)
        return XiaohongshuTopicCardModel(
            id: topic.id,
            title: TitleEmojiRenderer.plainTitle(fancyTitle: topic.fancyTitle, title: topic.title),
            excerpt: topic.excerpt,
            avatarURL: HomeTopicListLayoutSupport.avatarURL(for: topic, context: context),
            avatarUserId: context.viewModel.avatarUserId(for: topic),
            username: context.viewModel.username(for: topic),
            categoryName: context.viewModel.categoryDisplayName(for: category),
            categoryColor: category.flatMap { context.colorFromHex($0.color) },
            categoryPresentation: context.viewModel.categoryBadgePresentation(for: topic),
            categoryBaseURL: context.api.baseURL,
            tags: topic.tags ?? [],
            replyCount: max(topic.postsCount - 1, 0),
            views: topic.views,
            timeText: TopicCell.formatDate(topic.lastPostedAt ?? topic.createdAt),
            isUnread: topic.isUnreadForDisplay
        )
    }
}

struct WeChatHomeTopicListLayout: HomeTopicListLayout {
    let kind: HomeViewController.HomeListLayoutKind = .weChat
    var estimatedRowHeight: CGFloat { WeChatTopicListCell.estimatedHeight }

    func snapshotItemIdentifiers(
        topics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) -> [Int] {
        HomeTopicListLayoutSupport.uniqueOrderedIds(topics: topics, pinnedIds: pinnedIds)
    }

    func cell(
        tableView: UITableView,
        indexPath: IndexPath,
        itemId: Int,
        context: HomeTopicListCellContext
    ) -> UITableViewCell {
        guard let topic = context.viewModel.topic(id: itemId) else {
            return UITableViewCell()
        }
        if let pinned = HomeTopicListLayoutSupport.pinnedCell(
            tableView: tableView,
            indexPath: indexPath,
            topic: topic,
            context: context
        ) {
            return pinned
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: WeChatTopicListCell.reuseIdentifier,
            for: indexPath
        ) as? WeChatTopicListCell else {
            return UITableViewCell()
        }
        let category = context.viewModel.category(for: topic)
        cell.configure(
            with: topic,
            avatarURL: HomeTopicListLayoutSupport.avatarURL(for: topic, context: context),
            avatarUserId: context.viewModel.avatarUserId(for: topic),
            categoryName: context.viewModel.categoryDisplayName(for: category),
            categoryColor: category.flatMap { context.colorFromHex($0.color) },
            tags: topic.tags ?? [],
            categoryPresentation: context.viewModel.categoryBadgePresentation(for: topic),
            categoryBaseURL: context.api.baseURL
        )
        return cell
    }
}

struct TelegramHomeTopicListLayout: HomeTopicListLayout {
    let kind: HomeViewController.HomeListLayoutKind = .telegram
    var estimatedRowHeight: CGFloat { TelegramTopicListCell.estimatedHeight }

    func snapshotItemIdentifiers(
        topics: [DiscourseTopicList.Topic],
        pinnedIds: Set<Int>
    ) -> [Int] {
        HomeTopicListLayoutSupport.uniqueOrderedIds(topics: topics, pinnedIds: pinnedIds)
    }

    func cell(
        tableView: UITableView,
        indexPath: IndexPath,
        itemId: Int,
        context: HomeTopicListCellContext
    ) -> UITableViewCell {
        guard let topic = context.viewModel.topic(id: itemId) else {
            return UITableViewCell()
        }
        if let pinned = HomeTopicListLayoutSupport.pinnedCell(
            tableView: tableView,
            indexPath: indexPath,
            topic: topic,
            context: context
        ) {
            return pinned
        }
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: TelegramTopicListCell.reuseIdentifier,
            for: indexPath
        ) as? TelegramTopicListCell else {
            return UITableViewCell()
        }
        let category = context.viewModel.category(for: topic)
        cell.configure(
            with: topic,
            avatarURL: HomeTopicListLayoutSupport.avatarURL(for: topic, context: context),
            avatarUserId: context.viewModel.avatarUserId(for: topic),
            categoryName: context.viewModel.categoryDisplayName(for: category),
            tags: topic.tags ?? [],
            categoryBaseURL: context.api.baseURL
        )
        return cell
    }
}
