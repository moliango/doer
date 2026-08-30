# 主路径体感 — 总体设计

## 设计原则

1. **行为优先于抽象**：先修用户能感到的闪、等、空，再谈主题协议。
2. **一条路径一个主人**：启动 overlay 只在 `ForumContainerViewController`；进帖首屏策略只在 TopicDetail 加载路径；图片占位策略只在共用 loader。
3. **对照 FluxDO 抄行为**：`posts#by_number`、粘贴出图、盘古、`username_filters`、帖内查找条。UI 用现有 UIKit 主题，不搬 Flutter。
4. **子任务不互改同一热点文件的同一函数**，除非 implement.md 写明顺序。

## 边界

```
启动 overlay (A)
   │
   ▼
Home 列表 ──图片 loader (C)──► 话题详情首屏 (B)
                                 │
                                 ├── 看图关闭 (C)
                                 ├── 回复编辑器 (D)
                                 └── 帖内过滤/搜索 (E)
```

A 不碰 TopicDetail。B 可以新增 by_number 调用，但不改图片 cell 绑定（留给 C）。D 只改 composer。E 改详情过滤/搜索入口。

## 风险

| 风险 | 缓解 |
|------|------|
| 启动页无法读取 AppSettings 主题 | 系统启动页跟系统浅色/深色；overlay 在 `applyAppearance` 之后立刻铺主题色 |
| by_number 与 TopicView 字段不一致 | OP cooked 用 by_number，stream/权限仍用 TopicView；失败则回退现有 fetchTopic |
| 粘贴图片走 CF | 复用现有上传与 Cloudflare 门闸，不新开 session |
| username_filters 仍带回 1 楼 | 与 FluxDO 一样：服务端恒留主贴，客户端再滤展示 |

## 回滚

每个子任务单独 commit。父任务不混进一个巨型 diff。失败则回滚该子任务 commit，不影响已落地的前一项。
