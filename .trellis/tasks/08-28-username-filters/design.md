# 只看此人走 username_filters — 设计

## Boundaries

- 网络：`DiscourseRouter.topic` 增加可选 `usernameFilters: String?`。与 `track_visit` 拼 query。不要把 `username_filters` 塞进首次 `loadTopic` / `by_number` 并行请求。
- ViewModel：`setFilterUsername` 在话题已 `isReady` 时触发一次过滤重拉；打开过程中只记字段，等首屏完成后再拉。
- 展示：服务端窗口到达后仍用 `TopicFindFilterPolicy` / `visiblePosts` 做展示滤，避免 1 楼作者不是目标用户时整页看起来没过滤。

## Contracts

```
GET /t/{id}.json?username_filters={username}
GET /t/{id}.json?track_visit=true&username_filters={username}
```

- `fetchTopic(id:trackVisit:usernameFilters:)`
- 空 `usernameFilters` = 不带该 query。
- 取消过滤：`usernameFilters: nil` 再 `fetchTopic`。

## Data flow

1. 用户点只看此人 → `filterUsername` 立刻更新 UI（可先本地滤已有楼）。
2. 若 `isReady` 且非嵌套：`reloadTopicPreservingIdentity(usernameFilters:)`，新 `parseGeneration`，**不**走 `shouldEarlyPaintOpeningPost`。
3. 成功：替换 `topic` / `posts` 窗口，保留当前滚动目标若仍在 stream。
4. 失败：`errorMessage`，不清空已有 posts。
5. 清除过滤：同样重拉无 filter。

## Compatibility

- 不改 Cookie / push_url。
- 不回退 by_number 首屏。
- 查找条继续 `searchTopic`；跳楼仍 post id / post_number。

## Rollback

去掉 router query 与 `setFilterUsername` 里的 reload 调用，UI 退回纯客户端过滤。
