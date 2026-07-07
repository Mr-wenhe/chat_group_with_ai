import 'dart:async';
import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/theme/provider_style.dart';

class ChatRoomPage extends ConsumerStatefulWidget {
  final String groupId;

  const ChatRoomPage({super.key, required this.groupId});

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends ConsumerState<ChatRoomPage> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
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
  int _mentionSelectedIndex = 0; // 键盘上下选择的高亮项
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

  // 是否存在已配置 API Key 的角色（决定 AI 能否回复/自动聊天）
  bool _hasAnyApiConfig = false;

  // —— 流式输出（打字机）相关状态 ——
  Message? _streamingMessage; // 正在逐 token 渲染的内存态临时消息（不落库）
  StreamSubscription<ChatStreamEvent>? _streamSub; // 当前流的订阅，供「停止生成」取消
  Completer<void>? _streamDone; // 标记本轮流式是否结束
  bool _isStreaming = false; // 是否正在流式生成（控制「停止生成」按钮显隐）
  bool _disposed = false; // dispose 守卫，避免异步回调在销毁后写状态

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
    _disposed = true;
    // 取消未完成的流式订阅，并唤醒可能因 await 挂起的 _generateAiReply。
    _streamSub?.cancel();
    _streamSub = null;
    if (_streamDone != null && !_streamDone!.isCompleted) {
      _streamDone!.complete();
    }
    _textController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _autoChatTimer?.cancel();
    _hideMentionOverlay();
    super.dispose();
  }

  Future<void> _loadData() async {
    final db = ref.read(databaseServiceProvider);
    final group = db.chatGroupBox.get(widget.groupId);
    if (group == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('群聊不存在'), behavior: SnackBarBehavior.floating));
        Navigator.pop(context);
      }
      return;
    }

    final characters = group.aiCharacterIds
        .map((id) => db.aiCharacterBox.get(id))
        .whereType<AICharacter>()
        .where((c) => c.isActive)
        .toList();

    // 检测是否有角色配置了 API Key（决定 AI 能否回复/自动聊天）
    final hasApi = characters.any((c) {
      final cfg = _resolveApiConfig(c);
      return cfg != null && cfg.apiKey.isNotEmpty;
    });

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
      _hasAnyApiConfig = hasApi;
      _isLoading = false;
    });

    _scrollToBottom();

    if (_isAutoChatEnabled && _characters.isNotEmpty && hasApi) {
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
      if (_isEligibleToReply(c) && _autoChatRandom.nextDouble() < 0.35) {
        speakers.add(c);
      }
    }

    if (speakers.isEmpty) return;

    setState(() => _autoChatRoundCount++);

    for (final speaker in speakers.take(2)) {
      if (!_isEligibleToReply(speaker)) continue;
      await _generateAiReply(speaker, _messages.toList(), null,
          isAutoChat: true);
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
      if (mounted) {
        messenger.showSnackBar(const SnackBar(
            content: Text('该群聊没有活跃的角色'), behavior: SnackBarBehavior.floating));
      }
      return;
    }

    await _runAiRound(userMessage: text, mentionedIds: mentionedIds);
  }

  Future<void> _runAiRound(
      {String? userMessage,
      List<String>? mentionedIds,
      bool isAutoChat = false}) async {
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

    final recentMessages = _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages.toList();

    final character = _selectReplyCharacter(mentionedIds);
    if (character == null) {
      setState(() => _isAiReplying = false);
      if (mounted && !isAutoChat) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_hasAnyApiConfig
              ? '暂时没有可以回复的角色（可能已达回复上限）'
              : '角色未配置 API Key，AI 无法回复。请到「设置」配置 API'),
          behavior: SnackBarBehavior.floating,
          action: _hasAnyApiConfig
              ? null
              : SnackBarAction(
                  label: '去设置',
                  onPressed: () =>
                      Navigator.pushNamed(context, '/settings'),
                ),
        ));
      }
      return;
    }

    final wasPendingReply = _pendingMentionedIds.contains(character.id);

    await _generateAiReply(character, recentMessages, userMessage,
        isAutoChat: isAutoChat);
    await _delay();

    if (wasPendingReply) {
      _pendingMentionedIds.remove(character.id);
    }

    if (mentionedIds != null &&
        mentionedIds.isNotEmpty &&
        !mentionedIds.contains(character.id) &&
        _pendingMentionedIds.isNotEmpty) {
      final notMentionedPending = _pendingMentionedIds
          .where((id) => !mentionedIds.contains(id))
          .toList();
      if (notMentionedPending.isNotEmpty) {
        final proxyId = notMentionedPending.first;
        final proxyChar = _characters.firstWhere((c) => c.id == proxyId,
            orElse: () => _characters.first);
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

  Future<void> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false}) async {
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

    final apiMessages = _buildApiMessages(character, context, userMessage,
        isAutoChat: isAutoChat);
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );

    // —— 内存态临时消息：先以空内容入列用于增量渲染，整条完成后再落库一次 ——
    final temp = Message(
      groupId: widget.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: '',
    );
    if (mounted) {
      setState(() {
        _streamingMessage = temp;
        _messages = List.from(_messages)..add(temp);
      });
    }
    _scrollToBottom();

    // 订阅流式事件；用 Completer 协调「流结束」与「用户停止生成」两种收尾路径。
    final done = Completer<void>();
    String fullContent = '';
    var failed = false;

    final sub = _chatApi
        .streamChatMessage(
      apiKey: config.apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
    )
        .listen(
      (e) {
        if (_disposed) return;
        switch (e.type) {
          case ChatStreamEventType.token:
            // 逐 token 累加内容并增量渲染
            fullContent += e.delta ?? '';
            temp.content = fullContent;
            if (mounted) setState(() {});
            _scrollToBottom();
          case ChatStreamEventType.done:
            // 以 done 携带的完整内容为准（若为空则保留累计值）
            if ((e.content ?? '').isNotEmpty) fullContent = e.content!;
            temp.content = fullContent;
            if (mounted) setState(() {});
          case ChatStreamEventType.error:
            failed = true;
            fullContent = '[${character.name} 回复失败: ${e.message}]';
            temp.content = fullContent;
            if (mounted) setState(() {});
            if (!done.isCompleted) done.complete();
        }
      },
      onError: (err) {
        if (_disposed) return;
        failed = true;
        fullContent = '[${character.name} 回复失败: $err]';
        temp.content = fullContent;
        if (mounted) setState(() {});
        if (!done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: false,
    );

    // 记录订阅与完成器，供「停止生成」取消。
    _streamSub = sub;
    _streamDone = done;
    if (mounted) setState(() => _isStreaming = true);

    // 等待流结束，或被用户点击「停止生成」取消。
    await done.future;

    // 收尾：清理订阅状态。
    _streamSub = null;
    _streamDone = null;
    if (mounted) setState(() => _isStreaming = false);

    // 空内容（非失败）直接丢弃临时消息，不落库。
    if (!failed && fullContent.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _messages = _messages.where((m) => m.id != temp.id).toList();
          _streamingMessage = null;
        });
      }
      return;
    }

    // 解析 @ 提及 → mentionedAiIds（与原有逻辑一致）
    final mentionPattern = RegExp(r'@([^\s]+)');
    final mentionedIds = <String>[];
    for (final match in mentionPattern.allMatches(fullContent)) {
      final name = match.group(1);
      if (name == null) continue;
      final found = _characters.firstWhere((c) => c.name == name,
          orElse: () => _characters.first);
      mentionedIds.add(found.id);
    }

    // 持久化纪律：仅完成时 put 一次（包含失败占位消息）。
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    final db = ref.read(databaseServiceProvider);
    await db.messageBox.put(temp.id, temp);
    if (mounted) setState(() => _streamingMessage = null);
  }

  /// 停止当前流式生成：取消订阅并保留已生成的（部分）内容落库。
  void _stopStreaming() {
    if (!_isStreaming) return;
    _streamSub?.cancel();
    _streamSub = null;
    // 唤醒 await done.future，让 _generateAiReply 收尾并把现有内容落库。
    _streamDone?.complete();
    if (mounted) setState(() => _isStreaming = false);
  }

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      final config = ref
          .read(databaseServiceProvider)
          .apiConfigBox
          .get(character.apiConfigId);
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

  List<Map<String, dynamic>> _buildApiMessages(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false}) {
    final msgs = <Map<String, dynamic>>[];

    if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty) {
      msgs.add(
          {'role': 'system', 'content': '【群聊记忆】${_groupMemory!.topicSummary}'});
    }

    if (isAutoChat) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      if (otherCharacters.isNotEmpty) {
        final charInfo = otherCharacters
            .map((c) => '${c.name}(${c.role}, ${c.age}岁)')
            .join('、');
        msgs.add({
          'role': 'system',
          'content': '现在群聊中正在自动对话。在场的其他角色：$charInfo。请自然地参与对话，可以回应其他人的发言。'
        });
      }
    }

    msgs.add({'role': 'system', 'content': character.systemPrompt});

    final otherCharacters =
        _characters.where((c) => c.id != character.id).toList();
    if (otherCharacters.isNotEmpty) {
      final characterInfo = otherCharacters
          .map((c) =>
              '${c.name}(${c.role}, ${c.age}岁, ${c.personalityTags.join('/')})')
          .join('；');
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
        final mentionedNames =
            m.mentionedAiIds.map((id) => nameById[id] ?? id).toList();
        msgs.add({
          'role': role,
          'content': '${m.content} (提到: ${mentionedNames.join(', ')})'
        });
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
      provider: ApiProvider.values.firstWhere((p) => p.name == config.provider,
          orElse: () => ApiProvider.deepseek),
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
        : DateTime(
            character.lastReplyTimestamp!.year,
            character.lastReplyTimestamp!.month,
            character.lastReplyTimestamp!.day);

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
    _mentionSelectedIndex = 0;
  }

  void _showMentionOverlay(Offset globalPosition) {
    if (_showMentionPopup) return;
    _showMentionPopup = true;
    _mentionSelectedIndex = 0;

    _mentionOverlay = OverlayEntry(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        // TapRegion：点击弹窗外部（含输入框、消息区）即关闭，解决点击其他位置不消失的问题。
        return TapRegion(
          onTapOutside: (_) => _hideMentionOverlay(),
          child: Positioned(
            width: 300,
            child: CompositedTransformFollower(
              link: _mentionLayerLink,
              showWhenUnlinked: false,
              offset: const Offset(0, -10),
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(16),
                color: cs.surfaceContainerHighest,
                child: _buildMentionPopupContent(cs),
              ),
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
      constraints: const BoxConstraints(maxHeight: 264),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                Icon(Icons.alternate_email_rounded,
                    size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text('提到谁',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withOpacity(0.4)),
          Flexible(child: _buildMentionList(cs)),
        ],
      ),
    );
  }

  Widget _buildMentionList(ColorScheme cs) {
    if (_filteredMentionMembers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
            child: Text('无匹配角色', style: TextStyle(fontSize: 14))),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _filteredMentionMembers.length,
      itemBuilder: (ctx2, i) {
        final c = _filteredMentionMembers[i];
        final pColor = _senderColor(c);
        final selected = i == _mentionSelectedIndex;
        return InkWell(
          onTap: () => _insertMention(c),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? cs.primary.withOpacity(0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pColor.withOpacity(0.14),
                    border: Border.all(
                        color: pColor.withOpacity(0.3), width: 1.2),
                  ),
                  child: Center(
                    child: Text(
                      c.avatar.isNotEmpty ? c.avatar : c.name[0],
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: pColor),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                          overflow: TextOverflow.ellipsis),
                      if (c.role.isNotEmpty)
                        Text(c.role,
                            style: TextStyle(
                                fontSize: 12, color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// @ 弹窗打开时的键盘导航：↑↓ 选择、回车插入、Esc 关闭。
  KeyEventResult _handleMentionKeyEvent(KeyEvent event) {
    if (!_showMentionPopup) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _mentionSelectedIndex = (_mentionSelectedIndex + 1)
            .clamp(0, _filteredMentionMembers.length - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _mentionSelectedIndex = (_mentionSelectedIndex - 1)
            .clamp(0, _filteredMentionMembers.length - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_filteredMentionMembers.isNotEmpty) {
        _insertMention(_filteredMentionMembers[_mentionSelectedIndex]);
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      _hideMentionOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _insertMention(AICharacter character) {
    final text = _textController.text;
    final cursorPos = _textController.selection.baseOffset;

    int atPos = text.lastIndexOf('@', cursorPos - 1);
    if (atPos < 0) atPos = 0;

    final newText =
        '${text.substring(0, atPos)}@${character.name} ${text.substring(cursorPos)}';
    _textController.value = TextEditingValue(
      text: newText,
      selection:
          TextSelection.collapsed(offset: atPos + character.name.length + 2),
    );

    _hideMentionOverlay();
  }

  void _handleTextChanged(String text) {
    if (!_showMentionPopup) {
      if (text.contains('@')) {
        _filteredMentionMembers = List.from(_characters);
        _mentionSelectedIndex = 0;
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

    // 列表变化后，高亮索引重置到首项并夹取到合法范围
    if (_mentionSelectedIndex >= _filteredMentionMembers.length) {
      _mentionSelectedIndex = 0;
    }

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
      final found = _characters.firstWhere((c) => c.name == name,
          orElse: () => _characters.first);
      mentionedIds.add(found.id);
    }
    final englishPattern = RegExp(r'@(\w+)');
    for (final match in englishPattern.allMatches(content)) {
      final name = match.group(1)!;
      final found = _characters.firstWhere((c) => c.name == name,
          orElse: () => _characters.first);
      mentionedIds.add(found.id);
    }
    return mentionedIds;
  }

  AICharacter? _selectReplyCharacter(List<String>? mentionedIds) {
    final eligible = _characters.where(_isEligibleToReply).toList();
    if (eligible.isEmpty) return null;

    if (mentionedIds != null && mentionedIds.isNotEmpty) {
      final priorityChars =
          eligible.where((c) => mentionedIds.contains(c.id)).toList();
      if (priorityChars.isNotEmpty) {
        return _shuffle(priorityChars).first;
      }
    }

    if (_pendingMentionedIds.isNotEmpty) {
      final pendingEligible =
          eligible.where((c) => _pendingMentionedIds.contains(c.id)).toList();
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
        ? (ref
                .read(databaseServiceProvider)
                .apiConfigBox
                .get(sender.apiConfigId)
                ?.provider ??
            sender.apiProvider)
        : sender.apiProvider;
    return providerColor(providerName);
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
          title: Text(_group?.name ?? '加载中...',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: cs.onSurface)),
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
            Text(_group?.name ?? '群聊',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: cs.onSurface)),
            if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty)
              Text(_groupMemory!.topicSummary,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_rounded, size: 22),
            onPressed: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ExportPage(initialGroupId: widget.groupId),
              ));
            },
            tooltip: '导出本群对话',
          ),
          // 成员入口：头像堆叠 + 人数，比单一图标更易发现
          GestureDetector(
            onTap: () => _showMembersSheet(cs),
            child: _buildMemberStackChip(cs),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 未配置 API Key 时给出醒目提示，避免「发了消息 AI 不回复」的困惑
          if (!_hasAnyApiConfig) _buildApiWarningBanner(cs),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(cs)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      // 日期分隔：首条或与上一条不在同一天时显示
                      final showDate = index == 0 ||
                          !_isSameDay(message.timestamp,
                              _messages[index - 1].timestamp);
                      final sender = message.senderType == 'user'
                          ? null
                          : _characters.firstWhere(
                              (c) => c.id == message.senderId,
                              orElse: () => _characters.isNotEmpty
                                  ? _characters.first
                                  : AICharacter(
                                      name: '未知',
                                      avatar: '?',
                                      age: 0,
                                      role: '',
                                      personalityTags: const [],
                                      systemPrompt: '',
                                      apiKey: '',
                                      apiProvider: 'deepseek',
                                      apiConfigId: '',
                                    ),
                            );
                      final isStreaming = _streamingMessage != null &&
                          _streamingMessage!.id == message.id;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDate) _buildDateDivider(cs, message.timestamp),
                          _MessageBubble(
                            message: message,
                            sender: sender,
                            characters: _characters,
                            cs: cs,
                            isStreaming: isStreaming,
                          ),
                        ],
                      );
                    },
                  ),
          ),
          if (_isAiReplying)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Row(
                children: [
                  Text(
                    _isStreaming ? 'AI 正在生成...' : 'AI 正在回复...',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  if (_isStreaming) ...[
                    const SizedBox(width: 10),
                    // 「停止生成」按钮：取消当前流订阅
                    TextButton.icon(
                      onPressed: _stopStreaming,
                      icon: const Icon(Icons.stop_rounded, size: 16),
                      label: const Text('停止生成'),
                      style: TextButton.styleFrom(
                        foregroundColor: cs.error,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          _buildInputArea(cs),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppTheme.primaryGradient,
              ),
              child: const Icon(Icons.groups_rounded,
                  size: 44, color: Colors.white),
            ),
            const SizedBox(height: 24),
            Text('欢迎来到 ${_group?.name ?? '群聊'}',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              '这是一个 AI 群聊模拟器。\n发条消息，AI 角色会自动回复；\n用 @ 可以指定某个角色回应。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14, height: 1.6, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _hintChip(cs, '说句「你好」试试'),
                _hintChip(cs, '@角色名 提到谁'),
                if (_characters.isNotEmpty)
                  _hintChip(cs, '${_characters.length} 位 AI 在线'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hintChip(ColorScheme cs, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
    );
  }

  /// 未配置 API Key 时的醒目横幅
  Widget _buildApiWarningBanner(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.errorContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: cs.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '尚未配置 API Key，AI 不会回复或自动聊天',
              style: TextStyle(fontSize: 13, color: cs.onSurface),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pushNamed(context, '/settings'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
            child: Text('去配置',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: cs.error)),
          ),
        ],
      ),
    );
  }

  Widget _buildDateDivider(ColorScheme cs, DateTime dt) {
    final label = _dateLabel(dt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
        ),
      ),
    );
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String _dateLabel(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(target).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '$diff 天前';
    return '${dt.year}/${dt.month}/${dt.day}';
  }

  /// 成员头像堆叠 + 人数 chip（AppBar 入口）
  Widget _buildMemberStackChip(ColorScheme cs) {
    final shown = _characters.take(3).toList();
    const overlap = 16.0;
    final stackWidth = shown.isEmpty
        ? 0.0
        : 26.0 + (shown.length - 1) * overlap;
    return Container(
      padding: const EdgeInsets.only(left: 8, right: 10, top: 4, bottom: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (shown.isNotEmpty)
            SizedBox(
              width: stackWidth,
              height: 26,
              child: Stack(
                children: [
                  for (int i = 0; i < shown.length; i++)
                    Positioned(
                      left: i * overlap,
                      child: _miniAvatar(shown[i], 26, cs),
                    ),
                ],
              ),
            ),
          const SizedBox(width: 6),
          Text('${_characters.length}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface)),
        ],
      ),
    );
  }

  Widget _miniAvatar(AICharacter c, double size, ColorScheme cs) {
    final color = _senderColor(c);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: cs.surfaceContainerHighest, width: 2),
      ),
      child: Center(
        child: Text(
          c.avatar.isNotEmpty ? c.avatar : c.name[0],
          style: TextStyle(
              fontSize: size * 0.5,
              fontWeight: FontWeight.w700,
              color: Colors.white),
        ),
      ),
    );
  }

  void _showMembersSheet(ColorScheme cs) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _buildMembersSheet(cs),
    );
  }

  Widget _buildMembersSheet(ColorScheme cs) {
    final ownerName = _group?.ownerName ?? '我';
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Text('群成员',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface)),
                const SizedBox(width: 8),
                Text('${_characters.length + 1}',
                    style: TextStyle(
                        fontSize: 14, color: cs.onSurfaceVariant)),
              ],
            ),
            const SizedBox(height: 16),
            // 群主（真人用户）置顶
            _buildMemberTile(
              cs: cs,
              avatarText: '我',
              avatarColor: cs.primary,
              name: ownerName,
              subtitle: '群主',
              isOwner: true,
            ),
            Divider(
                height: 24,
                color: cs.outlineVariant.withOpacity(0.4)),
            ..._characters.map((c) {
              final color = _senderColor(c);
              return _buildMemberTile(
                cs: cs,
                avatarText: c.avatar.isNotEmpty ? c.avatar : c.name[0],
                avatarColor: color,
                name: c.name,
                subtitle: '${c.role} · ${c.age}岁',
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildMemberTile({
    required ColorScheme cs,
    required String avatarText,
    required Color avatarColor,
    required String name,
    required String subtitle,
    bool isOwner = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: avatarColor.withOpacity(0.15),
              border: Border.all(color: avatarColor.withOpacity(0.3), width: 1.5),
            ),
            child: Center(
              child: Text(avatarText,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: avatarColor)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(name,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (isOwner) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: cs.primary.withOpacity(0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('群主',
                            style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: cs.primary)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        fontSize: 13, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// 输入区键盘事件：@ 弹窗打开时走导航；桌面端回车发送、Shift+回车换行。
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // @ 弹窗键盘导航优先（↑↓ 选择、回车插入、Esc 关闭）
    if (_showMentionPopup) return _handleMentionKeyEvent(event);
    // 桌面端：Enter 发送、Shift+Enter 换行
    if (_isDesktop) {
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (!HardwareKeyboard.instance.isShiftPressed) {
          if (!_isInputEmpty && !_isAiReplying && !_isStreaming) {
            _sendMessage();
          }
          return KeyEventResult.handled; // 阻止插入换行
        }
        // Shift+Enter：放行，让 TextField 插入换行
      }
    }
    return KeyEventResult.ignored;
  }

  Widget _buildInputArea(ColorScheme cs) {
    return CompositedTransformTarget(
      link: _mentionLayerLink,
      child: KeyboardListener(
        focusNode: _focusNode,
        onKeyEvent: _handleKeyEvent,
        child: Container(
          padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 12,
              bottom: MediaQuery.of(context).padding.bottom + 12),
          decoration: BoxDecoration(
            color: cs.surface,
            border: Border(
                top: BorderSide(color: cs.outlineVariant.withOpacity(0.5))),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.25),
                  blurRadius: 14,
                  offset: const Offset(0, -4))
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(minHeight: 40, maxHeight: 120),
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: '输入消息，回车换行，@ 提到角色...',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: cs.outlineVariant)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: cs.outlineVariant)),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide:
                              BorderSide(color: cs.primary, width: 1.5)),
                      filled: true,
                      fillColor: cs.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 10),
                      isDense: true,
                    ),
                    // 多行：移动端回车=换行，靠发送按钮提交；桌面端回车=发送（见 _handleKeyEvent）
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    maxLines: null,
                    onChanged: _handleTextChanged,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                    _isStreaming ? Icons.stop_rounded : Icons.send_rounded,
                    size: 24),
                color: _isStreaming
                    ? cs.error
                    : ((_isAiReplying || _isInputEmpty)
                        ? cs.onSurfaceVariant.withOpacity(0.4)
                        : cs.primary),
                onPressed: _isStreaming
                    ? _stopStreaming
                    : ((_isAiReplying || _isInputEmpty) ? null : _sendMessage),
                tooltip: _isStreaming ? '停止生成' : '发送',
              ),
            ],
          ),
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
  final bool isStreaming;

  const _MessageBubble({
    required this.message,
    this.sender,
    required this.characters,
    required this.cs,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.senderType == 'user';

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser && sender != null) ...[
            CircleAvatar(
              radius: 20,
              backgroundColor: _senderColor(sender!).withOpacity(0.12),
              child: Text(
                  sender!.avatar.isNotEmpty ? sender!.avatar : sender!.name[0],
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _senderColor(sender!))),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (!isUser && sender != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Text(sender!.name,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurfaceVariant)),
                  ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser ? null : cs.surfaceContainer,
                    gradient: isUser ? AppTheme.primaryGradient : null,
                    border: isUser
                        ? null
                        : Border.all(color: cs.outlineVariant.withOpacity(0.6)),
                    borderRadius: BorderRadius.circular(18).copyWith(
                      bottomLeft: isUser
                          ? const Radius.circular(18)
                          : const Radius.circular(4),
                      bottomRight: isUser
                          ? const Radius.circular(4)
                          : const Radius.circular(18),
                    ),
                  ),
                  child: _buildContent(message, sender, isUser, cs),
                ),
                Padding(
                  padding: EdgeInsets.only(
                      top: 4, left: isUser ? 0 : 4, right: !isUser ? 0 : 4),
                  child: Text(
                    _ChatRoomPageState._formatTime(message.timestamp),
                    style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant.withOpacity(0.7)),
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

  Widget _buildContent(
      Message message, AICharacter? sender, bool isUser, ColorScheme cs) {
    final textColor = isUser ? cs.onPrimary : cs.onSurface;
    final content = message.content.replaceAll('\\n', '\n');

    Widget base;
    if (message.isMention &&
        message.mentionedAiIds.isNotEmpty &&
        sender != null) {
      final mentionNames = message.mentionedAiIds.map((id) {
        return characters.firstWhere((c) => c.id == id, orElse: () {
          return AICharacter(
              name: id,
              avatar: '?',
              age: 0,
              role: '',
              personalityTags: const [],
              systemPrompt: '',
              apiKey: '',
              apiProvider: 'deepseek',
              apiConfigId: '');
        }).name;
      }).toList();
      base = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(content,
              style: TextStyle(fontSize: 15, color: textColor, height: 1.4)),
          if (mentionNames.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 4,
                children: mentionNames.map((name) {
                  return Chip(
                      label: Text(name, style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap);
                }).toList(),
              ),
            ),
        ],
      );
    } else {
      base = Text(content,
          style: TextStyle(fontSize: 15, color: textColor, height: 1.4));
    }

    // 正在流式生成时，在内容末尾追加一个闪烁光标，营造「打字机」观感。
    if (isStreaming) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(child: base),
          const SizedBox(width: 2),
          _BlinkingCursor(color: textColor),
        ],
      );
    }
    return base;
  }

  Color _senderColor(AICharacter sender) => providerColor(sender.apiProvider);
}

/// 流式生成时显示在气泡末尾的闪烁光标（打字机效果）。
///
/// 自带 AnimationController 循环播放透明度，不依赖外部状态，自管理生命周期。
class _BlinkingCursor extends StatefulWidget {
  final Color color;

  const _BlinkingCursor({required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 600ms 一个周期，reverse 实现呼吸式闪烁
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Text(
        '▌',
        style: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600, color: widget.color),
      ),
    );
  }
}
