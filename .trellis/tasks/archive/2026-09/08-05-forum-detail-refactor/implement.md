# ForumDetail 大文件拆分 Implementation Plan

## 优先级顺序
1. TopicDetail（Coordinator + ViewModel 瘦身）
2. PostNativeCell（三部分拆）
3. PluginCenter
4. ForumContainer

## 预计工作量
- TopicDetail：3-4 天
- PostNativeCell：1-2 天
- PluginCenter：1 天
- ForumContainer：1 天

## 验证方式
- 改完每个模块后跑 `make generate`
- 重点 review：数据源回调、状态同步、Coordinator 注入

## 后续步骤
1. 创建 TopicDetailCoordinator.swift
2. 把 TopicDetailViewController 核心逻辑迁移
3. 逐步瘦身主文件
