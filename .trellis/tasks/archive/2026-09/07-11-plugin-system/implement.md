# DexoFlux Plugin System Implementation Plan

## Phase 1: Core Runtime

- Add manifest, capability, contribution, registry, scoped state store, and runtime types.
- Register LDC, CDK, and Topic Export in a built-in catalog.
- Add deterministic ordering, duplicate-ID rejection, default state, safe mode, and state-change notification.
- Add unit tests for registry validation and scoped enablement.

## Phase 2: Plugin Center

- Add a plugin center entry to the Me page.
- Implement the host-rendered plugin management list.
- Show version, internal trust state, permission summary, current forum/account scope, switches, and global safe mode.
- Add localized strings and accessibility labels.

## Phase 3: Contributions

- Hide/show the metaverse Me action based on LDC or CDK availability.
- Pass independent LDC/CDK availability into the shared service page and filter its rows.
- Hide LDC reward actions when LDC is disabled.
- Hide/show Topic Export menus and export-history entry based on Topic Export state.
- Rebuild visible actions immediately after plugin state changes.

## Phase 4: Verification

- Run registry/state unit tests.
- Run `git diff --check`.
- Generate the Tuist project if the test target changes.
- Build the `dexoflux` Debug scheme with signing disabled.
- Manually inspect plugin-center state transitions and verify existing credentials/history are not deleted.

## Phase 5: NewAPI Check-in Plugin

- Port NewAPI platform, request building, response classification, batch coordination, and scoped persistence from `NewAPSign`.
- Add a UIKit plugin Tab for endpoint management, individual check-in, batch check-in, and last-result display.
- Add an iOS 16+ App Intent and App Shortcuts provider using the same service and store.
- Add request/response/store tests without copying SwiftUI or the standalone app database.

## Phase 6: Plugin Tabs and LDC Store

- Add NewAPI Check-in and LDC Store manifests with `forumTab` contributions.
- Add a host-side built-in plugin Tab resolver.
- Merge plugin tabs into `ForumTabBarController` without extending the closed system-tab enum.
- Enforce the existing maximum of five visible tabs and rebuild on plugin/account changes.
- Render LDC Store through `InAppBrowserViewController` using the approved service URL.

## Risky Files and Rollback Points

- `MeViewController.swift`: action list ordering and immediate refresh.
- `TopicDetailViewController.swift`: menu reconstruction and reward/export gating.
- `MetaverseServicesViewController.swift`: shared LDC/CDK UI filtering.
- `Localizable.xcstrings`: large generated catalog; isolate string changes.

Rollback is limited to removing plugin contribution checks and the plugin-center entry. Existing credentials, OAuth caches, exports, and history are not migrated or rewritten.
