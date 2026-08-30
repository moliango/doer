# 进帖首屏

## Goal

打开话题时先看到主贴内容，再补后面的楼，减少对着空页等待。

## Confirmed Facts

- 打开路径走 `fetchTopic`（TopicView，约 20 楼 chunk）。
- `GET /posts/by_number/{topicId}/{postNumber}.json` 已封装为 `fetchPostByNumber`，目前用于跳楼。
- `TopicDetailPaginationPolicy.firstPaintPostCount = 6` 只切本地已有 posts，不减少首次网络体积。
- FluxDO 0.2.27 用 by_number 拉主贴 cooked。

## Requirements

- 打开话题（从 1 楼或默认入口）时，主贴 cooked 走 by_number 或同等轻量接口，尽快上屏。
- 标题、标签、权限、楼层 stream 仍以 TopicView 为准。
- by_number 失败时回退到现有 fetchTopic，不能白屏。
- 从通知/链接跳到非 1 楼时，仍以目标楼为先，不为此任务牺牲跳楼。
- 微信/电报详情与经典详情行为一致（都要先出首屏内容）。

## Acceptance Criteria

- [x] 默认进帖：主贴文本在 TopicView chunk 完成前可以出现（弱网可感）。
- [x] by_number 失败：仍能打开话题，无崩溃。
- [x] 跳到指定楼：仍能定位，不回到只显示 1 楼。
- [x] 现有时间线、目录、嵌套楼不回归。

## Out Of Scope

- 改 CookedHTML 解析器。
- 图片占位策略（C）。
- 帖内搜索 UI（E）。
