# 主路径体感这一轮

## Goal

把每天「打开 App → 刷列表 → 进帖 → 回一句」这条路的体感补齐，对照 FluxDO 0.2.27 仍能感到的差距。不扩功能面。

## User Value

冷启动不再先闪一帧错色；进帖更快看到主贴；列表和看图不再空闪；回复能粘贴出图、中英文空格正常；长帖里能找人和找句。

## Confirmed Facts

- 系统 `UILaunchScreen` 只有浅色 `LaunchBackground`，没有 logo。`DoerLaunchLoadingView` 再淡入，最短 1.15 秒，最长约 4.2 秒；文案颜色写死深色。深色/OLED 会先闪浅色，关掉时背景再切到主题色。
- 进帖仍走 `fetchTopic` 的 TopicView chunk；`fetchPostByNumber` 只用于跳楼。`firstPaintPostCount = 6`。
- 磁盘出图已改异步，冷启动第一次可能先占位再填上。看图没有跟手关掉。
- 回复编辑器字号已对齐正文；没有粘贴上传图片，没有盘古空格。
- 帖内搜索是 Alert + ActionSheet；过滤只有「只看楼主」。FluxDO 用 `username_filters` 和帖内查找条。

## Scope Map

| 子任务 | 目录 | 用户价值 |
|--------|------|----------|
| A 启动闪屏 | `08-28-launch-splash` | 每次打开的第一印象 |
| B 进帖首屏 | `08-28-topic-first-paint` | 每天进帖都付的等待 |
| C 图片不闪 | `08-28-image-no-flash` | 刷列表、进帖、看图 |
| D 回复粘贴与盘古 | `08-28-composer-paste-pangu` | 每天写回复 |
| E 帖内查找 | `08-28-topic-find-filter` | 长帖里找人/找句 |

## Global Constraints

- UIKit，iOS 15+，`String(localized:)`，不引入 SwiftUI 大页。
- 对照 FluxDO 的是行为和观感，不移植 Flutter 架构。
- Cookie 登录边界不变：不加 Discourse `push_url`。
- 不改主题分叉（微信/电报/小红书布局）、胶囊底栏、iPad 分栏、语音、政策块、扫码登录。
- 每子任务可独立验收、独立回滚。

## Cross-task Acceptance

- [x] 五个子任务各自有可演示的验收路径。
- [x] 主路径（冷启动 → Home → 进帖 → 看图/回复 → 帖内查找）无新增明显回归。
- [ ] 浅色、深色、OLED 各走一遍启动，不再先闪奶油色再切主题。
- [x] `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` 通过。

## Out Of Scope

- 悬浮胶囊底栏、长按预览一镜到底、iPad 分栏。
- 按住说话、编辑器里建投票、discourse-policy、GitHub 更新镜像、扫码登录。
- 主题布局协议收口（`08-13-home-theme-layout` 继续单开）。
- DoH/ECH 1:1（`08-21-fluxdo-doh-swift-port` 继续单开）。

## Recommended Order

1. A 闪屏（立刻可感，文件面小）
2. B 进帖首屏
3. C 图片不闪（可与 B 短并行，避免同时大改 TopicDetail 图片绑定）
4. D 粘贴/盘古
5. E 帖内查找

不启动父任务做实现。实现从 A 开始。
