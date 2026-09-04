# Mini Program System Implementation Plan

## Validation Commands

- After creating Swift files: `make generate`
- Targeted tests after model/store work: `xcodebuild test -workspace dexoflux.xcworkspace -scheme dexofluxTests -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:dexofluxTests/MiniProgramStoreTests`
- Final build: `xcodebuild build -workspace dexoflux.xcworkspace -scheme dexoflux -destination 'platform=iOS Simulator,name=iPhone 16'`

If the named simulator is unavailable, use `xcrun simctl list devices available` and pick an available iOS simulator.

## Task 1: Store Model With Tests

- Add `dexofluxTests/MiniProgramStoreTests.swift`.
- Add `dexo/Features/Plugins/MiniProgram/MiniProgramModels.swift`.
- Add `dexo/Features/Plugins/MiniProgram/MiniProgramStore.swift`.
- Test-first behaviors:
  - built-ins seed as `LDC`, `CDK`, `NewAPI 签到`, `LD 士多`
  - built-ins cannot be deleted
  - built-ins can be hidden and restored
  - custom URL programs can be added, edited, deleted
  - category deletion moves affected programs to `other`
  - ordering persists
  - recents ignore hidden/deleted IDs

## Task 2: Metadata and Icon Storage

- Add `dexofluxTests/MiniProgramMetadataTests.swift`.
- Add `dexo/Features/Plugins/MiniProgram/MiniProgramMetadataService.swift`.
- Add `dexo/Features/Plugins/MiniProgram/MiniProgramIconStore.swift`.
- Parse title/icon candidates from HTML with deterministic pure tests.
- Store local selected images in Application Support and keep relative paths in records.

## Task 3: Runtime Factory Migration

- Update `MiniProgramFactory` to read descriptors from `MiniProgramStore`.
- Add opening support for `LDC` and `CDK` via current metaverse service page.
- Keep `NewAPI` and `LD 士多` open paths working.
- Ensure opening a program records recents.

## Task 4: Drawer Update

- Update `MiniProgramDrawerViewController` to consume store data.
- Show recent, my programs, and categories from the store.
- Exclude hidden programs.
- Keep search/filter behavior.

## Task 5: Management UI

- Replace `PluginCenterViewController` or add `MiniProgramManagementViewController` and route the old plugin-center entry to it.
- Support toggling built-ins.
- Support adding URL program with metadata preview.
- Support editing custom program fields.
- Support deleting custom programs.
- Support category CRUD and sorting.
- Support local Logo selection via PHPicker.

## Task 6: Settings and Visible Plugin Removal

- Add `AppSettings.miniProgramsEnabled`.
- Convert appearance plugin Dock row to mini program global switch.
- Hide Home mini program button when disabled.
- Hide management entry when disabled.
- Remove Me mini program card.
- Rename plugin center row to mini program management.
- Remove bottom bar plugin tab options and prune stale plugin item IDs.
- Ensure user-facing strings no longer show old plugin center/Dock/Tab concepts.

## Task 7: Verification

- Run `make generate` because new Swift files are added.
- Run targeted mini program tests.
- Run final simulator build.
- If broad existing tests are too slow, document that only targeted tests/build were run.

## Risk Notes

- `SettingsViewController.swift`, `HomeViewController.swift`, and `MeViewController.swift` are large; keep edits localized.
- Do not delete old business code for LDC/CDK/NewAPI/LD Store unless replacement is verified.
- Existing uncommitted changes are present; avoid reverting unrelated files.

## 2026-07-31 Implementation Notes

- Added the global `MiniProgramStore` catalog, metadata parser, local icon storage, and focused unit tests.
- Replaced the old plugin-center user flow with 小程序管理, including built-in visibility toggles, custom URL programs, category management, ordering, and local logo selection.
- Moved the user-visible mini program entry to Home only; Me keeps only the management row when the global switch is enabled.
- Converted the Appearance switch from plugin Dock to mini programs, removed the old Dock mount, and removed plugin-provided bottom bar items from settings.
- Switched LDC/CDK visibility checks used by Me balance and metaverse services from plugin state to mini program catalog state.
- Verification passed:
  - `make generate`
  - `xcodebuild build -workspace dexoflux.xcworkspace -scheme dexoflux -destination 'platform=iOS Simulator,id=7C6C3BB8-0BD8-4B28-9F9F-11B2761F0F77'`
  - `xcodebuild build -workspace dexoflux.xcworkspace -scheme dexofluxTests -destination 'platform=iOS Simulator,id=7C6C3BB8-0BD8-4B28-9F9F-11B2761F0F77'`

## 2026-08-01 Implementation Notes

- Added `MeAccountFunctionPreferences` for global `我的`页账号功能 visibility and ordering.
- Added `我的`页账号功能卡片右上角“自定义” management with visible/hidden sections, hide/restore actions, drag sorting, and restore default.
- Updated `MeViewController` to render account functions from the preference order while keeping the card-level customize entry available even when all rows are hidden.
- Added account-function preference tests in `MeStatsPreferencesTests`.
- Verification passed:
  - `xcodebuild build -workspace dexoflux.xcworkspace -scheme dexofluxTests -destination 'platform=iOS Simulator,id=7C6C3BB8-0BD8-4B28-9F9F-11B2761F0F77'`
  - `xcodebuild build -workspace dexoflux.xcworkspace -scheme dexoflux -destination 'platform=iOS Simulator,id=7C6C3BB8-0BD8-4B28-9F9F-11B2761F0F77'`
