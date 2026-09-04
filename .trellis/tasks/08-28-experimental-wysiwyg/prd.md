# 实验性所见即所得编辑器

## Goal

现有 Aa/MD 编辑器不动。设置里加实验开关（默认关）。打开后，回复编辑器走另一套块级所见即所得内核：段落/标题/引用/列表/代码看得见样式，看不见源码标记。关掉或失败立刻回到现在的框。

## User Value

想试 FluxDO 那种「打字即排版」的人可以打开实验开关。不想试的人完全不受影响。

## Confirmed Facts

- 现有 composer：`UITextView` + `ComposerMarkdownCodec`（Aa 把 MD 画成 attributed string）+ MD 源码。粘贴、盘古、草稿、工具栏都认 raw Markdown。
- FluxDO：默认关的实验富文本；编辑器是块文档；进出口是 raw；cook 失败退纯文本。
- Doer 没有进程内 Discourse cook JS。第一期不用 cook，用本地 markdown 切块；进不了的语法整段当普通段落或源码块，不毁 raw。
- `composerInstantRender` 只是现有 Aa 框的重绘频率，不是新内核。

## Requirements

- 开关默认关，文案标明实验性。关着时回复/发帖/私信与现在字节级行为一致（现有 `UITextView` 路径一行不删）。
- 打开后回复编辑器替换正文输入面为块列表，不替换工具栏/上传/盘古/草稿/发送。
- 进出口仍是 raw Markdown。发送前若开了盘古，仍走 `ComposerPangu`。
- 第一期块：段落、标题 1–3、引用、无序/有序列表项、围栏代码。行内粗斜体仍可用现有 codec 在块内画出来。
- 投票、表格、宫格、policy 不在第一期孤岛化：导入时原样保留为 `literal` 块（等宽源码），导出不丢。
- 打不开实验内核（解析崩溃）→ 留在旧编辑器，不丢草稿。

## Acceptance Criteria

- [x] 默认关：回复编辑器仍是现在的 Aa/MD 框。
- [x] 设置里能打开「实验性所见即所得」；再开回复/发帖/私信，正文是块列表而不是整篇一个源码框。
- [x] 段落里打字看不见 `**` 仍能通过工具栏加粗；发出去是合法 `[b]`/`**` Markdown。
- [x] 标题/引用/列表/代码块有块级外观；导出能 round-trip 常见写法。
- [x] 含 `[poll]` 的草稿打开实验模式不丢投票 BBCode。
- [x] 关掉开关后再开回复，回到旧编辑器，草稿还在。
- [x] 中文输入法组合期间不把 attributed 回写成 markdown（光标不跳）。
- [x] 粘贴/上传图片后出现图片岛，焦点落在后面的可编辑段落。
- [x] 引用回复打开后是引用卡 + 下方可打字段落。
- [x] `tryLoad` 失败时撤掉实验视图，露出原来的 Aa/MD 框，草稿不丢。
## Out Of Scope

- Discourse 官方 cook JS、往返 cook 门禁。
- 投票 / onebox 作为可点选孤岛。图片岛与引用卡已在实验编辑器内实现。
- 发帖/私信第一期已同样走实验块编辑（开关关时仍是旧框）。
- 光标处显形（IR）模式。
- 改现有 `ComposerMarkdownCodec` 当唯一内核。

## Notes

- 2026-09-04：收尾见 `09-04-experimental-wysiwyg-closeout`（撤销、源码逃生、工具栏选中、投票替换当前块、图片/引用卡删除、跨块复制、预览焦点）。开关仍默认关。
