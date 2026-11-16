# 技术设计：DoH 自动选服与优选直连兜底

## 1. 边界

改动集中在三处，互不越界：

| 层 | 文件 | 职责 |
|---|---|---|
| 配置解析 | `Doer/Core/Settings/AppSettings+DoH.swift` | 决定"当前生效的服务器是谁"，输出仍然是一份 `DohProxyConfig` |
| 选服逻辑 | 新增 `Doer/Networking/DoH/DoHServerAutoSelector.swift` | 并发探测、选赢家、持久化、触发重选 |
| 连接捷径 | `Doer/Networking/DoH/LocalConnectProxy.swift` | 优选钉住的直连路径 + 失败回退解析 |

**不改**：`EncryptedDnsService`（复用现成的 `apply` / 代次守卫 / 探活）、`DohBootstrapTransport`（探测直接复用它已有的竞速 `query`）、`PreferredNodeSelector`（不碰优选本身）。

## 2. 配置层设计

### 2.1 新增存储键

| 键 | 类型 | 说明 |
|---|---|---|
| `dohAutoSelectEnabled` | Bool | 自动模式开关。**键不存在 = 按默认规则推断** |
| `dohAutoSelectedURL` | String | 上次选出的服务器 URL |
| `dohAutoSelectedAt` | Double | 上次选服时间（`timeIntervalSince1970`） |
| `dohServerManuallySelected` | Bool | 用户显式点过具体服务器 |

### 2.2 默认值推断

```swift
nonisolated static func dohAutoSelectEnabled(from defaults: UserDefaults) -> Bool {
    if let stored = defaults.object(forKey: "dohAutoSelectEnabled") as? Bool { return stored }
    // 未写入过：只有"从未配置过"的用户默认开启
    let everChose = defaults.object(forKey: "dohProvider") != nil
        || defaults.bool(forKey: "dohServerManuallySelected")
    return !everChose
}
```

已安装的老用户只要点过服务器，`dohProvider` 键就存在 → 保持原选择。新装用户没有该键 → 自动开启。

### 2.3 服务器解析

新增一个纯函数，`dohProxyConfig(from:)` 在算 `serverURL` / `bootstrap` 时改走它：

```swift
nonisolated static func effectiveDoHServer(from defaults: UserDefaults) -> (url: String, bootstrap: [String])
```

- 自动模式且 `dohAutoSelectedURL` 非空 → 用它 + `lockedBootstrapIPs(for:)` 推出的预设 bootstrap。
- 自动模式但没有选中结果 → 落回 `DoHProvider.dnspod`（保证冷启动**永远**有一份能用的 spec，不等探测）。
- 非自动模式 → 完全走现有逻辑，一行不改。

`lockedBootstrapIPs(for:)` 已经能从 `DohServerCatalog` 推出预设的 bootstrap，所以只需要存 URL，不需要重复存 IP 列表。存储里留一份 IP 只是审计用，不参与解析。

**性能约束**：`dohProxyConfig` 会被 `DiscourseAPI.session` 每个请求调用一次（算 signature）。新增的是 3 次 `UserDefaults` 读取，无 JSON、无钥匙串、无网络，可接受。

### 2.4 与 `DohProxyConfig.signature` 的关系

`signature` 已包含 `serverURL`。自动选服改了 URL → signature 变化 → `LightweightDohProxyService` 现有的"配置变了就 reapply"路径自动生效，**不需要新增通知机制**。

## 3. 选服器设计

### 3.1 形状

```swift
nonisolated enum DoHServerAutoSelector {
    enum Trigger { case launch, networkChange, watchdog, periodic, manual }
    static func rescan(trigger: Trigger, completion: ((String?) -> Void)? = nil)
}
```

完全参照 `PreferredNodeSelector.reselect(trigger:)` 的形状，便于维护者一眼认出。

### 3.2 候选集

`AppSettings.DoHProvider.builtInDisplayOrder.filter { !$0.bootstrapIPs.isEmpty }`
→ DNSPod / 腾讯 DNS / Cloudflare / 阿里 DNS / Quad9 / Google。

Canadian Shield（无 bootstrap）与自定义服务器不参与。

### 3.3 探测

对每个候选并发：

```
DohEndpoint(url: provider.url, bootstrapIPs: provider.bootstrapIPs, preferIPv6: false)
DohDNSMessage.makeQuery(host: "linux.do", type: .a)
DohBootstrapTransport.query(endpoint:dnsQuery:queue:quiet:true)
```

- **首个 `.success` 即胜出**（`DohBootstrapTransport.query` 内部已做 0.3s 错峰 + 最多 3 IP 竞速）。
- 3 秒总预算：`queue.asyncAfter` 一个超时任务，到点仍未 settle 就以 `nil` 收尾（不切服务器，保留现状）。
- `quiet: true`，避免 6 个候选 x 多个 IP 的连接日志把 500 行日志冲掉；只在结束时记一条汇总。

### 3.4 收敛与并发

- `isScanning` 标记 + 代次计数：同一时刻只允许一次扫描；扫描中进行的新请求**丢弃**（不排队），因为触发条件本身就是幂等的。
- 赢家变化时：写 `dohAutoSelectedURL` / `dohAutoSelectedAt` → 调 `LightweightDohProxyService.shared.configureFromSettings()`。后者会走 `EncryptedDnsService.apply` 的现有探活 + 代次守卫，**不绕过任何安全检查**。
- 赢家与当前相同：只更新 `dohAutoSelectedAt`，不触发 reapply。

### 3.5 节流

- `.launch` / `.periodic`：距 `dohAutoSelectedAt` < 6 小时 → 直接返回。
- `.networkChange` / `.watchdog` / `.manual`：忽略节流。
- 任何 trigger 都先检查 `dohEnabled && dohAutoSelectEnabled`，否则直接返回（R1.7）。

### 3.6 触发点接线

| 位置 | Trigger |
|---|---|
| `LightweightDohProxyService.configureFromSettings()` 尾部 | `.launch` |
| `LightweightDohProxyService.recoverAfterPathChange()` | `.networkChange` |
| `DohBootstrapTransport.onRepeatedFailure` 回调内（退回系统 DNS 之后） | `.watchdog` |
| `SceneDelegate.sceneWillEnterForeground` | `.periodic` |
| 设置页点「自动」 | `.manual` |

看门狗路径要注意顺序：先 `EncryptedDnsService.fallbackToSystemDNS` 让 App 恢复可用，再异步重选；重选出的服务器若与故障服务器不同，`retrySuppressedSpec` 不等于新 spec，冷却不会挡住它。

## 4. 优选直连兜底设计

### 4.1 现状与问题

`LocalConnectProxy.openTunnel` 的捷径条件是 `pinnedAddress && !echConfig.isEmpty`。ECH 抓取失败 → 捷径静默失效 → 退回解析 → 依赖 DoH。

### 4.2 规则调整

```swift
// 本地 ECH 模式：直连必须带 ECH，否则等于放弃了这条路的目的（藏 SNI）。
// Encrypted DNS 模式：SNI 本来就是明文，pin 单独存在即可直连。
let echRequired = LocalConnectProxy.originECHReady
```

`originECHReady` 是现成的模式开关（`AppSettings.DohConnectionMode` 派生），无需新状态。

### 4.3 失败回退

给 `connectUpstream` 增加可选参数：

```swift
onExhausted: (() -> Void)? = nil
```

`addressIndex >= addresses.count` 时：有 `onExhausted` 就调用它，否则维持现在的 `reject(client, "all upstream addresses failed")`。

新增的 pin 直连路径传 `onExhausted = { self.resolveAndConnect(...) }`，把现有的 `openTunnel` 解析段抽成一个 `resolveAndConnect(host:port:client:bufferedClientData:readyReply:)` 私有方法供两条路径复用。抽方法时**不改解析段任何行为**。

### 4.4 失败记账

沿用现有语义，不新增特例：

- 每个失败地址仍然 `resolver.recordHostFailure` + `PreferredNodeStore.reportOutcome(success: false)`。
- 赢家降级由 `PreferredNodeStore` 现有的 failStreak 窗口决定，单次瞬时失败不会立刻把赢家打下来（需要连续多次）。

这样"优选死了"仍然会被发现并降级，同时不会因为一次抖动误伤。

### 4.5 超时

PIN 直连沿用 `connectUpstream` 现有的 8 秒单地址超时。**不另外做 2 秒短超时**：短超时会让"网络慢"被误判成"节点死"，进而多打一次解析；8 秒后回退解析虽然慢，但结果正确。候选方案见 §6。

## 5. UI

`DohDetailSettingsViewController`：

- 服务器分组顶部插入「自动」行，`selected = settings.dohAutoSelectEnabled`。
- 副标题显示当前结果：`自动（DNSPod，2 小时前选择）`；未有结果时显示 `自动（正在探测…）`。
- 点「自动」→ `dohAutoSelectEnabled = true` → `configureFromSettings()` → `rescan(trigger: .manual)`。
- 点任一具体服务器 / 自定义服务器 → `dohServerManuallySelected = true`、`dohAutoSelectEnabled = false`，其余保持现在的行为。
- 文案全部走 `String(localized:)`，新增 key 前缀 `settings.network.doh.auto.*`。

## 6. 权衡与备选

**A. 自动选服 vs 让用户选**
自动选服的代价是"用户不知道自己在用哪台"。缓解：设置页显示选中的服务器名和选择时间，日志里也记。收益是彻底消除"选错服务器 → 开了 DoH 反而没网"这一类故障。

**B. 6 小时节流**
代价是同一网络下长期租用变慢的服务器最久 6 小时。收益是省电、省流量。看门狗与网络变化不受节流限制，覆盖了主要的坏情况。

**C. PIN 直连 8 秒超时 vs 2 秒短超时**
选 8 秒（与现有地址尝试一致）的理由见 §4.5。若实测发现死 pin 拖慢首屏，再单独任务改成"2 秒探测 + 后台并行解析"。

## 7. 回滚

- 自动选服：写 `dohAutoSelectEnabled = false` 即完全回到旧路径；旧逻辑分支未被修改。
- 直连兜底：`echRequired` 改为恒 `true`、`onExhausted` 传 `nil` 即回到现状。两处都是一行级回滚。
