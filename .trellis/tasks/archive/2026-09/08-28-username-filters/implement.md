# 只看此人走 username_filters — 执行清单

1. `DiscourseRouter.topic` 增加 `usernameFilters: String? = nil`，拼 `username_filters` query（与 `track_visit` 共存）。
2. `DiscourseAPI.fetchTopic` 向下传递该参数。
3. ViewModel：`reloadForUsernameFilter()`；`setFilterUsername` / `clearTopicFilters` / `setFilteringByOP` 在已就绪时调用。首屏 `loadTopic` 不带 filter。
4. 过滤重拉 `shouldEarlyPaintOpeningPost: false`。失败保留旧 posts。
5. 单测：router 路径；过滤生效判定排除 1 楼（对齐 FluxDO）。
6. 新/改签名若需则 `make generate`。
7. `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
8. `git diff --check`

不要改 ImagePaintPolicy、ComposerPangu、查找条 UI、by_number 首屏并行逻辑。
