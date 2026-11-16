# DoH 自动选服与优选直连兜底

## Goal

让用户不需要关心"填哪个 DoH 地址"：

1. **自动选服** —— DoH 设置里提供「自动」选项，App 并发探测内置服务器，选最快且答案合法的那个并持久化；用户只选一次「自动」，之后由 App 自己维护。
2. **优选直连兜底** —— 有优选赢家时，即使 ECH 配置缺失也优先走直连，失败再回退解析，避免"赢了优选却仍在等 DNS"。

两项合起来的目标：正常网络下 linux.do 的打开路径**不依赖 DoH 是否健康**；只有换网络 / 赢家失效时才轮到 DoH，而 DoH 是自动挑出来的。

## Background

- 我们的 DoH 预设（`DohServerCatalog.builtIn` / `AppSettings.DoHProvider`）与 CFluxDo 完全一致：7 个内置服务器、每个自带 bootstrap IP。差距不在名单，而在「谁来挑」和「挑不到时怎么办」。
- 现状：用户必须从列表里手动选一台，选错了（例如国内网络选 Google/Quad9）会走到 `EncryptedDnsService` 的"探活失败 → 退回系统 DNS"路径，表现为「开了 DoH 反而没网」。
- 现状：`LocalConnectProxy.openTunnel` 里已有"优选直连不查 DNS"的捷径，但条件是 `pinnedAddress && !echConfig.isEmpty`。ECH 抓取失败时捷径**静默失效**，退回 DoH 解析——这正是"优选看起来没生效"的一类原因。
- 平台约束：`NWParameters.PrivacyContext.requireEncryptedNameResolution(true)` 是**全进程唯一解析器**，无法像 CFluxDo 那样逐条查询回退。因此"可用性"只能靠**事前选对服务器** + **减少对 DNS 的依赖**来换，这两点正好对应上面两个目标。

## Requirements

### R1 「自动」选服模式

- R1.1 设置页 DoH 服务器列表顶部新增「自动」一项（本地化 key `settings.network.doh.auto`），与现有内置服务器、自定义服务器同属单选组。
- R1.2 自动模式的候选集 = 内置预设中**带 bootstrap IP** 的服务器（DNSPod / 腾讯 DNS / Cloudflare / 阿里 DNS / Quad9 / Google）。无 bootstrap 的预设（Canadian Shield）与用户自定义服务器不参与自动选服。
- R1.3 探测方式：对每个候选并发发起一条真实 DoH A 查询（复用 `DohBootstrapTransport.query` 的竞速能力，目标名如 `linux.do`），**首个返回合法应答的候选获胜**；应答必须能解析出至少一个地址。整体探测预算 ≤ 3 秒，失败候选不阻塞。
- R1.4 选中的服务器（URL + bootstrap IP + 选中时间）持久化；`EncryptedDnsService.spec(fromDefaults:)` 在自动模式下读取这份结果。
- R1.5 **冷启动不等待探测**：没有历史结果时先用默认服务器（DNSPod）落 spec，探测在后台进行；获胜者与当前不同则热切换。
- R1.6 重新选服的触发条件（任一满足）：App 回到前台、网络路径变化、`DohBootstrapTransport.onRepeatedFailure` 看门狗触发、距上次选服超过阈值（见待定项）。
- R1.7 自动模式**不得**在 DoH 关闭时探测。关闭 DoH 即停止一切探测。
- R1.8 用户手动选择任一具体服务器时，自动模式自动关闭（成为普通单选，不再被后台切换）。用户再次点「自动」才恢复。
- R1.9 自动模式下的结果必须能被现有日志体系看到：选中了谁、耗时多少、候选失败原因（走 `DohDebugLog`，不静默）。

### R2 优选直连 + ECH 解耦

- R2.1 现有"pin + ECH 齐全 → 直连不查 DNS"路径保持不变。
- R2.2 新增一条：**有 pin 但 ECH 为空**时，先用该 pin 发起连接（短超时，约 2 秒）；成功则完成隧道，失败则回到现有 `resolver.resolve` 路径（不得直接判失败）。
- R2.3 回退时日志需明确区分「优选直连成功」「优选直连失败，回退解析」，便于线上判断是哪条路径在生效。
- R2.4 该改动不得影响 `LocalConnectProxy` 现有的 `failStreak` / 优选降级记账：短超时失败**不计入** `PreferredNodeStore` 的失败计数（避免一次瞬时抖动把赢家打下来）——或按现有 `reportOutcome` 语义明确选一种并在 `design.md` 里写明理由。

## Acceptance Criteria

- [ ] 设置页可选择「自动」，选择后无需填写或挑选具体服务器。
- [ ] 自动模式下首次启动能在一轮探测后选中可用服务器，且选中结果在下次启动被直接使用（不重复探测等待）。
- [ ] 自动模式下把当前网络切到"只有 DNSPod 可达"的场景时，能在同一轮探测里选中 DNSPod，而不是卡在超时。
- [ ] 关闭 DoH 后不再发起任何探测请求（日志中无新的探测记录）。
- [ ] 用户手动选一台服务器后，后台不再自动切换。
- [ ] ECH 缺失但优选赢家存在时，`openTunnel` 走直连路径；直连失败后仍能在同一连接上回退到解析路径并打开页面。
- [ ] `Packages/DohProxy` 的 `swift test` 通过；新增选服逻辑至少有一个单测覆盖"候选全部失败时落到默认"。
- [ ] `xcodebuild -destination 'generic/platform=iOS Simulator'` 构建通过。

## Out Of Scope

- 服务端下发的"域名 → CF IP"路由表（需要服务端配合）。
- 逐查询降级到系统 DNS（`requireEncryptedNameResolution` 平台限制）。
- 解析路径上的 Cloudflare 网段筛选（`CfScreen` 式）、DoH 请求 UA / RFC 8467 padding、405/415 的 GET 回退。
- 挑战域名（`challenges.cloudflare.com`）借优选赢家、钉住时的地址族过滤。
- 自建 DoH 的 Bearer token 支持。

以上已在 DoH 对比结论中记录，作为后续独立任务处理，不在本任务范围内。

## Decisions

- **自动模式的默认值**：仅对**从未显式选过服务器**的用户默认开启（含新装）。已经显式选过具体服务器的用户保持原选择。判定依据：`dohProvider` 键存在 或 新标记 `dohServerManuallySelected == true` → 视为已显式选择。
- **重选时机**：网络路径变化、看门狗触发时立即重选；另有每 6 小时的节流重选（仅前台）。冷启动不额外探测，直接用已持久化的结果，超过 6 小时才重选。
