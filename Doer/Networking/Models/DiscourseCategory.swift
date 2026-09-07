import Foundation

struct DiscourseCategoryList: Decodable {
    let categoryList: CategoryList

    enum CodingKeys: String, CodingKey {
        case categoryList = "category_list"
    }

    struct CategoryList: Decodable {
        let categories: [DiscourseCategory]
    }
}

struct DiscourseSiteCategoryInfo: Decodable {
    let categories: [DiscourseCategory]?
}

enum DiscourseCategoryIndexSource: Int {
    case topicList
    case categoryList
    case site
}

struct DiscourseCategoryIndex {
    private var categoriesById: [Int: DiscourseCategory] = [:]
    private var sourcesById: [Int: DiscourseCategoryIndexSource] = [:]

    init(categories: [DiscourseCategory] = [], source: DiscourseCategoryIndexSource = .categoryList) {
        merge(categories, source: source)
    }

    var isEmpty: Bool {
        categoriesById.isEmpty
    }

    subscript(id: Int) -> DiscourseCategory? {
        categoriesById[id]
    }

    func source(for id: Int) -> DiscourseCategoryIndexSource? {
        sourcesById[id]
    }

    mutating func removeAll() {
        categoriesById.removeAll()
        sourcesById.removeAll()
    }

    mutating func merge(_ categories: [DiscourseCategory]?, source: DiscourseCategoryIndexSource) {
        guard let categories, !categories.isEmpty else { return }
        merge(categories, source: source)
    }

    mutating func merge(_ categories: [DiscourseCategory], source: DiscourseCategoryIndexSource) {
        let indexed = DiscourseCategory.indexedById(from: categories)
        for (id, category) in indexed {
            if let existingSource = sourcesById[id], existingSource.rawValue > source.rawValue {
                continue
            }
            categoriesById[id] = category
            sourcesById[id] = source
        }
    }
}

struct DiscourseCategory: Decodable, Identifiable {
    let id: Int
    let name: String
    let color: String
    let textColor: String?
    let slug: String
    let topicCount: Int
    let description: String?
    let descriptionExcerpt: String?
    let parentCategoryId: Int?
    let subcategoryList: [DiscourseCategory]?
    let uploadedLogo: String?
    let uploadedBackground: String?
    let readRestricted: Bool
    let icon: String?
    let topicTemplate: String?
    let minimumRequiredTags: Int
    let allowedTags: [String]
    let allowedTagGroups: [String]
    let allowGlobalTags: Bool
    let permission: Int?
    let notificationLevel: Int?
    let customFields: DiscourseCustomFields

    enum CodingKeys: String, CodingKey {
        case id, name, color, slug, description, icon, permission
        case textColor = "text_color"
        case topicCount = "topic_count"
        case descriptionExcerpt = "description_excerpt"
        case parentCategoryId = "parent_category_id"
        case subcategoryList = "subcategory_list"
        case uploadedLogo = "uploaded_logo"
        case uploadedBackground = "uploaded_background"
        case readRestricted = "read_restricted"
        case topicTemplate = "topic_template"
        case minimumRequiredTags = "minimum_required_tags"
        case allowedTags = "allowed_tags"
        case allowedTagGroups = "allowed_tag_groups"
        case allowGlobalTags = "allow_global_tags"
        case notificationLevel = "notification_level"
        case customFields = "custom_fields"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "808080"
        textColor = try container.decodeIfPresent(String.self, forKey: .textColor)
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        topicCount = try container.decodeIfPresent(Int.self, forKey: .topicCount) ?? 0
        description = try container.decodeIfPresent(String.self, forKey: .description)
        descriptionExcerpt = try container.decodeIfPresent(String.self, forKey: .descriptionExcerpt)
        parentCategoryId = try container.decodeIfPresent(Int.self, forKey: .parentCategoryId)
        subcategoryList = try container.decodeIfPresent([DiscourseCategory].self, forKey: .subcategoryList)
        uploadedLogo = Self.decodeUploadedAssetURL(from: container, forKey: .uploadedLogo)
        uploadedBackground = Self.decodeUploadedAssetURL(from: container, forKey: .uploadedBackground)
        readRestricted = Self.decodeBool(from: container, forKey: .readRestricted) ?? false
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        topicTemplate = try container.decodeIfPresent(String.self, forKey: .topicTemplate)
        minimumRequiredTags = Self.decodeInt(from: container, forKey: .minimumRequiredTags) ?? 0
        allowedTags = Self.decodeStringArray(from: container, forKey: .allowedTags)
        allowedTagGroups = Self.decodeStringArray(from: container, forKey: .allowedTagGroups)
        allowGlobalTags = Self.decodeBool(from: container, forKey: .allowGlobalTags) ?? true
        permission = Self.decodeInt(from: container, forKey: .permission)
        notificationLevel = Self.decodeInt(from: container, forKey: .notificationLevel)
        customFields = (try? container.decodeIfPresent(DiscourseCustomFields.self, forKey: .customFields)) ?? .empty
    }

    init(
        id: Int,
        name: String,
        slug: String,
        color: String = "808080",
        textColor: String? = nil,
        topicCount: Int = 0,
        description: String? = nil,
        descriptionExcerpt: String? = nil,
        parentCategoryId: Int? = nil,
        subcategoryList: [DiscourseCategory]? = nil,
        uploadedLogo: String? = nil,
        uploadedBackground: String? = nil,
        readRestricted: Bool = false,
        icon: String? = nil,
        topicTemplate: String? = nil,
        minimumRequiredTags: Int = 0,
        allowedTags: [String] = [],
        allowedTagGroups: [String] = [],
        allowGlobalTags: Bool = true,
        permission: Int? = nil,
        notificationLevel: Int? = nil,
        customFields: DiscourseCustomFields = .empty
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.textColor = textColor
        self.slug = slug
        self.topicCount = topicCount
        self.description = description
        self.descriptionExcerpt = descriptionExcerpt
        self.parentCategoryId = parentCategoryId
        self.subcategoryList = subcategoryList
        self.uploadedLogo = uploadedLogo
        self.uploadedBackground = uploadedBackground
        self.readRestricted = readRestricted
        self.icon = icon
        self.topicTemplate = topicTemplate
        self.minimumRequiredTags = minimumRequiredTags
        self.allowedTags = allowedTags
        self.allowedTagGroups = allowedTagGroups
        self.allowGlobalTags = allowGlobalTags
        self.permission = permission
        self.notificationLevel = notificationLevel
        self.customFields = customFields
    }

    var serverLevelName: String? {
        serverLevelDisplayName
    }

    private var serverLevelDisplayName: String? {
        Self.normalizedLevelName(from: name)
    }

    private static func normalizedLevelName(from name: String) -> String? {
        let compact = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased()
        guard compact.hasPrefix("LV") else { return nil }
        let digits = compact.dropFirst(2)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return "LV\(digits)"
    }

    func displayName(parent: DiscourseCategory?) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedName.isEmpty ? name : trimmedName

        // Only compose a Linux.do level label when one side is an actual
        // server-provided LV category; never infer LV from local hierarchy depth.
        if let ownLevel = serverLevelDisplayName {
            guard let parent else { return ownLevel }
            let parentName = parent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedParentName = parentName.isEmpty ? parent.name : parentName
            guard !resolvedParentName.isEmpty else { return ownLevel }
            guard !Self.name(resolvedParentName, containsLevel: ownLevel) else {
                return resolvedParentName
            }
            return "\(resolvedParentName)\(ownLevel)"
        }

        guard let parentLevel = parent?.serverLevelDisplayName else { return baseName }
        guard !Self.name(baseName, containsLevel: parentLevel) else { return baseName }
        return "\(baseName)\(parentLevel)"
    }

    private static func name(_ name: String, containsLevel level: String) -> Bool {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .uppercased()
            .contains(level)
    }

    static func hierarchy(fromFlat categories: [DiscourseCategory]) -> [DiscourseCategory] {
        let childrenByParent = Dictionary(grouping: categories.filter { $0.parentCategoryId != nil }) { category in
            category.parentCategoryId ?? -1
        }

        func withChildren(_ category: DiscourseCategory) -> DiscourseCategory {
            DiscourseCategory(
                id: category.id,
                name: category.name,
                slug: category.slug,
                color: category.color,
                textColor: category.textColor,
                topicCount: category.topicCount,
                description: category.description,
                descriptionExcerpt: category.descriptionExcerpt,
                parentCategoryId: category.parentCategoryId,
                subcategoryList: childrenByParent[category.id]?.map(withChildren),
                uploadedLogo: category.uploadedLogo,
                uploadedBackground: category.uploadedBackground,
                readRestricted: category.readRestricted,
                icon: category.icon,
                topicTemplate: category.topicTemplate,
                minimumRequiredTags: category.minimumRequiredTags,
                allowedTags: category.allowedTags,
                allowedTagGroups: category.allowedTagGroups,
                allowGlobalTags: category.allowGlobalTags,
                permission: category.permission,
                notificationLevel: category.notificationLevel,
                customFields: category.customFields
            )
        }

        return categories
            .filter { $0.parentCategoryId == nil }
            .map(withChildren)
    }

    static func normalizedTree(fromNested categories: [DiscourseCategory]) -> [DiscourseCategory] {
        categories.map { $0.withResolvedParentId(nil) }
    }

    static func indexedById(from categories: [DiscourseCategory]) -> [Int: DiscourseCategory] {
        var result: [Int: DiscourseCategory] = [:]

        func index(_ list: [DiscourseCategory]) {
            for category in list {
                result[category.id] = category
                if let subs = category.subcategoryList {
                    index(subs)
                }
            }
        }

        index(normalizedTree(fromNested: categories))
        return result
    }

    private func withResolvedParentId(_ fallbackParentId: Int?) -> DiscourseCategory {
        DiscourseCategory(
            id: id,
            name: name,
            slug: slug,
            color: color,
            textColor: textColor,
            topicCount: topicCount,
            description: description,
            descriptionExcerpt: descriptionExcerpt,
            parentCategoryId: parentCategoryId ?? fallbackParentId,
            subcategoryList: subcategoryList?.map { $0.withResolvedParentId(id) },
            uploadedLogo: uploadedLogo,
            uploadedBackground: uploadedBackground,
            readRestricted: readRestricted,
            icon: icon,
            topicTemplate: topicTemplate,
            minimumRequiredTags: minimumRequiredTags,
            allowedTags: allowedTags,
            allowedTagGroups: allowedTagGroups,
            allowGlobalTags: allowGlobalTags,
            permission: permission,
            notificationLevel: notificationLevel,
            customFields: customFields
        )
    }

    private static func decodeUploadedAssetURL(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let asset = try? container.decodeIfPresent(UploadedAsset.self, forKey: key) {
            return asset.url
        }
        return nil
    }

    private static func decodeInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeBool(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func decodeStringArray(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String] {
        if let values = try? container.decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let values = try? container.decodeIfPresent([LossyString].self, forKey: key) {
            return values.compactMap(\.value)
        }
        return []
    }

    private struct UploadedAsset: Decodable {
        let url: String?

        enum CodingKeys: String, CodingKey {
            case url
        }

        init(from decoder: Decoder) throws {
            let singleValue = try decoder.singleValueContainer()
            if let value = try? singleValue.decode(String.self) {
                url = value
                return
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            url = try container.decodeIfPresent(String.self, forKey: .url)
        }
    }

    private struct LossyString: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self.value = value
            } else if let value = try? container.decode(Int.self) {
                self.value = String(value)
            } else {
                self.value = nil
            }
        }
    }
}
