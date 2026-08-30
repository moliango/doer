# 回复粘贴与盘古 — 执行清单

1. `AppSettings` 增加 `autoPanguSpacing`，默认 true；`PreferencesSettingsViewController` 基础组加开关。
2. 新增 `ComposerPangu.swift` 纯函数 + 单测。
3. 回复/发帖/私信发送与预览前调用盘古（设置关闭则跳过）。
4. 共享 TextView 拦截图片粘贴 → 临时文件 → `uploadPickedFiles`；失败不插链。
5. 新 Swift 文件后 `make generate`。
6. `xcodebuild build` DoerTests generic iOS Simulator `CODE_SIGNING_ALLOWED=NO`。
7. `git diff --check`。

风险文件：`ComposerSharedCore.swift`、三个 Composer VC、`AppSettings+General.swift` 或 ProgressGestures 旁的 bool helper、`PreferencesSettingsViewController.swift`。
不要改进帖 ViewModel 加载，不要改图片 loader。
