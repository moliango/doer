# Home Page FluxDo Style Design

## Goal

Phase 1 updates the native UIKit home page so it visually matches FluxDo's mobile home page as closely as practical while preserving the existing Dexo data flow.

Phase 1.2 changes the product model from multi-site forum management to a single Linux.do site. Launch should go straight into Linux.do, and the arbitrary forum-add path should no longer be active UI.

Phase 1.4 makes iOS 15.0 the real minimum runtime target. Current local facts show `Project.swift`, `Packages/CookedHTML/Package.swift`, `README.md`, and `README.zh-CN.md` all still say iOS 17.0, and the app uses Swift Observation (`@Observable`, `withObservationTracking`) which is not an iOS 15 runtime API.

## FluxDo Reference

- `fluxdo/lib/pages/topics_screen.dart`: mobile home shell, topic list + FAB, single-forum product shape.
- `fluxdo/lib/pages/topics_page.dart`: collapsible header with search row, category tab row, and sort/filter row.
- `fluxdo/lib/widgets/topic/sort_and_tags_bar.dart`: compact filter/sort/tag controls.
- `fluxdo/lib/widgets/topic/topic_card.dart`: rounded topic card layout with avatar, title, unread/reply badge, category/tags, stats, and time.
- `fluxdo/lib/widgets/common/topic_badges.dart`: compact `CategoryBadge` and `TagBadge` sizing, corner radius, muted surfaces, category color dot/border treatment.
- `fluxdo/lib/widgets/topic/filter_dropdown.dart`: current-filter chip with dropdown arrow and checked menu state.
- `fluxdo/lib/pages/topic_detail_page/topic_detail_page.dart`: topic detail shell, scroll position tracking, app bar behavior, and post list orchestration.
- `fluxdo/lib/pages/topic_detail_page/widgets/topic_post_list.dart`: virtualized post stream and per-post `PostItem` composition.
- `fluxdo/lib/widgets/post/post_item/post_item.dart`: post item structure with header, cooked HTML content, signatures/hidden notices, and footer actions.
- `fluxdo/lib/widgets/post/post_links.dart`: collapsible related-link card driven by Discourse `LinkCount` data.
- `fluxdo/lib/widgets/post/post_boost/boost_bubble.dart`: compact Boost bubble with avatar, display text, and grouped count badge.
- `fluxdo/lib/widgets/post/post_boost/boost_content.dart`: Boost cooked HTML display-text extraction and grouping by content.
- `fluxdo/lib/widgets/content/discourse_html_content/builders/onebox_card_builder.dart`: onebox routing entry for link preview card variants.
- `fluxdo/lib/widgets/content/discourse_html_content/builders/onebox/default_onebox_builder.dart`: default onebox card shape with source header, title, description, thumbnail, and click count.
- `fluxdo/screenshots/preview.png`: visual reference for the mobile home screen.

## Native Mapping

- Keep `HomeViewController` as the implementation target. It already owns topic loading, category loading, refresh, pagination, and topic-detail navigation.
- Replace the current segmented-control-first header with a custom UIKit header:
  - search capsule row at the top
  - horizontal category tab strip below it
  - compact filter/sort chip row below the category tabs
- Keep `HomeViewModel` list modes (`latest`, `hot`, `top`) and category filtering.
- Rework `TopicCell` from a plain row into a rounded card-style cell:
  - content card with 10pt corner radius
  - 34-36pt avatar at leading
  - title max two lines
  - reply/unread-style badge at trailing
  - category badge/dot, real API tags, and relative time on the second row
  - preserve emoji title rendering and SDWebImage avatar loading
- Decode optional topic-list `tags` when the Discourse response provides them, and render them as muted compact badges. Missing tags render nothing; category remains the stable fallback badge.
- Replace the three separate latest/hot/top chips with one FluxDo-style filter dropdown chip whose menu contains the supported native list modes. Keep the category dropdown as a matching chip for access to categories not visible in the horizontal tab strip.
- Hide the Home tab navigation bar while Home is visible. Restore it for pushed detail/search screens and for other tabs so existing navigation titles still work.
- Add a database-level helper that creates or returns the persisted Linux.do `ForumInstance`.
- Change launch routing so `SceneDelegate` creates a `ForumContainerViewController` for the Linux.do instance directly.
- Allow `ForumContainerViewController` to run in root mode without the overlay minimize/close affordance.
- Keep `ForumListViewController` source available for now, but it should no longer be the launch path or expose add-forum UI if reached accidentally.

## Boundaries

- Do not port Flutter/Riverpod architecture into UIKit.
- Do not change Discourse API contracts in this phase.
- Do not implement FluxDo's full collapsible header behavior in the first pass unless it is low-risk. A static header with matching visual hierarchy is acceptable for Phase 1.
- Do not solve saved non-Linux.do forum deletion/migration in this phase.
- Do not fetch Linux.do basic info during launch; startup should work offline using a bundled default title/base URL.

## Compatibility

- The screen remains UIKit-only.
- User-facing strings must use `String(localized:)`.
- Existing pull-to-refresh, infinite scrolling, topic selection, and login-required state must continue to work.
- Existing category menu behavior can be adapted into a horizontal tab strip; nested categories may still be available through a menu or compact "all categories" fallback if needed.
- Existing auth behavior should continue because the persisted Linux.do `ForumInstance` gives AuthManager a stable DB row for username updates.
- Existing saved non-Linux.do forums remain in the database but become unreachable from the main UI in Phase 1.2.
- iOS 15 compatibility requires removing Swift Observation runtime usage rather than just changing the deployment target.
- Use a lightweight app-local observable base class with `NotificationCenter` change broadcasts. View models call `notifyChanged()` after state mutations, and `ObservableViewController` observes those broadcasts and calls `updateUI()` on the main actor.
- Keep the compatibility layer small and UIKit-oriented. Do not introduce SwiftUI, Combine-wide rewrites, or a larger architecture change for Phase 1.4.

## Phase 1.5 Detail Mapping

- Keep `TopicDetailViewController` and `TopicDetailViewModel` as the native implementation owners. They already handle Discourse topic loading, pagination, floor jumps, OP filtering, reactions, bookmarks, replies, and parsed cooked HTML.
- Keep `PostNativeCell` as the visible post item renderer. Rework its presentation toward FluxDo's `PostItem` shape:
  - inset rounded post surface
  - compact author/avatar header
  - clear content body spacing
  - bottom action row separated from the body
  - subtle selected/highlight-style affordance can be deferred until selection state exists natively
- Decode `link_counts` into `DiscourseTopicDetail.Post` as optional related-link data. Rendering belongs in `PostNativeCell`; the networking model owns the JSON contract.
- Decode `boosts` and `can_boost` into `DiscourseTopicDetail.Post`. Phase 1.5 only renders existing boost bubbles; create/delete/flag actions remain deferred.
- Add a native related-link card that mirrors FluxDo `PostLinks`: collapsible header, count badge, deduplicated internal reflection links with title, click count, and tap through the existing `PostCellDelegate`.
- Add a native Boost strip below the cooked content when the API provides boosts. Match FluxDo's compact bubble language: avatar, cooked-text summary, duplicate-content grouping, and count badge.
- Keep inline links in `LinkTextView` using attributed `.link` and `UITextViewDelegate`. Do not replace this with a WebView-only renderer.
- Refresh `OneboxCardView` styling to match FluxDo `OneboxContainer`: rounded surface, muted border, source header, title/description, optional thumbnail row, and full-card tap.
- Preserve fallback rendering for unsupported cooked HTML blocks. The source/copy button remains for unsupported content.

## Trade-Offs

- Exact Flutter animation parity is lower priority than matching the visible native home style.
- UIKit should lean into native controls and safe-area behavior instead of recreating Flutter layout mechanics verbatim.
- If topic model lacks FluxDo fields such as tags, unread counts, or like counts, Phase 1 should omit those details rather than fake data.
- Phase 1.3 adds only optional topic-list tags. It still does not implement unread/new/likes parity unless the existing endpoint/model already supports those fields.
- Keeping old forum rows avoids destructive migration risk, but leaves dormant legacy data until a later cleanup decision.
- The NotificationCenter observable fallback is less automatic than Swift Observation, but it is explicit, iOS 15-compatible, and low-risk for this UIKit codebase.
- Related links depend on `link_counts`; Linux.do may omit this field for some posts. In that case the detail page should simply omit the related-link card.
- Boosts depend on Linux.do returning the Discourse Boost plugin fields. In Phase 1.5, absent fields should simply omit the boost strip; action buttons for adding/deleting boosts are intentionally deferred.
- Onebox exact platform-specific variants from FluxDo are intentionally deferred. Phase 1.5 targets the shared default card quality first.

## Phase 1.6 Content And Loading Mapping

- FluxDo uses `PostListSkeleton(withHeader: true)` for initial topic-detail loading. Native mapping: add a UIKit `TopicDetailSkeletonView` that renders a title/header skeleton and multiple post skeleton cards, then show it only while `TopicDetailViewModel` is loading and no ready posts are available.
- FluxDo's incremental loading uses compact sliver indicators. Native mapping: keep the existing footer spinner and top loading bar for this phase, but restyle the top loading surface if it becomes visually noisy later.
- FluxDo's `DiscourseHtmlContent` applies readable text rhythm through body text height, paragraph spacing, and muted block surfaces. Native mapping: keep `CookedHTML` attributed strings, but add paragraph styles at the native renderer layer so all text blocks get consistent line height and spacing without changing parser contracts.
- FluxDo blockquote/callout surfaces use a low-contrast background and a left accent rail. Native mapping: update `BlockquoteRenderer` and `DiscourseQuoteRenderer` to use rounded muted surfaces, subtle borders, and a left rail while preserving nested native rendering.
- FluxDo code blocks use a muted rounded container with a small language label. Native mapping: update `CodeBlockRenderer` surface, padding, language badge, and monospaced line rhythm. Syntax highlighting and line numbers stay deferred.
- FluxDo details blocks use a compact card header and expandable body. Native mapping: update `DetailsRenderer` header background, chevron animation, divider, and expanded body padding while preserving lazy body creation.
- FluxDo table blocks use a bordered rounded surface with a muted header row. Native mapping: update `TableRenderer` border radius, separator alpha, header background, and cell padding without replacing the current width-allocation algorithm.
- FluxDo image and fallback loading are skeleton-like rather than bare gray rectangles. Native mapping: update `ImageRenderer` and `FallbackBlockView` placeholders to rounded muted surfaces with lightweight skeleton bars. Do not add network-dependent placeholder content.

## Phase 1.6 Deferred

- Full long-post chunk virtualization from FluxDo's `ChunkedHtmlContent` and `SegmentedLongPost`.
- Syntax highlighting, code line numbers, code copy controls, and Mermaid rendering.
- Platform-specific onebox variants beyond the default card already improved in Phase 1.5.

## Phase 1.7 Home Interaction Mapping

- FluxDo `TopicsScreen` shows the home FAB only for logged-in users and uses `_TopicsFab` as a two-state control. Native mapping: always keep a right-bottom floating button visible in Home, but route create actions through the existing `AuthGating` so unauthenticated users get the normal login flow.
- FluxDo `_TopicsFab` switches to refresh mode when `fabRefreshModeProvider` is set by user scroll direction. Native mapping: use `scrollViewDidScroll` / pan velocity in `HomeViewController` to switch the FAB icon between `plus` and `arrow.clockwise`; scrolling toward the top enables refresh mode, scrolling deeper restores create mode.
- FluxDo refresh mode calls `scrollToTopProvider` and `fabRefreshSignalProvider`. Native mapping: tapping refresh mode animates `tableView.contentOffset` to the top inset, then calls `HomeViewModel.loadTopics()`.
- FluxDo creates topics through `CreateTopicPage` and then refreshes/selects the created topic. Native mapping: add a minimal UIKit `NewTopicComposerViewController` that posts title/body/category through `DiscourseAPI.createTopic(...)`, refreshes Home, and pushes the created topic detail when the API returns a topic id.
- FluxDo `_TopicsHeaderDelegate` keeps the status bar and category tab row pinned, collapses search first, then the sort/filter row. Native mapping: use a dynamic header height in `HomeViewController`; collapse only the search row in Phase 1.7 and keep category/filter controls visible to reduce risk.
- FluxDo paints the status area with the same scaffold background. Native mapping: anchor the header container to `view.topAnchor`, include the safe-area height in its layout, and make `view` / `headerContainer` / `tableView` use grouped background consistently.

## Phase 1.7 Deferred

- FluxDo's FAB speed-dial overlay with drafts.
- Draft restore/autosave, markdown preview, AI review, and advanced editor controls.
- Full second-stage filter row collapse and compact filter shortcut inside the category tab row.

## Phase 1.8 Home Bugfix Mapping

- Bottom search button root cause: `ForumTabBarController` still creates `SearchViewController` as a third tab and uses `UISearchTab` on iOS 18. Native mapping: remove the search tab from the tab bar and keep search navigation through the home search capsule.
- Scrollbar root cause: the home table view keeps the default vertical scroll indicator visible. Native mapping: set `showsVerticalScrollIndicator = false`; the app already has pull-to-refresh, FAB refresh, and scroll position feedback, so the indicator is not needed for FluxDo parity.
- Count badge root cause: `TopicCell` currently renders the count as a plain numeric `UILabel` with a blue-ish background, which does not match FluxDo's icon-leading count chip. Native mapping: replace it with a compact horizontal chip containing an SF Symbol and count label.
- Card height root cause: earlier `TopicCell` self-sizing used loose vertical constraints, so table height estimation could temporarily allocate a taller row and stretch the badge stack during scroll/reuse. Native mapping: use Auto Layout self-sizing again, but make the vertical chain deterministic: title max three lines, badge row directly below title, card bottom tied to the badge row, and table `estimatedRowHeight` only as an estimate.
- Count badge width root cause: `TopicCountBadgeView` is a custom `UIView` with only a greater-than-or-equal width constraint and no stable intrinsic width. During Auto Layout fitting it can receive extra horizontal space. Native mapping: drive the badge with an explicit width constraint based on digit count and invalidate it on configure/reuse.
- Count badge readability refinement: use monospaced digits, clamp display to four digits (`9999`), and allocate wider fixed widths for three- and four-digit counts.
- Title/tag layout refinement: keep title typography in a local `Metrics` block, use a smaller fixed title font, let the title consume one to three lines based on content, and place the tag row directly below the actual title height instead of reserving blank title lines.
- FluxDo count icon: `fluxdo/lib/widgets/topic/topic_card.dart` uses `Symbols.chat_bubble_rounded` for reply counts. Native mapping: use the closest iOS 15 SF Symbol chat bubble (`bubble.left`) inside the compact count badge.
- High-count threshold: use a simple native threshold for visual emphasis. Normal counts render gray; counts at or above 50 render yellow/orange. This mirrors the user-visible FluxDo intent without inventing unread semantics.

## Phase 1.9 Tag Badge And Rate-Limit Mapping

- FluxDo reference target: topic badges should have a compact icon-plus-text treatment and use color as part of the badge identity.
- Local limitation: reading `/Users/naine/Documents/AndroidWorkspace/fluxdo` is still blocked by sandbox escalation approval failure, so this pass uses the already documented FluxDo badge direction rather than copying Flutter source.
- Native tag mapping: category badges keep the real Discourse category color. Topic tags only provide names in the current native model, so tag badges use `tag.fill` plus a deterministic local color palette derived from the tag text.
- Category level follow-up evidence: FluxDo `topic_card.dart` resolves the topic's `category_id` through `categoryMapProvider`, then renders `CategoryBadge(category: category)`. `CategoryBadge` displays `category.name` directly. FluxDo's `categoriesProvider` gets categories from `DiscourseService.getCategories()`, which first reads `PreloadedDataService().getCategories()` from preloaded `/site.json` `site.categories`, then falls back to `/site.json`.
- Native category-level mapping: Dexo should make `/site.json` categories the primary category display contract for topic-card category badges. `/categories.json?include_subcategories=true` can remain as a fallback for nested menu structure, but Home badge text should prefer the `/site.json` category record for the topic's `category_id`.
- Do not derive level text from local hierarchy depth. If Linux.do encodes the level in category display data, use that display data. If a fallback must compose a label from parent containers, only compose from actual category records and keep that logic centralized in `DiscourseCategory`, not in cells/controllers.
- 429 root cause: `DiscourseAPI.request` tries to decode the response before a dedicated 429 branch. If Linux.do returns a non-standard rate-limit body, Alamofire reports a decoding failure and the UI shows "Response could not be decoded." Native mapping: handle HTTP 429 immediately after receiving the response metadata and throw `DiscourseAPIError(errorType: "rate_limited")` with localized friendly text.

## Phase 1.9.1 Home Tab Bar Scroll Mapping

- FluxDo drives bottom navigation visibility through `barVisibilityProvider`; `AdaptiveScaffold` renders `_AnimatedBottomNav` with `Align(heightFactor:)` plus opacity so the bar collapses while the Home header collapses.
- Native mapping: keep the existing UIKit `UITabBarController` architecture and add scroll-driven tab bar visibility to `ForumTabBarController`, not to individual cells or table content.
- `HomeViewController` is the only first consumer. It already reads scroll direction for FAB/header behavior, so it should call the tab bar controller from `scrollViewDidScroll`.
- Direction semantics: an upward finger swipe on the Home topic list hides the tab bar; a downward finger swipe or returning near the top shows it.
- Animation: use a vertical transform on `UITabBar` so the bar pushes out below the screen and pushes back in. Set `isHidden` only after the hide animation completes so the final hidden state is clean without a visible edge.
- Scope guard: restore the tab bar when Home disappears so pushed detail/search pages and the Me tab do not inherit a hidden tab bar.
- Layout guard: recompute the hidden transform after layout changes so rotation / safe-area changes do not leave part of the tab bar visible.

## Phase 1.9.4 Detail Tag And Scrollbar Follow-Up

- Root cause: Home tag chips were updated with deterministic color and `tag.fill`, but topic-detail header tags kept their older gray `UIButton.Configuration` style. Native mapping: share the same tag color palette at the ForumDetail layer, then style detail tags as colored icon chips while preserving their tap-to-tag-list action.
- Topic-detail scroll indicator root cause: `TopicDetailViewController` creates a plain `UITableView` without disabling scroll indicators. Native mapping: hide the main table's vertical and horizontal scroll indicators. Do not change code-block horizontal scrolling in this pass.

## Phase 1.9.3 Incoming Topic Banner

- Correction: the FluxDo behavior the user highlighted is the list banner "查看 N 个新的或更新的话题" above the first topic, not the filter dropdown entries.
- FluxDo `topics_page.dart` reads `latestChannelProvider`, shows `_buildNewTopicIndicator` only on the `latest` filter, and uses `incomingCountForCategory(...)` for the count.
- FluxDo `topic_list_provider.dart` implements `loadBefore(topicIds)`: request `/latest.json?topic_ids=...`, remove duplicate existing rows, prepend returned topics, and highlight the inserted rows.
- FluxDo's count source is MessageBus `/latest` and `/new` channels. Native mapping for this phase: use a lightweight polling fallback against the current latest page, detect topics that appear before the current first row, and show the same banner. Full MessageBus long polling stays deferred.
- Native tapping behavior: call `/latest.json?topic_ids=...`, prepend returned topics to `HomeViewModel.topics`, clear incoming ids, and scroll Home back to the top.
- Existing `/new.json` and `/unread.json` filter additions can remain as a separate convenience, but they are not the corrected 1.9.3 target.

## Phase 2 Notifications Mapping

- FluxDo `notification_quick_panel.dart` uses a mobile bottom panel around 80% screen height and a rail/sidebar panel on larger layouts. Native mapping: present `NotificationsViewController` inside a `UINavigationController` as an iOS sheet from the Home bell button, using medium/large detents on iOS 15+.
- FluxDo `notifications_page.dart` is a standalone full notification history page. Native mapping: keep `NotificationsViewController` as a reusable page/controller and do not add it to `ForumTabBarController` yet. Future dynamic tab bar work can instantiate the same controller as a tab root.
- FluxDo `notification_item.dart` row shape: avatar, overlaid notification-type badge, title, description/time row, and unread dot. Native mapping: add a UIKit notification cell with the same information hierarchy using SF Symbols, SDWebImage avatars, semantic colors, and native Dynamic Type-friendly labels.
- FluxDo splits recent notification panel and full paged notification page. Native Phase 2 starts with one list backed by the existing `/notifications.json` endpoint, then leaves pagination and recent-specific query parameters as follow-up hooks.
- FluxDo click handling marks unread notifications read locally and then routes by notification type. Native mapping: mark the tapped row read locally, call `/notifications/mark-read`, and route topic-related notifications to `TopicDetailViewController` when `topic_id` exists. Profile/badge special routes are deferred until native pages and data contracts are ready.
- FluxDo notification model tolerates richer Discourse fields such as `post_number`, `high_priority`, `fancy_title`, top-level `acting_user_avatar_template`, and data-level usernames/avatar/badge fields. Native mapping: extend `DiscourseNotification` with optional fields and tolerant defaults so Linux.do variants do not cause decode failures.
- Login gating remains owned by existing `AuthGating`. If notifications return a login/403 state, show the login prompt and reload after authentication.

## Phase 2 Deferred

- Push notifications, background notification tasks, local notification scheduling, and realtime message-bus sync.
- Bottom tab bar notification entry and unread badge count integration.
- Full notification pagination, load-more footer, and retry footer.
- User profile, badge, revision-history, and boost-specific deep-link routes beyond opening the containing topic.

## Phase 2.1 Bookmarks Mapping

- FluxDo `bookmarks_page.dart` is a larger bookmarks workspace with search, name filtering, workspace tabs, manual sync, quick rename, reminders, and desktop/mobile variants. Native Phase 2.1 should not port that architecture.
- FluxDo `bookmarks_list_content.dart` ultimately renders bookmarks through the shared topic item builder with a bookmark metadata strip and excerpt. Native mapping: keep the existing `BookmarksViewController` / `BookmarksViewModel` / `BookmarkCell` ownership and restyle `BookmarkCell` toward the already tuned Home `TopicCell` card language.
- Native bookmark rows use the fields currently available from `DiscourseBookmark`: `title/name`, `topic_id`, `excerpt`, `username`, `avatar_template`, and `created_at`. Missing fields render nothing rather than fake category, tag, reply, or like data.
- `BookmarksViewController` remains reachable from Me with a known username, and also supports a future tab-root initializer that resolves the username through `AuthGating.currentUsername()`.
- Login-required, empty, error, and retry states mirror the structure used by the notification page so future dynamic tab integration can show a standalone page rather than a blank table.
- The list uses grouped background, hidden vertical scroll indicator, no separators, automatic row height, and pull-to-refresh to match the current native Home feel.

## Phase 2.1 Deferred

- Adding a visible bottom tab bar bookmarks entry.
- Bookmark pagination / load-more footer.
- Bookmark name summary filters, quick rename, reminder editing, delete actions, and manual sync.
- Opening bookmark detail at an exact post number if the API later exposes that field.

## Phase 3 Me/Profile Mapping

- FluxDo `profile_page.dart` uses a single-column card flow on mobile: profile header, stats card, optional balance cards, content/community cards, system/settings card, and an auth button.
- FluxDo `_ProfileHeader` shows avatar, display name, username, and a trust-level chip. Native mapping: implement a dedicated Me profile card in `MeViewController` so `ProfileHeaderView` can keep serving user profile pages without unexpected regressions.
- FluxDo `profile_stats_card.dart` supports configurable stats and grid/scroll layouts. Native mapping: start with a card-grid stats component fed by existing `DiscourseUserSummary` and `DiscourseUserProfile` fields, with locally persisted visible-stat selection.
- FluxDo profile actions are grouped into content/community/system cards. Native Phase 3 only exposes the user-requested and already-supported actions: private messages, bookmarks, my badges, trust requirements, invite links, and app settings.
- Private messages map to existing `MessagesViewController`.
- Bookmarks map to existing `BookmarksViewController`, preserving Phase 2.1 work.
- App settings map to existing `SettingsViewController`.
- My badges, trust requirements, and invite links do not yet have native Dexo pages or complete models. Native Phase 3 uses `SFSafariViewController` fallbacks for `/u/{username}/badges`, `https://connect.linux.do/`, and `/invites`.
- Invite links follow FluxDo's access intent: show the row, but disable it with a trust-level hint until the current profile reports trust level 3 or higher.
- Keep all Phase 3 helper views private inside `MeViewController.swift` to avoid the previous target-registration problem caused by adding Swift files without Xcode project registration.

## Phase 3 Deferred

- Native My Badges page, Trust Requirements parser/page, and Invite Links API/page.
- FluxDo stats edit page with drag ordering, layout mode, data-source switching, and connect.linux.do stat source.
- Balance cards, drafts, browsing history, browser, AI service, metaverse, and export-history entries.

## Phase 4.1 Account Features And Settings Mapping

- FluxDo `private_messages_page.dart` uses inbox, sent, and archive tabs backed by `/topics/private-messages/{username}.json`, `/topics/private-messages-sent/{username}.json`, and `/topics/private-messages-archive/{username}.json`. Native mapping: use a segmented control in `MessagesViewController`, keep one native table, and reuse the existing Home `TopicCell` topic-card language.
- Private message avatar mapping comes from `DiscourseTopicList.users` plus the topic `posters` user ids. Native `MessagesViewModel` owns this mapping so cells do not parse topic-list payloads locally.
- FluxDo `my_badges_page.dart` fetches `/user-badges/{username}.json?grouped=true`, groups badges by gold/silver/bronze, and opens badge details or related topics. Native mapping: decode `badges`, `user_badges`, and `topics`, show grouped native table sections, and open related topics when `topic_id` exists. Full badge-detail pages stay deferred.
- FluxDo `trust_level_requirements_page.dart` parses `https://connect.linux.do/` into native cards. Native Phase 4.1 maps this to an in-app `WKWebView` page so the feature is usable without external browser context. Full HTML parsing can follow later if the UI needs native cards.
- FluxDo `invite_links_page.dart` loads pending invites from `/u/{username}/invited/pending` and creates invites through `/invites`. Native mapping: load pending invites, create a one-day invite with optional description, then allow copy/share/open actions.
- Bookmark avatar bug root cause: native `DiscourseBookmark` only decoded `avatar_template`, while Discourse bookmark payloads may put avatar data in `post_user_avatar_template` or nested `user.avatar_template`. Native mapping: fix decoding at the model boundary.
- FluxDo `settings_page.dart` is a grouped category root: appearance, reading, network, preferences, bottom navigation, data management, integrations, shortcuts, about. Native Phase 4.1 implements the requested subset: appearance design, reading design, network settings, bottom bar design, and data management.
- Settings rows must represent real local settings/actions. Network keeps DoH toggle/provider/custom URL. Bottom bar auto-hide is wired into Home scroll behavior. Data management clears SDWebImage image cache.

## Phase 4.1 Deferred

- Native trust-requirement HTML parser and FluxDo-style cards for rings/bars/quotas.
- Badge detail pages, badge-user lists, favorite badge controls, and image/icon asset parity.
- Invite deletion, invite editing, cooldown/rate-limit UI, advanced email/restriction fields, and pending-invite pagination.
- Settings search, shortcut settings, Notion/integration settings, desktop-only behavior, and full FluxDo settings renderer abstraction.

## Phase 4.2 Manual Cloudflare Challenge

- FluxDo reference: `cf_challenge_service.dart` opens a browser/WebView challenge flow, detects `cf_clearance`, and syncs the cookie from WebView into the native request cookie jar at the boundary. `cf_challenge_interceptor.dart` treats 403/429 responses with `cf-mitigated: challenge` as Cloudflare challenge responses instead of normal API errors. `cf_verify_card.dart` exposes a settings entry for manual verification.
- Native mapping: keep the existing `WKWebView` + `WebCookieStore` architecture. Add a manual verification controller reachable from Network settings. The controller loads `https://linux.do/challenge` first, lets Cloudflare redirect/verify normally, and watches `WKHTTPCookieStore` for `cf_clearance`.
- Cookie boundary: `WebCookieStore` remains the app's native cookie source for web-authenticated API requests. Verification syncs all matching Linux.do cookies from `WKWebsiteDataStore.default()` into `WebCookieStore`, then persists the WebView user agent. This mirrors FluxDo's boundary sync without introducing a second cookie jar.
- API boundary: `DiscourseAPI.request` must identify Cloudflare challenge responses before surfacing decoding failures. The strongest signal is the `cf-mitigated: challenge` response header. Fallback signals are Cloudflare server/header plus body markers such as `cf_chl_opt`, `challenge-platform`, `Just a moment`, and `cf-turnstile`.
- UX: Network settings shows a FluxDo-like real action row for manual Cloudflare verification. Success requires a non-empty `cf_clearance`; otherwise the page can still be closed manually without pretending verification succeeded.

## Phase 4.2 Deferred

- Headless `cf_clearance` refresh/renewal service.
- Full WebView HTTP adapter / native request proxy through WebView.
- MessageBus/browser-trust startup orchestration from FluxDo.

## Phase 4.3 Home Layout And Tab Bar Fallback

- Screenshot root cause: Home only updated `tableView.contentInset.top` in `viewDidLayoutSubviews` and returned early when the top inset matched. It never reserved bottom space for the floating tab bar/FAB area, so topic rows could remain visible behind the bottom chrome.
- Dynamic-header root cause: when the search row collapses or expands, the header height changes and the table top inset changes. Updating the inset without preserving `contentOffset` makes the list appear to jump or stick around the incoming-topic banner.
- Incoming-banner root cause: `updateIncomingTopicsHeader()` assigned `tableView.tableHeaderView = incomingTopicsHeaderView` on every layout pass while incoming topics existed. Reassigning a table header during layout can force table geometry recalculation and amplify the sticky/jumpy feeling.
- Native mapping: centralize Home table inset updates in one method that updates both top and bottom insets, keeps scroll indicator insets aligned, and adjusts `contentOffset` by the top-inset delta to preserve visual position.
- Tab bar fallback root cause: `ForumContainerViewController` forced `UITabBarAppearance.configureWithDefaultBackground()`, which is translucent blur on systems without Liquid Glass. Native mapping: let `ForumTabBarController` own tab bar surface configuration; keep default/Liquid Glass behavior where available, and use `configureWithOpaqueBackground()` with `systemBackground` on older systems.

## Phase 4.4 Automatic Cloudflare Verification Popup

- FluxDo reference: `cf_challenge_interceptor.dart` detects 403/429 Cloudflare challenge responses, calls `CfChallengeService.showManualVerify(...)`, syncs `cf_clearance` back to the native cookie jar, then retries or lets the page recover. Native mapping mirrors the product contract, not the Dio/Riverpod implementation.
- Detection boundary: `DiscourseAPI` remains the single owner for classifying challenge responses. When `cf-mitigated: challenge` or existing Cloudflare body markers are detected, it posts `cloudflareChallengeDetectedNotification` with the normalized base URL before throwing the Cloudflare-specific API error.
- Presentation boundary: `ForumContainerViewController` owns single-site presentation. It listens for challenge notifications matching the current Linux.do forum and presents `CloudflareVerificationViewController` in a navigation controller sheet. This avoids scattering "if Cloudflare then show WebView" branches across Home, notifications, messages, bookmarks, and detail pages.
- Deduplication: the container tracks whether a CF verification sheet is already active. Parallel API failures should reuse the active user flow instead of stacking several WebViews.
- Cookie boundary: `CloudflareVerificationViewController` keeps using `WKWebsiteDataStore.default()` and `WebCookieStore.syncFromWebView(...)`. On success it syncs cookies, captures `navigator.userAgent`, broadcasts `cloudflareVerificationCompletedNotification`, and optionally auto-dismisses when launched by the API challenge flow.
- Recovery behavior: Home listens for verification completion for the current base URL and calls `loadTopics()` once. Other pages can add the same notification listener later if they need automatic retry; the first pass keeps the shared popup infrastructure in place without building a risky global retry queue.
- Follow-up root cause: the first automatic popup pass considered any existing `cf_clearance` in `WebCookieStore` as success. When the API had already hit a CF challenge, that cookie was often stale, so the verification sheet could close before the shield refreshed.
- Follow-up native mapping: snapshot the initial `cf_clearance`, delete only `cf_clearance` from both `WebCookieStore` and `WKHTTPCookieStore` for API-triggered verification, then require a non-empty clearance value that differs from the initial snapshot. Before completing, also inspect the page body for active challenge markers such as `cf-turnstile`, `challenge-running`, `challenge-stage`, and `cf_chl_opt`.
- Scope guard: do not clear login/session cookies while forcing the CF challenge refresh. Only the stale `cf_clearance` is removed.

## Phase 4.6 Avatar Loading Reliability

- FluxDo reference: `widgets/common/cached_image.dart` evicts failed image providers from Flutter `ImageCache` so a transient first failure does not become a permanent broken image until restart.
- Native root cause: avatar loading was scattered across Home, category/tag lists, bookmarks, notifications, search, profile, and topic detail. Some call sites handled `//cdn...`, others only checked `hasPrefix("http")`, so scheme-relative avatar URLs could be incorrectly resolved as `https://linux.do//cdn...`.
- Native root cause: SDWebImage was used without `.retryFailed`; SDWebImage can remember failed URLs, so a transient first failure can leave later reused cells blank.
- Native mapping: keep SDWebImage as the cache/downloader, add a small `AvatarImageLoader` boundary that resolves avatar templates and applies `.retryFailed`, `.continueInBackground`, and `.scaleDownLargeImages` consistently.
- Native mapping: configure SDWebImage's downloader concurrency once at app startup. Do not build a custom parallel downloader; SDWebImage already owns multi-threaded image download and memory/disk cache behavior.
- Placeholder behavior: avatar views should show a neutral person placeholder for missing or retrying avatars instead of clearing to `nil` and looking broken.

## Phase 4.7 Incoming Topic Banner Hardening

- FluxDo reference: `latestChannelProvider` tracks incoming topic IDs from MessageBus `/latest` and `/new`, and `TopicListNotifier.loadBefore(...)` requests `/latest.json?topic_ids=1,2,3`, removes duplicate current rows, and prepends returned topics.
- Native root cause: the polling fallback only detected topic IDs that appeared before the current first topic. That catches new topics and moved-up topics, but misses updated existing topics whose ID is already in the current list and whose row metadata changed.
- Native mapping: keep the Phase 1.9.3 lightweight polling fallback, but compare stable topic-list fields (`postsCount`, `replyCount`, `lastPostedAt`) against the current list so updated existing topics also produce the banner count.
- Native mapping: continue using the existing `/latest.json?topic_ids=...` route and `loadIncomingTopics()` insertion behavior. The fix is detection quality and lifecycle hardening, not replacing UIKit table/list architecture.
- Lifecycle mapping: after full Home reloads triggered by startup, filter/category changes, login, refresh FAB, or Cloudflare verification recovery, run the incoming detector once so the banner state is refreshed instead of waiting only for the 30-second timer.

## Phase 4.9 Topic Reading Tracking

- FluxDo reference: `_topics.dart` adds `track_visit=true` plus `Discourse-Track-View` headers when loading topic detail, and `_presence.dart` posts `/topics/timings` with per-post timings. `screen_track.dart` accumulates visible post numbers and flushes periodically.
- Native root cause: Dexo currently only fetches `/t/{id}.json` and paged post JSON. It never sends the Discourse read-tracking signals, so Linux.do has no browsing history/read-progress evidence even though the user opened and scrolled the topic.
- Topic-load mapping: `TopicDetailViewModel.loadTopic` should request topic detail with `trackVisit` enabled. `DiscourseAPI` owns the exact query/header contract so the view model does not know Discourse header names.
- Timing mapping: `TopicDetailViewController` owns the visible-row observation because the table view is the only layer that knows which comments are on screen. It maps visible diffable-data-source post ids back to `DiscourseTopicDetail.Post.postNumber`.
- API mapping: `DiscourseAPI.sendTopicTimings(...)` posts form-url-encoded fields to `/topics/timings`: `topic_id`, `topic_time`, and `timings[<postNumber>]`. The method reuses the existing Alamofire session, auth interceptor, cookie merge, and Cloudflare detection boundary.
- Failure mapping: timing upload is background read-state sync. Failures should be ignored outside DEBUG logging; a failed tracking request must not show an error or interrupt reading.
- Lifecycle mapping: the tracker ticks while the detail screen is visible, flushes about once per minute, and flushes pending milliseconds when the page disappears or deinitializes.
- Scope guard: keep the tracker private in `TopicDetailViewController.swift` to avoid adding another Swift file that can be missed by the generated Xcode project.

## Phase 5.1.1 Topic Detail Layout And Native Radial Controls

- FluxDo reference: `topic_detail_page.dart`, `topic_post_list.dart`, `PostItem`, `PostSegmentFrame`, `topic_bottom_bar.dart`, `topic_progress_gestures.dart`, and `progress_gesture_action_meta.dart` define the target feel: readable post sections, compact post height, a progress/floor affordance, and long-press radial gesture actions.
- Native boundary: keep `TopicDetailViewController`, `TopicDetailViewModel`, `PostNativeCell`, `TopicDetailBottomBar`, `ReplyComposerViewController`, and `NativeContentRenderer` as the implementation surface. Do not port FluxDo's Flutter widget tree, Riverpod providers, or `CustomScrollView` mechanics.
- Layout mapping: move detail toward FluxDo's `PostSegmentFrame` feel. The main/topic content may use a lighter surface than the reply cards if it improves reading flow; reply/comment rows should remain visually card-like with compact padding and stable short-content height.
- Typography mapping: increase detail body readability with a larger base font and ~1.5 line height in native cooked-content renderers/cells. Keep `AppSettings.readingComfortMode` and Dynamic Type behavior coherent; do not hardcode an unreadably giant fixed font.
- Comment-card mapping: use about 16pt internal padding and an approximate 80pt minimum height for short replies, matching FluxDo's compact `PostItem` constraints while still allowing long HTML content to self-size.
- Control mapping: replace the current four-button floating `TopicDetailBottomBar` with a centered floor/progress control. A normal tap opens the existing floor/timeline jump flow; a long press opens the radial action menu.
- Radial menu mapping: implement a UIKit overlay view anchored to the centered floor/progress control. It should draw a dim/blur backdrop, lay actions on an upper semicircle, highlight the nearest action while dragging, trigger on release, and cancel in a center/dead-zone. Use native `UILongPressGestureRecognizer`, `UIPanGestureRecognizer` where needed, `UIImpactFeedbackGenerator`, and `UIViewPropertyAnimator`/spring animations.
- First-pass radial actions: timeline/floor jump, scroll to top, reply topic, bookmark topic, and share topic link. Post-level actions remain in `PostNativeCell`; do not overload the topic-level radial menu with current-visible-post actions in this pass.
- Back navigation mapping: keep the `UINavigationController` interactive pop gesture enabled for `TopicDetailViewController`. If custom left-swipe handling is needed, it must fail early for mostly vertical pans so table scrolling remains reliable.
- Preservation guard: the pass must not regress reading tracking, post replies, post bookmark/reaction/boost actions, inline links, onebox/related links, images, tag taps, skeleton loading, or the reply composer.

## Phase 5.1.2 Home Topic Category Tab Manager

- FluxDo reference: `topics_page.dart` reads `pinnedCategoriesProvider`, builds the category tab row from "全部" plus pinned IDs, and opens `CategoryTabManagerSheet` from the three-line/segment icon near the topic header controls.
- FluxDo persistence: `pinned_categories_provider.dart` stores `pinned_category_ids` in shared preferences. Native mapping: `AppSettings` stores `homePinnedCategoryIds` in `UserDefaults` as stable string IDs.
- Native boundary: Dexo keeps UIKit ownership in `HomeViewController` and `HomeViewModel`. Do not port FluxDo's Flutter bottom sheet, Riverpod providers, or grid widgets.
- Tab-row mapping: `HomeViewController.rebuildCategoryTabs()` should render only "全部" plus categories resolved from `homePinnedCategoryIds`. The full category dropdown remains available for every loaded category and subcategory.
- Manager mapping: add a native sheet presented from the Home header near the notification button. The first section lists "我的分类" and tapping an item hides it from the search-below row. The second section lists available categories and tapping an item adds it to the row.
- Category display guard: category names in the manager and row must use the existing `HomeViewModel.categoryDisplayName(for:)` path so Linux.do level labels such as `开发调优LV2` remain server-data-backed.
- Detail-page guard: Phase 5.1.2 is not a topic-detail post filter. Do not add a right navigation filter menu or system-action rendering to `TopicDetailViewController` for this requirement.

## Phase 6 Lightweight DoH

- FluxDo reference: FluxDo uses a Rust DoH proxy with FFI, DNS cache, ECH support, gateway/MITM modes, and optional WebView proxying. Native Phase 6 mirrors only the product goal: bypass poisoned local DNS for Linux.do native API requests. It does not port Rust, ECH, h2 MITM, certificate handling, or Flutter network adapters.
- Native boundary: add a small iOS-native network layer under `dexo/Networking/DoH/`. `DohResolver` owns JSON DoH lookups, bootstrap provider metadata, TTL cache, and provider failover. `LocalConnectProxy` owns the loopback HTTP CONNECT listener and byte tunneling.
- Request boundary: keep `DiscourseAPI` and Alamofire as the API owner. `DiscourseAPI.makeSession` asks a shared DoH proxy service for the current loopback port when `AppSettings.dohEnabled` is true, then applies `connectionProxyDictionary` to `URLSessionConfiguration`. If the proxy is unavailable, it builds the existing direct session.
- TLS boundary: the proxy must never rewrite `https://linux.do` request URLs to IP literals. `URLSession` still sends `CONNECT linux.do:443`, then starts TLS over the tunnel using `linux.do` for SNI and certificate validation.
- Host scope: Phase 6 only resolves and tunnels Linux.do-related hostnames. Unknown CONNECT hosts are rejected or passed through only if the implementation has an explicit safe path. This keeps the experiment narrow and avoids turning the app into a general-purpose proxy.
- DoH protocol: first pass uses provider JSON endpoints because they are easy to implement and inspect in Swift. AliDNS and DNSPod are the practical defaults for the target connectivity problem; Cloudflare/Google can remain selectable but are not assumed to be reachable.
- Failure behavior: resolver errors, empty answers, listener startup failures, or CONNECT failures must fail closed for that tunnel and allow the app to rebuild/fallback to a direct session on later starts. Do not leave Alamofire permanently pointing at a dead port.

## Phase 6 Deferred

- FluxDo's Rust `doh_proxy`, ECH/HTTPS record support, h2 MITM, generated CA certificates, WebView proxy override, DNS cache UI, and proxy health dashboards.
- System-level DNS via NetworkExtension or `NEDNSSettingsManager`.
- Global proxying for arbitrary user-entered forums or non-Linux.do domains.

## Phase 5.4 Cloudflare Request Noise Reduction

- Field evidence: Cloudflare challenge diagnostics show `image.avatar`, `api.topicTimings`, and `api.foreground` can all receive `cf-mitigated: challenge`. A `429` status alone is not proof of a shield, but `cf-mitigated: challenge` is a strong Cloudflare challenge signal and must be handled as such.
- Product boundary: only user-facing requests should open the automatic verification sheet. Background/low-value traffic should log, pause, and retry later without interrupting the current reading flow.
- Image mapping: `CloudflareImageGate.reportImageChallenge` remains the central image challenge boundary. It should pause main-domain image downloads and keep coalescing repeated image challenges, but forward the event through `DiscourseAPI.handleCloudflareChallengeDetected(... shouldNotify: false)` so avatar/content-image failures do not present the verification sheet by themselves.
- Timing mapping: `/topics/timings` is read-progress telemetry. It should keep Cloudflare detection and diagnostics, but pass `shouldNotify: false` even when interactive web recovery is available. A failed timing post must not block reading or pop UI.
- Main-request mapping: `DiscourseAPI.request(...)` and other explicit user actions keep their existing `shouldNotify` behavior. Home `latest.json`, topic detail, search, notifications, uploads, reactions, bookmarks, and similar user-visible work can still open verification when challenged.
- Traffic shaping: reduce global SDWebImage avatar concurrency and prefetch concurrency. Home should prefetch only a small leading set of avatar URLs instead of 60 rows, and Cloudflare verification recovery should retry a small visible/near-visible avatar set rather than immediately creating another burst.
- Recovery mapping: after verification completes, `AvatarImageLoader.credentialsDidChange(...)` clears paused/failed state for selected retry URLs, Home reconfigures visible cells, and normal cell reuse can reload avatars. This keeps image recovery incremental instead of restarting every cached/prefetched image request at once.
- Deferred: a centralized `CloudflareRequestGate` with request priority queues, cooldown budgets, replay scheduling, or headless clearance refresh remains a later phase. This pass deliberately avoids broad networking architecture churn.

## Phase 7 User Profile And Me Completion

- Source design: `docs/superpowers/specs/2026-07-10-user-profile-and-me-completion-design.md` owns the approved detailed contract.
- Scope: complete the user preview card, other-user profile page, and current-user Me page with real Discourse or local behavior. CDK/LDC, Connect statistics, AI, Notion export, and metaverse remain excluded.
- Networking boundary: extend `DiscourseRouter`, `DiscourseAPI`, and typed models for user card capabilities, follow state, notification levels, private messages, user action pages, reactions, social lists, and drafts. UI code must not assemble raw endpoint payloads.
- Relationship boundary: one shared relationship state coordinates follow, mute, ignore, restore, permission visibility, in-flight mutations, optimistic updates, and rollback for both preview and full profile surfaces.
- Profile boundary: keep `UserProfileViewController` as the navigation owner, but move section data and paging state out of static UI construction. Summary, activity, topics, replies, likes received, and reactions are independently refreshable and paged.
- Me boundary: retain the current card dashboard and existing native routes. Add My Topics, Drafts, Discourse browsing history, in-app browser/bookmarks/history, local profile-stat ordering/layout, and export history.
- Export guard: export history ships only with a real topic Markdown/HTML export producer. A standalone empty history page is not acceptable.
- Storage boundary: browser and export records are account-scoped Codable stores under Application Support; compact statistics configuration remains in `UserDefaults`.
- Failure behavior: preserve loaded pages on pagination failure, retry from the footer, rollback failed mutations, route auth-required operations through `AuthGating`, and never expose a row that only opens an unavailable/coming-soon alert.
- Compatibility: UIKit only, iOS 15 minimum, current Dexo theme, existing dirty changes preserved, Tuist regenerated for new Swift sources, and Simulator Debug build required before completion.
