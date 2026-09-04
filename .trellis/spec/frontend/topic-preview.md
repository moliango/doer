# Topic Preview Morph

> Long-press topic cards morph into a preview (`08-28-topic-preview-morph`, `08-28-search-preview-morph`, `09-03-topic-preview-detail-window`).
> Learned 2026-08-28; 2026-09-04: preview is an expanded reading card, not a stuffed TopicDetail.

## Scenario: long-press opens an expanded reading card

### 1. Scope / Trigger

- Trigger: adding a list cell that should long-press-preview a topic, or changing how Home opens a topic from the preview.
- Surfaces: Home, 稍后, 历史, Xiaohongshu two-column, Search topic results.

### 2. Signatures

```swift
protocol TopicPreviewTargetProviding: AnyObject {
    var topicPreviewTargetView: UIView { get }
}

enum TopicPreviewMenu {
    static func present(
        topic: DiscourseTopicList.Topic,
        api: DiscourseAPI,
        categoryName: String?,
        actions: [TopicPreviewAction],
        sourceView: UIView?,
        from presenter: UIViewController
    )
}
```

### 3. Contracts

| Event | Behavior |
|-------|----------|
| Cell conforms to `TopicPreviewTargetProviding` | Morph starts from that view (card, not the full cell chrome) |
| Preview content | Title + meta (avatar / name / category / time) + native first-post blocks via `NativeContentRenderer`. Not `TopicDetailFactory` |
| While loading | List excerpt as placeholder; spinner on the meta row |
| Image gallery | Stays on the preview window |
| Avatar, other topic, category, tag | Dismiss preview, push on the presenting navigation stack |
| Reply / poll / quote-reply | Dismiss and run the first action (open topic) |
| First action in `actions` | 「打开」filled accent capsule |
| Remaining actions | Circular icon chips using `topicCountBackgroundColor` + `accentColor` |

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| Reduce Motion | Morph duration collapses to ~0.01s |
| Search user/category rows | No topic preview menu |
| Missing excerpt and failed load | Empty-state copy |
| Chat theme | Still a reading card, not WeChat/Telegram bubbles |

### 5. Good / Base / Bad Cases

- Good: long-press Home card → morph into a reading card of the OP → tap dim to close
- Base: later / history reuse `TopicPreviewMenu`
- Bad: stuffing full TopicDetail (progress bar, chat input, thread) into the floating window

### 6. Tests Required

- `DoerTests/TopicPreviewMorphTests.swift` for identifier helpers, excerpt placeholder, link policy

### 7. Wrong vs Correct

#### Wrong

```swift
addChild(TopicDetailFactory.make(api: api, topicId: topic.id))
```

#### Correct

```swift
let views = NativeContentRenderer.renderBlocks(annotatedBlocks, config: config, delegate: self)
```
