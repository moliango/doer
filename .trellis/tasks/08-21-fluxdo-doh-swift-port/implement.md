# 实施计划

按顺序做。每步可单独编译；不要先铺 UI 再补协议。对照 `/Users/naine/Documents/AndroidWorkspace/fluxdo`。

`ponytail:` 只允许 design.md 列出的平台偏离（无 Dio/rhttp、无 Flutter WebView 类名、不复刻 JA3、iOS 15–16 WebView API 限制、不暴露 `mitm_connect=false`）。**禁止**再给 ECH / Gateway / 全 Host MITM 写 ponytail。

1.8 原型（`linux.do` allowlist、`SSLCreateContext`、图片 `clearProxy`、系统 DNS 回落）是要替换的基线，不是可保留双路径。

## 0. 依赖与配置模型

- [ ] `Tuist/Package.swift` 增加 `swift-nio`、`swift-nio-ssl`、`swift-nio-http2`、`swift-nio-transport-services`；`Project.swift` Doer target 加对应 product（`.external`，与 Alamofire 相同）。
- [ ] rustls ECH 客户端：vendoring `fluxdo_doh` 的 ECH/HTTPS 查询 + rustls 出口，或等价 rustls-ffi。只承担 `lookupEchConfig` 与 origin TLS，不把整份 Rust 代理当第二套监听实现。
- [ ] `DohProxyConfig`：UserDefaults + Keychain 快照；签名变化才重建。
- [ ] `AppSettings+DoH`：Gateway（默认 true）、h2 MITM（默认 false）、prefer IPv6、server IP、ECH 服务器、上游协议/主机/端口/用户名/cipher、自定义 bootstrap。上游密码 Keychain `com.naine.doer.doh.upstream-password`。
- [ ] DoH 列表对齐 FluxDo：DNSPod、腾讯 DNS、Cloudflare、Canadian Shield、阿里、Quad9、Google、自定义。新安装默认 DNSPod；已有 `dohProvider` 不改写。
- [ ] `make generate`

**验证**：工程能解析 SPM / rustls；旧 `dohEnabled` 键仍在。

## 1. DoH 解析 + ECH lookup

- [ ] 去掉 `DohResolver.isAllowedHost`。任意 Host 可解析。
- [ ] JSON / wire / HTTPS 查询都打 bootstrap IP，SNI/Host 仍是 DoH 域名。禁止失败后回落 `URLSession.shared`。
- [ ] TTL 60…1800、inflight 去重、缓存上限 1000、粘性 IP 10 分钟、失败 IP 惩罚 2 分钟。
- [ ] `lookupEchConfig(host, dohServer)` 返回原始 bytes；空则 negative cache。
- [ ] 独立 ECH 服务器；空则与 A/AAAA 相同。
- [ ] 暴露 cache stats / records / `clearCache` / `recordHostSuccess`。
- [ ] 自定义 URL 无 bootstrap 且 Host 不是 IP → 启动失败，状态行可见。

**验证**：单测 bootstrap 不走系统 DNS；`example.com` 可解析；CF Host 可解析；无 ECH 时负缓存。

## 2. 门面改成 FluxDo 单路径

- [ ] `apply(to:)`：DoH 开就挂 CONNECT，不再要求 `linux.do`。
- [ ] Gateway 开：API/图片走 `GatewayRewriter`，不挂 CONNECT 字典。
- [ ] Gateway 关：API/图片挂 CONNECT。
- [ ] iOS 17+：WKWebView `proxyConfigurations` CONNECT；关掉 `EncryptedDnsService` 主路径。
- [ ] iOS 15–16 WebView：尽量原生挂钩；不行则设置页写明。API/图片仍走 Gateway/CONNECT。
- [ ] `AvatarImageLoader` / `ExternalImageFetcher` 与 API 同一路径，禁止 `clearProxy`。
- [ ] `statusDescription` 显示端口、Gateway/ECH 状态、失败原因。

**验证**：关 DoH 后字典、`proxyConfigurations`、Gateway 改写全部清空。

## 3. 默认 CONNECT MITM + rustls 出口

- [ ] `shouldMITM`：CF 除外任意 Host 为 true。非 CF 解析失败回 502，禁止系统 DNS 直通。
- [ ] 出口 rustls 连 DoH IP；有 ECH config 则启用 ECH。
- [ ] 默认 ALPN 锁 `http/1.1`，明文拷贝。
- [ ] 删掉 `SSLCreateContext` / semaphore 忙等。MITM 客户端 TLS = NIOSSL server。
- [ ] `MitmCertificateAuthority`：h2 关只签 http/1.1；开则 `h2` + `http/1.1`。

**风险文件**：`LocalConnectProxy.swift`、`MitmTLSBridge.swift`、`MitmCertificateAuthority.swift`、新 `DohEchClient.swift`。

**验证**：`LocalConnectProxyTests`：`example.com` MITM，CF 否。源码不再出现 `SSLCreateContext`。

## 4. Gateway

- [ ] 同一端口接受明文 HTTP。按 `Host` 做 rustls+ECH 反代。
- [ ] `GatewayRewriter`：只改发出的 `URLRequest`；Cookie/重试/拦截器看到原始 `https://`。
- [ ] 回环例外，避免 301 环。
- [ ] 开关变化重建代理并换 `DiscourseAPI` session。

**验证**：Gateway 开时抓包可见发往 `127.0.0.1` 的 HTTP，Cookie 域名仍是论坛 Host。

## 5. 信任挂钩

- [ ] `FluxDoMitmTrustManager`：DoH 开且走 MITM 时默认 evaluator 覆盖任意 Host。
- [ ] 对齐 `DohProxyCertHandler`：原生挂钩所有 `WKWebView`（登录、session 刷新、应用内浏览器、弹窗、CF 验证页）。
- [ ] 关闭 DoH 拆除挂钩。

**验证**：挑战页不 MITM；普通 HTTPS 叶证书能被 WebView 接受。

## 6. 上游 HTTP / SOCKS5 / Shadowsocks

- [ ] `UpstreamProxyClient`：HTTP CONNECT + Basic；SOCKS5 greeting/userpass/domain CONNECT。
- [ ] Shadowsocks：`aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-256-gcm`。
- [ ] 上游主机名用 DoH/bootstrap，不用系统 DNS。
- [ ] 无效配置 → 状态失败，不静默直连。
- [ ] 协议测试：handshake 字节、SS 2022 密钥长度 32、Keychain 读写。

## 7. h2 MITM

- [ ] 关：不得协商 h2。
- [ ] 开：NIOHTTP2 真多路复用；源站按 ALPN 走 h2 或 h1，出口仍 rustls+ECH。
- [ ] 开关变化重建代理，无孤儿端口。

**验证**：单测 ALPN 随开关变化。

## 8. 设置页

- [ ] 端口、缓存条数、清空、失败原因。
- [ ] Gateway、h2 MITM、IPv6、server IP、自定义 bootstrap。
- [ ] ECH 服务器 + “ECH 可用 / 无 ECH”。
- [ ] 上游卡片 + 测试按钮。
- [ ] iOS 15–16 浏览器限制说明（仅当无法 CONNECT 时）。
- [ ] 中英文案进 `Localizable.xcstrings`。

## 9. 回归测试

- [ ] 更新 `LocalConnectProxyTests`、`EncryptedDnsServiceTests`（若兜底仍在）。
- [ ] 新增：config 签名、resolver 缓存/去重、ECH 负缓存、Gateway 改写不污染 Cookie、upstream handshake、SS 密钥、ALPN、CF 不 MITM、关 DoH 清代理、禁止系统 DNS 回落。
- [ ] `make generate`
- [ ] 编译（不启动模拟器，除非用户要求）：

```bash
xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

能跑单测再跑 `DoerTests`。设备验收：linux.do API（Gateway 开/关）、登录 WebView、应用内浏览器、Turnstile、有/无 ECH 站点、关 DoH 恢复。

## 回滚点

| 点 | 动作 |
|---|---|
| 第 0 步依赖编不过 | 撤 SPM/FFI，停在 1.8 原型 |
| 第 3 步 MITM/ECH 不稳 | `dohEnabled=false` 立即回系统网络；不要回 SecureTransport |
| 第 4 步 Gateway Cookie 错乱 | 默认先关 Gateway，API 走 CONNECT MITM |
| 第 6–7 步 SS/h2 未完 | 主路径仍可开；对应开关默认关 |

## `task.py start` 前核对

- [x] `prd.md` 验收可测，第一批含默认 MITM + ECH + Gateway + 上游 + h2
- [x] `design.md` 有边界、数据流、仅平台偏离、回滚
- [x] 本清单有序且有验证命令
- [ ] 用户看过规划并同意开始实现
