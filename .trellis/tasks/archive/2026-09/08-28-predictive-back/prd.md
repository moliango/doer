# 预测式返回手势

## Goal

话题/查看器返回可跟手；能和看图 Hero 配对飞回（系统能力范围内）。

## Acceptance Criteria

- [ ] 详情页返回手势跟手缩放/位移，松手可取消。
- [x] 若 Hero 已落地，关闭查看器可配对飞回。
- [x] iOS 15 至少保留边缘返回，不崩溃。
- [x] 表情面板等需挡手势的场景不误关。

## Notes

- 2026-08-28：自定义 `TopicDetailInteractivePopController` 左滑有问题，已撤回。话题/聊天详情改回系统 `interactivePopGestureRecognizer`（与改之前一致）。看图 Hero 飞回未撤。

## Out Of Scope

- 改 iOS 系统全局 Predictive Back 开关。
