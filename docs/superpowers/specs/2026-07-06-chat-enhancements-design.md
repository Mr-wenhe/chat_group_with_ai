# 聊天室增强功能设计文档

**日期**: 2026-07-06  
**项目**: chat_group — AI 群聊模拟器

---

## 1. @ 成员列表弹窗

### 目标
用户在输入框中输入 `@` 后，输入框上方弹出一个成员浮层，列出所有活跃 AI 角色，方便用户选择并自动填入 `@成员名 `。

### 实现方案
- 监听 `_textController` 的文本变化
- 检测当前光标前的最后一个 `@` 符号，提取 `@` 后的输入作为过滤关键词
- 用 `OverlayEntry` 在输入框上方渲染浮层
- 点击成员项 → 将 `@xxx` 替换为 `@成员名 `（带空格），光标移到末尾
- 点击浮层外部 / 发送消息 → 关闭浮层
- 无匹配成员时显示"无匹配角色"

### 边界处理
- 连续输入 `@@` 时，以最后一个 `@` 为准
- `@` 后无输入时显示全部成员
- 浮层超出屏幕时自动调整位置

---

## 2. AI 自主聊天

### 目标
聊天室中 AI 角色不需要用户触发即可自动发起和参与对话。

### 实现方案
- 页面加载后启动一个 `Timer.periodic`（间隔 5-8 秒随机）
- 每个活跃 AI 角色有 15-25% 的概率在本轮发起发言
- 发起的 AI 读取当前群聊上下文（最近 20 条消息），生成一条消息
- 其他符合条件的 AI 可以接力回复（每轮最多 2 个 AI 回复）
- 一轮对话结束后暂停 3-5 秒再进入下一轮
- 用户发送消息时打断当前计时器，用户消息处理完成后恢复
- 达到最大连续轮数（当前 `_maxAutoRounds = 3`）后暂停一段时间再重新开始

### 上下文构建
- 自主聊天时，上下文包含所有最近消息（不限 senderId），让 AI 能看到彼此的发言
- 区分 AI 间对话和用户对话，AI 发言使用不同的 system prompt 提示

---

## 3. @ 后强制回复机制

### 目标
被 @ 的 AI 角色必须回复，不能完全无视。

### 实现方案
- 当用户或 AI 消息包含 `@成员名` 时，解析被 @ 的 AI ID 列表
- 在 `_runAiRound` 中，优先选择被 @ 的 AI 角色参与本轮回复
- 如果被 @ 的 AI 因频率限制无法回复：
  - 随机选一个其他活跃 AI 代为回复："xxx 刚才没看到，我帮你@他一下"
  - 将被 @ 的 AI ID 加入"待回应队列"
- 在后续轮次的 AI 选择中，优先从"待回应队列"中选取角色
- 待回应队列最大长度为 3，超过时丢弃最早的

### 数据结构
- `_pendingMentionedIds: List<String>` — 存储被 @ 但尚未回应的 AI ID

---

## 4. 截图说明

截图是用户在模拟 AI 角色"肉圆"（初中生人设）在被 @ 时的回复策略分析，属于 prompt 设计参考。实现中不需要直接处理截图内容，相关人设策略会通过 `systemPrompt` 传递给 AI。

---

## 5. 用户消息颜色修正

### 问题
用户消息气泡背景色使用 `cs.primary`，文字色使用 `cs.onSurface`。当 primary 为深色时，`onSurface`（通常也是深色）对比度不足。

### 修复
- 用户消息文字色从 `cs.onSurface` 改为 `cs.onPrimary`
- 确保在 primary 背景上有正确的可读性对比度

### 修改位置
[chat_room_page.dart:631] 和 [chat_room_page.dart:645] 的 `_MessageBubble._buildContent` 方法中用户消息文字颜色

---

## 6. 整体架构变更

### 新增状态变量（`_ChatRoomPageState`）
```dart
// 成员选择浮层
OverlayEntry? _mentionOverlay;
bool _showMentionPopup = false;
List<AICharacter> _filteredMembers = [];

// AI 自主聊天
Timer? _autoChatTimer;
bool _isAutoChatEnabled = true;
final int _maxAutoChatRounds = 5;  // 自主聊天最大连续轮数

// 待回应 @ 列表
final List<String> _pendingMentionedIds = [];
```

### 新增方法
- `_handleTextChanged()` — 监听输入变化，检测 @ 触发浮层
- `_showMentionOverlay()` — 显示成员选择浮层
- `_hideMentionOverlay()` — 隐藏浮层
- `_insertMention(AICharacter)` — 插入 @ 成员到输入框
- `_startAutoChat()` — 启动 AI 自主聊天定时器
- `_stopAutoChat()` — 停止 AI 自主聊天定时器
- `_tryAutoChatRound()` — 尝试触发一轮 AI 自主对话
- `_parseMentions(String)` — 解析消息中的 @ 成员
- `_selectEligibleCharacter(List<String>? mentionedIds)` — 选择符合条件的回复者（优先选被@的）

### 修改方法
- `_buildInputArea()` — 添加文本变化监听
- `_sendMessage()` — 解析 @、触发强制回复逻辑、关闭浮层
- `_runAiRound({String? userMessage, bool isAutoChat = false})` — 添加 `isAutoChat` 参数区分上下文，支持 pending mention 优先
- `_buildApiMessages(character, context, userMessage, {bool isAutoChat = false})` — 添加 `isAutoChat` 参数，自主聊天时使用全部消息作为上下文
- `_MessageBubble._buildContent()` — 用户文字色修正

---

## 文件变更清单

| 文件 | 变更类型 | 描述 |
|------|---------|------|
| `lib/features/chat_group/chat_room_page.dart` | 修改 | 主要实现文件，涵盖全部 5 个功能点 |
