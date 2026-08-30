# 启动闪屏 — 设计

## 两段启动

1. **系统 `UILaunchScreen`**：只能用 Asset Catalog 颜色。加 dark appearance，浅色保持现有奶油色，深色用接近纯黑的列表底（与 OLED/深色 `topicListBackgroundColor` 同量级）。
2. **应用 overlay**：`SceneDelegate.applyAppearance()` 之后立刻用 `themeStyle.topicListBackgroundColor` 铺满。这是能读到用户主题的第一帧。

系统浅色 + 用户 OLED：最多一次从浅启动页切到 overlay 的 OLED 底，不再经过「浅品牌页淡入再切首页」。

## Overlay 行为

- 加入层级时 `alpha = 1`，内容在最终 transform，不跑 `startPresenting` 的入场位移。
- `launchOverlayMinimumDuration`：仅当 Home **没有** initial content 时作为下限；有缓存则 delay = 0。
- 超时上限保留，避免 Home 通知丢失时卡死。
- 文案/logo 对比度跟主题走：浅底深字，深底浅字。黄色点可保留，但要在深底上可见。
- dismiss 完成后容器背景已是主题色，不要在 dismiss 回调里再赋一次造成闪。

## 测试

- 扩展 `LaunchConfigurationTests`：colorset 含 dark；`UIColor(named:)` 在 light/dark trait 下不是同一奶油色。
- 不在单测里驱动真实 Scene（保持现有风格）。

## 回滚

还原 `LaunchBackground.colorset`、`DoerLaunchLoadingView`、`ForumContainerViewController` overlay 计时、`LaunchConfigurationTests`。
