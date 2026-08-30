# 启动闪屏

## Goal

冷启动从系统启动页到首页，不再空一帧、不再先闪浅色再切主题。有列表缓存时尽快进首页。

## User Value

每次打开 App 的第一眼不再跳色、不再多等一秒品牌页。

## Confirmed Facts

- `Info.plist` `UILaunchScreen.UIColorName` = `LaunchBackground`。colorset 只有一组浅色 RGB (0.946, 0.944, 0.922)，没有 dark appearance。
- `SceneDelegate` 先 `applyAppearance()` 再装 `ForumContainerViewController`。窗口背景是 `DoerLaunchAppearance.backgroundColor`（同一浅色）。
- `DoerLaunchLoadingView` 盖满容器，`startPresenting()` 把内容从 alpha 0 / 下移淡入。品牌和说明文字写死深色。最短展示 `1.15s`，超时约 `4.2s`。Home 发出 `initialContentReadyNotification` 后仍要补满最短时间。
- 关掉 overlay 时把 `view.backgroundColor` 从奶油色改成 `themeStyle.topicListBackgroundColor`。
- `LaunchConfigurationTests` 锁定启动页用 `DoerLaunchAppearance.backgroundColorName`。

## Requirements

- 系统启动页提供浅色和深色两套底色。深色跟接近 OLED/深色首页，不能再是奶油色。
- overlay 在 `applyAppearance` 之后使用当前主题的列表背景色和可读的前景色，不再写死深字浅底。
- overlay 出现时内容已经在最终位置，不再从透明淡入造成「空底 → 品牌」一闪。
- Home 已有可展示缓存（发出 initial content ready，或列表非空）时，不强制 1.15 秒；能跳过就跳过，不能跳过则立刻淡出。
- 无缓存的冷启动仍可显示 logo / 加载指示，但底色必须已经是主题色。
- Reduce Motion 开启时不播呼吸和点动画。
- 关掉 overlay 后容器背景就是主题列表色，不能再切一次奶油色。

## Acceptance Criteria

- [x] 系统浅色模式：启动页与首页浅色底连续，没有空白帧。
- [x] 系统深色模式：启动页不是奶油色。
- [x] App 主题为 OLED / 深色时，品牌 overlay 不是深字浅底。
- [x] 有 Home 缓存的二次冷启动：不额外卡 1.15 秒品牌页。
- [x] `LaunchConfigurationTests` 更新后仍通过；启动页仍指向具名颜色资源。
- [x] 本地化字符串仍走 catalog，不硬编码用户可见英文/中文（品牌名 Doer 除外）。

## Out Of Scope

- 改首页列表布局或 Tab 形态。
- 自定义启动视频、全屏插画重做。
- 跟 AppSettings 主题 100% 同步系统启动页（系统启动页读不到 UserDefaults 主题；overlay 负责接到主题）。
