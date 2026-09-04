# 技术设计

- `DraftsViewController` 改为单一云端列表，移除 `ComposerLocalDraftStore.ListedDraft` 展示和打开分支；删除操作只调用云端 API。
- 三个 composer 取消正文本地 autosave，仅保留 2 秒云端 autosave和离开时云端保存。增加显式保存按钮，保存动作取消 debounce、执行一次云端 upsert，然后 dismiss。
- composer 增加 `discardDraftKey` / 保存与舍弃回调；舍弃动作调用 `clearServerDraft` 后 dismiss，并设置 `isDiscarding` 防止 `viewWillDisappear` 重存。
- 新主题云端草稿直接通过 `initialCategoryId` 与 `initialTags` 传入；由于 `DiscourseDraftData` 需要兼容 camelCase/snake_case、字符串数组及可能的单字符串 tags，补充稳健解码。
- 现有本地存储类型和 sequence 缓存 API 保留为兼容迁移代码，但不再被 composer 或草稿列表写入/读取用户内容。
