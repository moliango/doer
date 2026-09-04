# 长按预览一镜到底 — 执行清单

1. `TopicPreviewMenu`：支持 `previewTargetView`；`UITargetedPreview` 用卡片框。
2. Home / 稍后 / 历史：`previewForHighlightingContextMenuWithConfiguration` / `previewForDismissing` 指向卡片；commit `.pop`。
3. 小红书：按 `point` 命中左右卡，打开同一套预览菜单，不要整行 `nil`。
4. 打开/书签/稍后动作保留。
5. 单测：小红书行 identifier → 左右 topic；或 hit-test 纯函数。
6. 新文件则 `make generate`。
7. `xcodebuild build` DoerTests generic iOS Simulator `CODE_SIGNING_ALLOWED=NO`
8. `git diff --check`

不要改搜索页、图库 Hero、username_filters。
