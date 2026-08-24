import Foundation

struct DiscourseTemplate: Decodable, Identifiable {
    let id: Int
    let title: String
    let slug: String?
    let content: String
    let tags: [String]
    let usages: Int

    enum CodingKeys: String, CodingKey {
        case id, title, slug, content, tags, usages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        usages = try container.decodeIfPresent(Int.self, forKey: .usages) ?? 0
    }
}

struct DiscourseTemplatesResponse: Decodable {
    let templates: [DiscourseTemplate]

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           keyed.contains(.templates) {
            templates = try keyed.decodeIfPresent([DiscourseTemplate].self, forKey: .templates) ?? []
            return
        }
        templates = (try? decoder.singleValueContainer().decode([DiscourseTemplate].self)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case templates
    }
}
