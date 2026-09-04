# Implementation Plan

## Phase 1: Read-State Styling

- [ ] Decode Discourse topic read fields with safe defaults.
- [ ] Add a shared read-presentation computation.
- [ ] Merge successful timing updates into Home/list state.
- [ ] Apply secondary title color/weight to standard and alternate topic cards.
- [ ] Add model and state-merge tests.

## Phase 2: Browser Redesign

- [ ] Add `initialURL` routing and preserve shared cookies/user agent.
- [ ] Replace form/toolbar UI with address capsule and compact controls.
- [ ] Add bookmark, copy URL, share, external open, and scheme confirmation.
- [ ] Restyle browser home/history/bookmark pages and add bookmark rename/manual add.
- [ ] Add store and URL-policy tests.

## Phase 3: Topic Detail Actions and Search

- [ ] Decode topic details permissions and notification level.
- [ ] Add notification and topic-edit API routes.
- [ ] Decode search result `post_number` and implement scoped topic search.
- [ ] Add Search and More navigation items.
- [ ] Implement custom quick-action/menu panel with permission gating.
- [ ] Add account-isolated read-later store.
- [ ] Reuse bookmark/share/export/filter/reading settings actions.
- [ ] Route browser open through the redesigned in-app browser.
- [ ] Add topic editor and share-image renderer.
- [ ] Add targeted API/model/store/search tests.

## Phase 4: Metaverse / LDC / CDK

- [ ] Add service models, configuration, cache, and shared OAuth coordinator.
- [ ] Implement LDC authorization, balance, refresh, logout, and dashboard.
- [ ] Implement CDK authorization, score, refresh, logout, and dashboard.
- [ ] Add native service-management UI and Me entry.
- [ ] Add Keychain-backed LDC merchant credential configuration.
- [ ] Add LDC reward API, validation, confirmation sheet, and cooldown store.
- [ ] Add reward action to eligible post menus only.
- [ ] Add OAuth parsing, cache isolation, Keychain, and reward tests.

## Phase 5: Integration Verification

- [ ] Run `git diff --check`.
- [ ] Run targeted model/store/view-model tests.
- [ ] Build `dexoflux` for the configured iOS simulator.
- [ ] Manually verify Cloudflare/cookie continuity in browser and OAuth flows.
- [ ] Verify read styling restores unread emphasis after refreshed topic data.
- [ ] Verify Topic Detail existing reply/bookmark/export/timeline behavior.

## Risky Files

- `dexo/Networking/DiscourseAPI.swift`
- `dexo/Networking/DiscourseRouter.swift`
- `dexo/Features/ForumDetail/Home/HomeViewController.swift`
- `dexo/Features/ForumDetail/TopicDetail/TopicDetailViewController.swift`
- `dexo/Features/ForumDetail/Me/InAppBrowserViewController.swift`
- `dexo/Localizable.xcstrings`

## Execution Order

Complete and verify each phase before starting the next. Do not combine the
OAuth/reward work with Topic Detail menu changes in the same patch unless the
only shared change is an additive action route.
