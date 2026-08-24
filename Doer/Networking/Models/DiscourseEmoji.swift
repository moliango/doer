import Foundation

struct DiscourseCustomEmoji: Decodable {
    let name: String
    let url: String
}

struct DiscourseEmojiEntry: Codable {
    let name: String
    let url: String
    let searchAliases: [String]?

    enum CodingKeys: String, CodingKey {
        case name, url
        case searchAliases = "search_aliases"
    }
}

struct DiscourseEmojiGroup {
    let key: String
    let emojis: [DiscourseEmojiEntry]
}

struct DiscourseCreatePostResponse: Decodable {
    struct PendingPost: Decodable {
        let id: Int?
        let raw: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case raw
            case createdAt = "created_at"
        }
    }

    let id: Int?
    let topicId: Int?
    let postNumber: Int?
    let action: String?
    let success: Bool?
    let pendingCount: Int?
    let pendingPost: PendingPost?

    var isEnqueued: Bool {
        action == "enqueued" && success == true
    }

    enum CodingKeys: String, CodingKey {
        case id
        case topicId = "topic_id"
        case postNumber = "post_number"
        case action
        case success
        case pendingCount = "pending_count"
        case pendingPost = "pending_post"
    }
}

struct DiscourseUploadResponse: Decodable {
    /// Chat send uses `upload_ids`; markdown short URLs are ignored there.
    let id: Int?
    let shortURL: String
    let url: String?
    let originalFilename: String
    let width: Int?
    let height: Int?
    let thumbnailWidth: Int?
    let thumbnailHeight: Int?
    let filesize: Int?
    let humanFilesize: String?
    let fileExtension: String?

    enum CodingKeys: String, CodingKey {
        case id
        case shortURL = "short_url"
        case url
        case originalFilename = "original_filename"
        case width
        case height
        case thumbnailWidth = "thumbnail_width"
        case thumbnailHeight = "thumbnail_height"
        case filesize
        case humanFilesize = "human_filesize"
        case fileExtension = "extension"
    }

    private var imageSize: (Int, Int)? {
        if let thumbnailWidth, let thumbnailHeight {
            return (thumbnailWidth, thumbnailHeight)
        }
        if let width, let height {
            return (width, height)
        }
        return nil
    }

    var isImage: Bool {
        let ext = (fileExtension ?? (originalFilename as NSString).pathExtension).lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "avif"].contains(ext)
    }

    var markdown: String {
        if isImage {
            if let (width, height) = imageSize {
                return "![\(originalFilename)|\(width)x\(height)](\(shortURL))"
            }
            return "![\(originalFilename)](\(shortURL))"
        }
        let sizeText = humanFilesize ?? filesize.map(Self.formatFileSize) ?? ""
        let suffix = sizeText.isEmpty ? "" : " (\(sizeText))"
        return "[\(originalFilename)|attachment](\(shortURL))\(suffix)"
    }

    nonisolated private static func formatFileSize(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        guard kb >= 1024 else { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        guard mb >= 1024 else { return String(format: "%.1f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}
