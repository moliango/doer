# Topic Preview Morph

> Long-press topic cards morph into a preview (`08-28-topic-preview-morph`, `08-28-search-preview-morph`).
> Learned 2026-08-28.

## Scenario: UITargetedPreview from list / search cards

### 1. Scope / Trigger

- Trigger: adding a list cell that should long-press-preview a topic, or changing how Home opens a topic from context menu.
- Surfaces: Home, 稍后, 历史, Xiaohongshu two-column, Search topic results.

### 2. Signatures

```swift
protocol TopicPreviewTargetProviding: AnyObject {
    var topicPreviewTargetView: UIView { get }
}

enum TopicPreviewMenu {
    static func configuration(
        for topic: /* recommendation */,
        sourceView: UIView?,
        // existing bookmark / later actions…
    ) -> UIContextMenuConfiguration
}
```

### 3. Contracts

| Event | Behavior |
|-------|----------|
| Cell conforms to `TopicPreviewTargetProviding` | Preview uses `UITargetedPreview` of that view (card, not the full cell chrome) |
| No protocol / nil view | Preview appears from the default center; still opens |
| Commit `.pop` | Same topic the preview showed; Home split pane updates instead of a second push when `usesSplitDetail` |
| Search | `DiscourseSearchResult.SearchPost.makePreviewTopic`; commit calls `openSearchPost` |
| Xiaohongshu staggered | Same menu + morph as single-column Home cells |

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| Reduce Motion | System preview still works; do not invent a custom animation |
| Search user/category rows | No topic preview menu |
| Missing excerpt | Preview still shows title |

### 5. Good / Base / Bad Cases

- Good: long-press Home card → morph → lift finger into topic (or split detail)
- Base: later / history reuse `TopicPreviewMenu`
- Bad: wrapping the whole `UITableViewCell` as the targeted preview (jumps from full-width chrome)

### 6. Tests Required

- `DoerTests/TopicPreviewMorphTests.swift` for identifier / target helpers
- Compile-only for search cell conformance

### 7. Wrong vs Correct

#### Wrong

```swift
// Search results have no context menu, or use a different preview VC
```

#### Correct

```swift
extension SearchResultCell: TopicPreviewTargetProviding {
    var topicPreviewTargetView: UIView { cardView }
}
```
