# 进帖首屏 — 执行清单

## Checklist

1. `TopicDetailViewModel.posts`：`topic` 为空时用 `[firstPost].compactMap { $0 }`。
2. `loadTopic`：默认进帖并行 `fetchPostByNumber(1)` 与 `fetchTopic`；early OP 解析后 notify；TopicView 合并时跳过已解析 OP。
3. 抽共用 apply，供 `recoverAfterCloudflare` 使用。
4. 非 1 楼入口不 early-paint 主贴。入口信息从 VC 传入（`initialFloor`/`initialPostId`），不要猜。
5. 经典 / ChatTopicDetail 都走 ViewModel，不各写一套。
6. 单测：posts 回退；optional 判定「已有 parsedBlocks 则不重复 parse」。
7. `xcodebuild build` DoerTests generic iOS Simulator `CODE_SIGNING_ALLOWED=NO`。
8. `git diff --check`。

## 验证

```bash
xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

## 风险文件

- `Doer/Features/ForumDetail/TopicDetail/TopicDetailViewModel.swift`（主改）
- `Doer/Features/ForumDetail/TopicDetail/TopicDetailViewController.swift`（传 initial floor）
- `Doer/Features/ForumDetail/TopicDetail/ChatTopicDetailViewController.swift`（同样传入口）
- `DoerTests/TopicDetailNativeLayoutTests.swift` 或新建 focused tests

不要改 `PostNativeCell` 图片绑定。
