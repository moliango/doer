# Mini Program System Design

## Architecture

Replace the user-facing plugin surface with a first-party mini program system. The implementation keeps existing business capabilities where practical, but the product model becomes `MiniProgram` instead of `PluginManifest`.

The core data owner is a new global store under `Features/Plugins/MiniProgram/`:

- `MiniProgramModels.swift` defines program/category records, built-in IDs, and metadata fetch results.
- `MiniProgramStore.swift` persists enabled state, custom URL programs, categories, ordering, and recents in `UserDefaults` as a single-versioned JSON document.
- `MiniProgramMetadataService.swift` fetches URL title/icon candidates for the add flow.
- `MiniProgramIconStore.swift` stores user-selected local Logo images under Application Support and resolves icon images for UI.

UI entry points:

- Home remains the only launcher entry. `HomeViewController` hides the button when `AppSettings.miniProgramsEnabled == false`.
- The old plugin center position becomes `MiniProgramManagementViewController`.
- `MeViewController` removes the mini program card and plugin-center wording.
- `PluginDockViewController` and forum tab plugin paths disappear from user-visible UI. If files remain temporarily, they must not be reachable.

## Data Flow

```
AppSettings.miniProgramsEnabled
  -> Home button visibility
  -> Management entry visibility

MiniProgramStore document
  -> built-in program visibility/order/category
  -> custom URL programs
  -> categories
  -> recent program IDs
  -> drawer + management list

Add URL
  -> normalize URL
  -> MiniProgramMetadataService.fetch
  -> preview card
  -> optional local image via PHPicker
  -> MiniProgramIconStore save
  -> MiniProgramStore append
```

## Persistence Contract

Persist one global document because the app is permanently single-forum:

```swift
struct MiniProgramCatalogSnapshot: Codable, Equatable {
    var version: Int
    var programs: [MiniProgramRecord]
    var categories: [MiniProgramCategory]
    var recentProgramIDs: [String]
}
```

Built-ins are merged at load time so new app versions can introduce missing built-ins without overwriting user visibility/order. Custom programs use stable UUID-backed IDs. URL normalization is used for duplicate warnings, not as the primary ID.

Local Logo images are copied into Application Support using the program ID. The store keeps a relative icon path so the document survives app container path changes.

## Built-In Programs

Built-ins:

- `builtin.ldc`
- `builtin.cdk`
- `builtin.newapi-check-in`
- `builtin.ldc-store`

All appear in mini program management, can be hidden, cannot be deleted, and can be sorted/categorized. Opening behavior:

- `NewAPI 签到`: reuse `NewAPICheckInRuntime.shared.makeViewController()` inside `MiniProgramHostViewController`.
- `LD 士多`: reuse `InAppBrowserViewController` with `https://ldcstore.com/`.
- `LDC` / `CDK`: MVP opens `MetaverseServicesViewController`; follow-up can split them into dedicated pages if needed. This keeps current authorization and credential flows instead of duplicating OAuth code.

## Settings and Removal

Rename user-facing plugin concepts:

- Old plugin center row becomes mini program management.
- Appearance plugin Dock switch becomes the mini program global switch.
- Bottom bar plugin tab options are pruned and no longer displayed.
- Existing old plugin UserDefaults may remain as migration inputs, but new UI must not show plugin wording.

## Error Handling

- Metadata fetch failure returns a preview with URL host as name and default icon.
- Invalid URLs are blocked before fetch.
- Logo image import failure keeps the current/auto icon and shows a recoverable error.
- Hidden/deleted programs are removed from recents during normalization.
- Deleting a category moves programs to `other`.

## Testing Strategy

Use TDD for model/store behavior first:

- Built-ins are seeded and cannot be deleted.
- Built-ins can be hidden and restored.
- Custom URL programs can be added/edited/deleted.
- Category deletion moves programs to `other`.
- Sorting persists.
- Recents exclude hidden/deleted programs.
- Global app setting hides homepage/management entry through UI state helpers where practical.

UI-heavy flows get focused compile/build verification and small pure tests for routing/state where possible.
