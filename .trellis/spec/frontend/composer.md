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
| Experimental WYSIWYG | `AppSettings.experimentalRichComposerEnabled` default **true**. Off: reply/new-topic/PM keep the existing `UITextView` + `ComposerMarkdownCodec` path unchanged. On: reply, new topic, and PM swap the body for `ExperimentalComposerView` (block list) via `ExperimentalComposerHosting`. Send/preview/pangu/draft still use raw Markdown. `[poll]` / `[wrap=` / `[policy` / `[grid` stay `.literal`. Standalone `![alt](url)` lines become image islands; `[quote="user, post:N, topic:M"]` becomes a quote card with editable inner markdown. Consecutive ordered list items show and serialize as `1.` `2.` `3.`; Return on a `1. ` paragraph continues the run. Empty list item + Return exits to a paragraph. Parser is touched before hiding the old editor so a trap cannot leave a blank composer. Do not harvest markdown while `markedTextRange != nil` (CJK IME). After inserting an image/quote island, append a paragraph and focus it. `tryLoad` failure calls `ExperimentalComposerHosting.abandon` and shows the classic `UITextView`. Return/backspace restore the caret at the start of the new block or the merge join. Host placeholder overlays stay hidden while experimental is on; `ExperimentalComposerView` keeps its own placeholder behind the block stack. `ComposerBodyTextView.caretRect` must be at least the body font line height and 2pt wide. Experimental paragraphs keep a line-fragment gutter and do not clip chrome, so the insertion point is not cropped at x = 0. Structural edits push `ExperimentalComposerHistory` snapshots so Cmd-Z / shake undo survive `rebuild()`. Aa/MD in experimental mode toggles a source escape without `abandon`. Poll save uses `composerFocusedBlockRaw` / `composerReplaceFocusedBlock` when the caret is in a `[poll]` literal. Image and quote-card islands are tappable to preview/delete. Consecutive blocks can be selected from the list marker and copied as markdown. New topic and PM use `ComposerMentionController` for `@` (reply keeps its existing picker). Preview still uses native `ComposerMarkdownRenderer` / `CookedHTML` — Discourse cook JS is not bundled. |

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
| Experimental WYSIWYG on, IME composing | Harvest skipped; block text stays as typed |
| Paste image while experimental on | Image island + following paragraph focused |
| Quote-reply initial markdown | Quote card + empty paragraph |
| Experimental `tryLoad` fails | Classic `UITextView` shown; experimental view removed |

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
