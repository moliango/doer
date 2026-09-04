# DexoFlux Plugin System Design

## Architecture

The experimental system uses a host-owned registry containing immutable built-in plugin manifests. Runtime state is kept separately in a scoped store so registry metadata never depends on user settings.

Core types:

- `DexoPluginManifest`: stable identity, version, localized presentation metadata, capabilities, contribution kinds, default state, and ordering.
- `DexoPluginRegistry`: validates unique identifiers, returns stable ordered manifests, and filters enabled contributions.
- `DexoPluginStateStore`: persists global safe mode and per-plugin enablement using `pluginID + forum host + account` scope.
- `DexoPluginCenterViewController`: host-rendered management UI for status, permissions, enablement, and safe mode.
- `BuiltInPluginCatalog`: composition root for LDC, CDK, and Topic Export manifests.

## Scope Model

Plugin state keys use the normalized forum base URL and current username. Anonymous state uses a stable anonymous account component. This follows existing account-scoped stores and prevents settings leaking across forums or accounts.

Disabling a plugin hides its contributions immediately but preserves credentials, export history, and files. Data deletion remains an explicit feature-specific operation.

## Contributions

The first iteration exposes typed contribution kinds rather than arbitrary UIKit injection:

- `meAction`
- `topicMenu`
- `postAction`
- `settings`
- `forumTab`

Host screens query the registry/state store and decide whether to include their existing actions. The first migration deliberately reuses existing view controllers and services; it does not move OAuth/networking implementation into a plugin SDK yet.

LDC and CDK share `MetaverseServicesViewController`, so the controller receives availability flags and only shows enabled service rows. LDC reward UI is available only when the LDC plugin is enabled.

Topic Export controls both the Topic Detail export menu and the Me export-history entry.

NewAPI Check-in is a native built-in plugin. It ports the proven request shape from the existing NewAPSign project (`POST /api/user/checkin`, Bearer/Cookie authentication, optional `New-Api-User`, response classification, bounded batch concurrency) into a plugin-scoped Codable store and UIKit Tab page. Its App Intent uses the same store and service without opening the UI.

LDC Store is a host-resolved web plugin Tab. The manifest contains only the contribution metadata; a built-in resolver creates the in-app browser controller with the approved store URL. UIKit factories remain outside Codable manifests so future downloaded declarative packages cannot inject native code.

Plugin enablement and bottom-bar placement are separate states. Enabling a plugin only registers its `forumTab` contribution in the bottom-bar design catalog. The existing bottom-bar design page persists a unified ordered list of system and plugin item identifiers. `ForumTabBarController` resolves only configured identifiers, keeps the five-tab maximum, preserves the selected identifier during rebuilds, and falls back to Home when the selected plugin is disabled or removed.

## Composition

`BuiltInPluginCatalog` owns the three manifests. A shared `DexoPluginRuntime` exposes registry and scoped state to existing screens during the experiment. The public contracts avoid `DiscourseAPI`, cookies, Keychain, GRDB, and navigation controllers so they remain usable by a future declarative runtime.

## Permissions

The experimental manifests declare capabilities for presentation and future enforcement. V1 does not expose a general plugin network client because existing features continue to execute through host code.

Initial capabilities include:

- `forum.read`
- `topic.read`
- `topic.export`
- `post.reward`
- `network.discourse`
- exact external service hosts where required
- `storage.plugin`
- `browser.open`

## UI

The plugin center is opened from the Me page and uses the existing card/list visual language. It shows three internal plugins, version, permission summary, scope, and switches. A global safe-mode switch disables all optional contributions without changing individual plugin preferences.

Changes post a plugin-state notification. Visible host screens rebuild menus/action sections immediately.

## Migration and Compatibility

- Current LDC/CDK credentials and OAuth state remain untouched.
- Current export history and files remain untouched.
- Defaults preserve current behavior: all three built-in plugins start enabled for existing and new users.
- No database migration is needed; experimental state uses namespaced `UserDefaults` keys.
- Future manifest/schema versions can replace the built-in catalog without changing persisted plugin identifiers.

## Failure and Rollback

If the runtime cannot resolve scoped state, it falls back to manifest defaults. Safe mode can disable all contributions. Removing the host-screen checks restores the previous hard-coded behavior without data migration.

## Deferred Design

- Download, signature verification, catalog, update, and rollback of declarative packages.
- Host-rendered JSON pages and workflow execution.
- Restricted HTTP operation broker.
- Third-party developer CLI and validation tooling.
- Permission approval UI for newly installed packages.
