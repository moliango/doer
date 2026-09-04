# WeChat Style Theme

## Goal
Add a **微信风格** theme option alongside existing `systemDefault / eyeCare / xiaohongshu / telegram`, so users can switch the whole app visual language toward WeChat green / clean white surfaces without leaving DexoFlux.

## User Value
- Familiar, calm green accent for Chinese users who live in WeChat daily.
- Consistent with already-shipped WeChat-like mini-program chrome (capsule, drawer, swipe-back).
- One-tap switch in Appearance settings; no separate “mode” product.

## Confirmed Facts (from codebase)

1. Themes live in `AppSettings.ThemeStyle` (`Int` raw values 0…3 today) in `AppSettings+Appearance.swift`.
2. Appearance picker is `AppearanceSettingsViewController` + `ThemeStyleCardView` / `ThemeStylePreviewView`; it iterates `ThemeStyle.allCases`.
3. Theme tokens already drive:
   - accent / list / card / chip / count / hot colors
   - content + muted surfaces
   - web cooked HTML hex tokens
   - tag + category palettes
4. Runtime reads go through `AppSettingsRuntimeCache.themeStyle` (cross-thread safe).
5. Spec rules (`.trellis/spec/frontend/state-management.md`):
   - badge/chip colors must use ThemeStyle tokens
   - Home/TopicDetail must observe AppSettings and refresh on theme change
   - **layout-shape** changes (like Xiaohongshu grid) require diffable snapshot rebuild, not `reloadData()` alone
6. Xiaohongshu is the only theme that changes Home **layout shape**. EyeCare/Telegram are primarily color systems.
7. Mini-program host already uses WeChat-like capsule / drawer UX independent of ThemeStyle.

## Product Intent (open)

- How “deep” should WeChat theme go: **colors only** vs **colors + density/radius/tab bar chrome**?
- Dark mode: WeChat green on pure black vs green on WeChat-dark gray?
- Should selecting WeChat theme also nudge mini-program defaults (already WeChat-like), or stay color-only?

## Requirements (draft MVP)

### Must
1. Add `ThemeStyle.weChat` with unique raw value (`4`).
2. Exhaustive color/token coverage for every ThemeStyle switch (compile-safe).
3. Localized title: 微信风格 / WeChat.
4. Appearance settings card + live preview for WeChat.
5. Switching theme updates Home chips, topic cards, tab tint, settings chrome, TopicDetail accents via existing observe path.
6. No layout-shape change in MVP (keep list layout; avoid Xiaohongshu-style grid fork).
7. Dark/light adaptive surfaces (white/light gray day; WeChat-ish dark night).

### Should
8. Web cooked HTML quote/border/background hex tokens match WeChat green family.
9. Tag/category palettes use WeChat green + complementary neutrals (not copy Xiaohongshu red set).
10. Regression: theme switch does not reintroduce AppSettings MainActor/diff-queue crashes (use runtime cache path).

### Could (later)
11. Tab bar / navigation bar opaque WeChat-style chrome.
12. Corner radius + list density tokens (8–12pt continuous corners).
13. Optional alternate app icon.

## Acceptance Criteria
- [ ] Settings → Appearance shows 微信风格 card; selecting it persists across relaunch.
- [ ] Simulator Debug build succeeds with exhaustive ThemeStyle switches.
- [ ] Home list, topic card, tab accent, and settings surfaces use WeChat green accent.
- [ ] Dark mode remains readable (contrast on content text / chips).
- [ ] Switching away from WeChat restores previous theme tokens without layout stuck state.
- [ ] Mini-program open/close/swipe-back still works under WeChat theme.

## Out of Scope (MVP)
- Full WeChat redesign of every screen micro-interaction.
- Changing Home to a WeChat Moments layout.
- Replacing system fonts with WeChat-specific typefaces.
- Server-driven themes.
- Alternate app icon shipping.

## Risks
- Missing a ThemeStyle switch → compile fail or runtime wrong color.
- Accidental layout fork (Xiaohongshu path) if AppearanceSettings special-cases WeChat.
- Dark green on dark gray contrast failures.

## Notes
Task created for Trellis design before implementation. Implementation starts only after MVP depth decision is locked.


## Decision Log
- 2026-08-06: User chose **B** — colors + chrome quality (opaque tab/nav, WeChat gray chrome, denser corners token). No Home layout fork.
