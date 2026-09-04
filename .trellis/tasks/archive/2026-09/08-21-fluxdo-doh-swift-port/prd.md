# Port FluxDo DoH proxy to Swift for Doer

## Goal

把 FluxDo 现网 `doh_proxy` **行为一比一对齐**进 Doer。开启 DoH 后，API、图片、WKWebView 走同一套进程内代理：DoH 解析（bootstrap、不走系统 DNS）+ CONNECT MITM / Gateway + 出口 rustls ECH。对照仓库：`/Users/naine/Documents/AndroidWorkspace/fluxdo`。

用户价值：linux.do 在 DNS 污染和 SNI 阻断下可稳定打开；设置项、默认值、分流规则与 FluxDo 一致，不靠系统 Encrypted DNS 冒充。

## Confirmed Facts

- FluxDo 引擎是 Rust `Lingyan000/fluxdo_doh`（本地 `core/doh_proxy` 为空）+ Dart 总控 `NetworkSettingsService` / `DohProxyService`。iOS 走 FFI `doh_proxy_start_with_config_json`。
- 能力不是“只做 DoH”，而是本地 HTTP 代理：A/AAAA、HTTPS 记录取 ECH config、CONNECT MITM、CF 验证域名纯隧道、Gateway 反向代理、h2 MITM、HTTP/SOCKS5/Shadowsocks 上游、per-device CA、DNS 缓存/粘性 IP/RTT。
- FluxDo Apple PRD（`fluxdo/docs/doh-proxy-swift-prd.md`）把 **ECH 与 CONNECT MITM 定为硬需求**，禁止用 Network.framework 系统自动 ECH 冒充 rustls 可注入 config 的语义。`lookupEchConfig` 必须返回原始 ECH config bytes。
- CONNECT：启用 DoH 即 MITM（`WebViewMitmPolicy.useMitmConnect` 恒为 true）。`challenges.cloudflare.com` 强制纯隧道。
- Gateway：默认 `doh_gateway_enabled=true`。Dio 在 `fetch()` 期间把 `https://host/path` 改成 `http://127.0.0.1:port/path` 并设 `Host`，拦截器始终看到原始 URL（Cookie 不能落到 localhost）。关 Gateway 时 API 回退 CONNECT MITM。
- rhttp 是 FluxDo 另一条直连+ECH 路径。Doer 没有 rhttp/Dio；API 对齐 **Gateway 开 = 明文反代，关 = CONNECT MITM**，不是 rhttp。
- h2 MITM 默认关；关=锁 HTTP/1.1 明文拷；开=真 HTTP/2 多路复用。
- 上游：HTTP CONNECT、SOCKS5、Shadowsocks（`aes-128-gcm` / `aes-256-gcm` / `chacha20-ietf-poly1305` / `2022-blake3-aes-256-gcm`）。
- 默认 DoH 列表（顺序与 bootstrap）：DNSPod、腾讯 DNS、Cloudflare、Canadian Shield、阿里 DNS、Quad9、Google。默认选中 DNSPod。独立 ECH 服务器可选，空则与 A/AAAA 服务器相同。
- iOS 信任：`DohProxyCertHandler` 原生 swizzle 全部 InAppWebView challenge，不走 Dart 通道。
- Network.framework / NIOSSL **不能**把 DNS HTTPS 记录里的 ECH config bytes 注入 ClientHello。要 1:1 ECH，出口 TLS 必须用 rustls（与 FluxDo 相同语义）。
- Doer 现状（1.8 原型，**不等于本 PRD**）：只 MITM `linux.do`；其它 Host 系统 DNS 直通；`SSLCreateContext`；图片 `clearProxy`；JSON/bootstrap 失败回落 `URLSession`；无 ECH / Gateway / h2 / 上游；Alamofire 只信 `linux.do`；WebView 信任只接登录和 session 刷新。
- Doer 接入点：`DiscourseAPI.makeSession`、`AvatarImageLoader` / `ExternalImageFetcher`、`WKWebsiteDataStore`、登录/应用内浏览器/CF 验证页、`NetworkSettingsViewController`。
- Doer 最低 iOS 15。`WKWebsiteDataStore.proxyConfigurations` 需要 iOS 17。
- `.trellis/spec/frontend/fluxdo-porting.md`：行为从 FluxDo 按契约搬，UI 用 Doer 原生卡片。本任务不再把 ECH/Gateway 标成 `ponytail` 偏离。

## Requirements

1. **行为与 FluxDo 现网一比一。** 设置项语义、默认值、分流、失败可见性对齐 `NetworkSettingsService` + `DohProxyService` + `doh_proxy` FFI config。UI 用 Doer 原生卡片，不搬 Flutter。
2. 开启 DoH 后：
   - Discourse API（Alamofire / URLSession）走本地代理。
   - 图片走同一套代理，禁止再 `clearProxy` 改 Encrypted DNS。
   - WKWebView（登录、应用内浏览器、弹窗、Cloudflare 验证）走本地代理。
3. **DoH 解析**（对齐 FluxDo `BootstrapDohClient` / resolver）：
   - 用户选择的 DoH URL + 官方 bootstrap IP；查询打 bootstrap IP，TLS SNI / HTTP Host 仍是 DoH 域名。
   - 禁止任何回落 `URLSession.shared` / 系统 DNS。
   - A/AAAA、TTL 60…1800、inflight 去重、缓存上限 1000、粘性 IP、失败 IP 惩罚、`recordHostSuccess`、cache stats/records/clear。
   - 自定义 URL 无 bootstrap 且 Host 不是 IP → 启动失败，状态行可见。
4. **CONNECT MITM（硬需求）**：
   - 任意普通 HTTPS Host MITM：per-device CA 叶证书终止客户端 TLS，再向源站独立 TLS。
   - 出口连 DoH IP（或固定 server IP），不得把真实 Host 交给系统 DNS。
   - `challenges.cloudflare.com` 禁止 MITM，纯隧道，Turnstile 端到端 TLS。
   - 默认叶证书 ALPN 锁 `http/1.1`（`h2_mitm=false`）。
   - 删除 `SSLCreateContext`。客户端 MITM TLS 用可维护的 Swift TLS server（NIOSSL）。
   - 所有走代理的 WKWebView 原生层信任本地 CA（对齐 `DohProxyCertHandler` swizzle），禁止漏接。
5. **ECH（硬需求，对齐 FluxDo Apple PRD）**：
   - 查询 DNS HTTPS/SVCB，取出 ECH config。
   - `lookupEchConfig(host, dohServer)` 返回原始 config bytes；无 config 时 null + negative cache。
   - 可单独配置 ECH 查询服务器；未配置则与 A/AAAA 服务器相同。
   - 代理出口 TLS（MITM 上游、Gateway 上游）拿到 config 后必须启用 Encrypted Client Hello，外层不得暴露真实 SNI。
   - 禁止用系统 Encrypted DNS / 自动 ECH 充当完成。
   - 无 ECH 的站点仍须用 DoH IP + 常规 TLS 连通；设置页显示“无 ECH”，不得显示“ECH 可用”。
   - 出口 TLS 使用 rustls（可注入 EchConfig）。CONNECT 监听、MITM 客户端、Gateway HTTP、设置仍是 Swift。
6. **Gateway（硬需求，默认开）**：
   - 与 FluxDo 相同：DoH 开 + `gatewayEnabled` + 代理在跑 → API/图片走回环明文 HTTP，`Host` 为真实域名；代理按 Host 对源站做 TLS（含 ECH）。
   - Alamofire 拦截器 / Cookie / 重试必须始终看到原始 `https://` URL，不能把 cookie 存到 `127.0.0.1`。
   - 关闭 Gateway：API/图片改走 CONNECT MITM（与 FluxDo 回退一致）。
   - WebView 始终 CONNECT MITM，不因 Gateway 开关改成纯隧道。
7. **h2 MITM 开关**（默认关）：关=锁 HTTP/1.1 明文拷；开=与客户端真协商 HTTP/2 并多路复用转发。切换后代理重建，无孤儿端口。
8. **上游代理**：HTTP CONNECT、SOCKS5、Shadowsocks 四个 cipher 均可建连。上游主机用 DoH/bootstrap 解析。密码进 Keychain，不进 UserDefaults。无效配置失败可见，不静默直连。
9. **设置页**对齐 FluxDo 可观测性：端口、缓存条目、清空、失败原因、h2、IPv6 优先、固定 server IP、自定义 bootstrap、ECH 服务器、ECH 有/无、Gateway 开关、上游卡片+测试。服务器列表与 FluxDo 默认列表一致（补腾讯 DNS、Canadian Shield）。已保存的 `dohProvider` 不强制改写；新安装默认 DNSPod。
10. 不引入 Flutter/Dart/Dio/rhttp。实现留在 `Doer/Networking/DoH/`，由现有 `LightweightDohProxyService` 门面调度。
11. 不暴露 `mitm_connect=false`（FluxDo WebView 侧恒 MITM）。CF 除外。

## Acceptance Criteria

- [ ] 开启 DoH 后，任意 API Host 不走系统 DNS；设置页显示本地代理已启动及端口。
- [ ] 关闭 DoH 后，API / WebView / 图片恢复系统网络，无残留代理字典、`proxyConfigurations`、Gateway 改写、CA 挂钩。
- [ ] 默认 CONNECT 为 MITM：任意普通 HTTPS Host（不限 `linux.do`）客户端看到 per-device CA 叶证书；Alamofire 与所有走代理的 WKWebView 信任通过。
- [ ] MITM / Gateway 出口 TCP 连的是 DoH IP；有 ECH config 时抓包可见 Encrypted Client Hello，外层 SNI 不是真实站点名。
- [ ] 无 ECH config：negative cache 生效，连接仍成功，设置页为“无 ECH”。
- [ ] 独立 ECH 服务器设置生效：A/AAAA 与 HTTPS/ECH 查询可走不同 DoH URL。
- [ ] `lookupEchConfig` 返回非空 bytes 或明确空/负缓存；代码路径不把系统自动 ECH 当成已注入 config。
- [ ] 访问 `challenges.cloudflare.com` 不 MITM，Turnstile 可完成。
- [ ] 不再使用 `SSLCreateContext` / SecureTransport 做 MITM 客户端握手。
- [ ] Gateway 开：Alamofire 实际发往 `http://127.0.0.1:$port`，Cookie 仍按原始 `https://` 域名存取。
- [ ] Gateway 关：Alamofire 走 CONNECT MITM，行为与 FluxDo 回退一致。
- [ ] 图片与 API 同一代理路径；源码不再对 SDWebImage `clearProxy` 以混用 Encrypted DNS。
- [ ] DoH 查询失败不得回落系统 DNS；自定义无 bootstrap 时启动失败可见。
- [ ] h2 MITM 关闭时经代理 HTTPS 锁 HTTP/1.1；打开后实际协商到 HTTP/2。切换后代理重建，无孤儿端口。
- [ ] HTTP、SOCKS5、Shadowsocks 上游均可建连并完成至少一个 HTTPS 请求；Shadowsocks 密码只存在 Keychain。
- [ ] 设置页可看缓存、清空、失败原因、ECH 状态、端口；切换 DoH / ECH 服务器 / Gateway / h2 / 上游后代理按新配置重建。
- [ ] iOS 17+ WKWebView 走 CONNECT MITM；iOS 15–16 用与 FluxDo InAppWebView 同等的原生代理挂钩，做不到时设置页写明限制（不得静默假装 MITM）。
- [ ] 源码/测试覆盖：`example.com` 应 MITM；CF Host 不应；关 DoH 清代理。

## Out of Scope

- 把实现编译进 Android / Windows / Linux，或改 FluxDo 主仓库。
- 引入 Dart `DohProxyService` / rhttp / Dio 原样架构或 Riverpod。
- 把 per-device CA 私钥打进仓库或随包分发同一把密钥。
- 逐字节复刻 `tls_crypto.rs` 的 Chrome 密码套件排序（出口不得明显劣于 FluxDo 以至于 CF 普遍失败）。
- 用系统 Encrypted DNS 替代可注入 ECH。
- 继续把 1.8 的 `linux.do`-only 原型当成完成态。

## Notes

- 复杂改造，需要 `design.md` 和 `implement.md`。
- 第一批全要：默认 MITM + ECH + Gateway + 上游 + h2 开关。不再分“先无 ECH 的 MVP”。
- 1.8 已合入的原型是对照基线，必须按本 PRD 替换，不是可保留的双路径。
- 相关入口：
  - FluxDo Dart：`lib/services/network/doh/`、`doh_proxy/`、`proxy/`、`adapters/platform_adapter.dart`
  - FluxDo Apple：`ios/Runner/DohProxyCertHandler.swift`、`docs/doh-proxy-swift-prd.md`
  - FluxDo Rust：`https://github.com/Lingyan000/fluxdo_doh`
  - Doer：`Doer/Networking/DoH/`、`DiscourseAPI.swift`、WebView 登录/浏览器、`NetworkSettingsViewController.swift`
