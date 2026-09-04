# Design — Home theme layout + chat topic detail subclasses

## Architecture

Two surfaces, two shapes:

1. **Home topic list** — one `HomeViewController` + `HomeTopicListLayout` protocol. Theme change swaps the layout object in place.
2. **Chat topic detail** — `ChatTopicDetailViewController` parent + `WeChatTopicDetailViewController` / `TelegramTopicDetailViewController` subclasses. Factory picks the subclass at push time. An already-open page is not replaced when the theme changes.

Classic `TopicDetailViewController` stays a sibling of the chat parent, selected by `TopicDetailFactory` when `prefersChatTopicDetail` is false.

```
HomeViewController
  └─ topicListLayout: HomeTopicListLayout
        ├─ StandardHomeTopicListLayout   (systemDefault, eyeCare)
        ├─ XiaohongshuHomeTopicListLayout
        ├─ WeChatHomeTopicListLayout
        └─ TelegramHomeTopicListLayout

TopicDetailFactory.make
  ├─ !prefersChatTopicDetail → TopicDetailViewController
  └─ prefersChatTopicDetail
        ├─ .weChat    → WeChatTopicDetailViewController
        └─ .telegram  → TelegramTopicDetailViewController
        └─ other chat → WeChatTopicDetailViewController (fallback)
```

## Home contract

```swift
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

enum HomeTopicListLayoutFactory {
    static func make(style: AppSettings.ThemeStyle) -> HomeTopicListLayout
}
```

`HomeTopicListCellContext` carries `HomeViewModel` lookup, `api.baseURL`, open-topic callback, and pinned ids. Xiaohongshu pair cache lives on the xiaohongshu layout object (or a small helper it owns), not on `HomeViewController`.

`makeTopicDetail` delegates to `TopicDetailFactory` so Home call sites (`openTopic`, notifications, composer) go through the layout instead of repeating factory arguments.

WeChat and Telegram list layouts share a helper for session-row configuration; they only differ by cell class (`WeChatTopicListCell` vs `TelegramTopicListCell`) and estimated height. Standard and eye-care share `StandardHomeTopicListLayout`. Pinned compact cells stay in the shared helper used by every layout except where snapshot ids are grid rows.

`handleSettingsChanged` rebuilds `topicListLayout` from `HomeTopicListLayoutFactory.make(style:)` then applies snapshot as today.

## Chat detail contract

Rename the lifecycle type to `ChatTopicDetailViewController` (today’s `WeChatTopicDetailViewController` body). It stays `ObservableViewController` and keeps load, pagination, gestures, Cloudflare, ViewModel, reading tracker.

Subclasses implement theme hooks (template methods). Parent never reads `ChatTopicStyle.current` or branches on `.telegram`.

```swift
class ChatTopicDetailViewController: ObservableViewController {
    func chatThemeStyle() -> ChatTopicStyle { preconditionFailure("subclass") }
    func dateSeparatorText(for post: DiscourseTopicDetail.Post, at row: Int) -> String? { nil }
    func incomingLinkColor(defaultColor: UIColor) -> UIColor { defaultColor }
    func applyChatCanvas(to tableView: UITableView) { /* uses chatThemeStyle() */ }
}

final class WeChatTopicDetailViewController: ChatTopicDetailViewController {
    override func chatThemeStyle() -> ChatTopicStyle { .weChat }
}

final class TelegramTopicDetailViewController: ChatTopicDetailViewController {
    override func chatThemeStyle() -> ChatTopicStyle { .telegram }
    override func dateSeparatorText(...) -> String? { /* existing telegram separator */ }
    override func incomingLinkColor(defaultColor:) -> UIColor { chatThemeStyle().accentColor }
}
```

`WeChatChatPostCell` and `WeChatChatInputBar` take an explicit `ChatTopicStyle` from the parent (the subclass’s `chatThemeStyle()`), not `ChatTopicStyle.current`. That keeps cells shared. We do not split those cells into subclasses in this task.

Type checks (`ForumContainerViewController`, `ForumTabBarController`, `SettingsNavigationHelpers`) use `is ChatTopicDetailViewController` so both subclasses are covered. Cloudflare handler stays on the parent.

## Compatibility

- Theme change on Home: same VC, new layout object, snapshot reload if `kind` changed (existing `lastAppliedHomeListLayoutKind` path).
- Theme change while chat detail is open: no VC replace; next `TopicDetailFactory.make` uses the new subclass.
- `ChatTopicStyle` remains the metrics bag (colors, radii, input icons). Subclasses pick a case; they do not duplicate color tables.
- Public class name `WeChatTopicDetailViewController` remains as the WeChat subclass so existing file/type references can move in a controlled rename: parent gets the new name, WeChat subclass keeps the old name.

## Trade-offs

- Home uses protocol objects rather than VC subclasses so tab identity and in-flight `loadMore` survive theme changes.
- Chat detail uses VC subclasses as requested. Cost is factory + type-check updates; benefit is a closed set of override points for the next chat theme.
- Not extracting `WeChatChatPostCell` into two classes avoids a second 1k-line split; style is injected.

## Rollback

Revert the new layout types and restore Home `switch` / `WeChatTopicDetailViewController` as a standalone class. Factory and `is ChatTopicDetailViewController` checks are the main external touch points.
