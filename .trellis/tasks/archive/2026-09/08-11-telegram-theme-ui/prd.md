# Telegram App-like Theme + Topic Detail

## Goal
把 **Telegram 主题** 做成接近 Telegram iOS 应用的界面语言（与微信主题对标）：首页会话列表 + 聊天气泡 Topic Detail + 蓝系 chrome。

## Context
- 微信主题已有：`WeChatTopicListCell` 首页全宽列表 + `WeChatTopicDetailViewController` 聊天气泡详情。
- 工作区已有 WIP：`ChatTopicStyle`、`usesChatTopicDetail` / `usesChatHomeList`、详情 factory 分流。
- 缺口：首页仍只对 `.weChat` 走会话列表；列表 cell 未吃 Telegram 圆形头像 / 尺寸；外观预览色偏旧。

## Requirements

### Must
1. `ThemeStyle.telegram` 启用聊天详情（已有 factory 路径），视觉走 `ChatTopicStyle.telegram`。
2. `ThemeStyle.telegram` 启用首页会话列表布局（与 WeChat 同 cell 族，样式由 `ChatTopicStyle` 区分）。
3. Telegram 列表：圆形大头像、单行标题、右侧时间 + 未读/回复角标、浅灰列表底。
4. Telegram 详情：圆形头像、圆角气泡、自己侧 mint/深蓝气泡、对方白气泡、蓝名、pill 输入框 + paperclip/发送切换。
5. 切换主题后 Home layout-shape 通过 diffable snapshot 重建（不得卡在旧 cell 类）。
6. 非 Telegram / 非 WeChat 主题：经典详情与卡片列表不变。

### Should
7. Appearance 预览 swatch 使用 `#3390EC` 品牌蓝。
8. 导航/Tab 不透明 chrome 使用 Telegram chrome 色。

## Acceptance
- [x] 选 Telegram 主题：首页为会话列表（圆头像），点进话题为聊天气泡详情。
- [x] 选微信主题：仍为微信绿气泡 / 方头像列表，互不串味。
- [x] 切回默认：经典 TopicCell + TopicDetailViewController。
- [x] Debug 编译通过（`xcodebuild … BUILD SUCCEEDED`）。

## Out of Scope
- 完整复刻 Telegram 动画 / 双勾已读 / 语音消息。
- 独立 `TelegramTopicDetailViewController` 文件拆分（可与 WeChat 共用 VC + style 枚举）。
- 自定义壁纸资源包。
