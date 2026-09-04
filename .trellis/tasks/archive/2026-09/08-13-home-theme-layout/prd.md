# Home theme layout protocol for topic list and detail

## Goal

Home 话题列表走主题布局契约（同一 Home VC + 布局对象）。聊天式话题详情走父类 + 子类：父类管加载、分页、手势、ViewModel；`WeChatTopicDetailViewController` 与 `TelegramTopicDetailViewController` 实现主题方法。加聊天主题时主要新增子类并实现这些方法。

## Confirmed facts

- Home 是单一 `HomeViewController`，用 `homeListLayoutKind` / `AppSettings.themeStyle` 在 data source、snapshot、行高里 `switch`。
- 列表形态：`standard` / `eyeCare` 用 `TopicCell`；置顶用 `CompactPinnedTopicCell`；微信 `WeChatTopicListCell`；Telegram `TelegramTopicListCell`；小红书双列 `XiaohongshuTopicGridCell` + 负 id snapshot。
- `TopicListCellFactory` 已服务通知/历史/收藏等邻近列表，Home 自己的 cell provider 仍内联分支。
- 打开详情已走 `TopicDetailFactory.make`：`prefersChatTopicDetail` → `WeChatTopicDetailViewController`，否则 `TopicDetailViewController`。Home 入口：`openTopic`、通知 sheet、发帖成功回调。
- 微信和 Telegram 详情共用同一个聊天 VC，视觉差集中在 `ChatTopicStyle`，并由 `WeChatChatPostCell` / `WeChatChatInputBar` 读取 `ChatTopicStyle.current`。
- 经典 `TopicDetailViewController` 不按 weChat/telegram 分支，只吃 accent / 背景色。
- 换主题走 `handleSettingsChanged()` 原地刷新 Home；聊天详情若已打开，依赖 cell/input 再读 current style。

## Requirements

- Home 话题行的注册、行高、snapshot 行 id、dequeue/配置 Cell 由主题布局对象实现，Home VC 只调用契约方法。
- Home 打开话题详情走同一套主题入口（内部可委托 `TopicDetailFactory`），三处入口不再散落 `TopicDetailFactory.make`。
- 聊天详情抽出父类（现有 `WeChatTopicDetailViewController` 的生命周期），微信 / Telegram 子类实现画布、气泡、头像、输入栏、链接色等主题方法。
- 父类定义子类必须实现的方法；公共逻辑留在父类或共享 helper，供两个子类使用。
- `TopicDetailFactory` 按当前主题实例化对应聊天子类；经典 `TopicDetailViewController` 仍是另一条 factory 分支，不塞进聊天父类。
- 设置切换主题时，Home 在同一 VC 上换布局对象并刷新列表。
- 加一个聊天主题时，主要工作是新增详情子类并挂到 factory。

## Acceptance Criteria

- [ ] Home data source / snapshot 不再按 `themeStyle` / `homeListLayoutKind` 直接分支 Cell 类型。
- [ ] 存在聊天详情父类；微信与 Telegram 为子类，各自实现主题方法，父类无 `style == .telegram` 分支。
- [ ] `standard`、`eyeCare`、`xiaohongshu`、`weChat`、`telegram` 下列表外观、打开详情（经典 vs 聊天）、聊天气泡/输入栏与现状一致。
- [ ] 设置中切换主题后：Home 列表 Cell 类正确切换；**新打开**的详情走当前主题子类；已在栈上的聊天详情保持原生子类直到退出。
- [ ] Home 打开详情的三处入口（点话题、通知、发帖成功）都走同一契约方法。
- [ ] `is WeChatTopicDetailViewController` 类型判断改为聊天父类，覆盖两个子类（Cloudflare 刷新、返回手势、设置导航）。
- [ ] 编译：`xcodebuild build -workspace Doer.xcworkspace -scheme DoerTests -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`

## Out of scope

- 不把 Home 拆成 TelegramHomeViewController 等整页主题子类（列表用布局对象，详情才用 VC 子类）。
- 不在本任务重写分类抽屉、FAB、incoming 横幅、登录骨架等非话题行 chrome（除非契约必须碰行高/insets）。
- 不重写经典 `TopicDetailViewController` 的 native block 渲染结构。
- 不改通知/历史/收藏列表（它们已用 `TopicListCellFactory`）；后续可再让 factory 实现同一列表协议。

## Open questions

（无。已打开的详情保持当前子类，下次打开再换。）
