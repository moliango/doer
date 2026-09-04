# DexoFlux Plugin System

## Goal

Build a controlled extension architecture that lets DexoFlux isolate optional forum enhancements, enable or disable them per forum/account, and add new capabilities without continuing to hard-code every feature into large UIKit view controllers.

The first release should prove the architecture with real DexoFlux features while preserving iOS security, App Store compatibility, authentication behavior, Cloudflare handling, localization, and the existing visual system.

## User Value

- Users can enable only the enhancements they need.
- Optional Linux.do-specific services no longer clutter the core forum experience.
- Plugin permissions and data access are visible and controllable.
- Broken optional features can be disabled without destabilizing the forum client.
- Future official enhancements can be delivered through stable extension points instead of repeatedly modifying large core screens.

## Confirmed Facts

- DexoFlux is an iOS 15+ native UIKit application using GRDB and Alamofire.
- App startup and feature composition are currently hard-coded through `SceneDelegate`, `ForumContainerViewController`, and `ForumTabBarController`.
- Feature controllers commonly depend directly on the concrete `DiscourseAPI` type.
- Authentication cookies, CSRF behavior, Cloudflare recovery, networking, navigation, and storage are host responsibilities and must not be exposed directly to plugins.
- Existing natural contribution points include forum tabs, the Me action area, Topic Detail menu actions, Topic Detail radial actions, settings entries, and limited Home actions.
- LDC/CDK and metaverse services are the best first migration candidates because they are optional, forum-specific, and currently mix UI, OAuth, networking, credentials, and persistence.
- iOS cannot safely support downloading arbitrary Swift/Objective-C frameworks or executable code.
- Downloaded JavaScript capable of changing native application behavior creates significant App Store review and security risk.

## Product Direction

The recommended V1 direction is a host-controlled plugin runtime with two layers:

1. Built-in native plugins compiled and signed with DexoFlux, registered at runtime and independently enabled or disabled.
2. A versioned declarative plugin contract that can later support official signed extension packages containing manifests, resources, rules, and host-rendered UI descriptions, without arbitrary downloaded code execution.

The experimental implementation starts with built-in native plugins. Online third-party installation remains a planned second phase built on the same manifests, capabilities, contribution identifiers, and host services.

## Requirements

### Plugin Identity and Lifecycle

- Every plugin has a stable identifier, display name, semantic version, minimum host version, capability declaration, supported forum hosts, and deterministic contribution ordering.
- Plugins can be enabled or disabled per forum instance and account scope.
- The host can globally disable all optional plugins through a safe mode.
- A plugin failure must not prevent the core forum, login, settings, or Topic Detail screens from opening.
- Plugin initialization, action execution, cancellation, timeout, and failure must be logged with the plugin identifier.

### Supported V1 Contributions

- Me page action entry.
- Topic Detail menu action.
- Topic/Post contextual action using read-only host DTOs.
- Plugin settings entry and host-presented settings page.
- Limited forum menu or Home shortcut contribution.
- Optional forum tab contribution only for approved built-in plugins.
- Contributions must use host-rendered UIKit components and existing DexoFlux theme/localization behavior.

### Host Capabilities

- Plugins receive narrow, versioned host services rather than concrete singletons or view controllers.
- Required host services include forum context, authentication gating, navigation commands, plugin-scoped settings, plugin-scoped secure storage, logging, and a restricted forum HTTP client.
- The host executes authenticated requests and keeps cookies, CSRF tokens, Keychain values, Cloudflare state, and raw database access private.
- Network operations are selected from host-defined operation identifiers with validated parameters.
- External network access requires an exact host allowlist and explicit capability.
- Plugin storage is namespaced by plugin identifier, forum, and account.

### Permissions

- Capabilities are denied by default and must be explicitly declared.
- Permissions are displayed before enabling a plugin.
- New permissions introduced by an update require renewed approval.
- Read and write capabilities are separate.
- Destructive or publishing actions require host-controlled confirmation.
- Plugins cannot read authentication cookies, arbitrary Keychain items, another plugin's storage, arbitrary files, or raw GRDB tables.

### Management UI

- Settings contains a plugin management page matching the existing DexoFlux UI.
- The page shows plugin name, version, publisher/trust state, enabled state, forum/account scope, permissions, status, and last error.
- Users can enable, disable, configure, reset data, and inspect permissions.
- The system supports a global safe-mode switch.

### First-Party Migration

- The initial validation set should include separate LDC, CDK, and Topic Export built-in plugins so the architecture is tested against account services, Post/Topic actions, and local history/storage.
- The internal catalog also includes NewAPI Check-in and LDC Store plugins.
- NewAPI Check-in provides a native Tab page, multiple NewAPI endpoint accounts, individual and batch check-in, persisted results, and an iOS 16+ App Intent for Shortcuts/Siri batch check-in.
- NewAPI credentials and platform data remain isolated from forum cookies and other plugins.
- LDC Store contributes a Tab page rendered through the host in-app browser so it reuses DexoFlux browser history, cookies, Cloudflare handling, and navigation behavior.
- LDC/CDK/metaverse functionality is migrated without regressing OAuth, Cloudflare handling, credentials, service-page navigation, or Topic Detail entry behavior.
- Topic Export is migrated without deleting existing export files or export history.
- Core screens consume plugin contributions through registries rather than directly importing LDC/CDK feature controllers.
- The migration demonstrates at least one Me contribution, one Topic Detail action, one settings contribution, scoped storage, and restricted networking.
- Disabling a plugin removes its contributions immediately without requiring an app restart.
- Disabling a plugin preserves credentials and history; clearing plugin data is a separate destructive action.

### Compatibility and Quality

- Existing app behavior is unchanged when all plugins are disabled.
- Plugin-facing topic, post, user, and forum data use small versioned DTOs rather than internal Discourse response models.
- Plugin actions are asynchronous, cancellable, and executed through host-owned loading/error presentation.
- Plugin identifiers, capability identifiers, contribution identifiers, and persisted keys are stable across releases.
- All user-visible plugin strings support the existing string catalog localization flow.

## Acceptance Criteria

- [ ] The app has a single plugin registry created from the application composition root.
- [ ] A built-in plugin can register contributions without editing the target host screen's action construction logic.
- [ ] Plugins can be enabled and disabled independently per forum/account.
- [ ] Disabling every plugin produces the current core DexoFlux forum experience without missing required features.
- [ ] The first LDC/CDK plugin contributes a Me entry, Topic Detail action, and settings entry.
- [ ] LDC, CDK, and Topic Export can be enabled independently without affecting one another.
- [ ] NewAPI Check-in and LDC Store can be enabled independently and appear as plugin-contributed Tab pages.
- [ ] Enabling a plugin only registers its Tab as an available bottom-bar candidate; it does not automatically occupy the bottom bar.
- [ ] Users add, remove, and reorder enabled plugin Tabs from the existing bottom-bar design page under the same five-entry limit as system Tabs.
- [ ] NewAPI supports adding/removing endpoints, individual check-in, batch check-in, persisted last result, and an App Intent that uses the same store/service.
- [ ] Disabling the selected plugin Tab safely returns the user to Home.
- [ ] Existing LDC/CDK authorization state, merchant credentials, export history, and exported files survive migration.
- [ ] Plugin code cannot access raw cookies, CSRF tokens, `DatabaseManager`, `AppSettings`, or unrestricted `DiscourseAPI` instances.
- [ ] Plugin network calls use a restricted host client and exact-domain policy.
- [ ] Plugin state is isolated by plugin, forum, and account and can be reset from Settings.
- [ ] A throwing, timing-out, or disabled plugin does not block app startup or core screen rendering.
- [ ] The plugin management page exposes status, permissions, version, scope, enable/disable, and safe mode.
- [ ] Tests cover registry ordering, duplicate identifiers, availability rules, capability denial, scoped storage, enable/disable persistence, and plugin action failure handling.
- [ ] Existing authentication, Cloudflare recovery, Topic Detail, Me, and Settings tests continue to pass.

## Out of Scope for V1

- Downloading or loading Swift frameworks, dynamic libraries, or executable native code.
- Arbitrary JavaScript or WebView scripts controlling native application behavior.
- A public third-party plugin marketplace.
- Paid plugins, developer accounts, ratings, reviews, or marketplace moderation.
- User installation of unsigned packages from arbitrary URLs or files.
- Direct plugin access to UIKit navigation controllers, authentication cookies, Keychain, GRDB, or unrestricted file storage.
- Replacing the Home data source, Topic cells, Topic Detail renderer, or arbitrary native page lifecycle.
- Background daemons, unrestricted scheduled tasks, or plugin-to-plugin dependencies.

## Future Candidates

- Official signed declarative extension packages.
- Host-rendered schema pages and forms.
- Declarative Topic/Post decoration rules.
- Official extension catalog, staged rollout, emergency disable, version pinning, and rollback.
- Additional host-approved contribution points after real first-party plugins validate the contracts.

## Decisions

- Experimental V1 ships three built-in plugins: LDC, CDK, and Topic Export.
- The internal catalog expands to five plugins with NewAPI Check-in and LDC Store.
- LDC and CDK remain independently enabled even if their current management UI is shared.
- Online third-party installation will use declarative packages and host-provided operations in a later phase.
- Arbitrary downloadable Swift/native code and unrestricted JavaScript are not supported.
