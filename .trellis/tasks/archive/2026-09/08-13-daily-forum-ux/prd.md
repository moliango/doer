# Daily forum UX: push, trust widget, quote, connectivity

## Goal

Four daily-use fixes: APNs registration so remote/silent pushes can wake notification delivery; a home-screen widget for trust-level progress (posts read / remaining to TL3); select-text quote reply in topic posts; stop full Home reload when the network flaps.

## Requirements

- Register for APNs; `remote-notification` background mode runs the existing notification pipeline. Cookie login cannot use Discourse `push_url` without a User API Key and site whitelist; do not fake that path.
- Trust widget shows read/progress items persisted from connect.linux.do or Discourse summary fallback. Tap opens trust page.
- Selecting text in a post offers 引用回复 and opens the composer with Discourse `[quote]` markdown.
- Network restore shows/hides the offline banner and resets transport, but does not `reloadTopics` unless the list is empty or showing an error.

## Acceptance

- [x] `handleConnectivityChanged(true)` does not reload a populated Home list
- [x] Quote action appears on selected post text (classic + chat) and inserts `[quote="user, post:N, topic:ID"]`
- [x] Widget reads App Group snapshot; Trust page and background refresh update it
- [x] App registers for remote notifications; token stored; silent push wakes delivery pipeline
- [x] Compile: generic iOS Simulator `CODE_SIGNING_ALLOWED=NO`
