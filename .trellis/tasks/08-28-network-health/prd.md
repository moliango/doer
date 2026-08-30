# 网络健康总览

## Goal

设置里一张只读快照：当前通道（DoH/引擎）、盾态、CSRF、并发窗口。

## Acceptance Criteria

- [x] 可从网络设置进入总览。
- [x] 展示引擎或 DoH 状态、Cloudflare 盾/冷却、是否有 CSRF、并发限制。
- [x] 只读投影，不第二套判定逻辑。
- [x] 不做自动「修复」按钮改 Cookie 登录。

## Out Of Scope

- 重写 DoH 栈（`08-21-fluxdo-doh-swift-port`）。
