# 只看此人走 username_filters

## Goal

长帖里「只看此人 / 只看楼主」向服务端要这个人的楼，不再只滤已经加载的窗口。

## Confirmed Facts

- UI 已有：`filterUsername`、资料卡「只看此人」、只看楼主映射、与顶层/树形互斥、查找条。
- `visiblePosts` 客户端过滤。`fetchTopic` 只有 `track_visit`。
- FluxDO：`GET /t/{id}.json?username_filters=`。服务端恒留 1 楼；判断过滤是否生效时排除主贴。
- 进帖首屏并行 `by_number` + TopicView。过滤重拉不能和首屏抢同一代 `loadTopic`。

## Requirements

- 设置 `filterUsername` 后重拉 TopicView，带 `username_filters`。
- 清除过滤后重拉不带该参数，恢复全窗口。
- 只看楼主走同一参数（楼主用户名）。
- 服务端留下的 1 楼可以显示（与 FluxDO 一致）；客户端仍可按用户名滤展示，但数据源是过滤后的 TopicView。
- 打开话题默认进帖不带 `username_filters`，不拖慢首屏。
- 失败时保留已有楼，可见错误，不白屏。
- 经典与微信/电报详情同一套 ViewModel。

## Acceptance Criteria

- [x] 百楼帖只看某人：列表主要是该用户的楼（允许 1 楼留下）。
- [x] 取消筛选后能再看到其他人的已加载/新拉楼层。
- [x] 默认进帖首屏仍先出主贴，不因本任务变慢。
- [x] 与只看顶层、树形仍互斥。
- [x] 查找条在过滤后的楼里仍能跳。

## Out Of Scope

- 看图 Hero、预览变形、富文本。
- `filter_top_level_replies` 服务端化（已有客户端顶层过滤则保持现状，除非必须同请求互斥）。
