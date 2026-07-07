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
  final bool _isAutoChatEnabled = true;
  int _autoChatRoundCount = 0;
  final int _maxAutoChatRounds = 5;
  final Random _autoChatRandom = Random();

  // 待回应 @ 列表
  final List<String> _pendingMentionedIds = [];

  bool _isInputEmpty = true;

  @override
  void initState() {
    super.initState();
    _textController.addListener(() {
      final isEmpty = _textController.text.trim().isEmpty;
      if (isEmpty != _isInputEmpty) {
        setState(() => _isInputEmpty = isEmpty);
      }
    });
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

    if (_isAutoChatEnabled && _characters.isNotEmpty) {
      Future.delayed(const Duration(seconds: 3), _startAutoChat);
    }
  }

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
      _stopAutoChat();
      Future.delayed(const Duration(seconds: 10), _startAutoChat);
      return;
    }

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
    _hideMentionOverlay();
    final text = _textController.text.trim();
    if (text.isEmpty || _isAiReplying) return;

    _textController.clear();
    final messenger = ScaffoldMessenger.of(context);

    final mentionedIds = _parseMentions(text);
    for (final id in mentionedIds) {
      if (!_pendingMentionedIds.contains(id)) {
        _pendingMentionedIds.add(id);
      }
    }

    await _appendMessage(Message(
      groupId: widget.groupId,
      senderId: 'user',
      senderType: 'user',
      content: text,
    ));

    _autoChatRoundCount = 0;

    if (_characters.isEmpty) {
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('该群聊没有活跃的角色'), behavior: SnackBarBehavior.floating));
      return;
    }

    await _runAiRound(userMessage: text, mentionedIds: mentionedIds);
  }

  Future<void> _runAiRound({String? userMessage, List<String>? mentionedIds, bool isAutoChat = false}) async {
    if (!isAutoChat && _consecutiveRound >= _maxAutoRounds) {
      setState(() => _isAiReplying = false);
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

    final character = _selectReplyCharacter(mentionedIds);
    if (character == null) {
      setState(() => _isAiReplying = false);
      return;
    }

    final wasPendingReply = _pendingMentionedIds.contains(character.id);

    await _generateAiReply(character, recentMessages, userMessage, isAutoChat: isAutoChat);
    await _delay();

    if (wasPendingReply) {
      _pendingMentionedIds.remove(character.id);
    }

    if (mentionedIds != null && mentionedIds.isNotEmpty && !mentionedIds.contains(character.id) && _pendingMentionedIds.isNotEmpty) {
      final notMentionedPending = _pendingMentionedIds.where((id) => !mentionedIds.contains(id)).toList();
      if (notMentionedPending.isNotEmpty) {
        final proxyId = notMentionedPending.first;
        final proxyChar = _characters.firstWhere((c) => c.id == proxyId, orElse: () => _characters.first);
        if (_isEligibleToReply(proxyChar)) {
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

  Future<void> _generateAiReply(AICharacter character, List<Message> context, String? userMessage, {bool isAutoChat = false}) async {
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

    final apiMessages = _buildApiMessages(character, context, userMessage, isAutoChat: isAutoChat);
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
      final config = ref.read(databaseServiceProvider).apiConfigBox.get(character.apiConfigId);
      if (config != null) return config;
    }
    if (character.apiKey.isNotEmpty && character.apiProvider.isNotEmpty) {
      return ApiConfig(
        id: 'legacy_${character.id}',
        name: '${character.name} 原有配置',
        provider: character.apiProvider,
        modelName: character.modelName,
        apiKey: character.apiKey,
        customBaseUrl: character.customBaseUrl,
      );
    }
    return null;
  }

  List<Map<String, dynamic>> _buildApiMessages(AICharacter character, List<Message> context, String? userMessage, {bool isAutoChat = false}) {
    final msgs = <Map<String, dynamic>>[];

    if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty) {
      msgs.add({'role': 'system', 'content': '【群聊记忆】${_groupMemory!.topicSummary}'});
    }

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

    final historyMessages = <Message>[];
    for (final m in context) {
      if (isAutoChat) {
        historyMessages.add(m);
      } else {
        if (m.senderType == 'user') {
          historyMessages.add(m);
        } else if (m.senderType == 'ai' && m.senderId == character.id) {
          historyMessages.add(m);
        }
      }
    }

    final nameById = {for (final c in _characters) c.id: c.name};
    for (final m in historyMessages.take(15)) {
      final role = m.senderType == 'user' ? 'user' : 'assistant';
      if (m.isMention && m.mentionedAiIds.isNotEmpty) {
        final mentionedNames = m.mentionedAiIds.map((id) => nameById[id] ?? id).toList();
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
    final today = DateTime(now.year, now.month, now.day);
    final lastReplyDay = character.lastReplyTimestamp == null
        ? null
        : DateTime(character.lastReplyTimestamp!.year, character.lastReplyTimestamp!.month, character.lastReplyTimestamp!.day);

    if (lastReplyDay == null || lastReplyDay != today) {
      character.hourlyReplyCount = 0;
      character.lastReplyTimestamp = now;
      return true;
    }

    final diff = now.difference(character.lastReplyTimestamp!).inMinutes;
    if (diff >= 60) {
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
    _filteredMentionMembers = [];
  }

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
              child: _buildMentionPopupContent(cs),
            ),
          ),
        );
      },
    );

    final overlay = Overlay.of(context);
    overlay.insert(_mentionOverlay!);
  }

  Widget _buildMentionPopupContent(ColorScheme cs) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: Builder(
        builder: (ctx) {
          if (_filteredMentionMembers.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Text('无匹配角色', style: TextStyle(fontSize: 14)),
            );
          }
          return ListView.builder(
            shrinkWrap: true,
            itemCount: _filteredMentionMembers.length,
            itemBuilder: (ctx2, i) {
              final c = _filteredMentionMembers[i];
              final pColor = _senderColor(c);
              return InkWell(
                onTap: () => _insertMention(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: pColor.withOpacity(0.12),
                        ),
                        child: Center(
                          child: Text(
                            c.avatar.isNotEmpty ? c.avatar : c.name[0],
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: pColor),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(c.name, style: TextStyle(fontSize: 14), overflow: TextOverflow.ellipsis),
                      ),
                      Text(c.role, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _insertMention(AICharacter character) {
    final text = _textController.text;
    final cursorPos = _textController.selection.baseOffset;

    int atPos = text.lastIndexOf('@', cursorPos - 1);
    if (atPos < 0) atPos = 0;

    final newText = '${text.substring(0, atPos)}@${character.name} ${text.substring(cursorPos)}';
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: atPos + character.name.length + 2),
    );

    _hideMentionOverlay();
  }

  void _handleTextChanged(String text) {
    if (!_showMentionPopup) {
      if (text.contains('@')) {
        _filteredMentionMembers = List.from(_characters);
        _showMentionOverlay(Offset.zero);
        return;
      }
      return;
    }

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

    if (_mentionOverlay != null) {
      _mentionOverlay!.markNeedsBuild();
    }
  }

  List<String> _parseMentions(String content) {
    final mentionedIds = <String>[];
    if (_characters.isEmpty) return mentionedIds;

    final chinesePattern = RegExp(r'@([一-鿿]{1,10})');
    for (final match in chinesePattern.allMatches(content)) {
      final name = match.group(1)!;
      final found = _characters.firstWhere((c) => c.name == name, orElse: () => _characters.first);
      mentionedIds.add(found.id);
    }
    final englishPattern = RegExp(r'@(\w+)');
    for (final match in englishPattern.allMatches(content)) {
      final name = match.group(1)!;
      final found = _characters.firstWhere((c) => c.name == name, orElse: () => _characters.first);
      mentionedIds.add(found.id);
    }
    return mentionedIds;
  }

  AICharacter? _selectReplyCharacter(List<String>? mentionedIds) {
    final eligible = _characters.where(_isEligibleToReply).toList();
    if (eligible.isEmpty) return null;

    if (mentionedIds != null && mentionedIds.isNotEmpty) {
      final priorityChars = eligible.where((c) => mentionedIds.contains(c.id)).toList();
      if (priorityChars.isNotEmpty) {
        return _shuffle(priorityChars).first;
      }
    }

    if (_pendingMentionedIds.isNotEmpty) {
      final pendingEligible = eligible.where((c) => _pendingMentionedIds.contains(c.id)).toList();
      if (pendingEligible.isNotEmpty) {
        return _shuffle(pendingEligible).first;
      }
    }

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
    final providerName = sender.apiConfigId.isNotEmpty
        ? (ref.read(databaseServiceProvider).apiConfigBox.get(sender.apiConfigId)?.provider ?? sender.apiProvider)
        : sender.apiProvider;
    return _providerColor(providerName);
  }

  Color _providerColor(String provider) {
    switch (provider) {
      case 'deepseek': return const Color(0xFF1565C0);
      case 'qwen': return const Color(0xFF7C3AED);
      case 'zhipu': return const Color(0xFF0891B2);
      case 'moonshot': return const Color(0xFF7C3AED);
      case 'baidu': return const Color(0xFF4F46E5);
      case 'custom': return const Color(0xFFD97706);
      default: return const Color(0xFF2563EB);
    }
  }

  static String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24 && now.day == dt.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
                      final sender = message.senderType == 'user' ? null : _characters.firstWhere(
                        (c) => c.id == message.senderId,
                        orElse: () => _characters.isNotEmpty ? _characters.first : AICharacter(
                          name: '未知', avatar: '?', age: 0, role: '', personalityTags: const [],
                          systemPrompt: '', apiKey: '', apiProvider: 'deepseek', apiConfigId: '',
                        ),
                      );
                      return _MessageBubble(message: message, sender: sender, characters: _characters, cs: cs);
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
            final color = _senderColor(c);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withOpacity(0.12),
                      border: Border.all(color: color.withOpacity(0.25), width: 1.5),
                    ),
                    child: Center(child: Text(c.avatar.isNotEmpty ? c.avatar : c.name[0], style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: color))),
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
          }).toList(),
        ],
      ),
    );
  }

  Widget _buildInputArea(ColorScheme cs) {
    return CompositedTransformTarget(
      link: _mentionLayerLink,
      child: Container(
        padding: EdgeInsets.only(left: 16, right: 16, top: 12, bottom: MediaQuery.of(context).padding.bottom + 12),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outlineVariant.withOpacity(0.5))),
        ),
        child: Row(
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40, maxHeight: 120),
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
                  onChanged: _handleTextChanged,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.send_rounded, size: 22),
              color: (_isAiReplying || _isInputEmpty) ? cs.onSurfaceVariant.withOpacity(0.4) : cs.primary,
              onPressed: (_isAiReplying || _isInputEmpty) ? null : _sendMessage,
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final AICharacter? sender;
  final List<AICharacter> characters;
  final ColorScheme cs;

  const _MessageBubble({required this.message, this.sender, required this.characters, required this.cs});

  @override
  Widget build(BuildContext context) {
    final isUser = message.senderType == 'user';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser && sender != null) ...[
            CircleAvatar(
              radius: 20,
              backgroundColor: _senderColor(sender!).withOpacity(0.12),
              child: Text(sender!.avatar.isNotEmpty ? sender!.avatar : sender!.name[0], style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: _senderColor(sender!))),
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
                    child: Text(sender!.name, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
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
                  child: _buildContent(message, sender, isUser, cs),
                ),
                Padding(
                  padding: EdgeInsets.only(top: 4, left: isUser ? 0 : 4, right: !isUser ? 0 : 4),
                  child: Text(
                    _ChatRoomPageState._formatTime(message.timestamp),
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withOpacity(0.7)),
                  ),
                ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildContent(Message message, AICharacter? sender, bool isUser, ColorScheme cs) {
    final textColor = isUser ? cs.onPrimary : cs.onSurface;
    final content = message.content.replaceAll('\\n', '\n');

    if (message.isMention && message.mentionedAiIds.isNotEmpty && sender != null) {
      final mentionNames = message.mentionedAiIds.map((id) {
        return characters.firstWhere((c) => c.id == id, orElse: () {
          return AICharacter(name: id, avatar: '?', age: 0, role: '', personalityTags: const [], systemPrompt: '', apiKey: '', apiProvider: 'deepseek', apiConfigId: '');
        }).name;
      }).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(content, style: TextStyle(fontSize: 15, color: textColor, height: 1.4)),
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
    return Text(content, style: TextStyle(fontSize: 15, color: textColor, height: 1.4));
  }

  Color _senderColor(AICharacter sender) {
    switch (sender.apiProvider) {
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
