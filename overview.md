# 群聊体验大修 — 9 项问题修复

## 修改文件
- `lib/features/chat_group/chat_room_page.dart`（主体改造）
- `lib/core/models/chat_group.dart`（新增 ownerName 字段）
- `lib/core/models/chat_group.g.dart`（同步 Hive adapter，向后兼容）

## 问题 → 修复对照

| # | 问题 | 修复方案 |
|---|------|----------|
| 1 | 输入框无法换行 | `TextInputAction.newline`，移动端回车=换行、发送按钮提交；桌面端 `KeyboardListener` 拦截 Enter 发送、Shift+Enter 换行 |
| 2 | @ 弹窗太小太丑 | 宽 220→300，头像 32→40，加「提到谁」标题栏，选中项高亮，键盘 ↑↓/Enter/Esc 导航 |
| 3 | 点击外部 @ 弹窗不消失 | `TapRegion(onTapOutside)` 包裹弹窗，点击任意外部即关闭 |
| 4 | 群里没人说话 | 全群未配 API 时不启动自动聊天；自动聊天概率 0.2→0.35 |
| 5 | 说"大家好"AI 不回复 | `_selectReplyCharacter` 返回 null 时不再静默，弹 SnackBar 提示 + 「去设置」按钮 |
| 6 | AI 不会自己聊天 | 同 #4；并新增顶部 API 未配置警告横幅 |
| 7 | 看不到成员列表 | AppBar 单图标 → 头像堆叠 chip（3 个重叠头像+人数），点击展开增强面板 |
| 8 | 没有群主 | `ChatGroup` 加 `ownerName`(`@HiveField(6)`)；成员面板群主置顶 + 「群主」标签 |
| 9 | 整体 UI 优化 | 空状态重做、消息日期分隔、成员面板拖动条/计数、输入框提示语 |

## 关键技术点
- **换行方案**：移动端 `TextInputAction.newline`（回车插入换行，发送靠按钮）；桌面端 `KeyboardListener` 共用 `_focusNode`，Enter 发送并 `return handled` 阻止换行，Shift+Enter 放行换行。
- **@ 弹窗外部关闭**：`TapRegion`（Flutter 3.3+，项目 3.24 支持）。
- **群主字段**：手动同步 `.g.dart`，read 时 `fields[6] ?? '我'`，write 时 `writeByte(7)`，旧 6 字段数据向后兼容。
- **API 检测**：`_loadData` 计算 `_hasAnyApiConfig`（任意角色有非空 apiKey），决定是否启动自动聊天 + 是否显示警告横幅。

## 验证
`flutter analyze lib` → **No issues found**（0 error / 0 warning）。

## 重要提示
AI 回复与自动聊天**依赖已配置 API Key**。当前数据中角色统一指向讯飞星火配置（cfg-6）。若未填 Key，应用会显示警告横幅但不会回复——这是预期行为，请到「设置」填入 Key 后即可正常对话。
