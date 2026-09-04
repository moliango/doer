# 长按预览小窗嵌 TopicDetail — 实现

## Checklist

1. Add `TopicDetailEmbeddedPreview.swift` (action enum, hosting protocol, testable link policy).
2. `TopicDetailFactory.make(..., embeddedPreview:)`.
3. Classic TopicDetail: flag, hide reply/progress/TOC/find chrome, intercept composer / profile / `openInternalViewController`, skip reading tracker.
4. Chat TopicDetail: flag, omit input bar + find bar, intercept composer / profile / `handleLink`, skip reading tracker.
5. Rewrite `TopicPreviewViewController` body to host the child detail; keep morph + actions + close.
6. Tests: preview hosts a TopicDetail child; chrome hidden; link policy (same-topic stay vs navigate out).
7. `make generate` (new Swift file).
8. Update `.trellis/spec/frontend/topic-preview.md`.

## Validation

```bash
make generate
xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Run `DoerTests/TopicPreviewMorphTests.swift` (and any new preview-policy tests) in the DoerTests scheme.

Do not boot Simulator unless asked.

## Risky files

- `TopicDetailViewController.swift` / `+Actions` / `+PostCellDelegate` / `+Toc` / `+BottomBar` / Coordinator: chrome can reappear from `updateUI`.
- `ChatTopicDetailViewController.swift`: input-bar constraints and lazy `chatInputBar` access.
- `TopicPreviewViewController.swift`: transition still requires `transitionCardView` / `transitionDimView`.

## Rollback

`git checkout --` the files above plus the new preview helper. Restore excerpt-card tests.
