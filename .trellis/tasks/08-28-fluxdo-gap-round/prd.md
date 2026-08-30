# 对照 FluxDO 剩余差距

## Goal

把对照表里标成「部分」的八项做满，并把「没有」里选定的七项补上。扫码登录、桌面快捷键、悬浮胶囊底栏不做。

## User Value

长帖只看此人不再漏楼；看图和预览跟手；编辑器能富文本和完整投票；宽屏、壁纸、追觅、语音、政策、关注列表、更新镜像能用。

## Confirmed Facts

- 主路径五项（闪屏、进帖首屏、图片不闪、粘贴盘古、查找条+客户端只看此人）已实现并检查，尚未提交。本父任务不重做那五项。
- `filterUsername` 只滤已加载楼。`fetchTopic` / `DiscourseRouter.topic` 没有 `username_filters`。
- 看图可下滑关，没有缩略图 Hero。Home 长按有系统预览，搜索页没有，无一镜变形。
- 编辑器是源码 + 本地预览；投票是 Alert 写 `[poll]`。
- 返回是系统边缘手势。网络设置有 DoH/CF，没有健康快照页。
- FluxDO 有追觅、policy、语音条、关注列表、壁纸、iPad 分栏、GitHub 更新镜像。

## Scope Map

| 子任务 | 目录 | 来源 |
|--------|------|------|
| 1 只看此人走服务端 | `08-28-username-filters` | 部分 |
| 2 看图飞入 | `08-28-image-hero` | 部分 |
| 3 长按预览一镜 | `08-28-topic-preview-morph` | 部分 |
| 4 搜索长按预览 | `08-28-search-preview-morph` | 部分 |
| 5 所见即所得 | `08-28-rich-composer` | 部分 |
| 6 完整投票构建器 | `08-28-poll-builder` | 部分 |
| 7 预测式返回 | `08-28-predictive-back` | 部分 |
| 8 网络健康总览 | `08-28-network-health` | 部分 |
| 9 发现页/追觅 | `08-28-seeking-discover` | 没有 |
| 10 政策条款块 | `08-28-discourse-policy` | 没有 |
| 11 按住说话 | `08-28-hold-to-talk` | 没有 |
| 12 关注列表 | `08-28-following-list` | 没有 |
| 13 自定义背景图 | `08-28-custom-background` | 没有 |
| 14 iPad 左右分栏 | `08-28-ipad-split` | 没有 |
| 15 更新走 GitHub 镜像 | `08-28-github-update-proxy` | 没有 |

## Global Constraints

- UIKit，iOS 15+，`String(localized:)`，不引入 SwiftUI 大页。
- 对照 FluxDO 行为和观感，不移植 Flutter 架构。
- Cookie 登录不变：不加 Discourse `push_url`，不做扫码拷会话。
- 不改悬浮胶囊底栏。不做桌面快捷键。
- 主题布局收口（`08-13-home-theme-layout`）继续单开，不塞进本父任务。
- 不回退主路径五项。
- 每子任务可独立验收、独立回滚。不在父任务上写实现。

## Cross-task Acceptance

- [x] 十五个子任务各自有可演示验收路径。
- [x] 主路径五项无回归。
- [x] `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` 通过。

## Out Of Scope

- 扫码跨设备登录、桌面快捷键、悬浮胶囊底栏。
- 主题布局协议收口。

## Recommended Order

部分 1→8，再没有 9→15。实现从 `08-28-username-filters` 开始。
