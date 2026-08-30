# 主路径体感 — 执行计划

父任务不写业务代码。按子任务顺序 `task.py start` 后实现。

## 顺序

1. `08-28-launch-splash` — 启动闪屏
2. `08-28-topic-first-paint` — 进帖首屏
3. `08-28-image-no-flash` — 图片不闪
4. `08-28-composer-paste-pangu` — 粘贴与盘古
5. `08-28-topic-find-filter` — 帖内查找

B 与 C 不要同一天改 `PostNativeCell` 绑图和详情加载。C 在 B 落地后再动图片 cell。

## 每子任务门闩

- 子任务自己的 `prd.md` 验收打勾。
- `xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
- 不启动模拟器，除非主人要求。
- `git diff --check` 通过后再请主人确认该项。

## 父任务收口

五个子任务都 archive 之后，再走父任务的交叉验收（浅色/深色/OLED 冷启动 + 进帖 + 看图 + 回复粘贴 + 帖内查找），然后 archive 父任务。
