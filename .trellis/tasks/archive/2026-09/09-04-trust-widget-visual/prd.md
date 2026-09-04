# 信任等级小组件视觉

## Goal

信任等级小组件按「状态卡」来排：企鹅在卡片上，大数字看主进度，短进度条看其余要求，并显示更新时间。

## User Value

锁屏/主屏一眼能看出升到下一级还差什么，同时认出这是 Doer。

## Confirmed Facts

- 现有 `TrustLevelWidget` 是标题 + `ProgressView` 列表，没有吉祥物、没有更新时间。
- 快照已有 `items`、`trustLevel`、`badgeText`、`updatedAt`、`headlineItem`（优先已读帖子）。
- Widget 目标目前没有 Asset Catalog；企鹅 Icon 带蓝底，需透明主体才能像参考卡右侧的产品图。
- iOS 15+；Widget 不能引用 App 里的 SwiftSoup / VC。

## Requirements

- 中号：标题 + 更新时间；左侧主指标大数字 + 最多两个次指标短条；右侧企鹅；底部其余要求短条。
- 小号：企鹅角落标识 + TL 徽章 + 主指标大数字 + 一条进度。
- 企鹅用透明 PNG，不带蓝底方块。
- 未同步时仍显示企鹅和「打开 App 后同步」空态。
- 点按仍走 `doer://trust`。不改快照写入契约。

## Acceptance Criteria

- [x] 中号卡右侧能看到小企鹅（透明底，不是蓝方块 Icon）。
- [x] 主指标是大数字（优先已读帖子），次指标有彩色短条。
- [x] 显示「更新于 MM-dd HH:mm」。
- [x] 小号卡也有企鹅和 TL 徽章。
- [x] 空态可辨认。
- [x] 快照 round-trip / headline 仍优先已读帖子。
- [x] `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` 通过。

## Out Of Scope

- 快捷入口小组件重做（可共用底色，不当主改）。
- 可交互按钮（WidgetKit iOS 15 中号 StaticConfiguration 无 App Intent）。
- 改 Connect 解析或快照字段。
