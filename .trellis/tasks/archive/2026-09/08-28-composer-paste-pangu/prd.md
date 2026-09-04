# 回复粘贴与盘古

## Goal

回复/发帖/私信编辑器支持粘贴图片并上传；发出去的中英文之间有空格。

## Confirmed Facts

- 三个编辑器已共用字号/字体（`ComposerTypography`）。
- 工程内没有盘古实现，没有 `UIPasteboard` 图片上传到 composer。
- FluxDO：剪贴板转 PNG 上传；`autoPanguSpacing` 默认关，工具栏可手动盘古。

## Requirements

- 在回复、发帖、私信源码/富文本框中粘贴图片：上传并插入 Discourse 图片 Markdown，失败有可见错误。
- 走现有上传与 Cloudflare/Cookie session，不新开登录。
- 发送前对正文做盘古（中英文/数字边界加空格），不破坏代码块、行内 code、URL、已有空格。
- 预览与发出去的帖都带盘古后的文本。
- 用户可见开关：设置里可关盘古；默认开（面向中文社区）。

## Acceptance Criteria

- [x] 粘贴相册/截图：编辑器出现上传中 → 成功后是 `![...](url)` 或等价富文本图。
- [x] 粘贴失败（无网/CF）：不插入坏链，有错误提示。
- [x] `中文english中文` 发送后为 `中文 english 中文`；代码块内不插空格。
- [x] 关闭盘古设置后发送不再改空格。
- [x] 回复、发帖、私信三处行为一致。

## Out Of Scope

- 按住说话、编辑器内建投票、完整 WYSIWYG 重写。
