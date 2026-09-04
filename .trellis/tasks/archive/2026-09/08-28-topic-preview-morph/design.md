# 长按预览一镜到底 — 设计

## Boundaries

- Keep `UIContextMenu` + `TopicPreviewViewController`. Do not port FluxDO `MorphingDialogShell`.
- Search results are the next child (`08-28-search-preview-morph`).
- Do not change image gallery Hero.

## Contract

System lift already morphs the preview. Make the lift originate from the **card** (`UITargetedPreview` on the topic card view, not the full table row).

Commit: `willPerformPreviewActionForMenuWith` already `openTopic`. Set `animator.preferredCommitStyle = .pop` so the preview grows into the pushed topic (iOS 13+). Reduce Motion: leave default commit.

Xiaohongshu: one table row holds two cards (`xiaohongshuRowIndex`). Today context menu returns nil. Use `point` to hit-test left/right card, then same `TopicPreviewMenu` + targeted preview on that card.

Read Later / History already use `TopicPreviewMenu`; add targeted preview helpers they can share.

## Rollback

Remove targeted preview and xiaohongshu menu; restore `xiaohongshuRowIndex == nil` guard.
