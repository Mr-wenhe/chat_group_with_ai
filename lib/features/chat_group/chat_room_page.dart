import 'dart:async';
import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ChatRoomPage extends ConsumerStatefulWidget {
  final String groupId;

  const ChatRoomPage({super.key, required this.groupId});

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends ConsumerState<ChatRoomPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _chatApi = ChatApiService();
  final _random = Random();

  ChatGroup? _group;
  List<AICharacter> _characters = [];
  List<Message> _messages = [];
  GroupMemory? _groupMemory;

  bool _isLoading = true;
  bool _isAiReplying = false;
  int _consecutiveRound = 0;
  final int _maxAutoRounds = 3;

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

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _autoChatTimer?.cancel();
    _hideMentionOverlay();
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseServiceProvider);
    final group = db.chatGroupBox.get(widget.groupId);
    if (group == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('群聊不存在'), behavior: SnackBarBehavior.floating));
        Navigator.pop(context);
      }
      return;
    }

    final characters = group.aiCharacterIds
        .map((id) => db.aiCharacterBox.get(id))
        .whereType<AICharacter>()
        .where((c) => c.isActive)
        .toList();

    final messages = db.messageBox.values
        .where((m) => m.groupId == widget.groupId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final memoryBox = db.groupMemoryBox;
    final memoryKey = '${widget.groupId}_${_memoryPeriodKey(DateTime.now())}';
    var memory = memoryBox.get(memoryKey);
    if (memory == null) {
      memory = GroupMemory(groupId: widget.groupId, topicSummary: '');
      await memoryBox.put(memoryKey, memory);
    }

    setState(() {
      _group = group;
      _characters = characters;
      _messages = messages;
      _groupMemory = memory;
      _isLoading = false;
    });

    _scrollToBottom();
  }

  String _memoryPeriodKey(DateTime now) {
    final weekOfYear = _weekOfYear(now);
    return '${now.year}_W$weekOfYear';
  }

  int _weekOfYear(DateTime date) {
    final dayOfYear = _dayOfYear(date);
    final firstDay = DateTime(date.year, 1, 1);
    final firstDayOfWeek = firstDay.weekday;
    final offset = firstDayOfWeek <= DateTime.thursday ? 1 : 0;
    return ((dayOfYear + firstDayOfWeek - 1 - 4) / 7).floor() + offset;
  }

  int _dayOfYear(DateTime date) {
    final start = DateTime(date.year, 1, 1);
    return date.difference(start).inDays + 1;
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _isAiReplying) return;

    _textController.clear();
    final messenger = ScaffoldMessenger.of(context);

    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: 'user',
      senderType: 'user',
      content: text,
    ));

    if (_characters.isEmpty) {
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('该群聊没有活跃的角色'), behavior: SnackBarBehavior.floating));
      return;
    }

    await _runAiRound(userMessage: text);
  }

  Future<void> _runAiRound({String? userMessage}) async {
    if (_consecutiveRound >= _maxAutoRounds) {
      setState(() => _isAiReplying = false);
      return;
    }

    setState(() {
      _isAiReplying = true;
      _consecutiveRound++;
    });

    final recentMessages = _messages.length > 20 ? _messages.sublist(_messages.length - 20) : _messages.toList();
    final eligibleCharacters = _characters.where(_isEligibleToReply).toList();
    if (eligibleCharacters.isEmpty) {
      setState(() => _isAiReplying = false);
      return;
    }

    final aiCount = min(_random.nextInt(2) + 1, eligibleCharacters.length);
    final selectedAiCharacters = _shuffle(eligibleCharacters).take(aiCount).toList();

    for (final character in selectedAiCharacters) {
      if (!_isEligibleToReply(character)) continue;
      await _generateAiReply(character, recentMessages, userMessage);
      await _delay();
    }

    await _maybeUpdateMemory();

    setState(() {
      _isAiReplying = false;
      _consecutiveRound = 0;
    });
  }

  Future<void> _generateAiReply(AICharacter character, List<Message> context, String? userMessage) async {
    final config = _resolveApiConfig(character);
    if (config == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: '[${character.name} 未配置 API]',
      ));
      return;
    }

    final apiMessages = _buildApiMessages(character, context, userMessage);
    final result = await _chatApi.sendChatMessage(
      apiKey: config.apiKey,
      provider: ApiProvider.values.firstWhere((p) => p.name == config.provider, orElse: () => ApiProvider.deepseek),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
    );

    if (!(result['success'] ?? true)) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: '[${character.name} 回复失败: ${result['message']}]',
      ));
      return;
    }

    final reply = result['message']?.toString() ?? '';
    if (reply.isEmpty) return;

    final mentionPattern = RegExp(r'@([^\s]+)');
    final mentionedIds = <String>[];
    for (final match in mentionPattern.allMatches(reply)) {
      final name = match.group(1);
      final found = _characters.firstWhere((c) => c.name == name, orElse: () => _characters.first);
      mentionedIds.add(found.id);
    }

    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: reply,
      isMention: mentionedIds.isNotEmpty,
      mentionedAiIds: mentionedIds,
    ));
  }

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      return ref.read(databaseServiceProvider).apiConfigBox.get(character.apiConfigId);
    }
    return null;
  }

  List<Map<String, dynamic>> _buildApiMessages(AICharacter character, List<Message> context, String? userMessage) {
    final msgs = <Map<String, dynamic>>[];

    if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty) {
      msgs.add({'role': 'system', 'content': '【群聊记忆】${_groupMemory!.topicSummary}'});
    }

    msgs.add({'role': 'system', 'content': character.systemPrompt});

    final otherCharacters = _characters.where((c) => c.id != character.id).toList();
    if (otherCharacters.isNotEmpty) {
      final characterInfo = otherCharacters.map((c) => '${c.name}(${c.role}, ${c.age}岁, ${c.personalityTags.join('/')})').join('；');
      msgs.add({'role': 'system', 'content': '群聊中的其他角色：$characterInfo'});
    }

    final historyMessages = <Message>[];
    for (final m in context) {
      if (m.senderType == 'user') {
        historyMessages.add(m);
      } else if (m.senderType == 'ai' && m.senderId == character.id) {
        historyMessages.add(m);
      }
    }

    for (final m in historyMessages.take(10)) {
      final role = m.senderType == 'user' ? 'user' : 'assistant';
      if (m.isMention && m.mentionedAiIds.isNotEmpty) {
        final mentionedNames = m.mentionedAiIds.map((id) {
          return _characters.firstWhere((c) => c.id == id, orElse: () => _characters.first).name;
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

  Future<void> _appendMessage(Message message) async {
    final db = ref.read(databaseServiceProvider);
    await db.messageBox.put(message.id, message);
    setState(() {
      _messages = List.from(_messages)..add(message);
    });
    _scrollToBottom();
  }

  Future<void> _maybeUpdateMemory() async {
    if (_messages.length < 8) return;

    final recentText = _messages.map((m) => m.content).join(' ');
    final topicHint = recentText.substring(0, min(500, recentText.length));

    final summary = await _generateSummary(topicHint);
    if (summary.isNotEmpty && _groupMemory != null) {
      _groupMemory!.topicSummary = summary;
      await _groupMemory!.save();
      setState(() {});
    }
  }

  Future<String> _generateSummary(String recentText) async {
    final character = _characters.isNotEmpty ? _characters.first : null;
    if (character == null) return '';

    final config = _resolveApiConfig(character);
    if (config == null) return '';

    final msgs = [
      {'role': 'system', 'content': '你是群聊记忆记录员。请用1-2句话总结最近对话的核心话题，不要超过80字。'},
      {'role': 'user', 'content': '最近对话：$recentText\n\n请总结：'}
    ];

    final result = await _chatApi.sendChatMessage(
      apiKey: config.apiKey,
      provider: ApiProvider.values.firstWhere((p) => p.name == config.provider, orElse: () => ApiProvider.deepseek),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: msgs,
      temperature: 0.4,
    );

    if (result['success'] ?? false) {
      return result['message']?.toString().trim() ?? '';
    }
    return '';
  }

  bool _isEligibleToReply(AICharacter character) {
    if (!character.isActive) return false;

    final config = _resolveApiConfig(character);
    if (config == null || config.apiKey.isEmpty) return false;

    final now = DateTime.now();
    if (character.lastReplyTimestamp == null ||
        character.lastReplyTimestamp!.year != now.year ||
        character.lastReplyTimestamp!.day != now.day) {
      character.hourlyReplyCount = 0;
      character.lastReplyTimestamp = now;
      return true;
    }
    if (character.lastReplyTimestamp!.difference(now).inHours >= 1) {
      character.hourlyReplyCount = 0;
      character.lastReplyTimestamp = now;
      return true;
    }
    return character.hourlyReplyCount < character.hourlyReplyLimit;
  }

  List<T> _shuffle<T>(List<T> list) {
    final copy = List<T>.from(list);
    for (var i = copy.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final tmp = copy[i];
      copy[i] = copy[j];
      copy[j] = tmp;
    }
    return copy;
  }

  Future<void> _delay() async {
    await Future.delayed(Duration(milliseconds: 800 + _random.nextInt(2000)));
  }

  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _showMentionPopup = false;
  }

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
    for (final match in englishPattern.allMatches(content)) {
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Color _senderColor(AICharacter sender) {
    final providerName = _resolveApiConfig(sender)?.provider ?? sender.apiProvider;
    switch (providerName) {
      case 'deepseek': return const Color(0xFF1565C0);
      case 'qwen': return const Color(0xFF7C3AED);
      case 'zhipu': return const Color(0xFF0891B2);
      case 'moonshot': return const Color(0xFF7C3AED);
      case 'baidu': return const Color(0xFF4F46E5);
      case 'custom': return const Color(0xFFD97706);
      default: return const Color(0xFF2563EB);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: cs.surface,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          title: Text(_group?.name ?? '加载中...', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: cs.onSurface)),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_group?.name ?? '群聊', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: cs.onSurface)),
            if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty)
              Text(_groupMemory!.topicSummary, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.group_rounded, size: 22),
            onPressed: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: cs.surface,
                builder: (ctx) => _buildMembersSheet(cs),
              );
            },
            tooltip: '成员',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(cs)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      return _MessageBubble(message: message, characters: _characters, cs: cs);
                    },
                  ),
          ),
          if (_isAiReplying)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Text('AI 正在回复...', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            ),
          _buildInputArea(cs),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline_rounded, size: 64, color: cs.primary.withOpacity(0.3)),
          const SizedBox(height: 24),
          Text('开始对话吧', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('输入消息，AI 角色会自动回复', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _buildMembersSheet(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('群聊成员', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface)),
          const SizedBox(height: 16),
          ..._characters.map((c) {
            final providerColor = _senderColor(c);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: providerColor.withOpacity(0.12),
                      border: Border.all(color: providerColor.withOpacity(0.25), width: 1.5),
                    ),
                    child: Center(child: Text(c.avatar.isNotEmpty ? c.avatar : c.name[0], style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: providerColor))),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                        Text('${c.role} · ${c.age}岁', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildInputArea(ColorScheme cs) {
    return Container(
      padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: MediaQuery.of(context).padding.bottom + 12),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outlineVariant.withOpacity(0.5))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              decoration: InputDecoration(
                hintText: '输入消息，@ 提到角色...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: cs.outlineVariant)),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: cs.outlineVariant)),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide(color: cs.primary, width: 1.5)),
                filled: true,
                fillColor: cs.surfaceContainerHighest.withOpacity(0.4),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                isDense: true,
              ),
              maxLines: null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: Icon(Icons.send_rounded, size: 22, color: cs.primary),
            onPressed: _isAiReplying ? null : _sendMessage,
          ),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final List<AICharacter> characters;
  final ColorScheme cs;

  const _MessageBubble({required this.message, required this.characters, required this.cs});

  @override
  Widget build(BuildContext context) {
    final isUser = message.senderType == 'user';
    final sender = isUser
        ? null
        : characters.firstWhere((c) => c.id == message.senderId, orElse: () {
            final fallback = characters.isNotEmpty ? characters.first : AICharacter(
              name: '未知',
              avatar: '?',
              age: 0,
              role: '',
              personalityTags: const [],
              systemPrompt: '',
              apiKey: '',
              apiProvider: 'deepseek',
              apiConfigId: '',
            );
            return fallback;
          });

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser && sender != null) ...[
            CircleAvatar(
              radius: 20,
              backgroundColor: _senderColor(sender).withOpacity(0.12),
              child: Text(sender.avatar.isNotEmpty ? sender.avatar : sender.name[0], style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _senderColor(sender))),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isUser && sender != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(sender.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser ? cs.primary : cs.surfaceContainerHighest.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(18).copyWith(
                      bottomLeft: isUser ? const Radius.circular(18) : const Radius.circular(4),
                      bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(18),
                    ),
                  ),
                  child: _buildContent(message, sender),
                ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildContent(Message message, AICharacter? sender) {
    if (message.isMention && message.mentionedAiIds.isNotEmpty && sender != null) {
      final mentionNames = message.mentionedAiIds.map((id) {
        return characters.firstWhere((c) => c.id == id, orElse: () {
          return AICharacter(name: id, avatar: '?', age: 0, role: '', personalityTags: const [], systemPrompt: '', apiKey: '', apiProvider: 'deepseek', apiConfigId: '');
        }).name;
      }).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message.content, style: TextStyle(fontSize: 15, color: cs.onSurface, height: 1.4)),
          if (mentionNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 4,
                children: mentionNames.map((name) {
                  return Chip(label: Text(name, style: const TextStyle(fontSize: 11)), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap);
                }).toList(),
              ),
            ),
        ],
      );
    }
    return Text(message.content, style: TextStyle(fontSize: 15, color: cs.onSurface, height: 1.4));
  }

  Color _senderColor(AICharacter sender) {
    final providerName = sender.apiProvider;
    switch (providerName) {
      case 'deepseek': return const Color(0xFF1565C0);
      case 'qwen': return const Color(0xFF7C3AED);
      case 'zhipu': return const Color(0xFF0891B2);
      case 'moonshot': return const Color(0xFF7C3AED);
      case 'baidu': return const Color(0xFF4F46E5);
      case 'custom': return const Color(0xFFD97706);
      default: return const Color(0xFF2563EB);
    }
  }
}
