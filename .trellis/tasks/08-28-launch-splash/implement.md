# 启动闪屏 — 执行清单

## Checklist

1. `LaunchBackground.colorset` 增加 dark appearance；浅色保持现有奶油色。
2. `DoerLaunchAppearance` 若需辅助色（前景），从主题取，不要在 loading view 写死 RGB 深字。
3. `DoerLaunchLoadingView`：铺主题背景；入场不再位移淡入；深色前景；Reduce Motion 已跳过动画则保持。
4. `ForumContainerViewController`：有 `isHomeInitialContentReady` 时最短时长为 0；dismiss 时背景已经是主题色。
5. 更新 `LaunchConfigurationTests`（colorset 存在、启动页颜色名、dark 不是奶油色）。
6. `xcodebuild build` DoerTests、generic iOS Simulator、`CODE_SIGNING_ALLOWED=NO`。
7. `git diff --check`。

## 验证命令

```bash
xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

手动（主人设备）：浅色冷启动、深色冷启动、OLED 主题冷启动、杀掉 App 后再开（有缓存）。

## 风险文件

- `Doer/Features/ForumDetail/DoerLaunchLoadingView.swift`
- `Doer/Features/ForumDetail/ForumContainerViewController.swift`
- `Doer/Assets.xcassets/LaunchBackground.colorset/Contents.json`
- `Doer/SceneDelegate.swift`
- `DoerTests/LaunchConfigurationTests.swift`
