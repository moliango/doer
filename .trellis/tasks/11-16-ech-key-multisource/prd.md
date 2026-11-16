# 投毒网络下的 ECH 钥匙获取与优选降级

## Goal

DNS 被投毒的网络上（国内解析器把 `linux.do` 解析成 Facebook 段地址），优选仍然能工作。

## Background

现网日志（阿里 DNS）：

```
[DoH] DoH prewarm linux.do -> 157.240.6.35, 2a03:2880:f10f:83:face:b00c:0:25de ech=0
[优选] 取不到 ECH 钥匙，跳过优选（不查 linux.do）
[优选] 优选失败：全部候选都没通过
```

链条：配置的 DoH 投毒 → HTTPS 记录也拿不到 ECH 钥匙 → 优选直接放弃 → 没有钉住的 IP → 连接落到假地址 → 超时。

对照 CFluxDo（`fluxdo_doh` @ f584d0e）的做法：

1. **ECH 钥匙走独立的公共 DoH 端点**（`PUBLIC_DOH_ENDPOINTS`，全部 IP 字面量、证书带 IP SAN，完全不经系统 DNS），与用户配置的 DoH 无关。
2. **钥匙来源是多域名**（`HTTPS_KEY_DOMAINS = icook.tw / skk.moe / japan.com`），不吊死在目标站上。
3. **拿不到钥匙不放弃竞速**：`gather()` 同时返回 `(candidates, keys)`，钥匙为空也照跑，探针用明文 SNI。

## Requirements

- R1 新增一条"经公共 DoH 查 HTTPS 记录"的路径，用于 ECH 钥匙获取；端点取自 `AppSettings.DoHProvider` 的内置项（自带 bootstrap），并发发起，首个带回 ECH config 的胜出。
- R2 `fetchKeysFromHTTPSRecords` 先走公共端点；全部失败再回退到当前配置的 DoH 解析器（保持现有行为）。
- R3 钥匙仍为空时，`racePasses` 不再中止优选，而是以空钥匙（明文 SNI）继续跑完，并在日志里写明。
- R4 日志必须能回答"钥匙从哪来"：每个域名/端点是否成功、拿到了几把钥匙。

## Acceptance Criteria

- [ ] 配置的 DoH 返回投毒答案时，仍能通过公共端点拿到 ECH 钥匙（日志可见）。
- [ ] 所有端点都拿不到钥匙时，优选照常竞速（日志出现"按明文 SNI 继续竞速"），不再出现"跳过优选"。
- [ ] 优选在钥匙来源上不再依赖用户配置的那台 DoH。
- [ ] `xcodebuild ... generic/platform=iOS Simulator` 构建通过；`Packages/DohProxy` 测试通过。

## Out Of Scope

- 解析路径上的投毒应答过滤（`CfScreen` 式的 A 记录网段校验）。
- 路由表 / 节点表下发。

## Notes

- 数据来源：`/tmp/fluxdo_doh2` @ `f584d0e` 的 `src/select.rs`（`gather()`、`resolve_ech_key()`、`HTTPS_KEY_DOMAINS`）。
