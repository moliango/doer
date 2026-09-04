# Implement

## Checklist

1. `AppSettings.experimentalRichComposerEnabled` 默认 false；Preferences 基础区开关。
2. `ExperimentalComposerDocument` parse/serialize + `DoerTests/ExperimentalComposerDocumentTests.swift`。
3. `ExperimentalComposerView` + block views。
4. `ReplyComposerViewController`：开关打开时用实验视图填正文区；raw/发送/草稿/工具栏走 document.markdown。
5. 含 `[poll]` 的 round-trip 测试。
6. `make generate` 若需；`xcodebuild build` DoerTests；`git diff --check`。

## Validation

```bash
xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

不开模拟器除非用户要求。

## Rollback

设置关即回到旧框。代码回滚：去掉 Reply 分支和新文件。

## Do not touch

`ComposerMarkdownCodec` 行为、粘贴盘古契约、`username_filters`、ImagePaintPolicy。
