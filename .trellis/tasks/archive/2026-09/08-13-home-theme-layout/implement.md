# Implement — Home theme layout + chat topic detail subclasses

## Order

Do Home list extraction first so Topic Detail factory changes have a single Home entry (`layout.makeTopicDetail`). Then extract the chat parent/subclasses.

## Checklist

1. Add `HomeTopicListLayout` + `HomeTopicListCellContext` + `HomeTopicListLayoutFactory` under `Doer/Features/ForumDetail/Home/`.
2. Implement `StandardHomeTopicListLayout` (also used by eye-care): `TopicCell` + `CompactPinnedTopicCell`, 1:1 snapshot ids.
3. Implement `XiaohongshuHomeTopicListLayout`: move pair cache + negative row ids + `XiaohongshuTopicGridCell` dequeue out of `HomeViewController`.
4. Implement `WeChatHomeTopicListLayout` and `TelegramHomeTopicListLayout` with a shared session-row helper; only cell class / height differ.
5. Wire `HomeViewController` to hold `topicListLayout`, register cells via layout, snapshot/cell provider via layout; remove `homeListLayoutKind` switches from the data source.
6. Route `openTopic`, notifications, and composer success through `topicListLayout.makeTopicDetail` (delegates to `TopicDetailFactory`).
7. In `handleSettingsChanged`, rebuild layout from current `themeStyle` before snapshot.
8. Rename current chat VC body to `ChatTopicDetailViewController`. Keep load/pagination/gestures/VM there. Add template methods listed in `design.md`.
9. Add `WeChatTopicDetailViewController` and `TelegramTopicDetailViewController` subclasses that only override theme hooks.
10. Point `TopicDetailFactory` at the matching subclass; fallback WeChat if chat detail is on but theme is not weChat/telegram.
11. Replace `is WeChatTopicDetailViewController` with `is ChatTopicDetailViewController` in `ForumContainerViewController`, `ForumTabBarController`, `SettingsNavigationHelpers`.
12. Pass `chatThemeStyle()` into `WeChatChatPostCell` / `WeChatChatInputBar` instead of `ChatTopicStyle.current`.
13. Add a focused test: layout factory kind per `ThemeStyle`; factory returns Telegram subclass for `.telegram` + chat detail enabled, classic VC when chat detail is off.
14. Compile: `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`

## Validation

- Manual: each of the five themes — Home row type, tap opens the expected detail (classic vs WeChat vs Telegram subclass).
- Manual: switch WeChat → Telegram while a chat detail is open; page stays WeChat subclass; pop and reopen is Telegram.
- No Simulator boot in CI-style verification; compile-only as above.

## Risky files

- `HomeViewController.swift` (data source closure)
- `HomeViewController+Data.swift` (snapshot ids)
- `WeChatTopicDetailViewController.swift` (rename/split)
- `TopicDetailFactory.swift`
- Type checks in Forum container / tab bar / settings helpers

## Rollback

Stop after any checklist item if compile fails; the Home layout steps (1–7) are independently revertable from the chat subclass steps (8–12).
