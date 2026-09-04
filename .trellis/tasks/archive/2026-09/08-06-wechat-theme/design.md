# WeChat Style Theme — Design

## Approach
**Color-token theme first** (same class as EyeCare / Telegram), not a layout-mode theme (Xiaohongshu).

Reason: mini-program already carries WeChat interaction patterns; the missing piece is a coherent green visual system across the host app.

## Token Mapping (MVP)

| Token | Light | Dark |
|------|-------|------|
| accent | `#07C160` (WeChat green) | `#07C160` (slightly brighter if needed) |
| content bg | `#FFFFFF` | `#111111` |
| muted / list bg | `#EDEDED` | `#191919` |
| card bg | `#FFFFFF` | `#1C1C1E` |
| chip selected | accent @ 12–16% fill | accent @ 18% fill |
| hot topic | `#FA9D3B` or accent sibling | same family |
| count badge fg | white | white |
| count badge bg | accent | accent |
| web accent hex | `#07C160` | `#07C160` |
| web bg / muted | match content/muted | match dark surfaces |
| quote border | `#07C160` @ ~70% | same |

### Palettes
- **Tags**: green, teal, amber, blue-gray (avoid Xiaohongshu red dominance).
- **Categories**: same family, higher saturation steps.

## Integration Points

```
AppearanceSettingsViewController
  └─ ThemeStyle.allCases  → auto includes .weChat

AppSettings.ThemeStyle (AppSettings+Appearance.swift)
  └─ ~17 switch self sites must include .weChat

AppSettingsRuntimeCache.themeStyle
  └─ raw Int 4 persisted via existing themeStyle setter

Home / TopicDetail / Settings / TabBar
  └─ already read themeStyle tokens; observe path already exists
```

## Explicit Non-Goals in Code Paths
- Do **not** add `if themeStyle == .weChat` layout branches in Home snapshot builders (Xiaohongshu exception stays unique).
- Do **not** change mini-program capsule implementation for this theme (already WeChat-like).
- Do **not** introduce new font families for MVP.

## Implementation Sketch (for implement.md later)

1. Add `case weChat = 4` + title localization.
2. Exhaustive updates for every ThemeStyle color/hex/palette switch.
3. Tune `ThemeStylePreviewView` if it hardcodes previews per style (extension at file bottom).
4. Manual QA matrix: light/dark × Home / TopicDetail / Settings / MiniProgram.
5. Build + smoke theme switch thrash (switch A→WeChat→B rapidly).

## Open Decision (blocks implement.md detail)
**Theme depth**: colors-only MVP vs colors + chrome density (tab bar opacity, corner radii).
Recommended: **colors-only MVP** first; chrome density as follow-up task if users like the green system.
