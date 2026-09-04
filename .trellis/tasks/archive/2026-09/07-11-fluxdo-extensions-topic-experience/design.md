# Technical Design

## Architecture

The work is split into four independently testable slices that share the
existing `DiscourseAPI`, cookie store, theme, localization, and UIKit routing.
No Flutter/Riverpod code is ported.

## 1. Read-State Styling

- Extend topic list models with `unseen`, `unreadPosts`, `lastReadPostNumber`,
  and `highestPostNumber`.
- Define a single computed read presentation state. A topic is fully read only
  when it is not unseen, has no unread posts, and has a last-read position.
- After successful timing submission, post an account/baseURL-scoped read-state
  notification carrying topic ID and highest seen post.
- Home/list view models merge the update into in-memory topics and reconfigure
  visible cards. Server refresh remains authoritative and can restore unread
  emphasis when new replies arrive.

## 2. In-App Browser

- Keep `BrowserHistoryStore` as the persistence owner because it already
  isolates data by forum/account and bounds history.
- Refactor `InAppBrowserViewController` into a FluxDo-style WebView screen with
  address capsule, progress, compact navigation actions, and more menu.
- Add initial URL support so Topic Detail and other internal links share the
  same authenticated browser.
- Add explicit non-HTTP scheme confirmation and system handoff.
- Keep browser library/history/bookmark operations native and extend bookmark
  rename/manual add without breaking existing data.

## 3. Topic Detail Actions and Search

- Replace the export-only navigation item with Search and More.
- Use a custom action panel for the screenshot structure: five quick actions
  plus a permission-aware list.
- Reuse existing bookmark/share/export/filter/read settings implementations.
- Add `TopicReadLaterStore`, account isolated by base URL and username.
- Add notification-level API and decode `details.can_edit` plus current level.
- Add permission-gated topic editor backed by the real topic update API.
- Add a share-image renderer for title, OP identity/content, and topic URL.
- Search uses `/search.json` with `topic:<id>`, decodes `post_number`, and jumps
  through the existing floor-loading path.

## 4. Metaverse / LDC / CDK

- Add a native service-management page reached from Me.
- Implement a shared OAuth state machine parameterized by service base URL:
  login URL -> Connect approval link -> capture code/state -> callback -> user
  info. Reuse Dexo cookies and Cloudflare recovery.
- LDC and CDK cache non-sensitive user info per Linux.do account. Authorization
  expiry clears stale cache and exposes reauthorization.
- Store LDC merchant credentials in Keychain.
- LDC rewards use Basic Auth, validated amounts, confirmation, and an
  account/topic/post/user-scoped two-minute success cooldown.
- CDK exposes score and dashboard handoff only; unsupported exchange/history
  controls are excluded.

## Compatibility and Safety

- UIKit and iOS 15 only.
- All state mutations that affect UI run on `MainActor`.
- Sensitive credentials never enter UserDefaults or logs.
- All user-facing strings are localized.
- Existing Cloudflare, reply, bookmark, export, timeline, and read timing flows
  remain intact.

## Rollback Boundaries

- Each slice has separate model/store/controller changes and can be disabled at
  its entry point without reverting unrelated slices.
- New API routes are additive.
- Browser data format changes must remain backward compatible.
