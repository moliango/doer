# 图片不闪 — 设计

## 边界

不把磁盘解码搬回主线程。不改进帖 by_number 加载（B 已落地）。只改出图与看图关闭。

## 列表 / 正文 / 头像

- 内存命中：继续同步赋值，无占位。
- 磁盘命中：imageView 保持当前图或主题色底，完成后短淡入；禁止灰 `UIImage()` 占位闪一帧。
- 未命中：可用 1pt 主题色或现有骨架，不要系统灰。
- Cloudflare gate/grace 行为不变；磁盘命中仍可 `.fromCacheOnly` 异步出图。

入口收口到现有 `AvatarImageLoader` / `ForumImageLoader` / `ExternalImageFetcher`，不要第三套。

## 看图

`TopicImageGalleryViewController`（或当前 gallery）：加垂直跟手关闭。拖过阈值松手则 dismiss，未过则弹回。不要先缩小再 pop。iOS 15 用 pan + 自己的 dismiss，不要依赖 iOS 16+ only API 作为唯一路径。

## 测试

- 占位策略纯函数或 loader option：内存命中不得设置 placeholder。
- gallery 阈值常量可单测。
