# 执行计划：DoH 自动选服与优选直连兜底

> 每个阶段独立可编译、可回滚。做完一阶段再进下一阶段。

## 阶段 1 — 配置层（无 UI，无行为变化）

- [ ] 1.1 `AppSettings+DoH.swift` 新增读写属性：`dohAutoSelectEnabled`、`dohAutoSelectedURL`、`dohAutoSelectedAt`、`dohServerManuallySelected`
- [ ] 1.2 新增 `nonisolated static func dohAutoSelectEnabled(from:) -> Bool`（缺失时按"从未配置过"推断）
- [ ] 1.3 新增 `nonisolated static func effectiveDoHServer(from:) -> (url: String, bootstrap: [String])`
- [ ] 1.4 `dohProxyConfig(from:)` 的 `serverURL` / `bootstrap` 改走 1.3；非自动分支逐字保留
- [ ] 1.5 `selectDoHServer(provider:)` / `selectCustomDoHServer(_:)` 写 `dohServerManuallySelected = true`、`dohAutoSelectEnabled = false`

**验证**
```bash
xcodebuild -workspace Doer.xcworkspace -scheme Doer \
  -destination 'generic/platform=iOS Simulator' build
```
**回滚点**：`dohProxyConfig` 里恢复成直接用 `provider.url` / `customURL`。

## 阶段 2 — 选服器（可独立单测）

- [ ] 2.1 新建 `Doer/Networking/DoH/DoHServerAutoSelector.swift`：`Trigger` 枚举 + `rescan(trigger:completion:)`
- [ ] 2.2 实现候选集、并发探测、首个成功即胜出、3 秒总预算
- [ ] 2.3 实现 `isScanning` + 代次收敛、6 小时节流、`dohEnabled && autoSelectEnabled` 前置门禁
- [ ] 2.4 胜出后持久化并调 `configureFromSettings()`；同 URL 只更新时间戳
- [ ] 2.5 `DohDebugLog` 记录：开始扫描、赢家与耗时、全部失败的汇总原因

> 新增 Swift 文件后**必须**先 `make generate`，否则 Xcode 工程里没有它。

**验证**
```bash
make generate
xcodebuild -workspace Doer.xcworkspace -scheme Doer \
  -destination 'generic/platform=iOS Simulator' build
cd Packages/DohProxy && swift test
```

## 阶段 3 — 接线触发点

- [ ] 3.1 `LightweightDohProxyService.configureFromSettings()` 尾部 → `.launch`
- [ ] 3.2 `LightweightDohProxyService.recoverAfterPathChange()` → `.networkChange`
- [ ] 3.3 `onRepeatedFailure` 回调：先 `fallbackToSystemDNS`，再 `.watchdog`
- [ ] 3.4 `SceneDelegate.sceneWillEnterForeground` → `.periodic`

**验证**：构建通过；日志里能看到 `.launch` 被 6 小时节流跳过 / `.networkChange` 不被跳过。

## 阶段 4 — 设置页

- [ ] 4.1 服务器分组顶部插入「自动」行，选中态绑 `dohAutoSelectEnabled`
- [ ] 4.2 副标题显示选中的服务器名 + 相对时间；无结果时显示"正在探测…"
- [ ] 4.3 点击「自动」→ 置位 → `configureFromSettings()` → `rescan(trigger: .manual)`
- [ ] 4.4 `Localizable.xcstrings` 补 `settings.network.doh.auto.*` 的中文文案

**验证**：构建通过；设置页显示正确，切换「自动」与具体服务器时单选态互斥。

## 阶段 5 — 优选直连兜底

- [ ] 5.1 抽出 `openTunnel` 的解析段为 `resolveAndConnect(host:port:client:bufferedClientData:readyReply:)`，**行为不变**
- [ ] 5.2 `connectUpstream` 增加 `onExhausted: (() -> Void)? = nil`；地址耗尽时优先调用它
- [ ] 5.3 pin 直连条件改为 `pin && (!echRequired || eché非空)`，`echRequired = LocalConnectProxy.originECHReady`
- [ ] 5.4 pin 直连传 `onExhausted` → `resolveAndConnect(...)`
- [ ] 5.5 日志区分「优选直连成功」「优选直连失败，回退解析」

**验证**
```bash
xcodebuild -workspace Doer.xcworkspace -scheme Doer \
  -destination 'generic/platform=iOS Simulator' build
cd Packages/DohProxy && swift test
```

## 阶段 6 — 收尾

- [ ] 6.1 逐条走 PRD 的 Acceptance Criteria
- [ ] 6.2 检查无硬编码字符串（全部 `String(localized:)`）
- [ ] 6.3 按规范分阶段提交（`<type>: <描述>`，一次提交一件事）：
  - `feat: add doh auto server selection`
  - `feat: prefer pinned edge without ech in encrypted dns mode`
  - 或按实际拆分

## 风险与回滚

| 风险 | 处理 |
|---|---|
| 自动选服在弱网下选到"能解析但很慢"的服务器 | 探测只判可用性不判 RTT；若实测有问题再加 RTT 排序（独立任务） |
| 6 个候选并发探测被防火墙识别 | 探测目标名与日常一致（`linux.do`），复用现有传输栈，UA/路径不变 |
| 死 pin 拖慢首屏 8 秒 | 回滚 `onExhausted` 为 `nil` 即回到现状；或后续改 2 秒探测方案 |
| 自动模式与优选互相干扰 | 不相关：优选管"连哪个 IP"，自动选服管"问哪台 DNS" |
