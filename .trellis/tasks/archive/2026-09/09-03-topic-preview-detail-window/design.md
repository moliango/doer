# 长按预览小窗嵌 TopicDetail — 设计

## Boundaries

- Keep the existing morph overlay (`TopicPreviewViewController` dim + card + `TopicPreviewTransitioningDelegate`). Replace the excerpt body, not the shell.
- Reuse `TopicDetailFactory.make` so classic / WeChat / Telegram stay in lockstep with a real open.
- Do not wrap the embedded detail in a `UINavigationController` (that would push profile/topic inside the tiny window).
- Search / Home / later / history keep calling `TopicPreviewMenu.present`.

## Contract

`TopicDetailFactory.make(..., embeddedPreview: Bool = false)` sets `isEmbeddedPreview` on the returned VC.

```swift
enum TopicDetailEmbeddedPreviewAction {
    case navigate(UIViewController)
    case openCurrentTopic
}

protocol TopicDetailEmbeddedPreviewHosting: AnyObject {
    var isEmbeddedPreview: Bool { get set }
    var onEmbeddedPreviewAction: ((TopicDetailEmbeddedPreviewAction) -> Void)? { get set }
}
```

Classic (`TopicDetailViewController`) and chat (`ChatTopicDetailViewController`) both conform.

When `isEmbeddedPreview`:

| Surface | Behavior |
|---------|----------|
| Reply chrome | Hidden: `bottomBar` progress stays hidden too; no `floatingReplyButton`; no `chatInputBar`; no find bar / TOC FAB / new-replies banner |
| `presentReplyComposer` | `.openCurrentTopic` (dismiss preview, run the same open handler as「打开话题」) |
| Same-topic floor link | Jump in place |
| Other topic / user / category / tag | `.navigate(vc)` → dismiss preview, push on the presenting nav |
| Image gallery / like / Safari | Present from the preview VC (covers the small window) |
| Reading tracker | Off (peek must not consume unread) |

`TopicPreviewViewController` adds the factory VC as a child inside a clipped card. Close button overlays the card. Action row stays at the bottom of the card.

Window size: ~92% width, ~78% height, 16pt side inset, morph from the source card.

## Data flow

```
Long-press → TopicPreviewMenu.present
  → TopicPreviewViewController (overlay)
    → TopicDetailFactory.make(embeddedPreview: true)
      → child TopicDetail / ChatTopicDetail loads the topic as usual
    → onEmbeddedPreviewAction
      → dismiss overlay
      → presenter.navigationController.push / onOpen()
```

## Compatibility

- Full-screen TopicDetail unchanged when `embeddedPreview` is false (default).
- Old first-post plain-text loader is removed from the preview VC.
- iPad split: external navigation pushes on the presenting list nav (same as other list-side pushes). Opening the current topic still uses each surface’s existing `openTopic` / `openSearchPost` path, which already knows about split.

## Rollback

Revert the preview VC to the excerpt card and drop `embeddedPreview` on the factory. Reply chrome guards are no-ops when the flag is false.
