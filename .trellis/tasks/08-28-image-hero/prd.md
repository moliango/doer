# 看图从缩略图飞入

## Goal

点正文/宫格图从缩略图飞到全屏，关掉飞回原位。已有下滑关闭保留。

## Acceptance Criteria

- [x] 打开查看器有从源图框到全屏的过渡。
- [x] 关闭（按钮或下滑完成）飞回源位置；源 cell 已滚走则淡出。
- [x] Reduce Motion 时无飞入，仍能打开/关闭。
- [x] 不恢复 `queryDiskDataSync`；不回退 ImagePaintPolicy。

## Out Of Scope

- 预测式返回配对（`08-28-predictive-back`）。
