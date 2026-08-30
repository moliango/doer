# 所见即所得富文本编辑器

## Goal

回复、发帖、私信可在富文本和源码间切换；预览与发出去一致。

## Acceptance Criteria

- [x] 三处编辑器可切 Aa / MD，可切回源码。
- [ ] **未对齐 FluxDO**：所见即所得块编辑（fluxdo_render IR/WYSIWYG、cook 导入、图片岛、引用卡）。
- [x] 发送内容仍是 Discourse Markdown/cooked 可接受的 raw。
- [x] 粘贴出图、盘古在 Aa 路径仍有效。
- [x] 私信也有预览，不再只有纯源码。

## Out Of Scope

- 完整桌面级 WYSIWYG 插件生态。

## Notes

- 2026-08-28：本轮只补了私信预览。Aa 模式是 `ComposerMarkdownCodec` 把 markdown 画成 `NSAttributedString`，不是 FluxDO 的富文本内核。对照表保持「部分」，不算对齐。
