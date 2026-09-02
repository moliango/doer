# Component Guidelines

> How components are built in this project.

---

## Overview

<!--
Document your project's component conventions here.

Questions to answer:
- What component patterns do you use?
- How are props defined?
- How do you handle composition?
- What accessibility standards apply?
-->

(To be filled by the team)

---

## Component Structure

<!-- Standard structure of a component file -->

### Topic Detail Timeline

- `TopicDetail` progress and timeline controls must use Discourse `post_stream.stream` as the source of truth for ordering.
- Displayed progress is the 1-based stream index over `stream.count`, matching FluxDo's `TopicProgress` behavior.
- Timeline selection should return the selected post id from `stream`; the view controller may map that id back to the existing native floor-jump loader.
- Do not derive timeline position from visible table rows, loaded batch size, or filtered post arrays except as a temporary fallback for finding the current visible stream index.
- In-topic find and author filter: jump by post id / `post_number` (see [Topic Find Filter](./topic-find-filter.md)). Do not treat `post_number` as a stream index. Do not derive the filtered list from an unfiltered empty-snapshot fallback.
- The progress entry should remain a compact centered capsule (`current / total`) that opens the timeline on tap and keeps gesture actions attached to the same control.
- Custom-drawn timeline track views must be explicitly transparent (`isOpaque = false`, clear background) and must keep a fixed/natural visual height inside sheet layouts. Do not pin the track stack to both the sheet title and bottom buttons in a way that stretches the track into a full-height rectangle.

---

## Props Conventions

<!-- How props should be defined and typed -->

(To be filled by the team)

---

## Styling Patterns

<!-- How styles are applied (CSS modules, styled-components, Tailwind, etc.) -->

### Typography Baseline

- UIKit interface text uses `AppSettings.appInterfaceFont(...)` or the installed `UIFont.systemFont` override. Do not hardcode a separate visual default for the Me tab or other app chrome.
- The global interface font slider default is `100%`, but the visual baseline intentionally applies `AppSettings.interfaceFontDefaultVisualMultiplier` (`ContentFontSize.standard.basePointSize / 15`, currently `13.94 / 15`). A `15pt` source label therefore renders at `13.94pt` by default.
- Treat `ContentFontSize.standard.basePointSize` (`13.94pt`) as the shared default visual size for reading body and interface chrome at 100%. Keep `interfaceFontDefaultVisualPointSize` equal to that value; do not "fix" size mismatch by resetting either slider default away from `100%`. `85%` is legacy migration input, not the current user-facing default.
- Home topic-list titles use the 15pt design size through `appInterfaceFont` only, so 100% interface scale matches Topic Detail body (`13.94pt`). Do not also apply `effectiveInterfacePointSize` on that path; the PingFang shrink plus the visual multiplier makes list titles smaller than post body at the same 100%.
- Tab bar fonts stay outside global interface scaling and must continue to use `AppSettings.tabBarItemFont(selected:)`.
- Topic Detail post body and post-context identity text are content typography, not app chrome. Author name, username, user title, floor/time metadata, reply-target labels, and adjacent avatar sizing should scale from the content font settings so they stay visually aligned with comments.

---

## Accessibility

<!-- A11y requirements and patterns -->

(To be filled by the team)

---

## Common Mistakes

<!-- Component-related mistakes your team has made -->

### Me Customize Editors

- Stats card and account-function customizers use the card chrome in `MeCustomizeEditorViews.swift` (hero preview, icon-well rows, drag handle + hide/show).
- Reorder visible items with table drag-and-drop (`dragInteractionEnabled`, no `isEditing`). Hide/show with minus/plus. Do not turn on `isEditing` reorder handles — that hides accessories and blocks taps.
- Me stats layouts stay compact: grid is four equal columns at 84pt via `MeStatsLayoutCanvas`; horizontal shows about three tiles plus a peek so it never fills like the 4-up grid. Do not enlarge into two-column color cards.
### UIKit Card Controls

- Purely decorative subviews inside a tappable `UIControl` card must set `isUserInteractionEnabled = false`.
- Custom preview `UIView`s are especially easy to miss because they participate in hit-testing by default and can swallow taps before the parent control receives `.touchUpInside`.
- Apply this to visual-only preview layers, icon/title stacks, overlays, and selection badges unless those subviews intentionally handle their own gestures.
- Appearance settings app-icon and font option cards should be real controls backed by `AppSettings`, not static previews. If an option requires a system capability or imported resource, the tap path must either perform the action or show a localized error.
- Any subview constrained manually inside UIKit setting cards must set `translatesAutoresizingMaskIntoConstraints = false`. Missing this on labels or preview views can make arranged card content collapse or render off-screen inside `UIStackView`.

### Home Dynamic Header And Card Grid

- Home table geometry must be owned by a single inset update path that accounts for header height, incoming-topic banner space, bottom tab chrome, and the active card layout.
- Refresh actions that intentionally return Home to the top must first reveal the collapsed search/header row, then recompute table insets, then set `contentOffset` to `-tableView.contentInset.top`.
- Programmatic top refreshes and incoming-topic loads must keep a short geometry lock until after `UIRefreshControl.endRefreshing()` / the banner removal update and the next layout pass, so `scrollViewDidEndScrollingAnimation` cannot immediately collapse the search row against stale offsets.
- While that geometry lock is active, top inset changes must not preserve visible content by adding `oldTopInset - newTopInset` to `contentOffset`; the lock owns the final `-contentInset.top` offset. This prevents the incoming-topic banner disappearing from pushing the first card under the filter row.
- Standard Home cards and Xiaohongshu two-column cards both need explicit top and bottom content spacing in the table inset path; Xiaohongshu uses the larger top spacing so the first grid row does not visually tuck under the filter chip row after refresh or header collapse changes.
- Theme changes that switch between standard list and Xiaohongshu grid must call the snapshot rebuild path and recompute table insets; `tableView.reloadData()` alone is not enough.

### Forum Tab Bar And Safe Areas

- `ForumTabBarController` must keep native `hidesBottomBarWhenPushed` tab-bar hiding separate from Home scroll-driven tab-bar hiding.
- Pushed pages such as `TopicDetailViewController` own their bottom-bar visibility through UIKit's native `hidesBottomBarWhenPushed`; do not apply Home scroll-hide expansion or negative `additionalSafeAreaInsets` compensation while such pages are visible.
- Home scroll-hide may expand the selected root navigation content into the tab-bar area, but it must not mutate child view controllers' `additionalSafeAreaInsets.bottom` to remove the tab bar. Negative safe-area compensation can leave the system bottom safe-area host visible after a Topic Detail pop.
- When a navigation transition finishes, `ForumTabBarController` should re-apply the current tab-bar layout from the visible controller state so a popped Home view does not keep the transition container's shorter frame.

### Topic Detail Image Loading

- Topic Detail content images, inline image attachments, onebox thumbnails, video thumbnails, title emoji, and composer emoji must use the shared `ForumImageLoader` / `AvatarImageLoader.context(for:)` path instead of raw `sd_setImage(with:)` or `SDWebImageManager.loadImage(with:)`.
- The shared path supplies retry, background continuation, large-image downscaling, and `WebCookieStore` Cookie/User-Agent headers. Bypassing it can make Linux.do images fail behind Cloudflare/CDN or stay blank after a transient first failure.
- `CookedHTML` parsed blocks expose `imageSourceURLs`; Topic Detail controllers should prefetch newly ready posts after parsing/snapshot updates so image downloads run concurrently before cells become visible.
- Prefetch should be keyed by post id or another stable content id to avoid repeatedly prefetching the same images during `updateUI()`, theme reloads, or diffable snapshot refreshes.
- Boost strips must not flatten `cooked` content into `UILabel.text` only. They need to preserve inline emoji image nodes and convert raw `:shortcode:` text through `EmojiStore`, then load images with `ForumImageLoader` so custom emoji work behind Cloudflare.
- Boost and title emoji URL resolution must go through `EmojiStore` / `ForumImageLoader`, including cached `/emojis.json` entries, relative emoji URLs, alias lookup, and `:shortcode:tN` skin-tone suffix normalization. Direct `SDWebImageManager.loadImage` calls bypass Cookie/User-Agent retry behavior and can leave Linux.do emoji blank.
- Boost renderers must treat standalone small `/emoji` image blocks as inline emoji attachments instead of falling back to alt text, because Discourse can emit custom emoji outside a paragraph node.
- Boost strips shown inside comments should display the booster avatar and text content only; do not add the rocket/Boost action icon inside the rendered comment strip. Keep the rocket icon reserved for the actual Boost action button.

### Topic Detail Native Content Blocks

- Discourse poll cooked HTML (`<div class="poll" data-poll-name=...>`) must be decoded at the `CookedHTML` boundary as `ContentBlock.poll(PollBlock)`.
- Poll options live in `PollBlock.options` and are rendered by `PollRenderer`; the inner poll `<ul>/<li>` must not fall through to `ListExtractor` or `ListRenderer`.
- Poll UI must not be a static card. `PollRenderer` should render selectable controls, submit `postId + pollName + optionIds` through `PostCellDelegate`, call the Discourse `/polls/vote` route from the owning controller/view model, then refresh and re-parse the affected post so vote counts and selected state come from server cooked HTML.
- If poll HTML changes, update `BlockExtractorTests.testDiscoursePollDoesNotBecomeList` or an equivalent parser test before changing the renderer. A screenshot-only UI check is not enough because this bug happens at the parser boundary.
- If poll result metadata changes, update parser tests for `votersCount`, option vote count, percentage text, and selected option state before changing `PollRenderer`.
