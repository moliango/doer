# Anywhere Proxy Engine Research

## Context

Dexo Phase 6 first attempted a lightweight in-app DoH path:

- `URLSession` / Alamofire requests use a local HTTP `CONNECT` proxy.
- The proxy resolves `linux.do` with DoH.
- TLS remains end-to-end between the app and `linux.do`; no MITM and no local CA.

Real-device logs prove this is not enough on the tested network:

```text
CONNECT linux.do:443
Resolved linux.do -> 172.66.166.61, 104.20.16.234
Upstream connected 172.66.166.61:443
CONNECT tunnel established
Client TLS first bytes: ...; tlsHandshake=true; sni_linux_do=true
Tunnel receive failed: POSIXErrorCode(rawValue: 54): Connection reset by peer
```

Observed facts:

- DoH resolution works.
- The local `CONNECT` proxy works.
- SNI is present and correct (`linux.do`).
- Both returned Cloudflare IPs were tried.
- The remote side or network path resets after TLS ClientHello.

Therefore the remaining failure is above DNS and likely tied to SNI/TLS path handling. A resolver-only library such as `swift-dns` cannot fix this.

## Candidate

Repository proposed by user:

- `https://github.com/NodePassProject/Anywhere`

User-provided claims:

- Pure Swift native proxy client for iOS/iPadOS/tvOS.
- No Electron.
- Includes MITM engine.
- Includes TLS interception / rewrite support.
- Includes user-space TCP/IP stack (`lwIP`).
- Includes Network Extension support.

## What Must Be Verified In Source

Network access was blocked by the current approval service, so the repository source has not been inspected yet. Before implementation, verify these items from local source:

- License compatibility with Dexo.
- Whether the core proxy engine is a reusable Swift Package or tightly coupled to the Anywhere app target.
- Whether MITM code is implemented in Swift or wraps bundled C/C++/Rust/Go artifacts.
- Whether the user-space TCP/IP stack is vendored source, binary framework, or system dependency.
- Whether iOS support requires `NEPacketTunnelProvider`, `NEAppProxyProvider`, or `NETransparentProxyProvider`.
- Which entitlements are required for development and distribution.
- Whether certificate generation and CA install/trust flow is reusable.
- Whether the proxy can target only Dexo native requests, or whether it must run as device-level VPN/proxy.
- Whether it supports ECH or merely MITM/regular proxying.
- Whether it can solve SNI reset without a remote proxy/VPN exit.

## Preliminary Fit

Anywhere is directionally more relevant than `swift-dns` because the verified failure is no longer a DNS problem.

Potential fit:

- Good if Dexo needs a real proxy/NetworkExtension path.
- Good if the project wants a pure Swift stack instead of FluxDo's Rust/FFI proxy.
- Good if the MITM/certificate UX is acceptable.

Potential blockers:

- Network Extension entitlements may be required.
- MITM requires user-installed and trusted CA.
- App Store review risk is higher than resolver-only DoH.
- If the reset is caused by SNI filtering, MITM alone does not hide upstream SNI unless the proxy uses an alternate remote exit or ECH-capable upstream strategy.
- Full-client code may be expensive to extract into Dexo.

## Recommended Next Step

Do not directly port Anywhere yet. First inspect the repository and answer:

1. Can the core engine be embedded as a module with minimal app UI coupling?
2. Can it run without device-wide NetworkExtension entitlement?
3. Does it provide a reusable certificate install/trust flow for iOS?
4. Does it solve SNI reset, or only provide local TLS interception?
5. What is the minimum Dexo integration shape: local engine, app proxy extension, packet tunnel extension, or remote proxy profile?

If the repository confirms reusable NetworkExtension/proxy core and acceptable entitlement requirements, define this as Phase 6.2: proxy-engine route after lightweight DoH exhaustion.

## Current Blocker

Attempted command:

```bash
git clone --depth 1 https://github.com/NodePassProject/Anywhere.git /private/tmp/Anywhere
```

Result:

```text
Rejected by approval service: selected auto-review model endpoint returned 404.
```

This is an environment/tooling blocker, not a technical conclusion about Anywhere.
