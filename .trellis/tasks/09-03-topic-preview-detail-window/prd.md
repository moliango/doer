# 长按预览小窗嵌 TopicDetail

## Goal

长按话题卡片打开一张放大的阅读卡：标题/作者沿用列表卡，正文用原生首帖渲染（图、代码、引用），不是塞进去的全屏 TopicDetail。预览是看主帖，点打开再进整帖。

## Confirmed facts

- 现有长按已离开 `UIContextMenu`，走自定义 overlay：卡片变形、点遮罩关闭、底部打开/书签/稍后。实现在 `TopicPreviewViewController` / `TopicPreviewMenu`。
- 窗口里的内容仍是敷衍卡：标题 + 纯文本摘录 + 统计，不是 TopicDetail。
- Fluxdo 的 `TopicPreviewDialog` 也不是嵌 `TopicDetailPage`，而是首帖 cooked HTML 紧凑渲染。本任务按产品要求超过 Fluxdo：嵌真实详情。
- 进帖入口是 `TopicDetailFactory.make(...)`（经典 / 微信 / Telegram 聊天气泡）。
- 回复入口：经典 `floatingReplyButton` + `presentReplyComposer`；聊天主题 `chatInputBar` + plus 全屏 composer。小窗全部不要。
- 现有长按入口：Home（含小红书双列）、搜索话题结果、稍后、历史。书签列表目前没有长按预览。

## Requirements

- 长按仍从卡片变形到居中小窗，关闭沿路径收回；点遮罩关闭。
- 小窗是阅读卡，不是 `TopicDetailFactory` 子页面。聊天主题也不改成气泡串。
- 正文用 `NativeContentRenderer` 渲染首帖 cooked HTML（图、代码、引用）。加载中用列表 excerpt。
- 不要回复栏、进度条、目录、整帖楼层。回复类操作关掉预览并打开全屏详情。
- 图片 Lightbox 盖在小窗上；点赞就地完成。
- 点头像、另一帖、分类、标签：关掉预览后在主栈打开。
- 底部保留现有预览动作：打开话题、书签、稍后阅读。点「打开」关闭小窗后走现有进帖路径。
- 覆盖现有长按入口：Home（含小红书双列）、搜索话题结果、稍后、历史。

## Acceptance Criteria

- [ ] 长按 Home 卡片：小窗是阅读卡（标题 + 元信息 + 原生首帖），不是纯文本摘录卡，也不是塞进去的 TopicDetail。
- [ ] 微信/Telegram 主题下仍是阅读卡，不是聊天气泡串。
- [ ] 小窗内看不到回复输入栏、悬浮回复按钮、composer、进度条。
- [ ] 点遮罩或关闭：小窗收回，列表仍在。
- [ ] 点「打开话题」：关闭小窗后进入全屏（或 iPad 分栏）TopicDetail，与直接点卡片进帖一致。
- [ ] 点头像或另一帖内链：关闭小窗后在主栈打开对应页。
- [ ] 搜索 / 稍后 / 历史 / 小红书双列同样是嵌详情的小窗，不是另一套摘录卡。

## Out of scope

- 把 Fluxdo `MorphingDialogShell` 原样搬进 iOS。
- 改全屏 TopicDetail 的进帖、分栏、图片 Hero。
- 预览里回帖、按住说话、快捷回复。
- 给书签列表新增长按（当前没有入口）。
- 预加载首帖 HTML（旧摘录路径删除，不必再维护）。
