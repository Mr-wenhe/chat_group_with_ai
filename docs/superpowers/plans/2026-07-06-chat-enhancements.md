# 聊天室增强功能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在聊天室页面实现 @ 成员列表弹窗、AI 自主聊天、@ 强制回复、用户消息颜色修正共 4 项增强功能

**Architecture:** 所有变更集中在 `chat_room_page.dart` 一个文件中，通过新增状态变量和方法扩展现有逻辑。@ 弹窗用 OverlayEntry，AI 自主聊天用 Timer.periodic，强制回复用待回应队列。

**Tech Stack:** Flutter 3.x, Riverpod, Hive, OverlayEntry

## Global Constraints

- SDK 版本: `^3.6.0-134.0.dev`
- 不新增依赖包
- 修改文件仅限 `lib/features/chat_group/chat_room_page.dart`
- 保持现有代码风格和命名约定

---

### Task 1: 新增状态变量与辅助方法

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart:23-38`

**Interfaces:**
- Consumes: 现有 `_ChatRoomPageState` 字段
- Produces: 新增状态变量和辅助方法，为后续任务提供基础设施

```dart
// 在 _ChatRoomPageState 类中，initState 之前添加：

// @ 成员选择弹窗
OverlayEntry? _mentionOverlay;
bool _showMentionPopup = false;
List<AICharacter> _filteredMentionMembers = [];
final LayerLink _mentionLayerLink = LayerLink();

// AI 自主聊天
Timer? _autoChatTimer;
bool _isAutoChatEnabled = true;
int _autoChatRoundCount = 0;
final int _maxAutoChatRounds = 5;
final Random _autoChatRandom = Random();

// 待回应 @ 列表
final List<String> _pendingMentionedIds = [];

// 在 _ChatRoomPageState.dispose 中添加清理：
@override
void dispose() {
  _textController.dispose();
  _scrollController.dispose();
  _autoChatTimer?.cancel();
  _hideMentionOverlay();
  super.dispose();
}

// 在 _delay() 方法之后添加辅助方法：

/// 解析消息内容中的 @成员名，返回被 @ 的 AI ID 列表
List<String> _parseMentions(String content) {
  final mentionedIds = <String>[];
  // 匹配中文名 @某人
  final chinesePattern = RegExp(r'@([一-鿿]{1,10})');
  for (final match in chinesePattern.allMatches(content)) {
    final name = match.group(1)!;
    final found = _characters.isNotEmpty ? _characters.firstWhere((c) => c.name == name) : null;
    if (found != null) {
      mentionedIds.add(found.id);
    }
  }
  // 处理英文字符名
  final englishPattern = RegExp(r'@(\w+)');
  for (final match of englishPattern.allMatches(content)) {
    final name = match.group(1)!;
    final found = _characters.isNotEmpty ? _characters.firstWhere((c) => c.name == name) : null;
    if (found != null) {
      mentionedIds.add(found.id);
    }
  }
  return mentionedIds;
}

/// 选择回复者：优先选被 @ 且符合条件的角色
AICharacter? _selectReplyCharacter(List<String>? mentionedIds) {
  final eligible = _characters.where(_isEligibleToReply).toList();
  if (eligible.isEmpty) return null;

  // 优先选被 @ 的角色
  if (mentionedIds != null && mentionedIds.isNotEmpty) {
    final priorityChars = eligible.where((c) => mentionedIds.contains(c.id)).toList();
    if (priorityChars.isNotEmpty) {
      return _shuffle(priorityChars).first;
    }
  }

  // 其次选待回应队列中的角色
  if (_pendingMentionedIds.isNotEmpty) {
    final pendingEligible = eligible.where((c) => _pendingMentionedIds.contains(c.id)).toList();
    if (pendingEligible.isNotEmpty) {
      return _shuffle(pendingEligible).first;
    }
  }

  // 最后随机选
  return _shuffle(eligible).first;
}
```

**Note:** 使用 `firstWhere(..., orElse: () => ...)` 模式查找角色，已全部替换为项目现有写法。

- [ ] Step 1: 在 `_ChatRoomPageState` 中添加新的状态变量
- [ ] Step 2: 在 `dispose()` 中添加 `_autoChatTimer?.cancel()` 和 `_hideMentionOverlay()` 清理
- [ ] Step 3: 添加 `_parseMentions` 方法
- [ ] Step 4: 添加 `_selectReplyCharacter` 方法
- [ ] Step 5: 验证 `flutter analyze` 无错误

---

### Task 2: 实现 @ 成员列表弹窗

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart`

**Interfaces:**
- Consumes: `_characters`, `_textController`
- Produces: `_showMentionOverlay`, `_hideMentionOverlay`, `_insertMention`, `_handleTextChanged`

```dart
// 添加以下方法到 _ChatRoomPageState 中：

void _showMentionOverlay(Offset globalPosition) {
  if (_showMentionPopup) return;
  _showMentionPopup = true;

  _mentionOverlay = OverlayEntry(
    builder: (context) {
      final cs = Theme.of(context).colorScheme;
      return Positioned(
        width: 220,
        child: CompositedTransformFollower(
          link: _mentionLayerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, -8),
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(12),
            color: cs.surface,
            child: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              child: _filteredMentionMembers.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('无匹配角色', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filteredMentionMembers.length,
                      itemBuilder: (ctx, i) {
                        final c = _filteredMentionMembers[i];
                        final pColor = _senderColor(c);
                        return InkWell(
                          onTap: () => _insertMention(c),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              children: [
                                Container(
                                  width: 32, height: 32,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: pColor.withOpacity(0.12),
                                  ),
                                  child: Center(
                                    child: Text(c.avatar.isNotEmpty ? c.avatar : c.name[0],
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pColor)),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(c.name,
                                    style: TextStyle(fontSize: 14, color: cs.onSurface),
                                    overflow: TextOverflow.ellipsis),
                                ),
                                Text('${c.role}', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ),
      ),
    },
  );

  // 找到 Overlay 并插入
  final overlay = Overlay.of(context);
  overlay.insert(_mentionOverlay!);
}

void _hideMentionOverlay() {
  _mentionOverlay?.remove();
  _mentionOverlay = null;
  _showMentionPopup = false;
  _filteredMentionMembers = [];
}

void _insertMention(AICharacter character) {
  final text = _textController.text;
  final cursorPos = _textController.selection.baseOffset;

  // 找到光标前的最后一个 @ 的位置
  int atPos = text.lastIndexOf('@', cursorPos - 1);
  if (atPos < 0) atPos = 0;

  final newText = text.substring(0, atPos) + '@${character.name} ' + text.substring(cursorPos);
  _textController.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: atPos + character.name.length + 2),
  );

  _hideMentionOverlay();
}

void _handleTextChanged(String text) {
  if (!_showMentionPopup) {
    // 检测是否刚输入了 @
    if (text.contains('@')) {
      _filteredMentionMembers = List.from(_characters);
      _showMentionOverlay(Offset.zero);
      return;
    }
    return;
  }

  // 浮层已显示，检测过滤
  final cursorPos = _textController.selection.baseOffset;
  final textBeforeCursor = text.substring(0, cursorPos);
  final atIndex = textBeforeCursor.lastIndexOf('@');

  if (atIndex < 0) {
    _hideMentionOverlay();
    return;
  }

  final query = textBeforeCursor.substring(atIndex + 1);
  if (query.contains(' ')) {
    _hideMentionOverlay();
    return;
  }

  _filteredMentionMembers = query.isEmpty
      ? List.from(_characters)
      : _characters.where((c) => c.name.contains(query)).toList();

  // 如果浮层已存在，刷新
  if (_mentionOverlay != null) {
    _mentionOverlay!.markNeedsBuild();
  }
}
```

**修改输入区域：**

```dart
// _buildInputArea 中 TextField 的 onChanged 添加：
onChanged: _handleTextChanged,
```

```dart
// _sendMessage 开头添加关闭浮层：
_hideMentionOverlay();
```

- [ ] Step 1: 添加 `_showMentionOverlay` 方法
- [ ] Step 2: 添加 `_hideMentionOverlay` 方法
- [ ] Step 3: 添加 `_insertMention` 方法
- [ ] Step 4: 添加 `_handleTextChanged` 方法
- [ ] Step 5: 在 `TextField` 的 `onChanged` 中调用 `_handleTextChanged`
- [ ] Step 6: 在 `_sendMessage` 开头添加 `_hideMentionOverlay()`
- [ ] Step 7: 在 `dispose()` 中添加清理代码
- [ ] Step 8: 在输入框外层添加 `CompositedTransformTarget(link: _mentionLayerLink, child: ...)` 包裹 TextField 的 Row

---

### Task 3: 实现 AI 自主聊天

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart`

**Interfaces:**
- Consumes: `_characters`, `_messages`, `_isAiReplying`
- Produces: `_startAutoChat`, `_stopAutoChat`, `_tryAutoChatRound`

```dart
// 添加以下方法到 _ChatRoomPageState 中：

void _startAutoChat() {
  _autoChatTimer?.cancel();
  _autoChatTimer = Timer.periodic(
    Duration(seconds: 5 + _autoChatRandom.nextInt(4)),
    (_) => _tryAutoChatRound(),
  );
}

void _stopAutoChat() {
  _autoChatTimer?.cancel();
  _autoChatTimer = null;
  _autoChatRoundCount = 0;
}

Future<void> _tryAutoChatRound() async {
  if (_isAiReplying || _characters.isEmpty) return;
  if (_autoChatRoundCount >= _maxAutoChatRounds) {
    // 达到上限，暂停 10 秒后重置
    _stopAutoChat();
    Future.delayed(const Duration(seconds: 10), _startAutoChat);
    return;
  }

  // 每个角色有概率主动发言
  final speakers = <AICharacter>[];
  for (final c in _characters) {
    if (_isEligibleToReply(c) && _autoChatRandom.nextDouble() < 0.2) {
      speakers.add(c);
    }
  }

  if (speakers.isEmpty) return;

  setState(() => _autoChatRoundCount++);

  for (final speaker in speakers.take(2)) {
    if (!_isEligibleToReply(speaker)) continue;
    await _generateAiReply(speaker, _messages.toList(), null, isAutoChat: true);
    await _delay();
  }

  await _maybeUpdateMemory();
}

// 在 _loadData() 的末尾（_scrollToBottom() 之后）添加启动自动聊天：
void _loadData() async {
  // ... 现有代码 ...

  _scrollToBottom();

  // 启动 AI 自主聊天
  if (_isAutoChatEnabled && _characters.isNotEmpty) {
    Future.delayed(const Duration(seconds: 3), _startAutoChat);
  }
}
```

- [ ] Step 1: 添加 `_startAutoChat` 方法
- [ ] Step 2: 添加 `_stopAutoChat` 方法
- [ ] Step 3: 添加 `_tryAutoChatRound` 方法
- [ ] Step 4: 在 `_loadData` 末尾添加自动聊天启动
- [ ] Step 5: 在 `dispose()` 确认有 `_autoChatTimer?.cancel()`
- [ ] Step 6: 在 `_sendMessage` 中，用户发送消息后重置 `_autoChatRoundCount = 0`

---

### Task 4: 实现 @ 强制回复机制

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart`

**Interfaces:**
- Consumes: `_parseMentions`, `_selectReplyCharacter`, `_pendingMentionedIds`
- Produces: 修改 `_sendMessage` 和 `_runAiRound` 集成强制回复逻辑

```dart
// 修改 _sendMessage 方法，在追加用户消息后添加：

Future<void> _sendMessage() async {
  final text = _textController.text.trim();
  if (text.isEmpty || _isAiReplying) return;

  _textController.clear();
  _hideMentionOverlay();
  final messenger = ScaffoldMessenger.of(context);

  // 解析 @
  final mentionedIds = _parseMentions(text);

  await _appendMessage(Message(
    groupId: widget.groupId,
    senderId: 'user',
    senderType: 'user',
    content: text,
  ));

  // 将被 @ 的角色加入待回应队列
  for (final id in mentionedIds) {
    if (!_pendingMentionedIds.contains(id)) {
      _pendingMentionedIds.add(id);
    }
  }

  // 重置自主聊天轮数
  _autoChatRoundCount = 0;

  if (_characters.isEmpty) {
    if (mounted) messenger.showSnackBar(const SnackBar(content: Text('该群聊没有活跃的角色'), behavior: SnackBarBehavior.floating));
    return;
  }

  await _runAiRound(userMessage: text, mentionedIds: mentionedIds);
}
```

```dart
// 修改 _runAiRound 方法签名和逻辑：

Future<void> _runAiRound({String? userMessage, List<String>? mentionedIds, bool isAutoChat = false}) async {
  if (!isAutoChat && _consecutiveRound >= _maxAutoRounds) {
    setState(() => _isAiReplying = false);
    // 检查是否还有待回应的 @
    if (_pendingMentionedIds.isNotEmpty) {
      _pendingMentionedIds.clear();
    }
    return;
  }

  setState(() {
    _isAiReplying = true;
    if (!isAutoChat) _consecutiveRound++;
  });

  final recentMessages = _messages.length > 20 ? _messages.sublist(_messages.length - 20) : _messages.toList();

  // 用新的选择逻辑
  final character = _selectReplyCharacter(mentionedIds);
  if (character == null) {
    setState(() => _isAiReplying = false);
    return;
  }

  // 检查是否是待回应角色（需要优先回复）
  final wasPendingReply = _pendingMentionedIds.contains(character.id);

  await _generateAiReply(character, recentMessages, userMessage, isAutoChat: isAutoChat);
  await _delay();

  // 如果该角色回应了，从待回应队列移除
  if (wasPendingReply) {
    _pendingMentionedIds.remove(character.id);
  }

  // 如果没有被 @ 的角色且有待回应队列，安排其他角色代为@
  if (mentionedIds != null && mentionedIds.isNotEmpty &&
      !mentionedIds.contains(character.id) &&
      _pendingMentionedIds.isNotEmpty) {
    final notMentionedPending = _pendingMentionedIds
        .where((id) => !mentionedIds.contains(id))
        .toList();
    if (notMentionedPending.isNotEmpty) {
      final proxyId = notMentionedPending.first;
      final proxyChar = _characters.isNotEmpty ? _characters.firstWhere((c) => c.id == proxyId) : null;
      if (proxyChar != null && _isEligibleToReply(proxyChar)) {
        final targetName = proxyChar.name;
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: proxyChar.id,
          senderType: 'ai',
          content: '$targetName 刚才没看到，我帮你@他一下 @$targetName',
          isMention: true,
          mentionedAiIds: [proxyId],
        ));
      }
    }
  }

  await _maybeUpdateMemory();

  setState(() {
    _isAiReplying = false;
    if (!isAutoChat) _consecutiveRound = 0;
  });
}
```

```dart
// 修改 _generateAiReply 方法签名：

Future<void> _generateAiReply(AICharacter character, List<Message> context, String? userMessage, {bool isAutoChat = false}) async {
  // ... 保留原有逻辑，仅在 _buildApiMessages 调用处传递 isAutoChat
  final apiMessages = _buildApiMessages(character, context, userMessage, isAutoChat: isAutoChat);
  // ...
}
```

- [ ] Step 1: 修改 `_sendMessage` 解析 @ 并加入待回应队列
- [ ] Step 2: 修改 `_runAiRound` 方法签名，添加 `mentionedIds` 和 `isAutoChat` 参数
- [ ] Step 3: 在 `_runAiRound` 中使用 `_selectReplyCharacter` 替换原有的随机选择逻辑
- [ ] Step 4: 在 `_runAiRound` 中添加待回应队列清理和代为回复逻辑
- [ ] Step 5: 修改 `_generateAiReply` 方法签名传递 `isAutoChat`
- [ ] Step 6: 在用户发送消息后重置 `_autoChatRoundCount = 0`

---

### Task 5: 修改 _buildApiMessages 支持自主聊天上下文

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart:227-268`

**Interfaces:**
- Consumes: `character`, `context`, `userMessage`, `isAutoChat`
- Produces: 自主聊天时包含所有 AI 消息的上下文

```dart
List<Map<String, dynamic>> _buildApiMessages(AICharacter character, List<Message> context, String? userMessage, {bool isAutoChat = false}) {
  final msgs = <Map<String, dynamic>>[];

  if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty) {
    msgs.add({'role': 'system', 'content': '【群聊记忆】${_groupMemory!.topicSummary}'});
  }

  // 自主聊天时增加角色扮演提示
  if (isAutoChat) {
    final otherCharacters = _characters.where((c) => c.id != character.id).toList();
    if (otherCharacters.isNotEmpty) {
      final charInfo = otherCharacters.map((c) => '${c.name}(${c.role}, ${c.age}岁)').join('、');
      msgs.add({'role': 'system', 'content': '现在群聊中正在自动对话。在场的其他角色：$charInfo。请自然地参与对话，可以回应其他人的发言。'});
    }
  }

  msgs.add({'role': 'system', 'content': character.systemPrompt});

  final otherCharacters = _characters.where((c) => c.id != character.id).toList();
  if (otherCharacters.isNotEmpty) {
    final characterInfo = otherCharacters.map((c) => '${c.name}(${c.role}, ${c.age}岁, ${c.personalityTags.join('/')})').join('；');
    msgs.add({'role': 'system', 'content': '群聊中的其他角色：$characterInfo'});
  }

  // 自主聊天：包含所有最近消息；用户触发：只包含用户消息和当前角色的消息
  final historyMessages = <Message>[];
  for (final m in context) {
    if (isAutoChat) {
      // 自主聊天：包含所有消息
      final role = m.senderType == 'user' ? 'user' : 'assistant';
      historyMessages.add(m);
    } else {
      // 用户触发：只保留用户消息和当前角色的消息
      if (m.senderType == 'user') {
        historyMessages.add(m);
      } else if (m.senderType == 'ai' && m.senderId == character.id) {
        historyMessages.add(m);
      }
    }
  }

  // 先构建 ID -> name 的查找表
  final nameById = {for (final c in _characters) c.id: c.name};

  for (final m in historyMessages.take(15)) {
    final role = m.senderType == 'user' ? 'user' : 'assistant';
    if (m.isMention && m.mentionedAiIds.isNotEmpty) {
      final mentionedNames = m.mentionedAiIds.map((id) {
        return nameById[id] ?? id;
      }).toList();
      msgs.add({'role': role, 'content': '${m.content} (提到: ${mentionedNames.join(', ')})'});
    } else {
      msgs.add({'role': role, 'content': m.content});
    }
  }

  if (userMessage != null && historyMessages.isEmpty) {
    msgs.add({'role': 'user', 'content': userMessage});
  }

  return msgs;
}
```

- [ ] Step 1: 修改 `_buildApiMessages` 方法签名，添加 `{bool isAutoChat = false}` 参数
- [ ] Step 2: 在自主聊天模式中添加系统提示
- [ ] Step 3: 修改历史消息过滤逻辑，区分自主聊天和用户触发
- [ ] Step 4: 验证 `flutter analyze` 无错误

---

### Task 6: 修正用户消息文字颜色

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart:631,645`

**Interfaces:**
- Consumes: `_MessageBubble._buildContent`
- Produces: 用户消息文字使用 `cs.onPrimary` 确保对比度

在 `_MessageBubble._buildContent` 方法中：

```dart
// 用户消息的文字样式（isUser 为 true 时）：
// 将 color: cs.onSurface 改为 color: cs.onPrimary

// 第 631 行附近（mention 情况下的文本）：
Text(message.content, style: TextStyle(fontSize: 15, color: cs.onPrimary, height: 1.4)),

// 第 645 行附近（普通情况下的文本）：
return Text(message.content, style: TextStyle(fontSize: 15, color: cs.onPrimary, height: 1.4));
```

- [ ] Step 1: 修改 mention 场景下用户消息的文字色
- [ ] Step 2: 修改普通场景下用户消息的文字色
- [ ] Step 3: 验证修改正确性

---

### Task 7: 最终集成与验证

**Files:**
- Modify: `lib/features/chat_group/chat_room_page.dart`

- [ ] Step 1: 运行 `flutter analyze lib/features/chat_group/chat_room_page.dart` 确认无编译错误
- [ ] Step 2: 运行 `flutter run` 在模拟器/真机上验证：
  - 输入 `@` 弹出成员列表 → 选择成员 → 自动填入
  - 用户发送 @ 某角色的消息 → AI 回复中包含该角色
  - AI 自主聊天：等待几秒观察 AI 自动发言
  - 用户消息颜色对比度正常
- [ ] Step 3: 边界测试：连续快速发送消息、@ 不存在的角色、空输入等
