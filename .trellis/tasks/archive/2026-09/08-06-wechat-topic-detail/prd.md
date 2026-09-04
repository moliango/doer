# WeChat Chat Topic Detail

## Goal
在 **不改动现有 `TopicDetailViewController` 实现** 的前提下，新增一套「微信聊天界面」Topic Detail：气泡布局、长按操作（点赞 / 回复 / 收藏 / Boost）。当 `ThemeStyle.weChat` 时走新界面，其它主题仍走原详情。

## Constraints
- 原 `TopicDetailViewController` / `PostNativeCell` 行为与布局保持不变。
- 复用 `TopicDetailViewModel` 与现有 API（reaction / bookmark / boost / reply composer）。
- 入口通过 factory 分流，避免复制业务逻辑进旧 VC。

## Requirements
1. 新增 `WeChatTopicDetailViewController` + `WeChatChatPostCell`。
2. 自己的帖子右侧绿色气泡，他人左侧白气泡 + 头像。
3. 长按气泡弹出：点赞、回复、收藏、Boost（权限/自己的帖子项按现有规则隐藏）。
4. 底部简易输入条，点击打开现有 `ReplyComposerViewController`。
5. `TopicDetailFactory.make(...)`：`themeStyle == .weChat` → 新 VC，否则旧 VC。
6. 内容块复用 `NativeContentRenderer` + `viewModel.parsedBlocks`。

## Acceptance
- [ ] 非微信主题：详情 UI/交互与改前一致。
- [ ] 微信主题：从首页等入口进入为聊天布局。
- [ ] 长按可点赞/回复/收藏/Boost（在允许时）。
- [ ] Debug 编译通过。

## Out of Scope (MVP)
- 完整复刻经典详情所有手势/进度条/时间线。
- 语音/图片发送输入框。
- 已读回执 / 双勾。
