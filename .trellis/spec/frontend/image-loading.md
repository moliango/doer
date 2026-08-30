# Image Loading & Paint

> Shared paint rules for avatars, topic body images, and grids.
> Learned 2026-08-28 (`08-28-image-no-flash`).

## Scenario: Memory / disk / network paint

### 1. Scope / Trigger

- Trigger: any `UIImageView` that loads Discourse/CDN images through SDWebImage or `ExternalImageFetcher`.
- Do not restore `queryDiskDataSync`. Disk decode stays off the main thread.

### 2. Signatures

```swift
enum ImagePaintCacheSource { case memory, disk, network }
enum ImagePaintPolicy {
    static let fadeDuration: TimeInterval
    static var waitingFillColor: UIColor
    static func placeholderForAsyncLoad(currentImage: UIImage?, memoryHit: Bool) -> UIImage?
    static func shouldFadeIn(_ source: ImagePaintCacheSource) -> Bool
    static func prepareForLoad(on imageView: UIImageView)
    static func applyWaitingFillIfNeeded(on imageView: UIImageView)
    static func paint(_ image: UIImage, on imageView: UIImageView, source: ImagePaintCacheSource)
}
```

Callers: `AvatarImageLoader`, `ImageRenderer`, `ImageGridRenderer`. Gallery dismiss lives in `PostWebViewCell`.

### 3. Contracts

| Source | Placeholder | Alpha | Transition |
|--------|-------------|-------|------------|
| Memory | none (`nil`) | stay 1 | none, set image immediately |
| Disk | keep current bitmap or theme fill | stay 1 | 0.12s cross-dissolve |
| Network | same as disk | stay 1 | 0.12s cross-dissolve |

- Waiting fill: `themeStyle.topicChipBackgroundColor`, never a gray `UIImage()` glyph.
- Reduce Motion: skip fade, still keep alpha 1.
- `prepareForLoad` must cancel in-flight transitions on reuse.
- Gallery: vertical pan dismiss; if translation is under threshold or gesture `.failed` / `.cancelled`, snap back and restore paging `isScrollEnabled`.
- Open/close Hero: `presentTopicImageGallery(..., sourceView:)`. Flight from the tapped thumbnail to aspect-fit fullscreen; reverse on close. If the source is off-screen, fade. Reduce Motion or nil source uses `.crossDissolve` both ways. Do not hide a non-`UIImageView` web-snapshot anchor (use a mask) or the bitmap stays visible under the flight.

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| Memory hit | Sync paint, no placeholder, no fade |
| Disk/network, empty view | Theme fill visible until dissolve |
| Cell reuse mid-fade | Animations cancelled, alpha forced to 1 |
| Gallery pan `.failed` after `.began` | Restore `isScrollEnabled`; do not leave paging disabled |
| Cloudflare gate/grace image swap | Do not re-bind in a way that flashes the shield |

### 5. Good / Base / Bad Cases

- Good: second scroll over a memory-cached image — bitmap appears with no gray flash.
- Base: first disk hit after cold start — chip-colored fill, then 0.12s dissolve.
- Bad: `imageView.alpha = 0` then fade in — hides fill and previous frame, empty hole.

### 6. Tests Required

- `ImagePaintPolicyTests`: memory does not fade; disk/network fade; disk paint never sets alpha to 0; `prepareForLoad` restores alpha.
- `AvatarImageLoaderTests`: memory path skips placeholder.

### 7. Wrong vs Correct

#### Wrong

```swift
imageView.alpha = 0
imageView.image = image
UIView.animate(withDuration: 0.12) { imageView.alpha = 1 }
```

#### Correct

```swift
ImagePaintPolicy.prepareForLoad(on: imageView)
ImagePaintPolicy.applyWaitingFillIfNeeded(on: imageView)
ImagePaintPolicy.paint(image, on: imageView, source: .disk)
```

## Don't: gray placeholder or main-thread disk decode

**Problem**: `UIImage()` / system gray glyph, or `queryDiskDataSync` on the main thread.

**Why it's bad**: visible flash; main-thread hitch on first disk hit.

**Instead**: `ImagePaintPolicy` + async SDWebImage options `.delayPlaceholder` + `.avoidAutoSetImage`.
