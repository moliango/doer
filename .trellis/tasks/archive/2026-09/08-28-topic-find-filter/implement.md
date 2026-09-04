# 帖内查找 — 执行清单

1. ViewModel：`filterUsername`；`flatVisiblePosts` 按用户名过滤；OP 开关映射到该字段。
2. `UserProfilePreviewViewController` 增加「只看此人」；Topic/Chat 详情 present 时接上。
3. 替换 `searchTopicTapped` Alert：查找栏 + prev/next + 现有 jump。
4. Filter 菜单保留只看楼主，并显示当前过滤用户。
5. 单测过滤与结果索引。
6. 新文件则 `make generate`。
7. `xcodebuild build` DoerTests generic iOS Simulator `CODE_SIGNING_ALLOWED=NO`。
8. `git diff --check`。

不要改 ImagePaintPolicy / AvatarImageLoader。不要回退 by_number 首屏。
