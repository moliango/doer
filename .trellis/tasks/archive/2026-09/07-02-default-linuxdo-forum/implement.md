# Home Mini-Program Drawer — Completion Note

## Status: Complete

Option C: keep Home pull-to-refresh. Category row now hosts both the three-line category control and a WeChat-like mini-program drawer button.

## Layout

Category row:
```
[ categoryScrollView (全部 + pinned) ] [ 三线 categoryManager ] [ 小程序 square.grid.2x2 ]
```

Search row stays `[搜索] [通知]`. `UIRefreshControl` is unchanged.

## Drawer

- Child overlay on `HomeViewController` (fills Home content, tab bar stays visible)
- Dark translucent top panel with avatar/name, 「最近」, search, recent + frequent grids
- Tap / swipe-up / chevron dismiss
- Program open → dismiss drawer → `MiniProgramFactory.present` full-screen host
- Recent IDs stored in `MiniProgramRecentStore` (UserDefaults, capped)

## Files

| Path | Role |
|------|------|
| `dexo/Features/ForumDetail/Home/HomeViewController.swift` | Category-row trailing buttons + drawer host |
| `dexo/Features/Plugins/MiniProgram/MiniProgramDrawerViewController.swift` | WeChat-like top drawer |
| `dexo/Features/Plugins/MiniProgram/MiniProgramRecentStore.swift` | Recent program IDs |
| `dexo/Features/Plugins/MiniProgram/MiniProgramFactory.swift` | Records recent on present |

## Verification

```bash
make generate
xcodebuild -scheme dexoflux -workspace dexoflux.xcworkspace \
  -destination 'generic/platform=iOS' -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO
```
