# 技术设计

把 FluxDo 现网 `doh_proxy` 行为一比一对齐到 Doer 现有入口。UIKit 调用方不搬 Dart。出口 TLS 用 rustls 注入 ECH；监听 / CONNECT / Gateway HTTP / MITM 客户端用 Swift。

## 架构

```
Alamofire / URLSession / SDWebImage
        │
        ├─ gateway ON  →  http://127.0.0.1:port + Host: real
        └─ gateway OFF →  CONNECT 127.0.0.1:port
WKWebView (始终 CONNECT MITM)
        │
        ▼
LightweightDohProxyService   同一端口
        │
        ├─ DoH A/AAAA + HTTPS/SVCB ECH（bootstrap IP，禁止系统 DNS）
        ├─ challenges.cloudflare.com → 纯隧道
        ├─ CONNECT MITM：NIOSSL 终止客户端 TLS
        │     出口 rustls → DoH IP，ECH config 可注入
        ├─ Gateway：明文 HTTP 反代，出口同样 rustls+ECH
        ├─ h2 MITM 开：NIOHTTP2 多路复用后再 rustls 上游
        └─ 可选上游：HTTP CONNECT / SOCKS5 / Shadowsocks
```

门面仍叫 `LightweightDohProxyService`。内部从“Encrypted DNS + linux.do CONNECT 原型”改成 FluxDo 单代理。

## 模块边界

全部放在 `Doer/Networking/DoH/`。UIKit 只碰门面、`MitmTrust`、`AppSettings+DoH`。

| 文件 | 职责 | 处置 |
|---|---|---|
| `LightweightDohProxyService.swift` | 启停、签名、挂 session / WebView / 图片 | 改：DoH 开则全 Host；Gateway 改写与 CONNECT 按开关 |
| `LocalConnectProxy.swift` | 回环监听、CONNECT/SOCKS、Gateway HTTP、分流 | 改：任意 Host DoH；CF 隧道；禁止系统 DNS 直通 |
| `DohResolver.swift` | A/AAAA、HTTPS/SVCB、TTL、inflight、粘性 IP、负缓存 | 改：去 allowlist；只打 bootstrap；查 ECH |
| `DohEchClient.swift` | rustls 出口 TLS + `lookupEchConfig` | **新**（ECH 硬需求） |
| `MitmCertificateAuthority.swift` | per-device CA + 叶证书 ALPN | 留，补 h2 ALPN |
| `MitmTrust.swift` | Alamofire evaluator + WKWebView challenge | 改：任意 Host；原生 swizzle 防漏接 |
| `MitmTLSBridge.swift` | 客户端 TLS 终止 | **删 SecureTransport**，NIOSSL acceptor |
| `EncryptedDnsService.swift` | PrivacyContext Encrypted DNS | **删除主路径**。仅当 iOS 15–16 WebView 无法挂 CONNECT 时作解析兜底，且设置页标明不是 MITM/ECH |
| `DohProxyConfig.swift` | 运行时快照 | 新 |
| `GatewayRewriter.swift` | Alamofire 仅在发出时改写 URL，恢复原始 URL | 新 |
| `UpstreamProxyClient.swift` | HTTP / SOCKS5 / Shadowsocks | 新 |
| `H2MitmForwarder.swift` | h2 多路复用 | 新 |
| `Socks5Handshake.swift` / `DohConnectRequest.swift` | 本地握手解析 | 留 |

设置：`AppSettings+DoH.swift` + `NetworkSettingsViewController.swift`。上游密码 Keychain tag `com.naine.doer.doh.upstream-password`。

## 运行时合同

`DohProxyConfig` 在 `configureFromSettings()` 从 UserDefaults + Keychain 拍快照，签名变化则重建。

```
dohEnabled
dohServerURL + bootstrapIPs
dohEchServerURL          空 = 与 A/AAAA 相同
gatewayEnabled           默认 true
h2Mitm                   默认 false
preferIPv6               默认 false
serverIP                 可选，跳过解析
upstream: protocol/host/port/username/cipher + Keychain password
```

默认值对齐 FluxDo：`mitm_connect=true`（不暴露关闭）、`h2_mitm=false`、`gatewayEnabled=true`。

重建：开关 DoH / 换 DoH 或 ECH 服务器 / Gateway / h2 / IPv6 / server IP / 上游 → 停旧监听，取消旧连接，`configurationVersion += 1`，`DiscourseAPI` 换 session。

## 数据流

### 1. CONNECT MITM（WebView 恒走；Gateway 关时 API/图片也走）

1. 客户端 `CONNECT host:443`。
2. Host 是 `challenges.cloudflare.com` → 纯隧道。
3. DoH 解析 A/AAAA（有 `serverIP` 则跳过）+ HTTPS ECH。失败回 502，不系统 DNS。
4. 出口 TCP 连解析 IP（或先上游代理）。**rustls** 客户端：SNI = 真实 Host；有 ECH config 则启用 ECH。
5. 上游 TLS 成功后回 `HTTP/1.1 200 Connection Established`。
6. NIOSSL 用叶证书对客户端做 TLS server。h2 关则 ALPN 仅 `http/1.1`。
7. 握手后明文双向拷（h2 开且协商到 h2 则走 `H2MitmForwarder`）。

### 2. 纯隧道

仅 CF 验证域名。DoH 解析后裸 TCP 转发。禁止签发叶证书。

### 3. Gateway（默认开，仅 API/图片）

对齐 FluxDo `_GatewayAdapterWrapper`：

1. Alamofire `RequestAdapter` 在发出前把 `https://host/path` 改成 `http://127.0.0.1:$port/path`，设置 `Host: host`。
2. 响应链 / Cookie / 重试看到的仍是原始 `https://` URL（adapter 在 session 层改 `URLRequest`，不改 `DiscourseAPI` 的逻辑 URL）。
3. 代理按 `Host` 做源站 rustls+ECH，把明文 HTTP 转进去。
4. 回环不得再进系统代理，避免 Always-Use-HTTPS 301 死循环。
5. `gatewayEnabled=false` 或代理未跑：不改写，改挂 CONNECT。

### 4. h2 MITM（默认关）

开：叶证书 ALPN = `h2` + `http/1.1`。客户端选 `h2` 走 `H2MitmForwarder`，上游仍 rustls（可 ECH）。关：不得协商 h2。

### 5. 上游代理

到源站的 TCP 换成 HTTP CONNECT / SOCKS5h / Shadowsocks AEAD 2017 与 SIP022 `2022-blake3-aes-256-gcm`。上游域名用 DoH/bootstrap，禁止系统 DNS。密码只读 Keychain。

### 6. 接入点

| 调用方 | Gateway 开 | Gateway 关 |
|---|---|---|
| `DiscourseAPI.makeSession` | `GatewayRewriter` + 信任本地 CA | CONNECT 字典 + 全 Host MITM evaluator |
| 图片加载 | 同一 Gateway 改写 | 同一 CONNECT，**禁止** `clearProxy` |
| iOS 17+ WKWebView | 始终 CONNECT MITM | 同左 |
| iOS 15–16 WKWebView | 原生代理挂钩；不行则设置页写明无 MITM | 同左 |
| 登录 / 应用内浏览器 / CF 页 | `MitmTrust` swizzle | 同左 |

`ExceptionsList`：`127.0.0.1` / `localhost` / `::1`。

## ECH / rustls

Network.framework 与 NIOSSL 都不能注入 DNS HTTPS 的 ECH config bytes。1:1 要求：

- 新增 `DohEchClient`：rustls 客户端 + HTTPS 记录解析，语义对齐 `doh_proxy_lookup_ech_config` 与 FluxDo 出口 ECH。
- 源码可 vendoring `fluxdo_doh` 里 ECH/rustls 相关部分，或 rustls-ffi；**不要**把整份 Rust 代理（监听/MITM/Gateway）再链进 App 当第二套实现。
- `lookupEchConfig` 给设置页和负缓存用；出口握手用同一份 bytes。
- 无 config：常规 TLS，SNI 明文，UI 显示“无 ECH”。
- 禁止 `EncryptedDnsService` 充当 ECH。

## TLS 选型（客户端 MITM）

Network.framework 不能在已完成的 CONNECT TCP 上升级成 TLS server。客户端 MITM 用：

- `swift-nio-transport-services` + `swift-nio-ssl` + `swift-nio-http2`
- Tuist：`Tuist/Package.swift` `.external`，与 Alamofire 相同，不要第二份 `.package` URL
- 项目 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`：NIO / rustls FFI 类型必须 `nonisolated`，禁止 EventLoop hop 到 MainActor 再同步等

## 证书与信任

- CA：设备内 RSA 2048，Keychain tag 不变。禁止打包同一把 CA。
- 叶证书 SAN = 当前 Host，密钥复用（FluxDo 相同）。
- Alamofire：DoH 开时默认 `MitmTrustEvaluator` 覆盖任意 Host，失败再系统信任。Gateway 明文 HTTP 不走 MITM 证书。
- WKWebView：对齐 `DohProxyCertHandler`，原生 swizzle / 统一挂钩所有 `WKWebView` 子类。关闭 DoH 拆除。

## DoH 解析

- 只连 bootstrap IP。自定义 URL：Host 已是 IP 则当 bootstrap；否则 `dohCustomBootstrapIPs`；都没有则启动失败。
- TTL 60…1800s。inflight 去重。缓存 1000。粘性 IP 10 分钟。失败 IP 惩罚 2 分钟。
- 同时查 A/AAAA 与 HTTPS（ECH 服务器可不同）。
- 服务器列表对齐 FluxDo：DNSPod、腾讯 DNS（`dns.pub`）、Cloudflare、Canadian Shield、阿里、Quad9、Google、自定义。新安装默认 DNSPod；已有 `dohProvider` 不改写。

## 设置 UI

`NetworkSettingsViewController` 原生卡片。

保留：DoH 开关、服务器、自定义 URL、状态、CF 验证、调试日志。

新增/对齐 FluxDo：

- 状态行带端口
- 缓存条数 + 清空
- Gateway 开关（默认开）
- h2 MITM（默认关）
- IPv6 优先、固定 server IP、自定义 bootstrap
- ECH 服务器 + “ECH 可用 / 无 ECH”
- 上游：协议 / 主机 / 端口 / 用户名 / 密码 / cipher；测试按钮
- iOS 15–16 若无 CONNECT：明确写限制

文案 `String(localized:)`，中文进 `Localizable.xcstrings`。

## 兼容与迁移

| 1.8 原型 | 目标 |
|---|---|
| 只 MITM `linux.do` | 任意 Host；CF 除外纯隧道 |
| 其它 Host 系统 DNS 直通 | 解析失败 502，不直通 |
| 图片 `clearProxy` + Encrypted DNS | 与 API 同一 Gateway/CONNECT |
| `SSLCreateContext` | NIOSSL |
| 无 ECH | rustls 可注入 ECH |
| 无 Gateway | 默认开，Alamofire 改写 |
| JSON/bootstrap 失败回落 URLSession | 禁止 |
| Alamofire 只信 `linux.do` | 全 Host evaluator |
| 默认 AliDNS | 新用户 DNSPod；旧值保留 |

旧键 `dohEnabled` / `dohProvider` / `dohCustomURL` 保留。

## 有意偏离（仅平台/架构，写 `ponytail:`）

1. **无 Dio/rhttp。** Gateway 用 Alamofire `RequestAdapter` 等价改写，不是 Dart adapter。
2. **无 Flutter InAppWebView。** 信任挂钩打在 `WKWebView`，不是 `flutter_inappwebview_ios.InAppWebView`。
3. **不复刻 Chrome JA3 套件序。**
4. **iOS 15–16 WebView CONNECT** 若系统 API 不支持：设置页写明；API/图片仍走 Gateway/CONNECT。不得用 Encrypted DNS 冒充 ECH。
5. **不暴露 `mitm_connect=false`。** 与 FluxDo WebView 恒 MITM 一致。

不再把 ECH、Gateway、全 Host MITM 标成偏离。

## 回滚

总开关 `dohEnabled`。关掉必须：停监听、清代理字典 / `proxyConfigurations`、停 Gateway 改写、停 Encrypted DNS 兜底、停 CA 挂钩、换 `DiscourseAPI` session。NIO / rustls 依赖可留在工程，运行时不启动。

## 风险

- rustls FFI 与 MainActor：全部 `nonisolated`，启动失败要在状态行可见。
- 全 Host MITM + 漏接 WKWebView 信任 = 握手失败 → swizzle 是硬需求。
- Gateway Cookie：改写必须只发生在 `URLRequest` 发出瞬间。
- Shadowsocks 2022（Blake3、会话、时间戳）四个 cipher 都要能测通。
- 图片曾不能混 SOCKS 与 Encrypted DNS；统一代理后禁止再给 SDWebImage 开 PrivacyContext。
