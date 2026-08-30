# Design: experimental WYSIWYG composer

## Boundaries

- **Keep**: `ReplyComposerViewController` 的 `textView` 路径、`ComposerSharedCore`、粘贴/上传、盘古、草稿。
- **Add**: `Doer/Features/ForumDetail/TopicDetail/ExperimentalComposer/` 新模块。开关在 `AppSettings.experimentalRichComposerEnabled`（默认 false）。
- **Host**: 仅 `ReplyComposerViewController` 在开关打开时把正文区域换成 `ExperimentalComposerView`。`textView` 隐藏但保留在层级外或卸载约束，不走 delegate。

## Document

```swift
enum ExperimentalComposerBlock: Equatable {
    case paragraph(String)           // markdown inlines, no wrapping fences
    case heading(Int, String)        // 1...3
    case quote(String)
    case listItem(ordered: Bool, text: String)
    case code(language: String, code: String)
    case literal(String)             // poll / table / unmatched — round-trip raw
}

struct ExperimentalComposerDocument {
    var blocks: [ExperimentalComposerBlock]
    var markdown: String { serialize }
    static func parse(_ markdown: String) -> ExperimentalComposerDocument
}
```

Parse: fence 优先；`[poll]`…`[/poll]` 整段 literal；其余按行识别 heading/quote/list；连续普通行合成 paragraph。

Serialize: 块之间空行（list 项之间单换行）。literal 原样输出。

## View

`ExperimentalComposerView`: `UIScrollView` + `UIStackView`。每块一个 `ExperimentalComposerBlockView`（`UITextView`）。

- paragraph/heading/quote/list：显示用 `ComposerMarkdownCodec.richAttributedString`；回写用 `markdown(from:)`。
- code/literal：等宽，不跑 codec。
- Return 在空段落：插入新 paragraph 块并 focus。
- 工具栏 `composerInsertRaw` / `composerWrapSelection`：作用在当前 firstResponder 块。

## Data flow

```
raw (draft) → parse → blocks → views
edit view → markdown(from block) → document.markdown
send/preview/pangu → document.markdown → 旧路径
```

## Compatibility

- 开关 false：零调用新类型。
- 开关 true 但 `parse` 后 empty 且原文非空：仍展示一个 literal 块，避免空白。
- 不改 `ComposerEditingMode.stored`。实验模式下隐藏 Aa/MD（始终视觉块）。

## Rollback

删设置项 + Reply 里的 `if experimental` 分支 + 新目录。旧 composer 无依赖。

## Cook later

第二期才加 cook JS 和编辑已有帖门禁。第一期不改已发布帖的编辑入口也可以（回复新内容为主）。
