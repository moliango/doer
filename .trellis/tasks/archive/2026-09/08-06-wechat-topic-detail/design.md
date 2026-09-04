# Design — WeChat Chat Topic Detail

## Approach
Parallel surface (same pattern as `WeChatTopicListCell`):
- Factory selects VC by theme.
- New VC owns chat chrome; shares ViewModel/API.

## Components
```
TopicDetailFactory.make
  ├─ theme != weChat → TopicDetailViewController (unchanged)
  └─ theme == weChat → WeChatTopicDetailViewController
         ├─ UITableView + WeChatChatPostCell
         ├─ TopicDetailViewModel (load/parse/pagination)
         └─ long-press UIMenu → like/reply/bookmark/boost
```

## Action mapping
| Menu | Implementation |
|------|----------------|
| 点赞 | `api.toggleReaction(postId, "heart"|current)` + `viewModel.updatePostReaction` |
| 回复 | `ReplyComposerViewController(replyToPost:)` |
| 收藏 | `createBookmark` / `deleteBookmark` + `updatePostBookmark` |
| Boost | `BoostInputViewController` → `createBoost` |

## Non-goals in code
- Do not subclass/edit PostNativeCell footer for WeChat.
- Do not change classic bottom bar.
