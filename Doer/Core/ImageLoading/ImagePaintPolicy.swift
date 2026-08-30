import SDWebImage
import UIKit

enum ImagePaintCacheSource: Equatable {
    case memory
    case disk
    case network

    init(_ cacheType: SDImageCacheType) {
        switch cacheType {
        case .memory, .all:
            self = .memory
        case .disk:
            self = .disk
        case .none:
            self = .network
        @unknown default:
            self = .network
        }
    }
}

/// Shared list / topic / avatar paint rules: memory is instant, disk/network
/// fade in over a theme fill, never a gray `UIImage()` placeholder.
enum ImagePaintPolicy {
    static let fadeDuration: TimeInterval = 0.12

    static var waitingFillColor: UIColor {
        AppSettings.shared.themeStyle.topicChipBackgroundColor
    }

    /// Memory hits never install a placeholder. Async loads keep the current
    /// bitmap (or nil). Callers must not pass a gray glyph as a loading placeholder.
    static func placeholderForAsyncLoad(currentImage: UIImage?, memoryHit: Bool) -> UIImage? {
        if memoryHit {
            return nil
        }
        return currentImage
    }

    static func shouldFadeIn(_ source: ImagePaintCacheSource) -> Bool {
        switch source {
        case .memory:
            return false
        case .disk, .network:
            return true
        }
    }

    static func prepareForLoad(on imageView: UIImageView) {
        imageView.layer.removeAllAnimations()
        if imageView.alpha != 1 {
            imageView.alpha = 1
        }
    }

    static func applyWaitingFillIfNeeded(on imageView: UIImageView) {
        guard imageView.image == nil else { return }
        guard imageView.backgroundColor == nil || imageView.backgroundColor == UIColor.clear else { return }
        imageView.backgroundColor = waitingFillColor
    }

    static func paint(_ image: UIImage, on imageView: UIImageView, source: ImagePaintCacheSource) {
        imageView.tintColor = nil
        imageView.alpha = 1
        let fade = shouldFadeIn(source) && !UIAccessibility.isReduceMotionEnabled
        if fade {
            // Cross-dissolve keeps the waiting fill or previous bitmap visible.
            // Setting `imageView.alpha = 0` would hide both and flash a hole.
            UIView.transition(
                with: imageView,
                duration: fadeDuration,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
            ) {
                imageView.image = image
                imageView.backgroundColor = .clear
            }
        } else {
            imageView.image = image
            imageView.backgroundColor = .clear
        }
    }
}
