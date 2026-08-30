# Cooked Blocks: Policy & Voice

> Native `ContentBlock` additions from FluxDo gap round (`08-28-discourse-policy`, `08-28-hold-to-talk`).
> Learned 2026-08-28.

## Scenario: Discourse policy + voice wrap

### 1. Scope / Trigger

- Trigger: adding a case to `ContentBlock`, parsing `div.policy`, or inserting `[wrap=voice]`.
- Layers: `Packages/CookedHTML` extractors → native `BlockRenderer` → `DiscourseAPI` PUT.

### 2. Signatures

```swift
public struct PolicyBlock: Sendable, Equatable {
    public let acceptLabel: String
    public let revokeLabel: String
    public let version: String?
    public let groups: String?
    public let accepted: Bool
    public let content: [ContentBlock]
}

public enum ContentBlock {
    case policy(PolicyBlock)
    case video(url: String, thumbnailURL: String?, title: String?, width: Int?, height: Int?, videoId: String?, provider: String?)
    // existing cases…
}

enum DiscourseRouter {
    case acceptPolicy   // PUT /policy/accept
    case unacceptPolicy // PUT /policy/unaccept
}

func acceptPolicy(postId: Int) async throws
func unacceptPolicy(postId: Int) async throws
```

Voice is **not** a new `ContentBlock` case. `[wrap=voice]` / `data-wrap=voice` extracts as `.video(..., provider: "voice"|"audio")`. `VoiceMessageView` renders `provider == voice|audio`.

### 3. Contracts

| Input | Output |
|-------|--------|
| `div.policy` with `data-accept` / `data-revoke` | `.policy(PolicyBlock)` |
| `.policy-body` present | Nested blocks from that subtree only |
| `class` contains `accepted` or `data-policy-accepted=true` | `accepted == true` |
| Accept tap | `PUT /policy/accept` form `post_id` |
| Revoke tap | `PUT /policy/unaccept` form `post_id` |
| Missing plugin / 404 | Visible error; post body otherwise unchanged |
| `div[data-wrap=voice] audio` | `.video(provider: "voice")` |
| Bare `<audio>` | `.video(provider: "audio")` |
| Recorder success | Upload via existing `uploadMediaFile` + Cookie session; insert `[wrap=voice]` |

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| No `div.policy` | Ordinary blocks; no API call |
| Accept/revoke network fail | Error presented; `accepted` flag not flipped locally until success |
| Empty audio `src` | Extractor returns `nil` (falls through) |
| New `ContentBlock` case added | **Every exhaustive `switch` on `ContentBlock` must compile** — see below |

### 5. Good / Base / Bad Cases

- Good: policy HTML → native card with accept/revoke labels from `data-*`.
- Base: no policy plugin → post still native-renders.
- Bad: adding `.policy` and only updating `NativeRenderConfig.renderers`.

### 6. Tests Required

- `CookedHTMLTests.testPolicyDivExtractsAcceptLabels`
- `CookedHTMLTests.testVoiceWrapExtractsAudioVideoBlock`
- DoerTests compile after any `ContentBlock` case change

### 7. Wrong vs Correct

#### Wrong

```swift
private static func breaksOrderedListSequence(_ block: ContentBlock) -> Bool {
    switch block {
    case .list: return false
    case .paragraph, .heading, /* … */, .rawHTML: return true
    // missing .policy → compile error
    }
}
```

#### Correct

Grep all `switch` on `ContentBlock` in CookedHTML **and** Doer (row height, share card, gallery URLs, poll merge, callout terminator). Recurse into `policy.content` the same way as `.details` / `.blockquote`.

**Gotcha**: `ContentBlock` is exhaustive. Adding a case is a cross-package compile break, not a runtime miss.
