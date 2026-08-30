# 进帖首屏 — 设计

## 现状

`TopicDetailViewModel.loadTopic` 等 `fetchTopic`（TopicView，约 20 楼）返回后才 `applyLoadedTopicDetail`。`posts` 来自 `topic?.postStream.posts`。`fetchPostByNumber` 已有，只用于跳楼。经典详情和微信/电报详情共用该 ViewModel。

## 策略

默认从 1 楼打开时，并行：

1. `GET /t/{id}.json`（`fetchTopic`，trackVisit true）— 标题、权限、stream、其余楼
2. `GET /posts/by_number/{id}/1.json` — 主贴 cooked

by_number 先到：解析 OP，写入 `firstPost` + `parsedBlocks`，`isReady = true`，`isLoading = false`。`posts` 在 `topic == nil` 时回退为 `[firstPost]`，让列表先画出主贴。

TopicView 随后到：走现有 `applyLoadedTopicDetail`。若 OP id 已在 `parsedBlocks`，first-paint split 里跳过重复解析该帖，把 by_number 的 cooked 覆到 stream 第一帖（id 一致时）。

by_number 失败：忽略，仍等 TopicView。TopicView 失败：若已有 early OP，保留主贴，错误条提示其余楼失败；若没有 early OP，现有错误页。

打开目标不是 1 楼（通知/链接 `initialFloor`/`initialPostId`）：不跑「先画 1 楼」这条 early 路径，以免先闪主贴再跳。跳楼仍可用 by_number 解析目标楼。

`recoverAfterCloudflare` 同样并行 by_number，逻辑共用，避免 CF 后只走慢路径。

## 合约

- 不改 Discourse JSON 形状。
- 不在 `PostNativeCell` 里改绑图（留给 C）。
- `topic.firstpaint` 日志：记录 by_number 命中与 TopicView ready 的 elapsedMs。

## 测试

- `posts` 在 topic 为空、firstPost 有值时返回单元素。
- first-paint split 行为不变。
- 用 fixture 或纯函数测「id 相同则跳过重复 parse」的判定。
