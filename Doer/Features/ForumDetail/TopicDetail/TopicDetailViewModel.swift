import Foundation
import UIKit
import CookedHTML

struct TopicDetailPostHTML: Sendable {
    let postId: Int
    let cooked: String
}

struct TopicDetailParsedPost: Sendable {
    let postId: Int
    let annotatedBlocks: [AnnotatedBlock]
    let hasUnsupportedBlocks: Bool
}

enum TopicDetailHTMLParsing {
    nonisolated static func parse(posts: [TopicDetailPostHTML], baseURL: String) async -> [TopicDetailParsedPost] {
        guard posts.count > 1 else {
            return posts.map { parse(post: $0, baseURL: baseURL) }
        }

        return await withTaskGroup(
            of: (Int, TopicDetailParsedPost).self,
            returning: [TopicDetailParsedPost].self
        ) { group in
            for (index, post) in posts.enumerated() {
                group.addTask(priority: .userInitiated) {
                    (index, parse(post: post, baseURL: baseURL))
                }
            }

            var parsedPosts = Array<TopicDetailParsedPost?>(repeating: nil, count: posts.count)
            for await (index, parsedPost) in group {
                parsedPosts[index] = parsedPost
            }
            return parsedPosts.compactMap { $0 }
        }
    }

    nonisolated private static func parse(post: TopicDetailPostHTML, baseURL: String) -> TopicDetailParsedPost {
        let cooked = PostImageLinkPreprocessor.rewrite(post.cooked)
        let annotated = CookedHTMLParser.parseAnnotated(html: cooked, baseURL: baseURL)
        return TopicDetailParsedPost(
            postId: post.postId,
            annotatedBlocks: annotated,
            hasUnsupportedBlocks: annotated.contains { !canRenderNatively($0.block) }
        )
    }

    nonisolated private static func canRenderNatively(_ block: ContentBlock) -> Bool {
        switch block {
        case .paragraph,
             .heading,
             .codeBlock,
             .image,
             .imageGrid,
             .onebox,
             .video,
             .list,
             .poll,
             .table,
             .divider:
            return true
        case .blockquote(let blocks), .spoiler(let blocks):
            return blocks.allSatisfy(canRenderNatively)
        case .discourseQuote(_, _, _, _, _, _, _, let content):
            return content.allSatisfy(canRenderNatively)
        case .details(_, let content):
            return content.allSatisfy(canRenderNatively)
        case .rawHTML:
            return false
        }
    }
}

enum TopicDetailPollResultMerger {
    static func mergeInitialPollState(
        blocks: [AnnotatedBlock],
        post: DiscourseTopicDetail.Post
    ) -> [AnnotatedBlock] {
        guard !post.polls.isEmpty else { return blocks }
        return blocks.map { annotatedBlock in
            AnnotatedBlock(
                block: mergeInitialPollState(
                    block: annotatedBlock.block,
                    pollResults: DiscoursePollVoteResponse(polls: post.polls),
                    pollsVotes: post.pollsVotes
                ),
                sourceHTML: annotatedBlock.sourceHTML
            )
        }
    }

    static func merge(
        blocks: [AnnotatedBlock],
        voteResponse: DiscoursePollVoteResponse,
        submittedOptionIds: Set<String>
    ) -> [AnnotatedBlock] {
        return blocks.map { annotatedBlock in
            AnnotatedBlock(
                block: merge(block: annotatedBlock.block, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds),
                sourceHTML: annotatedBlock.sourceHTML
            )
        }
    }

    static func merged(
        _ blocks: [AnnotatedBlock],
        voteResponse: DiscoursePollVoteResponse,
        submittedOptionIds: Set<String>
    ) -> (blocks: [AnnotatedBlock], didChange: Bool) {
        let mergedBlocks = merge(blocks: blocks, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds)
        return (mergedBlocks, mergedBlocks.map(\.block) != blocks.map(\.block))
    }

    private static func mergeInitialPollState(
        blocks: [ContentBlock],
        pollResults: DiscoursePollVoteResponse,
        pollsVotes: [String: [String]]
    ) -> [ContentBlock] {
        blocks.map { mergeInitialPollState(block: $0, pollResults: pollResults, pollsVotes: pollsVotes) }
    }

    private static func mergeInitialPollState(
        block: ContentBlock,
        pollResults: DiscoursePollVoteResponse,
        pollsVotes: [String: [String]]
    ) -> ContentBlock {
        switch block {
        case .poll(let poll):
            guard let result = pollResults.poll(named: poll.name) else { return .poll(poll) }
            return .poll(merge(
                poll: poll,
                result: result,
                submittedOptionIds: selectedOptionIds(for: poll.name, pollsVotes: pollsVotes)
            ))
        case .blockquote(let blocks):
            return .blockquote(blocks: mergeInitialPollState(blocks: blocks, pollResults: pollResults, pollsVotes: pollsVotes))
        case .spoiler(let blocks):
            return .spoiler(blocks: mergeInitialPollState(blocks: blocks, pollResults: pollResults, pollsVotes: pollsVotes))
        case .discourseQuote(let username, let avatarURL, let topicTitle, let topicURL, let categoryName, let categoryURL, let quotePostNumber, let content):
            return .discourseQuote(
                username: username,
                avatarURL: avatarURL,
                topicTitle: topicTitle,
                topicURL: topicURL,
                categoryName: categoryName,
                categoryURL: categoryURL,
                quotePostNumber: quotePostNumber,
                content: mergeInitialPollState(blocks: content, pollResults: pollResults, pollsVotes: pollsVotes)
            )
        case .details(let summary, let content):
            return .details(
                summary: summary,
                content: mergeInitialPollState(blocks: content, pollResults: pollResults, pollsVotes: pollsVotes)
            )
        case .list(let ordered, let start, let items):
            let mergedItems = items.map { item in
                ListItem(
                    content: item.content,
                    children: mergeInitialPollState(blocks: item.children, pollResults: pollResults, pollsVotes: pollsVotes)
                )
            }
            return .list(ordered: ordered, start: start, items: mergedItems)
        case .table(let headers, let rows):
            return .table(
                headers: headers.map { mergeInitialPollState(blocks: $0, pollResults: pollResults, pollsVotes: pollsVotes) },
                rows: rows.map { row in
                    row.map { mergeInitialPollState(blocks: $0, pollResults: pollResults, pollsVotes: pollsVotes) }
                }
            )
        case .paragraph,
             .heading,
             .codeBlock,
             .image,
             .imageGrid,
             .onebox,
             .video,
             .divider,
             .rawHTML:
            return block
        }
    }

    private static func merge(
        blocks: [ContentBlock],
        voteResponse: DiscoursePollVoteResponse,
        submittedOptionIds: Set<String>
    ) -> [ContentBlock] {
        blocks.map { merge(block: $0, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds) }
    }

    private static func merge(
        block: ContentBlock,
        voteResponse: DiscoursePollVoteResponse,
        submittedOptionIds: Set<String>
    ) -> ContentBlock {
        switch block {
        case .poll(let poll):
            if let result = voteResponse.poll(named: poll.name) {
                return .poll(merge(poll: poll, result: result, submittedOptionIds: submittedOptionIds))
            }
            return .poll(mergeSubmittedVoteFallback(poll: poll, submittedOptionIds: submittedOptionIds))
        case .blockquote(let blocks):
            return .blockquote(blocks: merge(blocks: blocks, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds))
        case .spoiler(let blocks):
            return .spoiler(blocks: merge(blocks: blocks, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds))
        case .discourseQuote(let username, let avatarURL, let topicTitle, let topicURL, let categoryName, let categoryURL, let quotePostNumber, let content):
            return .discourseQuote(
                username: username,
                avatarURL: avatarURL,
                topicTitle: topicTitle,
                topicURL: topicURL,
                categoryName: categoryName,
                categoryURL: categoryURL,
                quotePostNumber: quotePostNumber,
                content: merge(blocks: content, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds)
            )
        case .details(let summary, let content):
            return .details(
                summary: summary,
                content: merge(blocks: content, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds)
            )
        case .list(let ordered, let start, let items):
            let mergedItems = items.map { item in
                ListItem(
                    content: item.content,
                    children: merge(blocks: item.children, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds)
                )
            }
            return .list(ordered: ordered, start: start, items: mergedItems)
        case .table(let headers, let rows):
            return .table(
                headers: headers.map { merge(blocks: $0, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds) },
                rows: rows.map { row in
                    row.map { merge(blocks: $0, voteResponse: voteResponse, submittedOptionIds: submittedOptionIds) }
                }
            )
        case .paragraph,
             .heading,
             .codeBlock,
             .image,
             .imageGrid,
             .onebox,
             .video,
             .divider,
             .rawHTML:
            return block
        }
    }

    private static func mergeSubmittedVoteFallback(
        poll: PollBlock,
        submittedOptionIds: Set<String>
    ) -> PollBlock {
        let submittedIds = normalizedOptionIds(submittedOptionIds)
        guard !submittedIds.isEmpty,
              poll.options.contains(where: { option in option.id.map { submittedIds.contains($0) } ?? false })
        else {
            return poll
        }

        let knownVoteTotal = poll.options.compactMap(\.voteCount).reduce(0, +)
        let currentTotal = max(poll.votersCount ?? 0, knownVoteTotal)
        let wasAlreadySelected = poll.options.contains { option in
            guard let id = option.id else { return false }
            return submittedIds.contains(id) && option.isSelected
        }
        let totalVotes = max(currentTotal + (wasAlreadySelected ? 0 : 1), 1)

        let options = poll.options.map { option in
            guard let id = option.id else { return option }
            let isSubmitted = submittedIds.contains(id)
            let voteCount: Int?
            if isSubmitted {
                voteCount = max((option.voteCount ?? 0) + (wasAlreadySelected ? 0 : 1), 1)
            } else {
                voteCount = option.voteCount
            }
            return PollOption(
                id: option.id,
                text: option.text,
                voteCount: voteCount,
                percentageText: percentageText(voteCount: voteCount, totalVotes: totalVotes) ?? option.percentageText,
                isSelected: isSubmitted
            )
        }

        return PollBlock(
            name: poll.name,
            status: poll.status,
            type: poll.type,
            options: options,
            votersText: poll.votersText,
            votersCount: totalVotes,
            minSelections: poll.minSelections,
            maxSelections: poll.maxSelections,
            resultsMode: poll.resultsMode,
            isPublic: poll.isPublic
        )
    }

    private static func merge(
        poll: PollBlock,
        result: DiscoursePollVoteResponse.Poll,
        submittedOptionIds: Set<String>
    ) -> PollBlock {
        var resultOptionsById: [String: DiscoursePollVoteResponse.Option] = [:]
        for option in result.options {
            guard let id = option.id else { continue }
            resultOptionsById[id] = option
        }

        let fallbackTotal = result.options.compactMap(\.voteCount).reduce(0, +)
        let totalVotes = result.votersCount ?? poll.votersCount ?? (fallbackTotal > 0 ? fallbackTotal : nil)
        let options = poll.options.map { option in
            guard let id = option.id,
                  let resultOption = resultOptionsById[id]
            else {
                return PollOption(
                    id: option.id,
                    text: option.text,
                    voteCount: option.voteCount,
                    percentageText: option.percentageText,
                    isSelected: option.id.map { submittedOptionIds.contains($0) } ?? option.isSelected
                )
            }

            let voteCount = resultOption.voteCount ?? option.voteCount
            return PollOption(
                id: option.id,
                text: option.text,
                voteCount: voteCount,
                percentageText: resultOption.percentageText
                    ?? option.percentageText
                    ?? percentageText(voteCount: voteCount, totalVotes: totalVotes),
                isSelected: resultOption.isSelected ?? (submittedOptionIds.contains(id) || option.isSelected)
            )
        }

        return PollBlock(
            name: poll.name ?? result.name,
            status: result.status ?? poll.status,
            type: result.type ?? poll.type,
            options: options,
            votersText: poll.votersText,
            votersCount: totalVotes,
            minSelections: result.minSelections ?? poll.minSelections,
            maxSelections: result.maxSelections ?? poll.maxSelections,
            resultsMode: result.resultsMode ?? poll.resultsMode,
            isPublic: result.isPublic ?? poll.isPublic
        )
    }

    private static func normalizedOptionIds(_ optionIds: Set<String>) -> Set<String> {
        Set(optionIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private static func selectedOptionIds(for pollName: String?, pollsVotes: [String: [String]]) -> Set<String> {
        guard !pollsVotes.isEmpty else { return [] }
        let normalizedName = normalizedPollName(pollName)
        if let normalizedName,
           let match = pollsVotes.first(where: { normalizedPollName($0.key) == normalizedName }) {
            return normalizedOptionIds(Set(match.value))
        }
        if pollsVotes.count == 1, let onlyVotes = pollsVotes.values.first {
            return normalizedOptionIds(Set(onlyVotes))
        }
        return []
    }

    private static func normalizedPollName(_ name: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func percentageText(voteCount: Int?, totalVotes: Int?) -> String? {
        guard let voteCount, let totalVotes, totalVotes > 0 else { return nil }
        let percent = Double(voteCount) / Double(totalVotes) * 100
        let rounded = (percent * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return "\(Int(rounded))%"
        }
        return "\(rounded)%"
    }
}

enum TopicDetailPaginationPolicy {
    /// Posts fetched per network window (Discourse post_ids batch).
    static let pageSize = 20
    /// Parse this many posts before first paint (~1–2 screens). The rest wait for scroll / idle.
    static let firstPaintPostCount = 6
    /// Keep about one page ahead of the visible stream index ready (parsed).
    static let forwardReadyBuffer = pageSize
    /// When jumping, also fetch a few floors before the target for upward scroll.
    static let jumpLookback = 5
    /// Table `willDisplay` backup trigger: rows from the end of the current snapshot.
    static let displayPrefetchRowThreshold = 8
    /// Live stream poll while TopicDetail is visible.
    static let liveSyncInterval: TimeInterval = 12
    /// Consider "at bottom" when within this many table rows of the end.
    static let liveSyncNearBottomRows = 4

    static func canStartEarlier(
        isLoadingEarlier: Bool,
        isLoadingMore: Bool,
        isJumping: Bool
    ) -> Bool {
        !isLoadingEarlier && !isLoadingMore && !isJumping
    }

    static func canStartMore(
        isLoadingEarlier: Bool,
        isLoadingMore: Bool,
        isJumping: Bool
    ) -> Bool {
        !isLoadingEarlier && !isLoadingMore && !isJumping
    }

    /// Desired exclusive end index in `allPostIds` so one window stays ready past `visibleStreamIndex`.
    static func desiredLoadedEnd(
        visibleStreamIndex: Int,
        totalCount: Int,
        buffer: Int = forwardReadyBuffer
    ) -> Int {
        guard totalCount > 0 else { return 0 }
        let visible = min(max(visibleStreamIndex, 0), totalCount - 1)
        return min(totalCount, visible + 1 + buffer)
    }

    static func jumpWindow(
        targetIndex: Int,
        totalCount: Int,
        lookback: Int = jumpLookback,
        pageSize: Int = pageSize
    ) -> Range<Int> {
        guard totalCount > 0 else { return 0..<0 }
        let target = min(max(targetIndex, 0), totalCount - 1)
        let start = max(0, target - lookback)
        let end = min(totalCount, max(target + 1, start + pageSize))
        return start..<end
    }

    static func firstPaintSplit<T>(_ items: [T]) -> (immediate: [T], deferred: [T]) {
        let count = min(firstPaintPostCount, items.count)
        return (Array(items.prefix(count)), Array(items.dropFirst(count)))
    }

    static func shouldRestoreEarlierAnchor(
        hasAnchor: Bool,
        isLoadingEarlier: Bool,
        snapshotChanged: Bool
    ) -> Bool {
        hasAnchor && !isLoadingEarlier && snapshotChanged
    }
}

enum TopicDetailSnapshotPolicy {
    enum Decision: Equatable {
        case skip
        case apply
        case queue
    }

    static func decision(
        isApplying: Bool,
        currentItemIDs: [Int],
        requestedItemIDs: [Int]
    ) -> Decision {
        if isApplying { return .queue }
        return currentItemIDs == requestedItemIDs ? .skip : .apply
    }
}

final class TopicDetailViewModel: DoerObservableObject {
    var topic: DiscourseTopicDetail?
    private(set) var category: DiscourseCategory?
    private(set) var categoryPresentation: TopicCategoryBadgePresentation?
    var parsedBlocks: [Int: [AnnotatedBlock]] = [:]
    var unsupportedPostIds: Set<Int> = []
    var isLoading = false
    var isReady = false
    var isLoadingMore = false
    var isLoadingEarlier = false
    var isFilteringByOP = false
    /// Client-side: only root posts (no reply_to_post_number) + OP. FluxDo `filter_top_level_replies`.
    var isFilteringTopLevel = false
    /// FluxDo nested tree mode (uses `/n/topic` API, not flat reordering).
    var isNestedViewEnabled = false
    /// Flattened nested rows for table snapshot when tree mode is on.
    private(set) var nestedRows: [NestedDisplayRow] = []
    private var nestedRoots: [DiscourseNestedNode] = []
    private var nestedOpPost: DiscourseTopicDetail.Post?
    private var nestedExpandedPostNumbers = Set<Int>()
    /// FluxDo sort chips under OP: top / new / old.
    private(set) var nestedSort: NestedReplySort = .old
    private var nestedHasMoreRoots = false
    private var nestedPage = 0
    private var nestedTopicId: Int?
    /// Posts loaded only via nested API (may not yet be in flat `post_stream.posts`).
    private var nestedPostById: [Int: DiscourseTopicDetail.Post] = [:]
    var isLoadingNested = false
    var isJumping = false
    var jumpTargetFloor: Int?
    var errorMessage: String?
    /// New replies discovered by live sync that are not yet on screen / not consumed.
    private(set) var pendingNewReplyCount = 0
    /// True while a background stream sync is in flight (not a full reload).
    private(set) var isSyncingStream = false

    private let api: DiscourseAPI
    private(set) var allPostIds: [Int] = []
    private var loadedPostIds: Set<Int> = []
    private(set) var loadedRangeStart: Int = 0
    private(set) var loadedRangeEnd: Int = 0
    /// Cached first post (OP) to preserve across jumpToFloor
    private var firstPost: DiscourseTopicDetail.Post?
    private var parseGeneration = 0
    /// Soft forward prefetch so the next window is ready before the user hits the end.
    private var forwardPrefetchTask: Task<Void, Never>?
    /// Stream length last time the user "saw" the tail (load/consume/scroll-catchup).
    private var acknowledgedStreamCount = 0
    private var categoryMetadataTask: Task<Void, Never>?
    private var categoryMetadataCategoryId: Int?
    private var loadedCategoryMetadataId: Int?

    init(api: DiscourseAPI) {
        self.api = api
    }

    var posts: [DiscourseTopicDetail.Post] {
        topic?.postStream.posts ?? []
    }

    var opUsername: String? {
        firstPost?.username ?? posts.first?.username
    }

    var visiblePosts: [DiscourseTopicDetail.Post] {
        if isNestedViewEnabled {
            let nested = nestedVisiblePosts()
            // While /n/topic is in flight (or returns an empty tree), keep the flat
            // stream on screen so notification / deep-link opens never paint a blank body.
            // Also: nested rows that resolve but have zero parsed blocks would paint a
            // title-only "white screen" — fall back to flat whenever flat can render.
            if !nested.isEmpty {
                let nestedCanPaint = nested.contains { parsedBlocks[$0.id] != nil }
                if nestedCanPaint || isLoadingNested || parsedBlocks.isEmpty {
                    return nested
                }
            }
        }
        return flatVisiblePosts()
    }

    /// Flat stream posts (filters applied). Used as the safe fallback under nested mode.
    private func flatVisiblePosts() -> [DiscourseTopicDetail.Post] {
        var base = posts.filter { !Self.isSystemActionPost($0) }
        if isFilteringByOP, let op = opUsername {
            base = base.filter { $0.username == op }
        }
        if isFilteringTopLevel {
            // Keep topic starter + posts that are not replies to another post.
            base = base.filter { $0.postNumber == 1 || $0.replyToPostNumber == nil }
        }
        // Always present in Discourse stream order so jump / load-earlier cannot
        // leave a mid-thread post above floor 1.
        return postsSortedByStream(base)
    }

    /// True only for the real topic OP (stream head / post_number 1), never a jump-window head.
    private func isRealOpeningPost(_ post: DiscourseTopicDetail.Post) -> Bool {
        if post.postNumber == 1 { return true }
        if let headId = allPostIds.first, headId == post.id { return true }
        return false
    }

    private func streamIndexOrder() -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: allPostIds.enumerated().map { ($1, $0) })
    }

    private func postsSortedByStream(_ posts: [DiscourseTopicDetail.Post]) -> [DiscourseTopicDetail.Post] {
        guard !allPostIds.isEmpty else { return posts }
        let idOrder = streamIndexOrder()
        return posts.sorted { (idOrder[$0.id] ?? Int.max) < (idOrder[$1.id] ?? Int.max) }
    }

    /// Keep `postStream.posts` aligned with `allPostIds` after any window mutation.
    private func resortLoadedPostsByStreamOrder() {
        guard var current = topic?.postStream.posts, !current.isEmpty, !allPostIds.isEmpty else { return }
        current = postsSortedByStream(current)
        topic?.postStream.posts = current
    }

    private func nestedVisiblePosts() -> [DiscourseTopicDetail.Post] {
        nestedRows.compactMap { post(byId: $0.postId) }
    }

    /// True when nested mode currently has at least one row that can enter the Diffable snapshot.
    var hasRenderableNestedPosts: Bool {
        guard isNestedViewEnabled else { return false }
        return nestedVisiblePosts().contains { parsedBlocks[$0.id] != nil }
    }

    /// Exit tree mode when it cannot paint (empty tree, unparsed nodes, or jump cleared blocks).
    /// Returns `true` if nested was turned off so the caller can rebuild the snapshot.
    /// - Parameter notify: When `false`, clears nested state without `notifyChanged` (safe inside `updateUI`).
    @MainActor
    @discardableResult
    func abandonNestedIfUnrenderable(notify: Bool = true) -> Bool {
        guard isNestedViewEnabled, !isLoadingNested else { return false }
        if hasRenderableNestedPosts { return false }
        let flatCanPaint = flatVisiblePosts().contains { parsedBlocks[$0.id] != nil }
        // Drop tree whenever flat can show content, or the tree itself is empty.
        guard flatCanPaint || nestedRows.isEmpty || nestedVisiblePosts().isEmpty else {
            return false
        }
        DohDebugLog.record(
            "abandon nested: rows=\(nestedRows.count) nestedVisible=\(nestedVisiblePosts().count) flatParsed=\(flatVisiblePosts().filter { parsedBlocks[$0.id] != nil }.count)",
            subsystem: "topic.nested"
        )
        clearNestedState()
        if notify {
            notifyChanged()
        }
        return true
    }

    /// Drop tree mode without fetching / notifying (shared by abandon + jump).
    private func clearNestedState() {
        isNestedViewEnabled = false
        nestedRows = []
        nestedRoots = []
        nestedOpPost = nil
        nestedPostById.removeAll(keepingCapacity: true)
        nestedExpandedPostNumbers.removeAll()
    }

    /// Force-exit nested mode (e.g. snapshot safety net inside `updateUI`).
    @MainActor
    func forceDisableNested(notify: Bool = true) {
        guard isNestedViewEnabled else { return }
        clearNestedState()
        if notify {
            notifyChanged()
        }
    }

    /// Resolve a post from flat stream or nested cache (tree mode may load posts not in stream window).
    func post(byId id: Int) -> DiscourseTopicDetail.Post? {
        if let p = posts.first(where: { $0.id == id }) { return p }
        if let p = nestedPostById[id] { return p }
        if let op = nestedOpPost, op.id == id { return op }
        return nil
    }

    func post(byPostNumber number: Int) -> DiscourseTopicDetail.Post? {
        if let p = posts.first(where: { $0.postNumber == number }) { return p }
        if let p = nestedPostById.values.first(where: { $0.postNumber == number }) { return p }
        if let op = nestedOpPost, op.postNumber == number { return op }
        return nil
    }

    func nestedRow(forPostId postId: Int) -> NestedDisplayRow? {
        nestedRows.first { $0.postId == postId }
    }

    var hasActiveTopicFilter: Bool {
        isFilteringByOP || isFilteringTopLevel || isNestedViewEnabled
    }

    var canLoadMore: Bool {
        // Nested tree pages roots via /n/topic, not the flat post_stream window.
        guard !isNestedViewEnabled else { return false }
        return !allPostIds.isEmpty && loadedRangeEnd < allPostIds.count
    }

    var canLoadEarlier: Bool {
        guard !isNestedViewEnabled else { return false }
        return loadedRangeStart > 0
    }

    var totalFloors: Int {
        allPostIds.count
    }

    /// Check if a floor (1-based) is already loaded
    func isFloorLoaded(_ floor: Int) -> Bool {
        let index = floor - 1
        guard index >= 0, index < allPostIds.count else { return false }
        return loadedPostIds.contains(allPostIds[index])
    }

    /// Find the index in `posts` array for a given floor (1-based)
    func postIndexForFloor(_ floor: Int) -> Int? {
        let index = floor - 1
        guard index >= 0, index < allPostIds.count else { return nil }
        let targetId = allPostIds[index]
        return posts.firstIndex(where: { $0.id == targetId })
    }

    /// Find the row index in `visiblePosts` for a given floor (1-based).
    /// Note: this is NOT safe for `UITableView.scrollToRow` — the table snapshot only
    /// includes posts with parsed blocks (and may use nested ordering). Prefer
    /// Diffable `dataSource.indexPath(for: postId)` at the call site.
    func visibleRowForFloor(_ floor: Int) -> Int? {
        let index = floor - 1
        guard index >= 0, index < allPostIds.count else { return nil }
        let targetId = allPostIds[index]
        return visiblePosts.firstIndex(where: { $0.id == targetId })
    }

    func setFilteringByOP(_ enabled: Bool) {
        guard isFilteringByOP != enabled else { return }
        isFilteringByOP = enabled
        // FluxDo: content filters are mutually exclusive with each other and exit tree view.
        if enabled {
            isFilteringTopLevel = false
            isNestedViewEnabled = false
        }
        notifyChanged()
    }

    func setFilteringTopLevel(_ enabled: Bool) {
        guard isFilteringTopLevel != enabled else { return }
        isFilteringTopLevel = enabled
        if enabled {
            isFilteringByOP = false
            isNestedViewEnabled = false
        }
        notifyChanged()
    }

    func setNestedViewEnabled(_ enabled: Bool) {
        guard isNestedViewEnabled != enabled else { return }
        isNestedViewEnabled = enabled
        if enabled {
            isFilteringByOP = false
            isFilteringTopLevel = false
            let topicId = topic?.id ?? nestedTopicId
            if let topicId {
                nestedTopicId = topicId
                Task { await loadNestedRoots(topicId: topicId, trackVisit: false) }
            } else {
                notifyChanged()
            }
        } else {
            clearNestedState()
            // clearNestedState already sets isNestedViewEnabled = false; keep flag consistent
            // when called from setNestedViewEnabled(false) after the flag was set above.
            notifyChanged()
        }
    }

    /// FluxDo sort chips: reload roots with the chosen order.
    func setNestedSort(_ sort: NestedReplySort) {
        guard nestedSort != sort else { return }
        nestedSort = sort
        // Refresh chip selection immediately — snapshot IDs often stay identical while
        // `/n/topic` reloads, so Diffable would otherwise skip cell reconfigure.
        notifyChanged()
        guard isNestedViewEnabled, let topicId = nestedTopicId ?? topic?.id else { return }
        Task { await loadNestedRoots(topicId: topicId, trackVisit: false) }
    }

    func clearTopicFilters() {
        let changed = isFilteringByOP || isFilteringTopLevel || isNestedViewEnabled
        isFilteringByOP = false
        isFilteringTopLevel = false
        if isNestedViewEnabled {
            setNestedViewEnabled(false)
            return
        }
        guard changed else { return }
        notifyChanged()
    }

    // MARK: - Nested tree (FluxDo /n/topic)

    @MainActor
    func loadNestedRoots(topicId: Int, trackVisit: Bool) async {
        nestedTopicId = topicId
        isLoadingNested = true
        notifyChanged()
        do {
            let response = try await api.fetchNestedRoots(
                topicId: topicId,
                sort: nestedSort.apiValue,
                page: 0,
                trackVisit: trackVisit
            )
            if let sort = response.sort {
                nestedSort = NestedReplySort.from(apiValue: sort)
            }
            nestedOpPost = response.opPost ?? firstPost ?? posts.first
            nestedRoots = response.roots
            nestedHasMoreRoots = response.hasMoreRoots
            nestedPage = response.page
            nestedExpandedPostNumbers.removeAll()
            indexNestedPosts(from: response.roots)
            if let op = nestedOpPost {
                nestedPostById[op.id] = op
            }
            // FluxDo: roots are always visible; children start collapsed until expanded.
            rebuildNestedRows()
            let width = max(UIScreen.main.bounds.width - 48, 300)
            await ensureParsed(for: nestedVisiblePosts(), containerWidth: width)
            isLoadingNested = false
            // Empty / unparsed tree → flat stream (avoids title-only white body).
            _ = abandonNestedIfUnrenderable()
            notifyChanged()
        } catch {
            isLoadingNested = false
            // Fallback: client-side tree from loaded posts (plugin may be missing).
            rebuildNestedRowsFromFlatPosts()
            indexNestedPosts(from: nestedRoots)
            if let op = nestedOpPost {
                nestedPostById[op.id] = op
            }
            let width = max(UIScreen.main.bounds.width - 48, 300)
            await ensureParsed(for: nestedVisiblePosts(), containerWidth: width)
            errorMessage = nil
            _ = abandonNestedIfUnrenderable()
            notifyChanged()
            DohDebugLog.record("nested roots failed: \(error.localizedDescription)", subsystem: "topic.nested")
        }
    }

    @MainActor
    func toggleNestedExpand(postNumber: Int, containerWidth: CGFloat) async {
        guard isNestedViewEnabled else { return }
        if nestedExpandedPostNumbers.contains(postNumber) {
            nestedExpandedPostNumbers.remove(postNumber)
            rebuildNestedRows()
            notifyChanged()
            return
        }

        // Expand: load children if node has more than loaded.
        if let node = findNestedNode(postNumber: postNumber),
           node.hasMoreChildren || node.children.isEmpty && node.directReplyCount > 0 {
            do {
                let response = try await api.fetchNestedChildren(
                    topicId: nestedTopicId ?? topic?.id ?? 0,
                    postNumber: postNumber,
                    sort: nestedSort.apiValue,
                    page: 0,
                    depth: 1
                )
                replaceNestedChildren(
                    postNumber: postNumber,
                    children: response.children,
                    directCount: max(node.directReplyCount, response.children.count)
                )
                indexNestedPosts(from: response.children)
                await ensureParsed(for: response.children.map(\.post), containerWidth: containerWidth)
            } catch {
                DohDebugLog.record("nested children failed: \(error.localizedDescription)", subsystem: "topic.nested")
            }
        }
        nestedExpandedPostNumbers.insert(postNumber)
        rebuildNestedRows()
        notifyChanged()
    }

    private func indexNestedPosts(from nodes: [DiscourseNestedNode]) {
        for node in nodes {
            nestedPostById[node.post.id] = node.post
            if !node.children.isEmpty {
                indexNestedPosts(from: node.children)
            }
        }
    }

    private func rebuildNestedRows() {
        var rows: [NestedDisplayRow] = []
        if let op = nestedOpPost {
            rows.append(
                NestedDisplayRow(
                    postId: op.id,
                    postNumber: op.postNumber,
                    depth: 0,
                    directReplyCount: op.replyCount,
                    loadedChildCount: 0,
                    hasMoreChildren: false,
                    isExpanded: false
                )
            )
        }
        func walk(_ nodes: [DiscourseNestedNode], depth: Int) {
            for node in nodes {
                let expanded = nestedExpandedPostNumbers.contains(node.post.postNumber)
                rows.append(
                    NestedDisplayRow(
                        postId: node.post.id,
                        postNumber: node.post.postNumber,
                        depth: depth,
                        directReplyCount: node.directReplyCount,
                        loadedChildCount: node.children.count,
                        hasMoreChildren: node.hasMoreChildren || (!node.children.isEmpty && node.directReplyCount > node.children.count),
                        isExpanded: expanded
                    )
                )
                if expanded {
                    walk(node.children, depth: depth + 1)
                }
            }
        }
        walk(nestedRoots, depth: 0)
        nestedRows = rows
    }

    /// Offline / no-plugin fallback: build tree from currently loaded flat posts.
    private func rebuildNestedRowsFromFlatPosts() {
        let real = posts.filter { !Self.isSystemActionPost($0) }.sorted { $0.postNumber < $1.postNumber }
        nestedOpPost = real.first { $0.postNumber == 1 } ?? real.first
        var byNumber: [Int: DiscourseTopicDetail.Post] = [:]
        for p in real { byNumber[p.postNumber] = p }
        var childrenMap: [Int: [DiscourseTopicDetail.Post]] = [:]
        var roots: [DiscourseTopicDetail.Post] = []
        for p in real where p.postNumber != 1 {
            if let parent = p.replyToPostNumber, parent != 1, byNumber[parent] != nil {
                childrenMap[parent, default: []].append(p)
            } else {
                roots.append(p)
            }
        }
        roots = sortFlatNestedRoots(roots)
        for key in childrenMap.keys {
            childrenMap[key] = sortFlatNestedRoots(childrenMap[key] ?? [])
        }
        func build(_ post: DiscourseTopicDetail.Post) -> DiscourseNestedNode {
            let kids = (childrenMap[post.postNumber] ?? []).map(build)
            return DiscourseNestedNode(
                post: post,
                children: kids,
                directReplyCount: post.replyCount,
                totalDescendantCount: kids.count,
                isDeletedPlaceholder: false
            )
        }
        nestedRoots = roots.map(build)
        nestedExpandedPostNumbers = Set(roots.prefix(20).map(\.postNumber))
        rebuildNestedRows()
    }

    private func sortFlatNestedRoots(_ posts: [DiscourseTopicDetail.Post]) -> [DiscourseTopicDetail.Post] {
        switch nestedSort {
        case .old:
            return posts.sorted { $0.postNumber < $1.postNumber }
        case .new:
            return posts.sorted { $0.postNumber > $1.postNumber }
        case .top:
            return posts.sorted {
                if $0.reactionUsersCount != $1.reactionUsersCount {
                    return $0.reactionUsersCount > $1.reactionUsersCount
                }
                return $0.postNumber < $1.postNumber
            }
        }
    }

    private func findNestedNode(postNumber: Int) -> DiscourseNestedNode? {
        func search(_ nodes: [DiscourseNestedNode]) -> DiscourseNestedNode? {
            for n in nodes {
                if n.post.postNumber == postNumber { return n }
                if let found = search(n.children) { return found }
            }
            return nil
        }
        return search(nestedRoots)
    }

    private func replaceNestedChildren(postNumber: Int, children: [DiscourseNestedNode], directCount: Int) {
        func mapNodes(_ nodes: [DiscourseNestedNode]) -> [DiscourseNestedNode] {
            nodes.map { node in
                if node.post.postNumber == postNumber {
                    return node.copyWith(children: children, directReplyCount: directCount)
                }
                return node.copyWith(children: mapNodes(node.children))
            }
        }
        nestedRoots = mapNodes(nestedRoots)
    }

    private func ensureParsed(for posts: [DiscourseTopicDetail.Post], containerWidth: CGFloat) async {
        _ = containerWidth
        let missing = posts.filter { parsedBlocks[$0.id] == nil }
        guard !missing.isEmpty else { return }
        for post in missing {
            nestedPostById[post.id] = post
        }
        _ = await parseAndStore(posts: missing, generation: parseGeneration)
    }

    func loadTopic(id: Int, containerWidth: CGFloat) async {
        let firstPaintStartedAt = Date()
        DohDebugLog.record("open topic=\(id)", subsystem: "topic.firstpaint")
        await loadTopic(id: id, containerWidth: containerWidth, retryingExplicitCancellation: false)
        if isReady {
            let ms = Int(Date().timeIntervalSince(firstPaintStartedAt) * 1000)
            DohDebugLog.record("ready topic=\(id) elapsedMs=\(ms)", subsystem: "topic.firstpaint")
        }
    }

    /// After Cloudflare verification: keep a recovery message, retry fetch with backoff,
    /// and avoid wiping the page into a permanent CF error while grace is active.
    func recoverAfterCloudflare(id: Int, containerWidth: CGFloat) async {
        isLoading = true
        errorMessage = String(
            localized: "cloudflare.recovering",
            defaultValue: "验证已通过，正在重新加载…"
        )
        notifyChanged()

        let delays: [UInt64] = [
            300_000_000,
            700_000_000,
            1_200_000_000,
            2_000_000_000,
        ]
        var lastError: String?
        for index in delays.indices {
            if index > 0 {
                try? await Task.sleep(nanoseconds: delays[index - 1])
            }
            do {
                let detail = try await api.fetchTopic(id: id, trackVisit: true)
                parseGeneration += 1
                let generation = parseGeneration
                guard await applyLoadedTopicDetail(
                    detail,
                    containerWidth: containerWidth,
                    generation: generation
                ) else {
                    isLoading = false
                    notifyChanged()
                    return
                }
                return
            } catch {
                lastError = error.localizedDescription
                let isCF = lastError?.localizedCaseInsensitiveContains("cloudflare") == true
                if isCF, index < delays.count - 1 {
                    errorMessage = String(
                        localized: "cloudflare.recovering",
                        defaultValue: "验证已通过，正在重新加载…"
                    )
                    notifyChanged()
                    continue
                }
                errorMessage = lastError
            }
        }
        isLoading = false
        if CloudflareVerificationPolicy.isInVerificationGrace(baseURL: api.baseURL),
           (lastError?.localizedCaseInsensitiveContains("cloudflare") == true) {
            errorMessage = String(
                localized: "cloudflare.recovering_failed",
                defaultValue: "验证已通过，但内容仍在加载。请稍候下拉刷新，或退出后重新进入。"
            )
        }
        notifyChanged()
    }

    private func loadTopic(id: Int, containerWidth: CGFloat, retryingExplicitCancellation: Bool) async {
        cancelForwardWindowPrefetch()
        isLoading = true
        isReady = false
        errorMessage = nil
        parsedBlocks = [:]
        unsupportedPostIds = []
        parseGeneration += 1
        let generation = parseGeneration
        notifyChanged()

        guard ConnectivityService.shared.isConnected else {
            isLoading = false
            errorMessage = String(localized: "error.offline", defaultValue: "当前无网络，连接后将自动刷新")
            notifyChanged()
            return
        }

        do {
            let detail = try await api.fetchTopic(id: id, trackVisit: true)
            guard await applyLoadedTopicDetail(
                detail,
                containerWidth: containerWidth,
                generation: generation
            ) else {
                isLoading = false
                notifyChanged()
                return
            }
            return
        } catch {
            #if DEBUG
            print("[TopicDetail] Load failed: \(error)")
            #endif
            if !retryingExplicitCancellation,
               !Task.isCancelled,
               DiscourseAPI.isExplicitlyCancelledRequest(error) {
                #if DEBUG
                print("[TopicDetail] Initial request was explicitly cancelled; retrying once")
                #endif
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    isLoading = false
                    notifyChanged()
                    return
                }
                guard !Task.isCancelled else {
                    isLoading = false
                    notifyChanged()
                    return
                }
                await loadTopic(id: id, containerWidth: containerWidth, retryingExplicitCancellation: true)
                return
            }
            errorMessage = error.localizedDescription
        }

        isLoading = false
        notifyChanged()
    }

    /// Apply a freshly fetched topic: parse ~1–2 screens, paint, then fill the rest off the first-paint path.
    /// - Returns: `false` when a newer `parseGeneration` won the race.
    @discardableResult
    private func applyLoadedTopicDetail(
        _ detail: DiscourseTopicDetail,
        containerWidth: CGFloat,
        generation: Int
    ) async -> Bool {
        topic = detail
        startLoadingCategoryMetadata(for: detail.categoryId)

        allPostIds = detail.postStream.stream ?? detail.postStream.posts.map(\.id)
        loadedPostIds = Set(detail.postStream.posts.map(\.id))
        firstPost = detail.postStream.posts.first

        loadedRangeStart = 0
        let postsToRender = detail.postStream.posts
        let split = TopicDetailPaginationPolicy.firstPaintSplit(postsToRender)
        if let lastImmediateId = split.immediate.last?.id,
           let lastIndex = allPostIds.firstIndex(of: lastImmediateId) {
            loadedRangeEnd = lastIndex + 1
        } else {
            loadedRangeEnd = split.immediate.count
        }

        guard !split.immediate.isEmpty else {
            isReady = true
            isLoading = false
            errorMessage = nil
            acknowledgedStreamCount = allPostIds.count
            pendingNewReplyCount = 0
            notifyChanged()
            return true
        }

        guard await parseAndStore(posts: split.immediate, generation: generation) else {
            return false
        }

        isReady = true
        isLoading = false
        errorMessage = nil
        acknowledgedStreamCount = allPostIds.count
        pendingNewReplyCount = 0
        notifyChanged()

        if isNestedViewEnabled {
            await loadNestedRoots(topicId: detail.id, trackVisit: false)
            _ = abandonNestedIfUnrenderable()
            if !isNestedViewEnabled {
                notifyChanged()
            }
        }

        scheduleCachedRemainderParse(
            containerWidth: containerWidth,
            generation: generation
        )
        return true
    }

    /// Parse already-fetched posts past the first-paint window in small chunks, then prefetch the next network page.
    private func scheduleCachedRemainderParse(containerWidth: CGFloat, generation: Int) {
        cancelForwardWindowPrefetch()
        let width = containerWidth
        forwardPrefetchTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            await self.parseCachedRemainderThenPrefetch(
                containerWidth: width,
                generation: generation
            )
        }
    }

    private func parseCachedRemainderThenPrefetch(containerWidth: CGFloat, generation: Int) async {
        let chunkSize = TopicDetailPaginationPolicy.firstPaintPostCount
        while !Task.isCancelled, generation == parseGeneration, loadedRangeEnd < allPostIds.count {
            let byId = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
            var chunk: [DiscourseTopicDetail.Post] = []
            var newEnd = loadedRangeEnd
            for id in allPostIds[loadedRangeEnd...] {
                guard let post = byId[id] else { break }
                newEnd += 1
                if parsedBlocks[id] == nil {
                    chunk.append(post)
                }
                if chunk.count >= chunkSize { break }
                if chunk.isEmpty, newEnd - loadedRangeEnd >= chunkSize { break }
            }
            if newEnd == loadedRangeEnd { break }
            if !chunk.isEmpty {
                guard await parseAndStore(posts: chunk, generation: generation) else { return }
            }
            guard !Task.isCancelled, generation == parseGeneration else { return }
            loadedRangeEnd = newEnd
            notifyChanged()
            await Task.yield()
        }
        guard !Task.isCancelled, generation == parseGeneration else { return }
        scheduleForwardWindowPrefetch(
            containerWidth: containerWidth,
            visibleStreamIndex: max(0, loadedRangeEnd - 1)
        )
    }

    /// Resolve `batch` from the in-memory stream when possible; fetch only missing ids, then parse unparsed posts.
    private func fetchAndParsePosts(
        topicId: Int,
        batch: [Int],
        generation: Int
    ) async throws -> Bool {
        let existingById = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let missingIds = batch.filter { existingById[$0] == nil }

        if !missingIds.isEmpty {
            let response = try await api.fetchTopicPosts(topicId: topicId, postIds: missingIds)
            let newPosts = response.postStream.posts.filter { !loadedPostIds.contains($0.id) }
            if !newPosts.isEmpty {
                let sortedPosts = postsSortedByStream(newPosts)
                topic?.postStream.posts.append(contentsOf: sortedPosts)
                resortLoadedPostsByStreamOrder()
                for post in sortedPosts {
                    loadedPostIds.insert(post.id)
                }
            }
        }

        for id in batch {
            loadedPostIds.insert(id)
        }

        let latestById = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let toParse = batch.compactMap { id -> DiscourseTopicDetail.Post? in
            guard parsedBlocks[id] == nil else { return nil }
            return latestById[id]
        }
        if toParse.isEmpty { return true }
        return await parseAndStore(posts: toParse, generation: generation)
    }

    private func startLoadingCategoryMetadata(for categoryId: Int?) {
        guard let categoryId else {
            categoryMetadataTask?.cancel()
            categoryMetadataTask = nil
            categoryMetadataCategoryId = nil
            loadedCategoryMetadataId = nil
            category = nil
            categoryPresentation = nil
            return
        }
        if loadedCategoryMetadataId == categoryId { return }
        if categoryMetadataCategoryId == categoryId, categoryMetadataTask != nil { return }

        if let cachedCategory = DiscourseTaxonomySessionStore.category(id: categoryId, for: api.baseURL) {
            let cachedParent = cachedCategory.parentCategoryId.flatMap {
                DiscourseTaxonomySessionStore.category(id: $0, for: api.baseURL)
            }
            category = cachedCategory
            categoryPresentation = TopicCategoryBadgePresentation.resolve(
                category: cachedCategory,
                parent: cachedParent,
                displayName: cachedCategory.displayName(parent: cachedParent),
                baseURL: api.baseURL
            )
            loadedCategoryMetadataId = categoryId
            return
        }

        if category?.id != categoryId {
            loadedCategoryMetadataId = nil
            let seededCategory = LinuxDoCategoryCatalog.category(id: categoryId, baseURL: api.baseURL)
            let seededParent = seededCategory?.parentCategoryId.flatMap {
                LinuxDoCategoryCatalog.category(id: $0, baseURL: api.baseURL)
            }
            category = seededCategory
            categoryPresentation = TopicCategoryBadgePresentation.resolve(
                category: seededCategory,
                parent: seededParent,
                displayName: seededCategory?.displayName(parent: seededParent),
                baseURL: api.baseURL
            )
        }

        let refreshBaseURL = api.baseURL
        categoryMetadataTask?.cancel()
        categoryMetadataCategoryId = categoryId
        categoryMetadataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.categoryMetadataCategoryId == categoryId {
                    self.categoryMetadataTask = nil
                    self.categoryMetadataCategoryId = nil
                }
            }

            do {
                let categories: [DiscourseCategory]
                if DiscourseTaxonomySessionStore.beginRefresh(for: refreshBaseURL) {
                    defer { DiscourseTaxonomySessionStore.endRefresh(for: refreshBaseURL) }
                    categories = try await self.api.fetchSiteCategories()
                    try Task.checkCancellation()
                    DiscourseTaxonomySessionStore.replace(categories: categories, for: refreshBaseURL)
                } else {
                    categories = await DiscourseTaxonomySessionStore.waitForRefresh(for: refreshBaseURL)
                    try Task.checkCancellation()
                }
                self.applyCategoryMetadata(categories, categoryId: categoryId)
            } catch is CancellationError {
                return
            } catch {
                DohDebugLog.record(
                    "topic detail category metadata load failed: \(error.localizedDescription)",
                    subsystem: "Category"
                )
            }
        }
    }

    private func applyCategoryMetadata(_ categories: [DiscourseCategory], categoryId: Int) {
        guard topic?.categoryId == categoryId else { return }
        let index = DiscourseCategoryIndex(categories: categories, source: .site)
        guard let category = index[categoryId] else { return }
        let parent = category.parentCategoryId.flatMap { index[$0] }
        self.category = category
        categoryPresentation = TopicCategoryBadgePresentation.resolve(
            category: category,
            parent: parent,
            displayName: category.displayName(parent: parent),
            baseURL: api.baseURL
        )
        loadedCategoryMetadataId = categoryId
        notifyChanged()
    }

    func loadMorePosts(containerWidth: CGFloat) async {
        guard canLoadMore,
              TopicDetailPaginationPolicy.canStartMore(
                  isLoadingEarlier: isLoadingEarlier,
                  isLoadingMore: isLoadingMore,
                  isJumping: isJumping
              ),
              let topicId = topic?.id
        else { return }
        cancelForwardWindowPrefetch()
        isLoadingMore = true
        notifyChanged()

        let newEnd = min(loadedRangeEnd + TopicDetailPaginationPolicy.pageSize, allPostIds.count)
        let batch = Array(allPostIds[loadedRangeEnd..<newEnd])

        guard !batch.isEmpty else {
            isLoadingMore = false
            notifyChanged()
            return
        }

        do {
            guard try await fetchAndParsePosts(
                topicId: topicId,
                batch: batch,
                generation: parseGeneration
            ) else {
                isLoadingMore = false
                notifyChanged()
                return
            }
            loadedRangeEnd = newEnd
        } catch {
            // Silently fail; user can scroll again to retry
        }

        isLoadingMore = false
        notifyChanged()
    }

    @discardableResult
    func loadEarlierPosts(containerWidth: CGFloat) async -> Bool {
        guard canLoadEarlier,
              TopicDetailPaginationPolicy.canStartEarlier(
                  isLoadingEarlier: isLoadingEarlier,
                  isLoadingMore: isLoadingMore,
                  isJumping: isJumping
              ),
              let topicId = topic?.id
        else { return false }
        isLoadingEarlier = true
        notifyChanged()

        let newStart = max(0, loadedRangeStart - TopicDetailPaginationPolicy.pageSize)
        let batch = Array(allPostIds[newStart..<loadedRangeStart])

        guard !batch.isEmpty else {
            isLoadingEarlier = false
            notifyChanged()
            return true
        }

        do {
            let response = try await api.fetchTopicPosts(topicId: topicId, postIds: batch)
            let newPosts = response.postStream.posts.filter { !loadedPostIds.contains($0.id) }

            guard !newPosts.isEmpty else {
                for id in batch { loadedPostIds.insert(id) }
                loadedRangeStart = newStart
                isLoadingEarlier = false
                notifyChanged()
                return true
            }

            // Sort new posts by their order in allPostIds
            let sortedPosts = postsSortedByStream(newPosts)

            // Only skip index 0 when the real OP is intentionally pinned there.
            // Jump windows used to set firstPost = window head (e.g. #16), then this
            // path inserted floors 1…15 *after* #16 — "16 above 1". Never do that.
            let insertIndex: Int
            if let fp = firstPost,
               isRealOpeningPost(fp),
               posts.first?.id == fp.id,
               loadedRangeStart > 0 {
                insertIndex = 1
            } else {
                insertIndex = 0
            }
            topic?.postStream.posts.insert(contentsOf: sortedPosts, at: insertIndex)
            resortLoadedPostsByStreamOrder()

            for post in sortedPosts {
                loadedPostIds.insert(post.id)
            }
            // Refresh OP cache once stream head is actually loaded.
            if let headId = allPostIds.first,
               let head = topic?.postStream.posts.first(where: { $0.id == headId }) {
                firstPost = head
            }
            guard await parseAndStore(posts: sortedPosts, generation: parseGeneration) else {
                isLoadingEarlier = false
                notifyChanged()
                return true
            }

            loadedRangeStart = newStart
        } catch {
            // Silently fail; user can scroll again to retry
        }

        isLoadingEarlier = false
        notifyChanged()
        return true
    }

    func jumpToFloor(_ floor: Int, containerWidth: CGFloat) async {
        guard !allPostIds.isEmpty, let topicId = topic?.id else { return }

        let targetIndex = max(0, min(floor - 1, allPostIds.count - 1))
        let window = TopicDetailPaginationPolicy.jumpWindow(
            targetIndex: targetIndex,
            totalCount: allPostIds.count
        )
        let startIndex = window.lowerBound
        let endIndex = window.upperBound
        let batch = Array(allPostIds[window])

        guard !batch.isEmpty else { return }

        cancelForwardWindowPrefetch()
        isJumping = true
        jumpTargetFloor = floor
        pendingNewReplyCount = 0
        notifyChanged()

        // Clear current posts
        topic?.postStream.posts.removeAll()
        parsedBlocks.removeAll()
        unsupportedPostIds.removeAll()
        loadedPostIds.removeAll()
        firstPost = nil
        parseGeneration += 1
        let generation = parseGeneration
        // Jump replaces the flat window. Nested rows still point at the old tree; until
        // we re-parse, nested mode would filter every id out of the snapshot → white body.
        // Prefer showing the jumped flat window (notification / timeline deep-link).
        if isNestedViewEnabled {
            clearNestedState()
        }

        do {
            let response = try await api.fetchTopicPosts(topicId: topicId, postIds: batch)

            // Sort by stream order
            let sortedPosts = postsSortedByStream(response.postStream.posts)

            topic?.postStream.posts = sortedPosts
            // Only cache real OP. Falling back to sortedPosts.first made mid-thread
            // jump heads look "pinned", so load-earlier inserted lower floors after them.
            firstPost = sortedPosts.first(where: { isRealOpeningPost($0) })

            for post in sortedPosts {
                loadedPostIds.insert(post.id)
            }
            guard await parseAndStore(posts: sortedPosts, generation: generation) else {
                isJumping = false
                notifyChanged()
                return
            }

            loadedRangeStart = startIndex
            loadedRangeEnd = endIndex
            // User landed mid-thread; only ack up to what they can see in this window.
            acknowledgedStreamCount = max(acknowledgedStreamCount, endIndex)
            pendingNewReplyCount = max(0, allPostIds.count - max(acknowledgedStreamCount, endIndex))
        } catch {
            #if DEBUG
            print("[TopicDetail] Jump failed: \(error)")
            #endif
            errorMessage = error.localizedDescription
            jumpTargetFloor = nil
        }

        isJumping = false
        if isReady {
            // Force updateUI to re-run even if isReady was already true
            isReady = false
            isReady = true
        } else {
            isReady = true
        }
        notifyChanged()
        if errorMessage == nil {
            scheduleForwardWindowPrefetch(
                containerWidth: containerWidth,
                visibleStreamIndex: targetIndex
            )
        }
    }

    /// Updates reaction fields in place. Default skips `notifyChanged` so the VC can
    /// `reloadPostCell` only — avoids full snapshot + scroll chrome refresh on every like.
    func updatePostReaction(
        postId: Int,
        reactions: [DiscourseTopicDetail.Reaction],
        reactionUsersCount: Int?,
        currentUserReaction: DiscourseTopicDetail.Reaction?,
        notify: Bool = false
    ) {
        guard let index = topic?.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        topic?.postStream.posts[index].reactions = reactions
        topic?.postStream.posts[index].reactionUsersCount = reactionUsersCount ?? reactions.reduce(0) { $0 + $1.count }
        topic?.postStream.posts[index].currentUserReaction = currentUserReaction
        topic?.postStream.posts[index].currentUserUsedMainReaction = currentUserReaction?.id == "heart"
        if notify { notifyChanged() }
    }

    /// Updates bookmark fields in place. Default skips full UI notify; pair with `reloadPostCell`.
    func updatePostBookmark(postId: Int, bookmarked: Bool, bookmarkId: Int?, notify: Bool = false) {
        guard let index = topic?.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        topic?.postStream.posts[index].bookmarked = bookmarked
        topic?.postStream.posts[index].bookmarkId = bookmarked ? bookmarkId : nil
        if notify { notifyChanged() }
    }

    func updateSharedIssue(count: Int, userCreated: Bool) {
        topic?.sharedIssueCount = count
        topic?.userCreatedSharedIssue = userCreated
        notifyChanged()
    }

    func appendPostBoost(postId: Int, boost: DiscourseTopicDetail.Boost, notify: Bool = false) {
        guard let index = topic?.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        var boosts = topic?.postStream.posts[index].boosts ?? []
        if !boosts.contains(where: { $0.id == boost.id }) {
            boosts.append(boost)
        }
        topic?.postStream.posts[index].boosts = boosts
        // Only consume local canBoost when this boost is from the signed-in user
        // (MessageBus / other users' boosts must not hide the button).
        let me = AuthManager.shared.username(for: api.baseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fromMe = boost.user.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let me, !me.isEmpty, fromMe == me {
            topic?.postStream.posts[index].canBoost = false
        } else if boost.canDelete {
            // create response often marks own boost canDelete=true even if username missing
            topic?.postStream.posts[index].canBoost = false
        }
        if notify { notifyChanged() }
    }

    func updatePostBoost(postId: Int, boost: DiscourseTopicDetail.Boost, notify: Bool = false) {
        guard let index = topic?.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        var boosts = topic?.postStream.posts[index].boosts ?? []
        if let existing = boosts.firstIndex(where: { $0.id == boost.id }) {
            boosts[existing] = boost
        } else {
            boosts.append(boost)
        }
        topic?.postStream.posts[index].boosts = boosts
        if notify { notifyChanged() }
    }

    func removePostBoost(postId: Int, boostId: Int, notify: Bool = false) {
        guard let index = topic?.postStream.posts.firstIndex(where: { $0.id == postId }) else { return }
        var boosts = topic?.postStream.posts[index].boosts ?? []
        let removed = boosts.contains(where: { $0.id == boostId })
        boosts.removeAll { $0.id == boostId }
        topic?.postStream.posts[index].boosts = boosts
        if removed {
            // Deleting own boost typically restores ability to boost again.
            topic?.postStream.posts[index].canBoost = true
        }
        if notify { notifyChanged() }
    }

    func submitPollVote(postId: Int, pollName: String, optionIds: [String]) async throws {
        let voteResponse = try await api.votePoll(postId: postId, pollName: pollName, optionIds: optionIds)
        let submittedOptionIds = Set(optionIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        do {
            try await reloadPost(postId: postId)
        } catch {
            if applyPollVoteResponse(voteResponse, postId: postId, submittedOptionIds: submittedOptionIds) {
                notifyChanged()
                return
            }
            throw error
        }
        if applyPollVoteResponse(voteResponse, postId: postId, submittedOptionIds: submittedOptionIds) {
            notifyChanged()
        }
    }

    func reloadPost(postId: Int) async throws {
        guard let topicId = topic?.id else { return }
        let response = try await api.fetchTopicPosts(topicId: topicId, postIds: [postId])
        guard var updatedPost = response.postStream.posts.first(where: { $0.id == postId }) else { return }

        // `/posts` batch for a single id often omits boosts/can_boost — keep prior values (FluxDo).
        if let index = topic?.postStream.posts.firstIndex(where: { $0.id == postId }) {
            let old = topic!.postStream.posts[index]
            if updatedPost.boosts.isEmpty, !old.boosts.isEmpty {
                updatedPost.boosts = old.boosts
                updatedPost.canBoost = old.canBoost
            }
            topic?.postStream.posts[index] = updatedPost
        } else {
            topic?.postStream.posts.append(updatedPost)
        }
        loadedPostIds.insert(updatedPost.id)
        guard await parseAndStore(posts: [updatedPost], generation: parseGeneration) else { return }
        notifyChanged()
    }

    @discardableResult
    private func applyPollVoteResponse(
        _ voteResponse: DiscoursePollVoteResponse,
        postId: Int,
        submittedOptionIds: Set<String>
    ) -> Bool {
        guard let blocks = parsedBlocks[postId] else { return false }
        let result = TopicDetailPollResultMerger.merged(
            blocks,
            voteResponse: voteResponse,
            submittedOptionIds: submittedOptionIds
        )
        guard result.didChange else { return false }
        parsedBlocks[postId] = result.blocks
        return true
    }

    // MARK: - Private

    private static func isSystemActionPost(_ post: DiscourseTopicDetail.Post) -> Bool {
        normalizedActionCode(post.actionCode) != nil
    }

    private static func normalizedActionCode(_ actionCode: String?) -> String? {
        guard let actionCode = actionCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !actionCode.isEmpty
        else { return nil }
        return actionCode
    }

    /// Lightweight live sync: refresh `post_stream.stream` without wiping the page.
    /// - When `autoAppend` and the user is near the bottom, pull new posts in.
    /// - Otherwise surface `pendingNewReplyCount` so the UI can show a banner.
    @discardableResult
    func syncLiveTopicStream(autoAppend: Bool, containerWidth: CGFloat) async -> Int {
        guard isReady,
              !isLoading,
              !isJumping,
              !isSyncingStream,
              !isLoadingMore,
              !isLoadingEarlier,
              let topicId = topic?.id
        else { return pendingNewReplyCount }

        isSyncingStream = true
        defer {
            isSyncingStream = false
        }

        do {
            let detail = try await api.fetchTopic(id: topicId, trackVisit: false)
            let newStream = detail.postStream.stream ?? detail.postStream.posts.map(\.id)
            guard !newStream.isEmpty else {
                notifyChanged()
                return pendingNewReplyCount
            }

            let oldStream = allPostIds
            let oldCount = oldStream.count
            allPostIds = newStream

            // Preserve already-loaded post bodies; only extend the id stream.
            let growth = max(0, newStream.count - max(acknowledgedStreamCount, oldCount))
            let pureAppend = oldCount == 0
                || (oldCount <= newStream.count && Array(newStream.prefix(oldCount)) == oldStream)

            if pureAppend {
                // loadedRange* indices stay valid for the shared prefix.
                if loadedRangeEnd > newStream.count {
                    loadedRangeEnd = newStream.count
                }
            } else {
                // Stream reshuffled (rare). Keep loaded posts; remap range best-effort.
                if let firstLoaded = posts.first?.id,
                   let start = newStream.firstIndex(of: firstLoaded) {
                    loadedRangeStart = start
                } else {
                    loadedRangeStart = min(loadedRangeStart, max(newStream.count - 1, 0))
                }
                if let lastLoaded = posts.last?.id,
                   let end = newStream.firstIndex(of: lastLoaded) {
                    loadedRangeEnd = end + 1
                } else {
                    loadedRangeEnd = min(max(loadedRangeEnd, loadedRangeStart), newStream.count)
                }
                // Re-align in-memory bodies to the new stream so floors never invert.
                resortLoadedPostsByStreamOrder()
            }

            if growth <= 0 && newStream.count <= acknowledgedStreamCount {
                // No newly acknowledged tail growth.
                if pendingNewReplyCount != 0 && newStream.count <= acknowledgedStreamCount {
                    pendingNewReplyCount = 0
                    notifyChanged()
                }
                return pendingNewReplyCount
            }

            let unacked = max(0, newStream.count - acknowledgedStreamCount)
            if unacked == 0 {
                notifyChanged()
                return 0
            }

            if autoAppend {
                // User is following the tail — pull windows until we catch the stream end
                // or one page (avoid multi-page hoarding on a huge burst).
                var guardPages = 0
                while canLoadMore,
                      loadedRangeEnd < newStream.count,
                      guardPages < 2 {
                    let before = loadedRangeEnd
                    await loadMorePosts(containerWidth: containerWidth)
                    guardPages += 1
                    if loadedRangeEnd <= before { break }
                }
                acknowledgedStreamCount = allPostIds.count
                pendingNewReplyCount = max(0, allPostIds.count - loadedRangeEnd)
                // If fully caught up on loaded tail:
                if loadedRangeEnd >= allPostIds.count {
                    pendingNewReplyCount = 0
                }
                notifyChanged()
                return pendingNewReplyCount
            }

            pendingNewReplyCount = unacked
            notifyChanged()
            return pendingNewReplyCount
        } catch {
            #if DEBUG
            print("[TopicDetail] live sync failed: \(error)")
            #endif
            notifyChanged()
            return pendingNewReplyCount
        }
    }

    /// Load pending tail posts and return the 1-based floor of the first unacked post.
    @discardableResult
    func consumePendingNewReplies(containerWidth: CGFloat) async -> Int? {
        let startFloor: Int?
        if acknowledgedStreamCount < allPostIds.count {
            startFloor = acknowledgedStreamCount + 1
        } else if canLoadMore {
            startFloor = loadedRangeEnd + 1
        } else {
            startFloor = totalFloors > 0 ? totalFloors : nil
        }

        var guardPages = 0
        while canLoadMore, guardPages < 3 {
            let before = loadedRangeEnd
            await loadMorePosts(containerWidth: containerWidth)
            guardPages += 1
            if loadedRangeEnd <= before { break }
            if loadedRangeEnd >= allPostIds.count { break }
        }

        acknowledgedStreamCount = allPostIds.count
        pendingNewReplyCount = 0
        notifyChanged()
        return startFloor.map { min(max($0, 1), max(totalFloors, 1)) }
    }

    func acknowledgeVisibleTailIfNeeded(visibleStreamIndex: Int) {
        // When the user scrolls into the real tail, clear the banner.
        guard !allPostIds.isEmpty else { return }
        let tailStart = max(0, allPostIds.count - TopicDetailPaginationPolicy.liveSyncNearBottomRows)
        guard visibleStreamIndex >= tailStart else { return }
        guard loadedRangeEnd >= allPostIds.count else { return }
        if pendingNewReplyCount != 0 || acknowledgedStreamCount != allPostIds.count {
            pendingNewReplyCount = 0
            acknowledgedStreamCount = allPostIds.count
            notifyChanged()
        }
    }

    /// Keep about one page ahead of the visible stream index loaded+parsed.
    /// Does not chain through the whole topic — only fills up to `desiredLoadedEnd`.
    func ensureForwardWindowReady(visibleStreamIndex: Int, containerWidth: CGFloat) async {
        let desiredEnd = TopicDetailPaginationPolicy.desiredLoadedEnd(
            visibleStreamIndex: visibleStreamIndex,
            totalCount: allPostIds.count
        )
        guard loadedRangeEnd < desiredEnd else { return }
        await loadMorePosts(containerWidth: containerWidth)
    }

    func scheduleForwardWindowPrefetch(containerWidth: CGFloat, visibleStreamIndex: Int) {
        cancelForwardWindowPrefetch()
        guard canLoadMore else { return }
        let desiredEnd = TopicDetailPaginationPolicy.desiredLoadedEnd(
            visibleStreamIndex: visibleStreamIndex,
            totalCount: allPostIds.count
        )
        guard loadedRangeEnd < desiredEnd else { return }

        let width = containerWidth
        let index = visibleStreamIndex
        forwardPrefetchTask = Task { [weak self] in
            // Let first paint / snapshot apply win the run loop.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.ensureForwardWindowReady(
                visibleStreamIndex: index,
                containerWidth: width
            )
        }
    }

    func cancelForwardWindowPrefetch() {
        forwardPrefetchTask?.cancel()
        forwardPrefetchTask = nil
    }

    private func parseAndStore(posts: [DiscourseTopicDetail.Post], generation: Int) async -> Bool {
        let snapshots = posts.map { TopicDetailPostHTML(postId: $0.id, cooked: $0.cooked) }
        let baseURL = api.baseURL
        let parsedPosts = await TopicDetailHTMLParsing.parse(posts: snapshots, baseURL: baseURL)
        let postsById = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })

        guard generation == parseGeneration else { return false }
        for parsedPost in parsedPosts {
            let annotatedBlocks: [AnnotatedBlock]
            if let post = postsById[parsedPost.postId] {
                annotatedBlocks = TopicDetailPollResultMerger.mergeInitialPollState(
                    blocks: parsedPost.annotatedBlocks,
                    post: post
                )
            } else {
                annotatedBlocks = parsedPost.annotatedBlocks
            }
            parsedBlocks[parsedPost.postId] = annotatedBlocks
            if parsedPost.hasUnsupportedBlocks {
                unsupportedPostIds.insert(parsedPost.postId)
            } else {
                unsupportedPostIds.remove(parsedPost.postId)
            }
        }
        return true
    }
}
