# Design

- Connectivity: `HomeConnectivityRecoveryPolicy.shouldReloadTopicList` — observers call transport reset always, reload only when empty/error.
- Quote: `DiscourseQuoteMarkdown` + `PostCellDelegate.postCell(didQuoteSelectedText:postId:)` with default no-op. Cells add iOS 16 edit menu + iOS 15 `UIMenuItem`.
- Widget: `group.com.naine.doer` shared `TrustLevelWidgetSnapshot`. App writes; widget reads. Kind `DoerTrustLevelWidget`.
- Push: `APNsPushRegistration` stores device token; AppDelegate registers; `didReceiveRemoteNotification` runs `BackgroundNotificationDeliveryPipeline`. No Discourse User API Key (cookie auth).
