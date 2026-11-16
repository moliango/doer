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