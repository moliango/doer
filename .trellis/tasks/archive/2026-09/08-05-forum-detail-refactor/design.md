# ForumDetail 大文件拆分 Design

## 总体设计
将**功能堆出来的上帝类**拆成**职责单一**的模块，引入 **Coordinator** 模式管理复杂 UI 页面的生命周期和交互。

## 1. TopicDetailViewController（1668 行）

### 核心职责（待拆）
- viewDidLoad / viewWillAppear / viewDidAppear / viewDidLayoutSubviews
- updateUI、applyThemeStyle、applyTypography、configureTitleLabel
- 数据源 + cell 配置 + height reconciliation
- 各种 action（reply、share、bookmark、export、notion、attachment）
- 通知/Cloudflare/readingTracker 等观察

### 推荐拆分
- **TopicDetailCoordinator**（550-650 行）：生命周期、子 VC 管理、通知路由、Cloudflare 观察、所有 action
- **TopicDetailViewModel**（扩充）：配置逻辑、状态、订阅
- **TopicDetailViewController**（700-750 行）：仅视图搭建 + 数据源 + layoutSubviews + 少数生命周期钩子

## 2. PostNativeCell（1188 行）

### 核心职责
- configure()、setupViews()、layoutSubviews()、heightReconciliation
- cardView、contentStack、avatar、reactions、boost 等布局

### 继续拆分
- PostNativeCell + PostContentRenderer（渲染层）
- PostNativeCell + PostActions（交互层）
- PostNativeCell + PostMedia（媒体处理层）

## 3. PluginCenterViewController（1262 行）

### 核心职责
- 拖拽排序列表 + 程序预览 + 分类管理 + 空态 + 共享 UI 原子

### 拆分
- PluginCenterViewModel（数据 + 拖拽排序）
- PluginCenterCoordinator（sheet 管理、导航）
- 剩下根容器 + 列表

## 4. ForumContainerViewController（1020 行）

### 核心职责
- 根容器、ForumTabBar 管理、登录态、Cloudflare、通知路由、auth gating

### 拆分
- ForumCoordinator（根容器生命周期、登录态、Cloudflare、通知路由）
- ForumContainerViewController（视图搭建 + tabBar 同步）

## 实施顺序
1. TopicDetailCoordinator + ViewModel 瘦身
2. PostNativeCell 三部分拆
3. PluginCenter 拆
4. ForumContainer 拆

**注意**：改完每个模块后必须跑 `make generate`，并 review 数据源回调和状态同步。
