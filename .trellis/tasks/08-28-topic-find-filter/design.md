# 帖内查找 — 设计

## 只看此人

`visiblePosts` 的 OP 过滤推广为 `filterUsername: String?`。`setFilteringByOP(true)` 设为 `opUsername`；资料卡/头像菜单「只看此人」设为该用户名。与顶层过滤、树形互斥（沿用现有 OP 过滤互斥）。清除过滤器把 `filterUsername` 置空。允许列表里留下 1 楼（与 FluxDO 服务端恒留主贴一致：客户端展示时若该用户不是楼主，仍可只显示该用户；1 楼是否留下：PRD 允许主贴按服务端规则留下——客户端先只滤 username 匹配，不额外强留 1 楼，除非当前过滤就是楼主）。

不在本任务重拉 `username_filters` TopicView，除非已加载窗口里一个人都没有；先做已加载楼层的客户端过滤，避免和进帖首屏抢 `loadTopic`。

## 查找条

替换 Alert + ActionSheet：话题内一条查找栏（输入、结果计数、上一条/下一条、关闭）。仍用 `searchTopic`。结果用 post id / post_number 现有 jump。无结果/失败有文案。经典与 Chat 详情都要有入口。

## 测试

- filterUsername 与 OP 过滤互斥的纯函数或 ViewModel 可测逻辑
- 查找结果导航索引环绕/边界
