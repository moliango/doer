# CF 出盾循环与解析挂死修复

## Goal

linux.do 的 Cloudflare 验证页不再反复弹出，验证页本身也不再无限转圈。

## Background

现网日志（设备 19:20–19:47，来自 `/tmp/doer-net3.log`）：

1. **429 被当成可解的盾**

```
19:23:19.993 [CF] challenge detected status=429 hasClearance=true route=/session/current.json
19:25:43.902 [CF] challenge detected status=429 hasClearance=true route=/session/current.json
```

429 的响应体是 `cType: 'managed'` 的挑战页，带 `<meta http-equiv="refresh" content="360">`——CF 的限流规则把动作配成 Managed Challenge 时回的就是 429 挑战页。窗口没过之前用户怎么点都过不去，`cf_clearance` 也绕不过。旧代码把它当普通盾：停图 60s、arm 前台 gate 20s、弹验证 sheet，于是每 30 秒一轮「弹 sheet → 解不开 → 再弹」。

2. **验证页依赖的域名解析永久挂死**

```
19:23:27.514 [DoH] CONNECT brunhild.challenges.cloudflare.com:443
19:23:28.559 [DoH] bootstrap ok 1.1.1.1 bytes=100
（之后既无 Resolved，也无 Resolve failed）
```

对照 15:03 成功解盾那次：

```
15:03:05.926 [DoH] Resolved brunhild... -> 2606:4700:...:1092, ...:1192
15:03:06.534 [DoH] Upstream first bytes 5147 from brunhild.challenges.cloudflare.com
```

`DohBootstrapResolver.load` 用 `DispatchGroup` 等 A / AAAA / HTTPS 三路查询，`group.notify` 之前没有总超时。任何一路不回调，`resolve()` 永远不返回，上层的 CONNECT 和 WKWebView 请求一起挂死。

## Requirements

- R1 单次 `resolve` 必须有总超时（8s，比传输层 `raceTimeout = 6` 长），超时返回可诊断的 `.resolveTimeout(host)` 并写负缓存；打一行 `resolve timeout host=...`。
- R2 超时后迟到的查询结果不得重复回调调用方，但仍要写入缓存并清掉超时写下的负缓存。
- R3 429 + `cf-mitigated: challenge` 归类为**限流**：只记窗口和日志，不暂停图片、不 arm 前台 challenge gate、不发验证通知。
- R4 限流窗口取 `Retry-After`（缺省 60s，钳在 30–600s）；窗口内前台请求直接抛限流错误，不发网络；2xx 清窗口；默认不滚动延长，只有服务器明确给 `Retry-After` 才允许延长。
- R5 各 `DiscourseAPI+*` 扩展里的 429 错误语义统一为 `error.rate_limited`，不再抛「需要完成 Cloudflare 验证」。

## Acceptance Criteria

- [x] 模拟器构建通过：`xcodebuild -workspace Doer.xcworkspace -scheme Doer -destination 'generic/platform=iOS Simulator' build`，exit=0。
- [x] `cd Packages/DohProxy && swift build && swift test` 通过（44 通过，1 跳过）。
- [x] 日志出现 `rate limit window armed base=... duration=Ns` 与 `rate limited, not a solvable challenge ... status=429`，且不再紧跟 `foreground challenge gate armed`。
- [ ] 真机复测：出盾后验证页要么解开，要么日志给出 `resolve timeout host=brunhild... after 8s` 这类明确失败原因，不再无限转圈。

## Out Of Scope

- 优选的 trace 探针仍在打 `Host: linux.do`（降低 zone 侧 bot 分，另开任务）。
- bootstrap 跳过 `198.18.0.0/15`（TUN fake-IP）答案、或按可用性切换 DoH server。
- 前台轮询降频。
## Follow-up：回前台断网与 IPv6-only 域名（21:34–21:49 日志）

1. `brunhild.challenges.cloudflare.com` 只有 AAAA（dns.google 实测），IPv4-only 的 Wi‑Fi 上 `2606:...` 连接直接 `ENETDOWN(50)`，`connectUpstream` 只在 `.failed/.cancelled` 换地址，`.waiting` 要等到超时；一次 blev 16 秒才 `Reject proxy`。
2. 回前台后所有请求 `kCFErrorDomainCFNetwork 310`（HTTPS proxy 连接失败），期间没有任何 `[DoH] CONNECT ...` 日志 → URLSession 连不上 127.0.0.1 监听端口；`ensureProxyAlive()` 只看 `listener != nil && boundPort != nil`，监听器挂起后停在 `.waiting` 时仍然判活。

- R6 `ensureProxyAlive` 必须对回环端口做一次真实 connect 探活；探活失败就拆掉重建代理并打日志。
- R7 `connectUpstream` 在 `.waiting` 且错误为 `EAFNOSUPPORT/ENETDOWN/ENETUNREACH/EHOSTUNREACH` 时立刻换下一个地址，不 arm 看门狗、不等超时；`connectGatewayOriginTCP` 保持一致。
- AC：模拟器构建通过；真机日志出现 `Local CONNECT proxy health check failed` 后能自行恢复，且 IPv6-only 域名不再有 8 秒级 `Upstream waiting`。

## Follow-up：DoH 全线不可用导致验证页过不去（10:01–10:02 日志）

设备日志里这段时间**没有任何一次 DoH 解析成功**：

```
10:01:53.230 [DoH] bootstrap failed 8.8.4.4: DoH query failed for timeout
10:01:53.436 [DoH] bootstrap failed 8.8.8.8: DoH query failed for timeout
10:01:53.712 [DoH] bootstrap failed 2001:4860:4860::8888: DoH query failed for timeout
10:01:56.744 [DoH] 自动选服失败（3029ms）：候选应答均不可用：
        AliDNS(投毒 128.242.245.93), DNSPod(投毒 173.236.182.137), 腾讯 DNS(投毒 173.236.182.137)
```

`dns.google` 的 8.8.8.8 / 8.8.4.4 在该网络里连不通；国内三家的 DoH 应答被污染，
被选服器否决；3s 的扫描预算又比传输层 6s 的竞速预算还短，慢一点但能用的候选根本来不及回报。
结果是除「优选直连 linux.do」以外，**所有域名都解析失败**：

```
10:01:55.227 [DoH] Resolve failed for challenges.cloudflare.com: DoH query failed for timeout
10:01:55.227 [DoH] Reject proxy: resolve failed
```

验证页要加载 Turnstile 的 iframe（`challenges.cloudflare.com`），解析失败 → iframe 起不来 →
Cloudflare 页面提示「检查浏览器设置 / 禁用扩展」。用户看到的就是「出盾了但过不去」。
`cdn.ldstatic.com` 等 CDN 域名同理，图片一起挂。

实测（curl `--resolve`）确认：Cloudflare 任何边缘 IP 都能服务任意 CF zone 的域名，
`162.159.237.199`、`104.16.248.249` 对 `challenges.cloudflare.com` 均返回 302，
对 `cdn3.ldstatic.com` 返回 200。

- R8 `resolveAndConnect`（以及网关解析路径）在目标主机属于「验证页离不开的 CF 域名」
  （`challenges.cloudflare.com` 及其子域、`ldstatic.com` 及其子域）且 DoH 解析失败时，
  用优选赢家 IP（存在且地址族可路由）直接建连，走正确 SNI，不 reject；
  解析成功但全部地址连不上时同样退到赢家 IP。日志打
  `Resolve unavailable for <host>; using Cloudflare edge <ip>`。
- R9 自动选服的扫描预算必须长于传输层竞速预算（6s + 0.6s 错峰），否则「慢但可用」的
  服务器会被判死；取 8s。
- AC：模拟器构建通过；DoH 不可用时验证页仍能加载 Turnstile 并完成验证；
  日志出现上述兜底行，且不再有 `challenges.cloudflare.com ... Reject proxy`。
