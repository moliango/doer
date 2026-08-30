# GitHub Update Proxy

> Optional reverse-proxy prefix for GitHub release checks (`08-28-github-update-proxy`).
> Learned 2026-08-28.

## Scenario: Mirror prefix for `/releases/latest`

### 1. Scope / Trigger

- Trigger: changing App Update check URL, About-page mirror field, or GitHub download links.
- Code: `GitHubProxy`, `AppSettings.githubProxyPrefix`, `AppUpdateService.check`, `AppUpdateCoordinator.openReleasePage`.

### 2. Signatures

```swift
enum GitHubProxy {
    static func normalize(_ raw: String) -> String          // trim + trailing `/`
    static func isValid(_ raw: String) -> Bool             // empty OR http(s)+host
    static func apply(to url: URL, prefix: String) -> URL  // identity if empty/already prefixed
    static func applyIfValid(to url: URL, prefix: String) throws -> URL
}

enum GitHubProxyError: Error { case invalidPrefix }

extension AppSettings {
    var githubProxyPrefix: String // UserDefaults `githubProxyPrefix`, stored normalized
}
```

### 3. Contracts

| Surface | Behavior |
|---------|----------|
| About → GitHub 镜像 | Empty string = direct GitHub. Invalid prefix is **not** saved. |
| `AppUpdateService.check` | Rewrites `latestReleaseURL` **before** the request. Uses the injected `defaults`, not a second `UserDefaults.standard`. |
| Invalid stored prefix | Throws `GitHubProxyError.invalidPrefix`; do **not** write a 200-cache for a garbage URL. |
| `openReleasePage` | Try mirrored URL; on throw, open the original GitHub URL. |
| Apply twice | `apply` is idempotent when `absoluteString` already has the prefix. |

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| `""` / whitespace | Identity URL; `isValid == true` |
| `https://ghproxy.com` | Normalized to `https://ghproxy.com/` |
| `not a url` / missing host | `isValid == false`; About refuses save; `applyIfValid` throws |
| `ftp://…` | Invalid |
| Network 404 on mirror | Existing update error path; do not treat as a successful empty cache |

### 5. Good / Base / Bad Cases

- Good: prefix `https://ghproxy.com/` → request `https://ghproxy.com/https://api.github.com/…`
- Base: empty prefix → `api.github.com` unchanged
- Bad: concatenating prefix in `AppUpdateService` without `isValid`, then caching the failure body

### 6. Tests Required

- `GitHubProxyTests` in `DoerTests/FluxDoGapRoundTests.swift`: normalize slash, reject garbage, no double-prefix, empty identity, `applyIfValid` throw

### 7. Wrong vs Correct

#### Wrong

```swift
let url = URL(string: prefix + endpoint.absoluteString)! // may be nil / ftp / relative
```

#### Correct

```swift
let url = try GitHubProxy.applyIfValid(to: endpoint, prefix: defaults.string(forKey: "githubProxyPrefix") ?? "")
```
