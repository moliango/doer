# 图片不闪 — 执行清单

## Checklist

1. 查清头像、正文、预取三条 loader 的 placeholder 与 disk 回调。
2. 内存命中无 placeholder；磁盘完成短淡入；未命中用主题底而非灰块。
3. 看图 VC 加跟手下滑关闭，可取消。
4. 不改 TopicDetailViewModel 加载，不恢复 `queryDiskDataSync`。
5. 单测占位/阈值。
6. `xcodebuild build` DoerTests generic iOS Simulator `CODE_SIGNING_ALLOWED=NO`。
7. `git diff --check`。

## 风险文件

- `Doer/Core/ImageLoading/` 下 loader
- `PostWebViewCell.swift` / gallery VC
- `AvatarImageLoader.swift`

B 刚改过 TopicDetailViewModel，本任务不要再大改它。
