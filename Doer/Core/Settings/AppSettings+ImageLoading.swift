import UIKit
import ObjectiveC
import CoreText

// MARK: - Image Loading
extension AppSettings {

    enum AvatarLoadingProfile: Int, CaseIterable {
        case low = 0
        case medium = 1
        case high = 2

        var title: String {
            switch self {
            case .low:
                return String(localized: "settings.network.avatar_loading.low", defaultValue: "低")
            case .medium:
                return String(localized: "settings.network.avatar_loading.medium", defaultValue: "中")
            case .high:
                return String(localized: "settings.network.avatar_loading.high", defaultValue: "高")
            }
        }

        var summary: String {
            switch self {
            case .low:
                return "4 / 2 / 8"
            case .medium:
                return "6 / 3 / 16"
            case .high:
                return "8 / 4 / 24"
            }
        }

        var maxConcurrentDownloads: Int {
            switch self {
            case .low: return 4
            case .medium: return 6
            case .high: return 8
            }
        }

        var maxConcurrentPrefetchCount: Int {
            switch self {
            case .low: return 2
            case .medium: return 3
            case .high: return 4
            }
        }

        var homeAvatarPrefetchLimit: Int {
            switch self {
            case .low: return 8
            case .medium: return 16
            case .high: return 24
            }
        }
    }

    var avatarLoadingProfile: AvatarLoadingProfile {
        get {
            guard defaults.object(forKey: "avatarLoadingProfile") != nil else { return .high }
            return AvatarLoadingProfile(rawValue: defaults.integer(forKey: "avatarLoadingProfile")) ?? .high
        }
        set {
            defaults.set(newValue.rawValue, forKey: "avatarLoadingProfile")
            notifyChanged()
        }
    }

    /// Disk + memory cap for avatar / post image cache (SDWebImage + process cache).
    /// Discrete stops match the settings slider: 500MB … 2GB.
    enum AvatarCacheSizeLimit: Int, CaseIterable {
        case mb500 = 0
        case gb1 = 1
        case gb15 = 2
        case gb2 = 3

        /// Lower bound of the configurable range.
        static let minimumMegabytes = 500
        /// Upper bound of the configurable range.
        static let maximumMegabytes = 2048

        var megabytes: Int {
            switch self {
            case .mb500: return 500
            case .gb1: return 1024
            case .gb15: return 1536
            case .gb2: return 2048
            }
        }

        var byteCount: Int {
            megabytes * 1024 * 1024
        }

        var title: String {
            switch self {
            case .mb500:
                return String(localized: "settings.data.avatar_cache_size.mb500", defaultValue: "500 MB")
            case .gb1:
                return String(localized: "settings.data.avatar_cache_size.gb1", defaultValue: "1 GB")
            case .gb15:
                return String(localized: "settings.data.avatar_cache_size.gb15", defaultValue: "1.5 GB")
            case .gb2:
                return String(localized: "settings.data.avatar_cache_size.gb2", defaultValue: "2 GB")
            }
        }

        var shortTickTitle: String {
            switch self {
            case .mb500: return "500"
            case .gb1: return "1G"
            case .gb15: return "1.5G"
            case .gb2: return "2G"
            }
        }

        var summary: String {
            String(
                format: String(
                    localized: "settings.data.avatar_cache_size.summary_format",
                    defaultValue: "内存与磁盘各上限 %@"
                ),
                title
            )
        }
    }

    var avatarCacheSizeLimit: AvatarCacheSizeLimit {
        get {
            guard defaults.object(forKey: "avatarCacheSizeLimit") != nil else { return .mb500 }
            return AvatarCacheSizeLimit(rawValue: defaults.integer(forKey: "avatarCacheSizeLimit")) ?? .mb500
        }
        set {
            defaults.set(newValue.rawValue, forKey: "avatarCacheSizeLimit")
            notifyChanged()
        }
    }
}
