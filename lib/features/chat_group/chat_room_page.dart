import 'dart:async';
import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:flutter_tts/flutter_tts.dart';

enum AutoChatStatus { idle, waiting, generating, paused, unavailable, error }

enum ReplyBlockReason {
  noApiConfig,
  inactive,
  hourlyLimit,
  alreadyGenerating,
  networkError,
}

List<String> parseMentionedCharacterIds(
  String content,
  List<AICharacter> characters,
) {
  final mentionedIds = <String>[];
  if (characters.isEmpty || content.isEmpty) return mentionedIds;

  final byName = {for (final c in characters) c.name: c.id};
  final mentionPattern = RegExp(r'@([^@\s，。！？!?、；;：:,.]+)');
  for (final match in mentionPattern.allMatches(content)) {
    final name = match.group(1);
    final id = name == null ? null : byName[name];
    if (id != null && !mentionedIds.contains(id)) {
      mentionedIds.add(id);
    }
  }
  return mentionedIds;
}

class ChatRoomPage extends ConsumerStatefulWidget {
  final String groupId;

  const ChatRoomPage({super.key, required this.groupId});

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends ConsumerState<ChatRoomPage> {
  final _textController = TextEditingController();
  final _memberSearchController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  final _chatApi = ChatApiService();
  final _random = Random();
  final FlutterTts _flutterTts = FlutterTts();
  late final DatabaseService _db;

  ChatGroup? _group;
  List<AICharacter> _characters = [];
  List<Message> _messages = [];
  GroupMemory? _groupMemory;

  bool _isLoading = true;
  bool _isAiReplying = false;
  int _consecutiveRound = 0;
  final int _maxAutoRounds = 3;

  // 用户消息队列：AI 回复期间用户发的消息排队在此，回合结束后自动触发回复。
  final List<dynamic> _pendingUserMessages = [];

  // @ 成员选择弹窗
  OverlayEntry? _mentionOverlay;
  bool _showMentionPopup = false;
  List<AICharacter> _filteredMentionMembers = [];
  int _mentionSelectedIndex = 0; // 键盘上下选择的高亮项
  final LayerLink _mentionLayerLink = LayerLink();

  // AI 自主聊天
  Timer? _autoChatTimer;
  bool _isAutoChatEnabled = true;
  int _autoChatRoundCount = 0;
  final int _maxAutoChatRounds = 5;
  final Random _autoChatRandom = Random();
  AutoChatStatus _autoChatStatus = AutoChatStatus.idle;
  ReplyBlockReason? _lastReplyBlockReason;

  // 待回应 @ 列表
  final List<String> _pendingMentionedIds = [];

  bool _isInputEmpty = true;

  // —— 引用回复（quote-reply）——
  Message? _quotedMessage;

  // —— 重新生成 ——
  bool _isRegenerating = false;
  String _regenerateMessageId = '';
  List<Message> _regenerateContext = [];

  // —— 搜索 ——
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  List<Message> _searchResults = [];
  int? _searchFocusIndex;

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
    _db = ref.read(databaseServiceProvider);
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
    _memberSearchController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    _searchController.dispose();
    _autoChatTimer?.cancel();
    _hideMentionOverlay();
    _ttsStop();
    super.dispose();
  }

  Future<void> _loadData() async {
    final group = _db.chatGroupBox.get(widget.groupId);
    if (group == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('群聊不存在'), behavior: SnackBarBehavior.floating));
        Navigator.pop(context);
      }
      return;
    }

    final characters = group.aiCharacterIds
        .map((id) => _db.aiCharacterBox.get(id))
        .whereType<AICharacter>()
        .where((c) => c.isActive)
        .toList();

    // 检测是否有角色配置了 API Key（决定 AI 能否回复/自动聊天）
    final hasApi = characters.any((c) {
      final cfg = _resolveApiConfig(c);
      return cfg != null && cfg.apiKey.isNotEmpty;
    });

    final messages = _db.messageBox.values
        .where((m) => m.groupId == widget.groupId)
        .toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));

    final memoryBox = _db.groupMemoryBox;
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
      _autoChatStatus =
          hasApi ? AutoChatStatus.waiting : AutoChatStatus.unavailable;
      _isLoading = false;
    });

    _scrollToBottom();

    if (_isAutoChatEnabled && _characters.isNotEmpty && hasApi) {
      Future.delayed(const Duration(seconds: 3), () {
        if (_canTouchUi) _startAutoChat();
      });
    }
  }

  void _startAutoChat() {
    if (!_canTouchUi || !_isAutoChatEnabled || !_hasAnyApiConfig) return;
    _autoChatTimer?.cancel();
    setState(() => _autoChatStatus = AutoChatStatus.waiting);
    _autoChatTimer = Timer.periodic(
      Duration(seconds: 3 + _autoChatRandom.nextInt(3)),
      (_) => _tryAutoChatRound(),
    );
  }

  void _stopAutoChat() {
    _autoChatTimer?.cancel();
    _autoChatTimer = null;
    _autoChatRoundCount = 0;
    if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
  }

  Future<void> _tryAutoChatRound() async {
    if (!_canTouchUi || !_isAutoChatEnabled || _characters.isEmpty) return;
    if (_isAiReplying ||
        _isStreaming ||
        _textController.text.trim().isNotEmpty) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (_autoChatRoundCount >= _maxAutoChatRounds) {
      _stopAutoChat();
      Future.delayed(const Duration(seconds: 10), () {
        if (_canTouchUi && _isAutoChatEnabled) _startAutoChat();
      });
      return;
    }

    final speakers = ChatActivityPolicy.selectAutoChatSpeakers(
      characters: _characters,
      isEligible: _isEligibleToReply,
      random: _autoChatRandom,
    );

    if (speakers.isEmpty) {
      if (_canTouchUi) {
        setState(() {
          _autoChatStatus = AutoChatStatus.unavailable;
          _lastReplyBlockReason = _eligibleCharacters.isEmpty
              ? _firstBlockReason(_characters)
              : null;
        });
      }
      return;
    }

    setState(() {
      _autoChatRoundCount++;
      _autoChatStatus = AutoChatStatus.generating;
    });

    for (final speaker in speakers) {
      if (!_canTouchUi || !_isAutoChatEnabled) break;
      if (!_isEligibleToReply(speaker)) continue;
      await _generateAiReply(speaker, _messages.toList(), null,
          isAutoChat: true);
      await _delay();
    }

    await _maybeUpdateMemory();
    if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.waiting);
  }

  bool get _canTouchUi => mounted && !_disposed;

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
    if (text.isEmpty) return;

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
      replyToMessageId: _quotedMessage?.id,
    ));
    _cancelQuote();

    _autoChatRoundCount = 0;

    if (_characters.isEmpty) {
      if (mounted) {
        messenger.showSnackBar(const SnackBar(
            content: Text('该群聊没有活跃的角色'), behavior: SnackBarBehavior.floating));
      }
      return;
    }

    if (_isAiReplying) {
      // AI 正在回复中，排队等待当前回合结束后再处理。
      _pendingUserMessages.add(_PendingUserMessage(text, mentionedIds));
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

    final charactersToReply = _selectReplyCharacters(mentionedIds);
    if (charactersToReply.isEmpty) {
      final blockReason = _firstBlockReason(_characters);
      setState(() {
        _isAiReplying = false;
        _lastReplyBlockReason = blockReason;
        _autoChatStatus = AutoChatStatus.unavailable;
      });
      if (mounted && !isAutoChat) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_replyBlockText(blockReason)),
          behavior: SnackBarBehavior.floating,
          action: blockReason == ReplyBlockReason.noApiConfig
              ? SnackBarAction(
                  label: '去设置',
                  onPressed: () => Navigator.pushNamed(context, '/settings'),
                )
              : null,
        ));
      }
      return;
    }

    final repliedIds = <String>[];
    for (final character in charactersToReply) {
      if (!_canTouchUi) return;
      final wasPendingReply = _pendingMentionedIds.contains(character.id);
      await _generateAiReply(
          character, _recentMessagesForContext(), userMessage,
          isAutoChat: isAutoChat);
      repliedIds.add(character.id);
      await _delay();
      if (wasPendingReply) {
        _pendingMentionedIds.remove(character.id);
      }
    }

    if (mentionedIds != null &&
        mentionedIds.isNotEmpty &&
        repliedIds.every((id) => !mentionedIds.contains(id)) &&
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

    // 处理排队中的用户消息：当前回合结束后自动触发下一轮 AI 回复。
    if (_pendingUserMessages.isNotEmpty) {
      final next = _pendingUserMessages.removeAt(0);
      await _runAiRound(userMessage: next.text, mentionedIds: next.mentionedIds);
    }
  }

  Future<void> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false}) async {
    final config = _resolveApiConfig(character);
    if (config == null) {
      if (_canTouchUi) {
        setState(() {
          _autoChatStatus = AutoChatStatus.unavailable;
          _lastReplyBlockReason = ReplyBlockReason.noApiConfig;
        });
      }
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
    debugPrint('[AI Reply] ${character.name} apiMessages count=${apiMessages.length}');
    for (var i = 0; i < apiMessages.length; i++) {
      final m = apiMessages[i];
      final preview = (m['content'] as String?)?.substring(0, (m['content'] as String?)?.length.clamp(0, 60) ?? 0);
      debugPrint('[AI Reply]   [$i] role=${m['role']} content=${preview}');
    }

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
    int? promptTokens;
    int? completionTokens;

    final sub = _chatApi
        .streamChatMessage(
      apiKey: config.apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
    ).listen(
      (e) {
        if (!_canTouchUi) return;
        debugPrint('[AI Stream] ${character.name} event=${e.type}');
        switch (e.type) {
          case ChatStreamEventType.token:
            fullContent += e.delta ?? '';
            temp.content = fullContent;
            if (_canTouchUi) setState(() {});
            _scrollToBottom();
            break;
          case ChatStreamEventType.done:
            if ((e.content ?? '').isNotEmpty) fullContent = e.content!;
            temp.content = fullContent;
            if (_canTouchUi) setState(() {});
            if (e.promptTokens != null) promptTokens = e.promptTokens;
            if (e.completionTokens != null) completionTokens = e.completionTokens;
            if (!done.isCompleted) done.complete();
            break;
          case ChatStreamEventType.error:
            failed = true;
            _lastReplyBlockReason = ReplyBlockReason.networkError;
            fullContent = '[${character.name} 回复失败: ${e.message}]';
            temp.content = fullContent;
            if (_canTouchUi) {
              setState(() => _autoChatStatus = AutoChatStatus.error);
            }
            if (!done.isCompleted) done.complete();
        }
      },
      onError: (err) {
        if (!_canTouchUi) return;
        failed = true;
        _lastReplyBlockReason = ReplyBlockReason.networkError;
        fullContent = '[${character.name} 回复失败: $err]';
        temp.content = fullContent;
        if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.error);
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

    debugPrint('[AI Stream] ${character.name} DONE fullContent=${fullContent.substring(0, (fullContent.length).clamp(0, 50))} failed=$failed');

    // 空内容也给出可见反馈，否则 @ 触发会像没有人理会。
    if (!failed && fullContent.trim().isEmpty) {
      debugPrint('[AI Stream] ${character.name} EMPTY content -> using fallback');
      fullContent = ChatActivityPolicy.emptyReplyFallback(
        characterName: character.name,
        role: character.role,
        groupTheme: _group?.theme ?? '',
        userMessage: userMessage,
        isAutoChat: isAutoChat,
        random: _random,
      );
      temp.content = fullContent;
      if (_canTouchUi) setState(() {});
    }

    // 解析 @ 提及 → mentionedAiIds（未知名称忽略，避免误指向第一个成员）。
    final mentionedIds = parseMentionedCharacterIds(fullContent, _characters);

    // 移除 LLM 可能附带的名字前缀（UI 已独立显示角色名）。
    fullContent = _stripNamePrefix(fullContent, character.name);

    // 持久化纪律：仅完成时 put 一次（包含失败占位消息）。
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    await _db.messageBox.put(temp.id, temp);
    _recordReplyUsage(character);
    if (promptTokens != null && completionTokens != null) {
      _db.recordTokenUsage(
        characterId: character.id,
        inputTokens: promptTokens!,
        outputTokens: completionTokens!,
      );
    }
    if (_canTouchUi) setState(() => _streamingMessage = null);
  }

  /// 停止当前流式生成：取消订阅并保留已生成的（部分）内容落库。
  void _stopStreaming() {
    if (!_isStreaming) return;
    _streamSub?.cancel();
    _streamSub = null;
    // 唤醒 await done.future，让 _generateAiReply 收尾并把现有内容落库。
    if (_streamDone != null && !_streamDone!.isCompleted) {
      _streamDone!.complete();
    }
    if (_canTouchUi) {
      setState(() {
        _isStreaming = false;
        _autoChatStatus = AutoChatStatus.paused;
      });
    }
  }

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      final config = _db.apiConfigBox.get(character.apiConfigId);
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

    // ── 1. 群聊记忆摘要 ───────────────────────────────────────────────
    if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty) {
      msgs.add(
          {'role': 'system', 'content': '【群聊记忆】${_groupMemory!.topicSummary}'});
    }

    // ── 2. 角色个体记忆（如果有的话） ────────────────────────────────
    if (character.memorySummary.isNotEmpty) {
      msgs.add(
          {'role': 'system', 'content': '【${character.name}的自我记忆】${character.memorySummary}'});
    }

    // ── 3. 群聊场景 + 当前对话焦点 ─────────────────────────────────
    final groupName = _group?.name ?? '这个群';
    final groupTheme = _group?.theme ?? '日常聊天';
    final scenarioPrompt = _scenarioPromptFor(groupTheme);
    final recentContext = _extractRecentFocus(context);
    final nameById = {for (final c in _characters) c.id: c.name};
    msgs.add({
      'role': 'system',
      'content':
          '你正在参加一个高活跃度群聊「$groupName」，主题是「$groupTheme」。'
          '回复要像真实聊天群：自然接话、简短、有个人观点，可以顺手回应上一位成员或点名邀请别人，但不要每次都长篇总结。'
          '重要：你的回复不要带自己的名字前缀（如「张三：」或「【张三】：」），直接说内容即可，头像和名字由界面自动显示。'
          '$scenarioPrompt'
          '$recentContext'
    });

    // ── 3.5 最后一条用户消息强调 ──────────────────────────────────
    if (context.isNotEmpty) {
      final lastUserMsg = context.lastWhere((m) => m.senderType == 'user', orElse: () => context.first);
      if (lastUserMsg.senderType == 'user') {
        final speakerName = nameById[lastUserMsg.senderId] ?? '一位群友';
        final truncated = lastUserMsg.content.length > 100
            ? '${lastUserMsg.content.substring(0, 100)}...'
            : lastUserMsg.content;
        msgs.add({
          'role': 'system',
          'content': '【当前任务】$speakerName 刚说："$truncated" —— 请作为 ${character.name} 针对这条消息做出自然回应。'
        });
      }
    }

    // ── 4. 自动聊天提示（仅 auto-chat 模式） ────────────────────────
    if (isAutoChat) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      if (otherCharacters.isNotEmpty) {
        final charInfo = otherCharacters
            .map((c) => '${c.name}(${c.role}, ${c.age}岁)')
            .join('、');
        msgs.add({
          'role': 'system',
          'content':
              '现在群聊中正在自动对话。在场的其他角色：$charInfo。请主动抛话题、接上一条发言，或把话题递给某位成员，让群显得有人气。'
        });
      }
    }

    // ── 5. 角色人设 ─────────────────────────────────────────────────
    msgs.add({'role': 'system', 'content': character.systemPrompt});

    // ── 6. 其他角色信息 ─────────────────────────────────────────────
    final otherCharacters2 =
        _characters.where((c) => c.id != character.id).toList();
    if (otherCharacters2.isNotEmpty) {
      final characterInfo = otherCharacters2
          .map((c) =>
              '${c.name}(${c.role}, ${c.age}岁, ${c.personalityTags.join('/')})')
          .join('；');
      msgs.add({'role': 'system', 'content': '群聊中的其他角色：$characterInfo'});
    }

    // ── 7. 聊天历史（最多 20 条） ──────────────────────────────────
    final historyMessages = context.toList();
    final recentHistory = historyMessages.length > 20
        ? historyMessages.sublist(historyMessages.length - 20)
        : historyMessages;
    for (final m in recentHistory) {
      if (m.senderType == 'user') {
        // 真人用户消息 → user 角色。
        msgs.add({'role': 'user', 'content': m.content});
      } else if (m.senderId == character.id) {
        // 当前角色自己的消息 → assistant 角色（LLM 看到自己的历史发言）。
        msgs.add({'role': 'assistant', 'content': m.content});
      } else {
        // 其他 AI 角色的消息 → user 角色 + 发言者标注（LLM 知道这是别人说的话）。
        final speakerName = nameById[m.senderId] ?? '其他角色';
        final content =
            m.content.startsWith('【$speakerName】：')
                ? m.content
                : '【$speakerName】：${m.content}';
        msgs.add({'role': 'user', 'content': content});
      }
    }

    // ── 8. 当前用户消息（仅当历史为空时） ──────────────────────────
    if (userMessage != null && historyMessages.isEmpty) {
      msgs.add({'role': 'user', 'content': userMessage});
    }

    return msgs;
  }

  /// 根据群聊主题匹配场景模板，返回额外的系统提示词片段。
  /// 不匹配任何模板时返回空字符串。
  String _scenarioPromptFor(String groupTheme) {
    final t = groupTheme.toLowerCase();
    if (t.contains('辩论') || t.contains('debate')) {
      return '\n\n【场景模式：辩论】你正在参与一场正式辩论。立场鲜明、逻辑清晰、使用论据支撑观点，反驳对方论点但不人身攻击。每轮发言控制在 3 句话以内。';
    }
    if (t.contains('吐槽') || t.contains('调侃') || t.contains('roast')) {
      return '\n\n【场景模式：吐槽大会】你正在参加吐槽大会。用犀利幽默的方式吐槽在场话题或人物，玩笑适度不过分，语气轻松有梗。';
    }
    if (t.contains('开会') || t.contains('会议') || t.contains('board') || t.contains('meeting')) {
      return '\n\n【场景模式：会议讨论】你正在参加一场正式会议。发言简洁有条理，可以提问、补充意见、总结要点，避免闲聊。';
    }
    if (t.contains('采访') || t.contains('访谈') || t.contains('interview')) {
      return '\n\n【场景模式：采访】你正在接受采访。回答问题详细有深度，可以分享经历和见解，偶尔反问记者以增加互动。';
    }
    if (t.contains('相亲') || t.contains('dating') || t.contains('交友')) {
      return '\n\n【场景模式：相亲交友】你正在参加相亲/交友活动。展示个人魅力，真诚友好，互相了解兴趣爱好，避免过于冒进。';
    }
    if (t.contains('职场') || t.contains('办公') || t.contains('工作') || t.contains('office')) {
      return '\n\n【场景模式：职场办公】你正在职场环境中交流。语气专业但友好，可以讨论工作进展、协调任务、分享职场经验。';
    }
    return '';
  }

  /// 从最近的消息中提取对话焦点，帮助 AI 理解"现在在聊什么"。
  /// 取最近 3 条消息的内容拼成一段焦点摘要，注入到 system prompt 中。
  String _extractRecentFocus(List<Message> messages) {
    if (messages.isEmpty) return '';
    final recent = messages.length > 3
        ? messages.sublist(messages.length - 3)
        : messages;
    final snippets = recent.map((m) => m.content).toList();
    final joined = snippets.join(' → ');
    if (joined.length > 200) {
      return '\n\n【当前对话焦点】最近大家在聊：${joined.substring(0, 200)}...';
    }
    return '\n\n【当前对话焦点】最近大家在聊：$joined';
  }

  /// 移除 LLM 回复中可能附带的名字前缀（如「张三：」「【张三】：」）。
  /// UI 已独立显示角色名，内容中不应重复。
  String _stripNamePrefix(String content, String characterName) {
    var result = content;
    final patterns = [
      '【$characterName】：',
      '$characterName：',
      '$characterName: ',
      '【$characterName】',
    ];
    for (final p in patterns) {
      if (result.startsWith(p)) {
        result = result.substring(p.length).trimLeft();
        break;
      }
    }
    return result;
  }

  Future<void> _appendMessage(Message message) async {
    await _db.messageBox.put(message.id, message);
    if (!_canTouchUi) return;
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
    if (_blockReasonFor(character) != null) return false;
    return true;
  }

  ReplyBlockReason? _blockReasonFor(AICharacter character) {
    if (!character.isActive) return ReplyBlockReason.inactive;
    final config = _resolveApiConfig(character);
    if (config == null || config.apiKey.isEmpty) {
      return ReplyBlockReason.noApiConfig;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastReplyDay = character.lastReplyTimestamp == null
        ? null
        : DateTime(
            character.lastReplyTimestamp!.year,
            character.lastReplyTimestamp!.month,
            character.lastReplyTimestamp!.day);

    if (lastReplyDay == null || lastReplyDay != today) {
      return null;
    }

    final diff = now.difference(character.lastReplyTimestamp!).inMinutes;
    if (diff >= 60) {
      return null;
    }

    return character.hourlyReplyCount < character.hourlyReplyLimit
        ? null
        : ReplyBlockReason.hourlyLimit;
  }

  List<AICharacter> get _eligibleCharacters =>
      _characters.where(_isEligibleToReply).toList();

  ReplyBlockReason? _firstBlockReason(List<AICharacter> characters) {
    if (characters.isEmpty) return null;
    final reasons =
        characters.map(_blockReasonFor).whereType<ReplyBlockReason>().toList();
    if (reasons.isEmpty) return null;
    if (reasons.every((r) => r == ReplyBlockReason.noApiConfig)) {
      return ReplyBlockReason.noApiConfig;
    }
    if (reasons.every((r) => r == ReplyBlockReason.inactive)) {
      return ReplyBlockReason.inactive;
    }
    if (reasons.every((r) => r == ReplyBlockReason.hourlyLimit)) {
      return ReplyBlockReason.hourlyLimit;
    }
    return reasons.first;
  }

  void _recordReplyUsage(AICharacter character) {
    final now = DateTime.now();
    final last = character.lastReplyTimestamp;
    final sameDay = last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day;
    final withinHour = last != null && now.difference(last).inMinutes < 60;
    if (!sameDay || !withinHour) {
      character.hourlyReplyCount = 1;
    } else {
      character.hourlyReplyCount += 1;
    }
    character.lastReplyTimestamp = now;
    character.save();
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
      constraints: const BoxConstraints(maxWidth: 300, maxHeight: 264),
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
          SizedBox(
            height: min(220, _filteredMentionMembers.length * 62.0),
            child: _buildMentionList(cs),
          ),
        ],
      ),
    );
  }

  Widget _buildMentionList(ColorScheme cs) {
    if (_filteredMentionMembers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: Text('无匹配角色', style: TextStyle(fontSize: 14))),
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color:
                  selected ? cs.primary.withOpacity(0.14) : Colors.transparent,
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
                    border:
                        Border.all(color: pColor.withOpacity(0.3), width: 1.2),
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
    return parseMentionedCharacterIds(content, _characters);
  }

  List<AICharacter> _selectReplyCharacters(List<String>? mentionedIds) {
    return ChatActivityPolicy.selectUserReplyCharacters(
      characters: _characters,
      mentionedIds: mentionedIds ?? const [],
      pendingMentionedIds: _pendingMentionedIds,
      isEligible: _isEligibleToReply,
      random: _random,
    );
  }

  List<Message> _recentMessagesForContext() {
    return _messages.length > 20
        ? _messages.sublist(_messages.length - 20)
        : _messages.toList();
  }

  String _replyBlockText(ReplyBlockReason? reason) {
    switch (reason) {
      case ReplyBlockReason.noApiConfig:
        return '角色未配置 API Key，AI 无法回复。请到「设置」配置 API';
      case ReplyBlockReason.inactive:
        return '当前群聊没有启用中的角色';
      case ReplyBlockReason.hourlyLimit:
        return '角色已达到本小时回复上限，稍后再试';
      case ReplyBlockReason.alreadyGenerating:
        return 'AI 正在生成中，请稍后再发';
      case ReplyBlockReason.networkError:
        return '网络请求失败，请检查 API 配置';
      case null:
        return '暂时没有可以回复的角色';
    }
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
        ? (_db.apiConfigBox.get(sender.apiConfigId)?.provider ??
            sender.apiProvider)
        : sender.apiProvider;
    return providerColor(providerName);
  }

  String get _autoChatStatusText {
    if (!_isAutoChatEnabled) return '自动发言已关闭';
    switch (_autoChatStatus) {
      case AutoChatStatus.idle:
        return '自动发言空闲';
      case AutoChatStatus.waiting:
        return '自动发言等待中';
      case AutoChatStatus.generating:
        return '自动发言生成中';
      case AutoChatStatus.paused:
        return _textController.text.trim().isNotEmpty
            ? '你正在输入，自动发言暂停'
            : '自动发言已暂停';
      case AutoChatStatus.unavailable:
        return _replyBlockText(_lastReplyBlockReason);
      case AutoChatStatus.error:
        return '自动发言异常，已暂停';
    }
  }

  IconData get _autoChatStatusIcon {
    if (!_isAutoChatEnabled) return Icons.voice_over_off_rounded;
    switch (_autoChatStatus) {
      case AutoChatStatus.generating:
        return Icons.auto_awesome_rounded;
      case AutoChatStatus.paused:
        return Icons.pause_circle_outline_rounded;
      case AutoChatStatus.unavailable:
      case AutoChatStatus.error:
        return Icons.info_outline_rounded;
      case AutoChatStatus.idle:
      case AutoChatStatus.waiting:
        return Icons.forum_outlined;
    }
  }

  void _toggleAutoChat(bool enabled) {
    if (!_canTouchUi) return;
    setState(() {
      _isAutoChatEnabled = enabled;
      _autoChatStatus =
          enabled ? AutoChatStatus.waiting : AutoChatStatus.paused;
    });
    if (enabled) {
      _startAutoChat();
    } else {
      _autoChatTimer?.cancel();
      _autoChatTimer = null;
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

  void _enterSearch() {
    setState(() => _isSearching = true);
    _searchResults = [];
    _searchFocusIndex = null;
  }

  void _exitSearch() {
    setState(() {
      _isSearching = false;
      _searchController.clear();
      _searchResults = [];
      _searchFocusIndex = null;
    });
  }

  void _performSearch(String query) {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    final q = query.toLowerCase();
    setState(() {
      _searchResults = _messages.where((m) => m.content.toLowerCase().contains(q)).toList();
      _searchFocusIndex = _searchResults.isEmpty ? null : 0;
    });
    if (_searchResults.isNotEmpty) {
      final idx = _messages.indexOf(_searchResults[0]);
      _scrollToMessageIndex(idx);
    }
  }

  void _scrollToMessageIndex(int index) {
    if (index < 0 || index >= _messages.length) return;
    final itemHeight = 80.0;
    final targetOffset = index * itemHeight;
    _scrollController.animateTo(
      targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _searchPrev() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    setState(() {
      _searchFocusIndex = ((_searchFocusIndex! - 1 + _searchResults.length) % _searchResults.length);
    });
    final msg = _searchResults[_searchFocusIndex!];
    final idx = _messages.indexOf(msg);
    _scrollToMessageIndex(idx);
  }

  void _searchNext() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    setState(() {
      _searchFocusIndex = ((_searchFocusIndex! + 1) % _searchResults.length);
    });
    final msg = _searchResults[_searchFocusIndex!];
    final idx = _messages.indexOf(msg);
    _scrollToMessageIndex(idx);
  }

  String get _searchResultLabel {
    if (_searchResults.isEmpty) return '';
    if (_searchFocusIndex == null) return '${_searchResults.length} 条结果';
    return '${_searchFocusIndex! + 1} / ${_searchResults.length}';
  }


  // —— 语音播放 ——
  bool _isSpeaking = false;
  String? _speakingMessageId;

  bool get _isTtsEnabled => _db.isTtsEnabled;

  Future<void> _ttsSpeak(Message message) async {
    if (_isSpeaking) {
      _ttsStop();
      return;
    }
    final text = message.content;
    if (text.trim().isEmpty) return;
    setState(() {
      _isSpeaking = true;
      _speakingMessageId = message.id;
    });
    try {
      await _flutterTts.setLanguage('zh-CN');
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(0.5);
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint('TTS error: $e');
    }
    if (mounted) {
      setState(() {
        _isSpeaking = false;
        _speakingMessageId = null;
      });
    }
  }

  void _ttsStop() async {
    await _flutterTts.stop();
    if (mounted) {
      setState(() {
        _isSpeaking = false;
        _speakingMessageId = null;
      });
    }
  }

  void _showMessageActionSheet(Message message, AICharacter? sender) {
    if (message.senderType != 'ai' || sender == null) return;
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: cs.outlineVariant, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('${sender.name} 的消息', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            _sheetBtn(ctx, cs, Icons.refresh_rounded, '重新生成', () {
              Navigator.pop(ctx);
              _regenerateAiReply(message, sender);
            }),
            const SizedBox(height: 8),
            _sheetBtn(ctx, cs, Icons.format_quote_rounded, '引用回复', () {
              Navigator.pop(ctx);
              _quoteMessage(message);
            }),
            if (_isTtsEnabled) ...[
              const SizedBox(height: 8),
              _sheetBtn(ctx, cs, _isSpeaking && _speakingMessageId == message.id
                  ? Icons.stop_circle_rounded
                  : Icons.volume_up_rounded,
                  _isSpeaking && _speakingMessageId == message.id ? '停止朗读' : '朗读',
                  () {
                Navigator.pop(ctx);
                if (_isSpeaking && _speakingMessageId == message.id) {
                  _ttsStop();
                } else {
                  _ttsSpeak(message);
                }
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _sheetBtn(BuildContext ctx, ColorScheme cs, IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.onSurface),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(fontSize: 15, color: cs.onSurface)),
          ],
        ),
      ),
    );
  }

  Future<void> _regenerateAiReply(Message original, AICharacter character) async {
    if (_isRegenerating || _isAiReplying) return;
    setState(() {
      _isRegenerating = true;
      _regenerateMessageId = original.id;
    });

    final config = _resolveApiConfig(character);
    if (config == null) {
      if (_canTouchUi) setState(() => _isRegenerating = false);
      return;
    }

    final msgsBefore = _messages.where((m) => m.id != original.id).toList();
    _regenerateContext = msgsBefore.length > 20
        ? msgsBefore.sublist(msgsBefore.length - 20)
        : msgsBefore;

    final apiMessages = _buildApiMessages(character, _regenerateContext, null);
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider, orElse: () => ApiProvider.deepseek);

    final temp = Message(
      groupId: widget.groupId, senderId: character.id, senderType: 'ai', content: '');
    setState(() {
      _streamingMessage = temp;
      _messages = List.from(_messages)
        ..removeWhere((m) => m.id == original.id)
        ..add(temp);
    });
    _scrollToBottom();

    final done = Completer<void>();
    String fullContent = '';
    var failed = false;
    int? promptTokens;
    int? completionTokens;

    final sub = _chatApi.streamChatMessage(
      apiKey: config.apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
    ).listen((e) {
      if (!_canTouchUi) return;
      switch (e.type) {
        case ChatStreamEventType.token:
          fullContent += e.delta ?? '';
          temp.content = fullContent;
          if (_canTouchUi) setState(() {});
          _scrollToBottom();
          break;
        case ChatStreamEventType.done:
          if ((e.content ?? '').isNotEmpty) fullContent = e.content!;
          temp.content = fullContent;
          if (_canTouchUi) setState(() {});
          if (e.promptTokens != null) promptTokens = e.promptTokens;
          if (e.completionTokens != null) completionTokens = e.completionTokens;
          if (!done.isCompleted) done.complete();
          break;
        case ChatStreamEventType.error:
          failed = true;
          fullContent = '[${character.name} 重新生成失败: ${e.message}]';
          temp.content = fullContent;
          if (_canTouchUi) setState(() {});
          if (!done.isCompleted) done.complete();
      }
    }, onError: (err) {
      if (!_canTouchUi) return;
      failed = true;
      fullContent = '[${character.name} 重新生成失败: $err]';
      temp.content = fullContent;
      if (_canTouchUi) setState(() {});
      if (!done.isCompleted) done.complete();
    }, onDone: () {
      if (!done.isCompleted) done.complete();
    });

    _streamSub = sub;
    _streamDone = done;
    if (mounted) setState(() => _isStreaming = true);

    await done.future;
    _streamSub = null;
    _streamDone = null;
    if (mounted) setState(() => _isStreaming = false);

    if (!failed && fullContent.trim().isEmpty) {
      fullContent = ChatActivityPolicy.emptyReplyFallback(
        characterName: character.name, role: character.role,
        groupTheme: _group?.theme ?? '', userMessage: null,
        isAutoChat: false, random: _random);
      temp.content = fullContent;
      if (_canTouchUi) setState(() {});
    }

    final mentionedIds = parseMentionedCharacterIds(fullContent, _characters);
    fullContent = _stripNamePrefix(fullContent, character.name);
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    temp.replyToMessageId = original.id;
    await _db.messageBox.put(temp.id, temp);
    _recordReplyUsage(character);
    if (promptTokens != null && completionTokens != null) {
      _db.recordTokenUsage(
        characterId: character.id,
        inputTokens: promptTokens!,
        outputTokens: completionTokens!,
      );
    }

    if (_canTouchUi) {
      setState(() {
        _streamingMessage = null;
        _isRegenerating = false;
        _regenerateMessageId = '';
        _regenerateContext = [];
      });
    }
  }

  void _quoteMessage(Message message) {
    setState(() => _quotedMessage = message);
    _inputFocusNode.requestFocus();
  }

  void _cancelQuote() {
    setState(() => _quotedMessage = null);
  }

  String _senderNameById(String id) {
    final c = _characters.firstWhere((c) => c.id == id, orElse: () => _characters.isNotEmpty
        ? _characters.first
        : AICharacter(name: '未知', avatar: '?', age: 0, role: '', personalityTags: const [], systemPrompt: '', apiKey: '', apiProvider: 'deepseek', apiConfigId: ''));
    return c.name;
  }

  Widget _buildSearchBar(ColorScheme cs) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '搜索消息...',
              hintStyle: TextStyle(color: cs.onSurfaceVariant.withOpacity(0.6)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: cs.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: cs.outlineVariant),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: cs.primary, width: 1.5),
              ),
              filled: true,
              fillColor: cs.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              isDense: true,
            ),
            onChanged: _performSearch,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withOpacity(0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            _searchResultLabel,
            style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
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
        title: _isSearching
            ? _buildSearchBar(cs)
            : Column(
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
        actions: _isSearching
            ? [
                if (_searchResults.isNotEmpty) ...[
                  TextButton.icon(
                    onPressed: _searchPrev,
                    icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                    label: Text(_searchResultLabel),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward_rounded, size: 20),
                    onPressed: _searchNext,
                    tooltip: '下一个',
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 22),
                  onPressed: _exitSearch,
                  tooltip: '关闭搜索',
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.search_rounded, size: 22),
                  onPressed: _enterSearch,
                  tooltip: '搜索消息',
                ),
                IconButton(
                  icon: const Icon(Icons.upload_rounded, size: 22),
                  onPressed: () {
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ExportPage(initialGroupId: widget.groupId),
                    ));
                  },
                  tooltip: '导出本群对话',
                ),
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
          _buildAutoChatStatusBar(cs),
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
                      final isRegenerating = _isRegenerating &&
                          _regenerateMessageId == message.id;
                      final isAiBubble = message.senderType == 'ai' &&
                          sender != null;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDate)
                            _buildDateDivider(cs, message.timestamp),
                          _MessageBubble(
                            message: message,
                            sender: sender,
                            characters: _characters,
                            cs: cs,
                            isStreaming: isStreaming,
                            isRegenerating: isRegenerating,
                            onLongPress: isAiBubble
                                ? () => _showMessageActionSheet(message, sender)
                                : null,
                            senderColor: (c) => _senderColor(c),
                            quotedMessage: message.replyToMessageId != null
                                ? _messages.firstWhere(
                                    (m) => m.id == message.replyToMessageId,
                                    orElse: () => message)
                                : null,
                            quotedSenderName: message.replyToMessageId != null
                                ? _senderNameById(
                                    _messages.firstWhere(
                                        (m) => m.id == message.replyToMessageId,
                                        orElse: () => message)
                                      .senderId)
                                : null,
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
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.error)),
          ),
        ],
      ),
    );
  }

  Widget _buildAutoChatStatusBar(ColorScheme cs) {
    final enabled = _isAutoChatEnabled && _hasAnyApiConfig;
    final statusColor = switch (_autoChatStatus) {
      AutoChatStatus.generating => cs.primary,
      AutoChatStatus.unavailable || AutoChatStatus.error => cs.error,
      AutoChatStatus.paused => cs.onSurfaceVariant,
      AutoChatStatus.idle || AutoChatStatus.waiting => cs.onSurfaceVariant,
    };

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(_autoChatStatusIcon, size: 18, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _autoChatStatusText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '自动发言',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
          Switch.adaptive(
            value: enabled,
            onChanged: _hasAnyApiConfig ? _toggleAutoChat : null,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
    final stackWidth =
        shown.isEmpty ? 0.0 : 26.0 + (shown.length - 1) * overlap;
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
    _memberSearchController.clear();
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final query = _memberSearchController.text.trim();
        final filtered = query.isEmpty
            ? _characters
            : _characters
                .where((c) =>
                    c.name.contains(query) ||
                    c.role.contains(query) ||
                    c.personalityTags.any((tag) => tag.contains(query)))
                .toList();
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.78,
          ),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
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
                      style:
                          TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _memberSearchController,
                decoration: InputDecoration(
                  hintText: '搜索名称、角色或标签',
                  prefixIcon: Icon(Icons.search_rounded,
                      size: 18, color: cs.onSurfaceVariant),
                  isDense: true,
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: cs.outlineVariant),
                  ),
                ),
                onChanged: (_) => setSheetState(() {}),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: ListView(
                  children: [
                    _buildMemberTile(
                      cs: cs,
                      avatarText: '我',
                      avatarColor: cs.primary,
                      name: ownerName,
                      subtitle: '群主',
                      isOwner: true,
                    ),
                    Divider(
                        height: 24, color: cs.outlineVariant.withOpacity(0.4)),
                    if (filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text('未找到匹配成员',
                              style: TextStyle(
                                  fontSize: 14, color: cs.onSurfaceVariant)),
                        ),
                      )
                    else
                      ...filtered.map((c) {
                        final color = _senderColor(c);
                        return _buildMemberTile(
                          cs: cs,
                          avatarText:
                              c.avatar.isNotEmpty ? c.avatar : c.name[0],
                          avatarColor: color,
                          name: c.name,
                          subtitle: _memberStatusText(c),
                        );
                      }),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _memberStatusText(AICharacter c) {
    final blockReason = _blockReasonFor(c);
    final base = '${c.role} · ${c.age}岁';
    final usage = '${c.hourlyReplyCount}/${c.hourlyReplyLimit} 次/小时';
    final status = switch (blockReason) {
      null => '可回复',
      ReplyBlockReason.noApiConfig => '未配置 API',
      ReplyBlockReason.inactive => '已停用',
      ReplyBlockReason.hourlyLimit => '达到上限',
      ReplyBlockReason.alreadyGenerating => '生成中',
      ReplyBlockReason.networkError => '网络异常',
    };
    return '$base · $status · $usage';
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
              border:
                  Border.all(color: avatarColor.withOpacity(0.3), width: 1.5),
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
                    style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
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
      child: Focus(
        onKeyEvent: (_, event) => _handleKeyEvent(event),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_quotedMessage != null) _buildQuoteBar(cs),
            Container(
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
                        focusNode: _inputFocusNode,
                        decoration: InputDecoration(
                          hintText: _quotedMessage != null
                              ? '回复 ${_senderNameById(_quotedMessage!.senderId)}...'
                              : '输入消息，回车换行，@ 提到角色...',
                          suffixIcon: _quotedMessage != null
                              ? IconButton(
                                  icon: Icon(Icons.close_rounded, size: 18, color: cs.onSurfaceVariant),
                                  onPressed: _cancelQuote,
                                  tooltip: '取消引用',
                                )
                              : null,
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
          ],
        ),
      ),
    );
  }

  Widget _buildQuoteBar(ColorScheme cs) {
    final quoted = _quotedMessage!;
    final senderName = _senderNameById(quoted.senderId);
    final snippet = quoted.content.length > 60
        ? '${quoted.content.substring(0, 60)}...'
        : quoted.content;
    return Container(
      margin: const EdgeInsets.only(left: 16, right: 16, top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withOpacity(0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: cs.primary.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.format_quote_rounded, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(senderName,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
                Text(snippet,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant),
            onPressed: _cancelQuote,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

/// 用户在 AI 回复期间发的消息，排队等当前回合结束后再触发 AI 回复。
class _PendingUserMessage {
  final String text;
  final List<String> mentionedIds;

  _PendingUserMessage(this.text, this.mentionedIds);
}

class _MessageBubble extends StatelessWidget {
  final Message message;
  final AICharacter? sender;
  final List<AICharacter> characters;
  final ColorScheme cs;
  final bool isStreaming;
  final bool isRegenerating;
  final VoidCallback? onLongPress;
  final Color Function(AICharacter) senderColor;
  final Message? quotedMessage;
  final String? quotedSenderName;

  const _MessageBubble({
    required this.message,
    this.sender,
    required this.characters,
    required this.cs,
    this.isStreaming = false,
    this.isRegenerating = false,
    this.onLongPress,
    required this.senderColor,
    this.quotedMessage,
    this.quotedSenderName,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.senderType == 'user';

    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(
          mainAxisAlignment:
              isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser && sender != null) ...[
              CircleAvatar(
                radius: 20,
                backgroundColor: senderColor(sender!).withOpacity(0.12),
                child: Text(
                    sender!.avatar.isNotEmpty ? sender!.avatar : sender!.name[0],
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: senderColor(sender!))),
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
                      child: Row(
                        children: [
                          Text(sender!.name,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurfaceVariant)),
                          if (isRegenerating)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: SizedBox(width: 12, height: 12,
                                child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary)),
                            ),
                        ],
                      ),
                    ),
                  if (message.replyToMessageId != null)
                    _buildQuotedRef(cs, quotedMessage ?? message, quotedSenderName),
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
      ),
    );
  }

  Widget _buildQuotedRef(ColorScheme cs, Message? quoted, String? senderName) {
    if (quoted == null) return const SizedBox.shrink();
    final snippet = quoted.content.length > 50
        ? '${quoted.content.substring(0, 50)}...'
        : quoted.content;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withOpacity(0.35),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.format_quote_rounded, size: 12, color: cs.primary),
          const SizedBox(width: 6),
          if (senderName != null)
            Text(senderName,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.primary)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(snippet,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
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
