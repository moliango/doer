# 看图从缩略图飞入 — 设计

## Boundaries

- Viewer stays `TopicImageGalleryViewController` (`.overFullScreen`). Do not add Lightbox.
- Paint path unchanged: `ImagePaintPolicy`, no `queryDiskDataSync`.
- Pan dismiss (`TopicImageGalleryDismissPolicy`) stays. Hero is the present/dismiss transition, not a replacement for the pan.
- Predictive-back pairing is out of scope (`08-28-predictive-back`).

## Contract

Extend the tap to carry a source view:

```swift
func postCell(didTapImageURL url: URL, imageURLs: [URL], sourceView: UIView?)
func presentTopicImageGallery(currentURL: URL, imageURLs: [URL], sourceView: UIView?)
```

`sourceView` is the tapped `UIImageView` (single image or grid tile). Chat / replies / web cell pass it when known; nil → current cross-dissolve.

Open: snapshot or current bitmap flies from `sourceView.convert(bounds, to: nil)` to the gallery page frame (aspect-fit). Source view hides (alpha 0) during flight so it does not double-draw.

Close (X or pan past threshold): reverse to the source frame if the view is still in a window and intersects the screen; otherwise fade. Restore source alpha.

Reduce Motion: skip flight, keep `.crossDissolve`.

## Compatibility

- Unique URL list and “don’t stack two galleries” stay.
- Cloudflare image gate unchanged.
- iOS 15+ UIKit only.

## Rollback

Drop `sourceView` and custom animator; present with `.crossDissolve` again.
