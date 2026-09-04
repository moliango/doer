# App Extensions: Widgets, App Groups, APNs

> Cross-layer contracts for WidgetKit, App Groups, silent push, and in-app
> deep links. Cookie web-session auth cannot use Discourse official `push_url`.

---

## Scenario: Trust-level widget snapshot

### 1. Scope / Trigger
- Trigger: home-screen WidgetKit reads progress the app writes; the widget
  target must not import app types (SwiftSoup, Discourse models, UIKit VCs).

### 2. Signatures
- `TrustLevelWidgetIDs.appGroup` = `group.com.naine.doer`
- `TrustLevelWidgetIDs.snapshotKey` = `trustLevel.widget.snapshot`
- `TrustLevelWidgetIDs.widgetKind` = `DoerTrustLevelWidget`
- `TrustLevelWidgetIDs.deepLink` = `doer://trust`
- `TrustLevelWidgetSnapshotStore.save(_:defaults:)` / `.load(defaults:)`
- `TrustLevelWidgetRefresher.persist(report:trustLevel:)` (connect.linux.do)
- `TrustLevelWidgetRefresher.persist(fallback:trustLevel:note:)` (summary.json)
- `TrustLevelWidgetRefresher.refreshIfPossible()` (background / silent push)

### 3. Contracts
- Shared source compiled into **both** `Doer` and `DoerWidget`:
  `Shared/TrustLevelWidgetSnapshot.swift` (listed in `Project.swift` `sources`).
- Widget chrome (penguin mascot, card gradient) lives in
  `Extensions/DoerWidget/Assets.xcassets`. Do not load App `Assets.xcassets`
  from the widget target.
- Codable snapshot only. Widget UI reads `TrustLevelWidgetSnapshot`; it must
  not parse Connect HTML.
- Entitlements: `com.apple.security.application-groups` = `[group.com.naine.doer]`
  on **app and widget**. App also has `aps-environment`.
- Write path: Trust page after a successful fetch, and
  `BackgroundNotificationDeliveryPipeline.refreshInBackground()` after delivery.
- Empty Connect `div.card.empty-state` must **not** overwrite a previous
  snapshot; fall through to `/u/{username}/summary.json`.
- Tap: `doer://trust` → `DoerInAppRoute.trustLevel` → Me tab +
  `TrustRequirementsViewController`.

### 4. Validation & Error Matrix
- App Group `UserDefaults(suiteName:)` is nil → save/load no-ops (unsigned /
  missing entitlement). Tests pass an explicit suite.
- Connect HTML missing `div.card` → parser throws → summary fallback.
- Connect empty-state card → summary fallback, keep prior widget if summary
  also fails.
- Bar copy `"5,000 / 20,000"` → strip `,` / `，` then take first two integers.

### 5. Good/Base/Bad Cases
- Good: linux.do session + Connect card with 已读帖子 → widget headline is that bar.
- Base: non-linux.do forum → summary fallback items + `TL{n}` badge.
- Bad: persist empty-state Connect report (blank widget).

### 6. Tests Required
- Snapshot encode/decode via injected `UserDefaults`; headline prefers 帖/post/读.
- `parseBarCurrentAndTarget("5,000 / 20,000")` → `(5000, 20000)`.
- `doer://trust` and `doer://trust-level` → `.trustLevel`.

### 7. Wrong vs Correct
#### Wrong
```swift
// Widget imports ConnectTrustParser / SwiftSoup
// Project.swift widget sources: ["Extensions/DoerWidget/**"] only
```
#### Correct
```swift
sources: [
    "Extensions/DoerWidget/**",
    "Shared/TrustLevelWidgetSnapshot.swift",
]
```

---

## Scenario: APNs wakes local notification pipeline

### 1. Scope / Trigger
- Trigger: cookie web-session login has no User API Key, so Discourse
  `allowed_user_api_push_urls` / `push_url` cannot be used. Do not fake that path.

### 2. Signatures
- `APNsPushRegistration.register()` → `UIApplication.registerForRemoteNotifications()`
- `APNsPushRegistration.storeDeviceToken(_:)` stores lowercase hex in
  `UserDefaults` key `apns.deviceToken`
- `APNsPushRegistration.handleRemoteNotification(userInfo:fetchCompletionHandler:)`
  → `BackgroundNotificationDeliveryPipeline.shared.refreshInBackground()`
- Info.plist `UIBackgroundModes` includes `fetch` **and** `remote-notification`

### 3. Contracts
- Launch: register for remote notifications (silent push does not require
  alert authorization).
- Silent / remote payload wakes the **existing** local-notification pipeline
  (`ForumNotificationCoordinator` / delivery store). Token is stored for a
  future relay; linux.do will not push to this cert without a whitelisted
  `push_url` + User API Key.
- `didReceiveRemoteNotification` must use the
  `fetchCompletionHandler` variant or iOS will not relaunch for
  `content-available`.

### 4. Validation & Error Matrix
- Simulator register fails → log `apns register failed`; not a crash.
- Pipeline cancelled / no new rows → completion `.noData`.
- Pipeline delivered or refreshed → `.newData`.

### 5. Good/Base/Bad Cases
- Good: silent push → pipeline fetch + widget refresh.
- Base: token hex `Data([0x0A, 0xFF, 0x00])` → `"0aff00"`.
- Bad: calling Discourse `/user-api-key/new` or setting `push_url` while
  auth is cookie-only.

### 6. Tests Required
- `APNsPushRegistration.hexString(from:)` lowercase hex.
- Compile-only; do not boot Simulator to test APNs.

### 7. Wrong vs Correct
#### Wrong
```swift
// Claim Discourse server push works after cookie login
api.updatePushURL(token) // needs User API Key + site whitelist
```
#### Correct
```swift
APNsPushRegistration.register()
// silent push → BackgroundNotificationDeliveryPipeline.refreshInBackground()
```

---

## Scenario: Home connectivity flap

### 1. Scope / Trigger
- Trigger: subway Wi-Fi / LTE flaps fire `ConnectivityService.didChangeNotification`.
  Reloading a healthy Home list jumps scroll position.

### 2. Signatures
- `HomeConnectivityRecoveryPolicy.shouldReloadTopicList(topicsEmpty:hasError:) -> Bool`
- `HomeViewController.handleConnectivityChanged(isConnected:)`

### 3. Contracts
- Always: update offline banner; if connected, `api.resetSession()` + clear DoH cache.
- Reload topics only when `topicsEmpty || hasError`.
- Manual empty-state / offline retry may still call `recoverTransportAndReload()`.

### 4. Validation & Error Matrix
- Connected + populated list + no error → no `reloadTopics()`.
- Connected + empty or error → `reloadTopics()`.

### 5. Good/Base/Bad Cases
- Good: flap with existing rows → banner only.
- Base: first launch empty list comes online → reload.
- Bad: `handleConnectivityChanged(true)` always `reloadTopics()`.

### 6. Tests Required
- Policy unit tests: healthy / empty / error.

### 7. Wrong vs Correct
#### Wrong
```swift
func handleConnectivityChanged(isConnected: Bool) {
    guard isConnected else { return }
    reloadTopics()
}
```
#### Correct
```swift
guard HomeConnectivityRecoveryPolicy.shouldReloadTopicList(
    topicsEmpty: viewModel.topics.isEmpty,
    hasError: viewModel.errorMessage != nil
) else { return }
reloadTopics()
```

---

## Quote-reply contract

Discourse BBCode from selected post text:

```
[quote="{username}, post:{N}, topic:{id}"]
{excerpt}
[/quote]
```

- iOS 16+: `UITextViewDelegate.editMenuForTextIn` via `DiscourseQuoteMarkdown.editMenu`.
- iOS 15: `UIMenuItem` on `LinkTextView` only (`UIMenuController` is process-global;
  do not install the item on iOS 16 or the action duplicates).
- Username `"` is replaced with `'` so the quote tag does not break.

---

## Tuist wiring gotchas

- `Target.target` argument order: `resources` must precede `entitlements`.
- New Swift files + entitlements files require `make generate`.
- Widget `if/else` View builders cannot take `.padding()` on the `if`; wrap in `Group`.
