# Composer Paste & Pangu

> Reply, new topic, and PM share one paste/upload path and one spacing function.
> Learned 2026-08-28 (`08-28-composer-paste-pangu`).

## Scenario: Clipboard image paste + CJK spacing on send

### 1. Scope / Trigger

- Trigger: any composer `UITextView` that should accept pasted images or apply 盘古 before send/preview.
- Surfaces: `ReplyComposerViewController`, `NewTopicComposerViewController`, `PrivateMessageComposerViewController` via `ComposerTextSurface` / `ComposerSharedCore`.

### 2. Signatures

```swift
protocol ComposerTextSurface: AnyObject {
    var bodyTextView: UITextView { get }
    // existing upload entry
    func uploadPickedFiles(_ urls: [URL])
    func presentUploadError(_ error: Error)
}

enum ComposerPangu {
    static func spacing(_ markdown: String) -> String
}

extension AppSettings {
    var autoPanguSpacing: Bool // default true
}
```

Paste lives on `ComposerBodyTextView` + `ComposerMarkdownCoordinator.claimPastedImageHandling()`.

### 3. Contracts

| Event | Behavior |
|-------|----------|
| Clipboard has image, no text | Show Paste in edit menu even if `UITextView` would hide it |
| Menu / Cmd+V image | Read `UIPasteboard`, encode, `uploadPickedFiles` |
| Drop / `paste(itemProviders:)` | Prefer providers; clipboard is menu path only |
| Concurrent menu + provider paste | First `claimPastedImageHandling()` wins; second is ignored |
| Upload success | Insert returned Discourse markdown; no invented URL |
| Upload failure | `presentUploadError`; do not insert a broken `![](…)` |
| Send / preview | If `autoPanguSpacing`, run `ComposerPangu.spacing` on body |
| Pangu skip | Fenced code, inline code, `http(s)` URLs; do not double existing spaces |
| PM composer | Same preview eye as reply/new-topic; pangu on send and preview |
| Poll insert | `ComposerSharedCore.presentPollBuilder()` → `PollBuilderViewController`; selected `[poll]` is parsed by `ComposerPollSpec.parse` and replaced via `replacingPoll` |
| Voice | Toolbar 语音消息 presents `ComposerVoiceRecorderViewController` (AAC/m4a). Success uploads via `uploadMediaFile` and inserts `[wrap=voice]…[/wrap]`. Failure: `presentUploadError`, no markdown |
| Aa / MD | `ComposerEditingMode` already exists on reply, new topic, and PM; do not add a second toggle |
| Experimental WYSIWYG | `AppSettings.experimentalRichComposerEnabled` default **false**. Off: reply/new-topic/PM keep the existing `UITextView` + `ComposerMarkdownCodec` path unchanged. On: **reply composer only** swaps the body for `ExperimentalComposerView` (block list). Send/preview/pangu/draft still use raw Markdown. `[poll]` / `[quote]` / `[wrap=` stay `.literal`. Consecutive ordered list items show and serialize as `1.` `2.` `3.`; Return on a `1. ` paragraph continues the run. Empty list item + Return exits to a paragraph. New topic and PM stay on the old editor in this phase. |

Setting toggle: Preferences → 基础 (`autoPanguSpacing` and `experimentalRichComposerEnabled`). Also import/export with other bool prefs.

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| Screenshot-only pasteboard | Paste action enabled; `pasteConfiguration` accepts `UIImage` |
| Encode / network / CF fail | Visible error, body unchanged |
| Second paste while upload in flight | Ignored (claim already held) |
| `autoPanguSpacing == false` | Send/preview leave spacing untouched |
| Code fence contains `中文english` | No spaces inserted inside the fence |
| Selected `[poll]` in body | Builder opens with parsed `ComposerPollSpec`; save replaces that block only |
| No `[poll]` selected | Builder inserts a new block at the caret |
| Microphone denied | `ComposerVoiceRecorderError.microphoneDenied`; no `[wrap=voice]` |

### 5. Good / Base / Bad Cases

- Good: screenshot paste → upload spinner → `![…](https://…)` in the body.
- Base: `中文english中文` send → `中文 english 中文`.
- Bad: `paste(itemProviders:)` always reading the clipboard — a drop uploads the wrong image.
- Good: hold-to-talk → upload → `[wrap=voice]…[/wrap]`.
- Bad: Alert with a text field as the poll builder (no type/chart/close time).

### 6. Tests Required

- `ComposerPanguTests`: CJK↔latin/digit boundaries; existing spaces; fences; inline code; URLs.
- `ComposerPollSpecTests` in `DoerTests/FluxDoGapRoundTests.swift`: round-trip, parse selection, number poll omits `- ` lines, `replacingPoll`.
- Compile-only verification for UI paste / recorder (no simulator unless the owner asks).

### 7. Wrong vs Correct

#### Wrong

```swift
override func paste(itemProviders: [NSItemProvider]) {
    handleClipboardImage() // ignores the dropped item; can double-fire with menu paste
}
```

#### Correct

```swift
override func paste(itemProviders: [NSItemProvider]) {
    handlePastedImage(from: itemProviders) // providers first
}
override func paste(_ sender: Any?) {
    handlePastedImage(from: nil) // clipboard / Cmd+V
}
// claimPastedImageHandling() before load/encode
```
