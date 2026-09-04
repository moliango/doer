# 回复粘贴与盘古 — 设计

## 粘贴出图

三个编辑器共用 `ComposerTextSurface` + `ComposerSharedCore.uploadPickedFiles`。在共享 `UITextView` 上拦截图片粘贴（剪贴板 `hasImages` / `image`）：写成临时 JPEG/PNG，走现有 `uploadComposerFile`，插入返回的 markdown。失败用现有 `presentUploadError`，不插入坏链。纯文本粘贴保持系统默认。

不要为每个 composer 复制上传逻辑。Chat 房间另有 `ChatRoomComposerActions`；本任务范围是回复/发帖/私信三个论坛编辑器。

## 盘古

独立纯函数 `ComposerPangu.spacing(_:)`：先抽出围栏代码、行内 code、URL，再在 CJK 与拉丁字母/数字边界插入空格（已有空格不重复）。发送前若 `AppSettings.autoPanguSpacing`（默认 true）则处理 raw；预览走同一 raw。设置放在「功能设置」基础分组。关闭后发送不再改空格。

## 测试

- `中文english中文` → `中文 english 中文`
- 围栏/行内 code、http URL 内部不插空格
- 已有空格不加倍
