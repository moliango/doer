# 帖内查找

## Goal

长帖里能只看某个人，并能在帖内搜索结果之间上一条/下一条跳楼。

## Confirmed Facts

- 现有过滤：`isFilteringByOP`。
- 帖内搜索：`TopicDetailCoordinator.searchTopicTapped` 用 Alert 输入，ActionSheet 列出最多 12 条再跳。
- `DiscourseAPI.searchTopic` 已用 `topic:{id}` 查询。
- FluxDO：`username_filters`；资料卡/头像菜单可「只看此用户」；帖内查找条。

## Requirements

- 从资料卡或头像菜单可「只看此人」；再点一次或清除过滤器恢复全部。
- 只看楼主仍保留，并与「只看此人」互斥或合并为同一套 username 过滤。
- 帖内搜索改为话题内查找条（输入、结果数、上一条/下一条），不要 Alert + ActionSheet 两跳。
- 跳楼用 post id / post_number 现有 jump API，不把 post_number 当 stream 下标。
- 嵌套视图、微信/电报详情同样可用。

## Acceptance Criteria

- [x] 点某用户「只看此人」：列表主要是该用户的楼（允许主贴按服务端规则留下）。
- [x] 清除过滤后恢复全部楼层。
- [x] 帖内搜索：输入关键词后可在结果间前后跳，能落到对应楼。
- [x] 无结果、失败有明确空态/错误，不崩溃。
- [x] 现有只看楼主、只看顶层、树形楼仍可用。

## Out Of Scope

- 全站搜索改版。
- 文末相关帖、政策块。
