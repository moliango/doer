# 聊天单独成底栏 Tab

## Goal

站内聊天成为论坛底栏的可选项：默认显示，可在底栏设置里取消。不与私信合并。

## User Value

不用进「我的」就能打开频道列表。不想要的人可以在设置里拿掉。

## Confirmed Facts

- 论坛底栏是 `ForumTabBarController`：首页固定、最多 3 个动态项、我的固定。
- 动态项来自 `AppSettings.ForumDynamicTabItem`：history / search / notifications / messages / bookmarks。聊天不在其中。
- 底栏设置 `BottomBarLayoutViewController` 用 `allCases` 列出可添加 / 可取消。
- 聊天页已是 `ChatChannelsViewController`；进房间 `hidesBottomBarWhenPushed = true`。
- 未读角标现在打在「我的」Tab 上（`ForumTabBarController.applyChatTabBadge` + `MeViewController.applyChatTabBadge`）。
- 「我的」账号功能里已有聊天入口，保留。
- 未改过底栏的用户读 `defaultForumDynamicTabItems`；改过的用户读已存 `forumDynamicTabItemIds`。

## Requirements

- `ForumDynamicTabItem` 增加 `chat`，标题用现有 `chat.title`。
- 底栏设置可添加、排序、取消聊天，规则与其他动态项相同（最多 5 候选、前 3 显示）。
- 默认动态项改为：历史、通知、聊天。书签仍可添加。已自定义底栏的用户不强制插入。
- 聊天 Tab 根页是现有 `ChatChannelsViewController`，不重做列表。
- 聊天 Tab 在底栏上时，未读角标打在聊天 Tab；取消后回到「我的」。
- 「我的」里点聊天：若底栏正在显示聊天 Tab，切过去；否则仍 push 频道列表。
- 私信 Tab、聊天页、Me 聊天行都不合并。

## Acceptance Criteria

- [x] 未改过底栏：论坛底栏是首页 + 历史 + 通知 + 聊天 + 我的。
- [x] 设置 → 底栏：聊天可从「显示」里减掉，减掉后底栏不再出现；可从「可添加」加回来。
- [x] 已自定义底栏且列表里没有聊天：聊天出现在「可添加」，不自动改现有三项。
- [x] 聊天 Tab 打开频道列表；进房间后底栏隐藏。
- [x] 有未读且聊天 Tab 可见：角标在聊天，不在「我的」。取消聊天 Tab 后角标回到「我的」。
- [x] 「我的」聊天入口仍在；聊天 Tab 可见时点它切到底栏聊天，不在「我的」栈再 push 一层。

## Out Of Scope

- 私信 + 聊天合成一个收件箱。
- 改 App 根 Tab（论坛列表 / 设置）。
- 扫码登录、悬浮胶囊底栏。
- 重做聊天 UI。
