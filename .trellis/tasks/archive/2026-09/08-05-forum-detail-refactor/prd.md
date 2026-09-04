# ForumDetail 大文件拆分 PRD

## 背景
ForumDetail 模块过重（53k 行），其中：
- TopicDetailViewController 1668 行（最大黑洞）
- PostNativeCell 1188 行
- PluginCenterViewController 1262 行
- ForumContainerViewController 1020 行

目标是把这些**上帝类**拆成可测、可读、可维护的结构，降低后续改动风险。

## 拆分目标
1. TopicDetailViewController → TopicDetailCoordinator + TopicDetailViewModel + TopicDetailViewController
2. PostNativeCell → PostNativeCell + PostContentRenderer + PostActions + PostMedia
3. PluginCenterViewController → PluginCenterViewModel + PluginCenterCoordinator + PluginCenterViewController
4. ForumContainerViewController → ForumCoordinator + ForumContainerViewController

## 验收标准
- 主文件行数显著下降（TopicDetail 目标 700-750 行）
- 每个模块职责单一、边界清晰
- 改完后 `make generate` 能编译通过
- 单元测试覆盖关键路径（如果已有）

## 拆分原则
- 优先级：TopicDetail > PostNativeCell > PluginCenter > ForumContainer
- 改完后必须跑 `make generate`
- 改完后重点 review：数据源回调、状态同步、Coordinator 注入
