import CookedHTML
import UIKit

/// First-post outline state + scroll-spy. Jump geometry lives on the host VC.
@MainActor
final class TopicTocController {
    static let spyBuffer: CGFloat = 150
    static let topBuffer: CGFloat = 12

    private(set) var tocData: TocData?
    private(set) var activeHeadingId: String?
    private(set) var activeAncestorIds: Set<String> = []
    private(set) var isJumping = false

    private var parentById: [String: String?] = [:]
    private var signature = 0

    var hasToc: Bool { tocData?.flat.isEmpty == false }

    func update(from viewModel: TopicDetailViewModel) {
        guard let post = viewModel.posts.first(where: { $0.postNumber == 1 }),
              let annotated = viewModel.parsedBlocks[post.id]
        else {
            clear()
            return
        }

        let tagNames = Set(viewModel.topic?.tags.map(\.name) ?? [])
        let categoryName = viewModel.categoryPresentation?.name
        let nextSignature = post.id
            &+ post.cooked.hashValue
            &+ tagNames.hashValue
            &+ (categoryName?.hashValue ?? 0)
        if nextSignature == signature { return }
        signature = nextSignature
        let blocks = annotated.map(\.block)
        let data = TocExtractor.build(
            blocks: blocks,
            postId: post.id,
            cooked: post.cooked
        ) { level, text in
            if HeadingPresentationPolicy.shouldRenderTagBadge(
                level: level,
                text: text,
                topicTagNames: tagNames
            ) {
                return false
            }
            if HeadingPresentationPolicy.shouldRenderCategoryBadge(
                level: level,
                text: text,
                categoryName: categoryName
            ) {
                return false
            }
            return true
        }

        guard let data, !data.isEmpty else {
            clear()
            return
        }
        apply(data)
    }

    func beginJump(to id: String) {
        isJumping = true
        setActive(id)
    }

    func endJump() {
        isJumping = false
    }

    /// Frames are heading minY in tableView coordinates, in flat TOC order.
    func applySpy(frames: [(id: String, minY: CGFloat)], threshold: CGFloat) {
        guard !isJumping else { return }
        var activeId: String?
        for frame in frames where frame.minY <= threshold {
            activeId = frame.id
        }
        setActive(activeId)
    }

    func clear() {
        guard tocData != nil || signature != 0 else { return }
        tocData = nil
        signature = 0
        parentById = [:]
        activeHeadingId = nil
        activeAncestorIds = []
        isJumping = false
    }

    private func apply(_ data: TocData) {
        tocData = data
        var parents: [String: String?] = [:]
        func walk(_ items: [TocEntry], parentId: String?) {
            for item in items {
                parents[item.id] = parentId
                walk(item.children, parentId: item.id)
            }
        }
        walk(data.tree, parentId: nil)
        parentById = parents
        activeHeadingId = nil
        activeAncestorIds = []
    }

    private func setActive(_ id: String?) {
        if id == activeHeadingId { return }
        activeHeadingId = id
        var ancestors: Set<String> = []
        var cursor = parentById[id ?? ""] ?? nil
        while let current = cursor {
            ancestors.insert(current)
            cursor = parentById[current] ?? nil
        }
        activeAncestorIds = ancestors
    }
}

enum TopicHeadingAnchor {
    static func collect(from view: UIView) -> [HeadingBlockView] {
        if let heading = view as? HeadingBlockView {
            return [heading]
        }
        return view.subviews.flatMap { collect(from: $0) }
    }
}
