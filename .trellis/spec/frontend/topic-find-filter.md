# Topic Find & Author Filter

> In-topic find bar and “only this user” filter.
> Learned 2026-08-28 (`08-28-topic-find-filter`, `08-28-username-filters`).

## Scenario: Client-side username filter + in-topic find bar

### 1. Scope / Trigger

- Trigger: filtering posts by author or searching inside an open topic.
- Surfaces: classic `TopicDetailViewController`, `ChatTopicDetailViewController` (WeChat/Telegram subclasses). User card: `UserProfilePreviewViewController`.
- First-paint `loadTopic` / `by_number` must omit `username_filters`. After `isReady`, `setFilterUsername` / clear reloads TopicView with `GET /t/{id}.json?username_filters=`. Client `visiblePosts` still hides floor 1 when the OP is not the filtered user.
- Switching to 「只看顶层」 while a username filter is active reloads unfiltered TopicView (top-level stays client-side). Switching to nested defers that unfiltered reload until nested is off.

### 2. Signatures

```swift
enum TopicFindFilterPolicy {
    static func visiblePosts(_ posts: [Post], filterUsername: String?) -> [Post]
    static func wrappedIndex(current: Int, count: Int, delta: Int) -> Int
}

class TopicDetailViewModel {
    var filterUsername: String?
    func setFilteringByOP(_ on: Bool) // maps to op username or clears
    func reloadForUsernameFilter() // TopicView with username_filters; nil clears query
}

DiscourseRouter.topic(id:trackVisit:usernameFilters:)
DiscourseAPI.fetchTopic(id:trackVisit:usernameFilters:)

class TopicFindBarView: UIView {
    // query, result count, prev/next, close, empty/error copy
}
```

Jump: existing post-id / `post_number` APIs. Search still uses `DiscourseAPI.searchTopic` (`topic:{id}`).

### 3. Contracts

| Action | Result |
|--------|--------|
| User card 「只看此人」 | `filterUsername = that username`; list is `visiblePosts` |
| Same user again or 「取消筛选」 | `filterUsername = nil`; refetch TopicView without `username_filters` |
| 「只看楼主」 | `filterUsername = opUsername` (same field, not a second flag) |
| Username filter vs top-level / nested | Mutually exclusive, same as former OP filter |
| Non-OP username filter | Do not force-keep floor 1 |
| Empty snapshot fallback | Use filtered `visiblePosts`, never the unfiltered stream |
| Find bar | Replaces Alert + ActionSheet; input, count, prev/next, close |
| Jump | Post id first, else `post_number`; never treat `post_number` as stream index. Chat in-topic links/quotes/open must call `jumpToPostNumber`, not `jumpToFloor`. Opening at floor 1 / OP / `last_read <= 1` is `.top` — do not `scrollToRow` the first cell (that hides the title and looks like a jump to 1层). |
| No hits / search fail | Copy, no crash |

Replies-list sheet user card does not need 「只看此人」. Chat floor numbers may still use stream index while filtered; classic re-numbers.

### 4. Validation & Error Matrix

| Condition | Result |
|-----------|--------|
| Filter user with no loaded posts | Empty list / empty snapshot of filtered posts |
| Clear filter | Refetch TopicView without `username_filters`; keep old posts if the fetch fails |
| Find wrap at ends | `TopicFindFilterPolicy.wrappedIndex` |
| Search network error | Error copy on the bar |

### 5. Good / Base / Bad Cases

- Good: tap avatar → 「只看此人」 → TopicView reload with `username_filters`; list is that author (plus server-kept floor 1, then client-hidden if OP is someone else). Clear refetches the full window.
- Base: find “foo” → 3 hits → next/prev lands on the matching post id.
- Bad: `username_filters` on the same `loadTopic` that first-paint is using for by_number OP.

### 6. Tests Required

- `TopicFindFilterTests`: username match, OP mapping exclusivity with top-level/nested, wrap index.
- Compile-only UI check unless the owner asks to boot Simulator.

### 7. Wrong vs Correct

#### Wrong

```swift
searchTopicTapped() // UIAlertController then ActionSheet of 12 hits
jump(to: post.postNumber) // treating Discourse floor as table index
```

#### Correct

```swift
findBar.show()
jumpToPost(id: hit.postId, postNumber: hit.postNumber)
```
