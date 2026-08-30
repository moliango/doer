# 看图从缩略图飞入 — 执行清单

1. `postCell(didTapImageURL:imageURLs:sourceView:)` 与 `presentTopicImageGallery(..., sourceView:)`；旧调用补 `sourceView: nil`。
2. `ImageRenderer` / `ImageGridRenderer` / `SignatureImageView` / web 图点击传入被点中的 image view。
3. `TopicImageGalleryViewController`：自定义 present/dismiss（或内部 cover 飞层）从 source 框飞到全屏；关闭飞回；源不在屏上则淡出。
4. Reduce Motion：不飞，现有 crossDissolve。下滑关闭阈值逻辑不改。
5. 单测：有 source 且 Reduce Motion 关 → 应飞；无 source 或 Reduce Motion → 不飞。纯函数即可。
6. `make generate` 仅当新增 Swift 文件。
7. `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
8. `git diff --check`

不要改 ImagePaintPolicy 淡入规则、username_filters、ComposerPangu、by_number 首屏。
