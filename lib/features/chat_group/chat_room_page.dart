import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:chat_group/features/agentic/agentic_task_classifier.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/chat_group/scene_behavior.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:chewie/chewie.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:video_player/video_player.dart';

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
    if (name != null && _isMentionAllToken(name)) {
      for (final character in characters) {
        if (!mentionedIds.contains(character.id)) {
          mentionedIds.add(character.id);
        }
      }
      continue;
    }
    final id = name == null ? null : byName[name];
    if (id != null && !mentionedIds.contains(id)) {
      mentionedIds.add(id);
    }
  }
  return mentionedIds;
}

bool _isMentionAllToken(String token) {
  final normalized = token.trim().toLowerCase();
  return normalized == 'all' ||
      normalized == 'everyone' ||
      normalized == '所有人' ||
      normalized == '全部';
}

class ChatRoomPage extends ConsumerStatefulWidget {
  final String groupId;

  const ChatRoomPage({super.key, required this.groupId});

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends ConsumerState<ChatRoomPage>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _memberSearchController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  final _chatApi = ChatApiService();
  final _random = Random();
  final FlutterTts _flutterTts = FlutterTts();
  late final DatabaseService _db;

  ChatGroup? _group;
  List<AICharacter> _characters = []; // 活跃角色（用于 AI 回复等逻辑）
  List<AICharacter> _allGroupCharacters = []; // 全部群成员（含停用），供 @ 弹窗使用
  List<Message> _messages = [];
  GroupMemory? _groupMemory;
  List<CharacterMemory> _characterMemories = [];
  List<RelationshipState> _relationshipStates = [];
  final Map<String, ReplyIntent> _pendingReplyIntents = {};
  _PendingAgentToolApproval? _pendingAgentApproval;
  int _autoChatMemoryTick = 0;

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
  final TextEditingController _mentionSearchController =
      TextEditingController();

  // 输入框 GlobalKey，用于精确定位 @ 弹窗。
  final GlobalKey _inputFieldKey = GlobalKey();

  // AI 自主聊天
  Timer? _autoChatTimer;
  bool _isAutoChatEnabled = true;
  int _autoChatRoundCount = 0;
  final int _maxAutoChatRounds = 4;
  static const Duration _autoChatInitialDelay = Duration(seconds: 8);
  static const Duration _autoChatBurstPause = Duration(seconds: 35);
  static const Duration _streamUiFlushInterval = Duration(milliseconds: 80);
  static const Duration _searchDebounceDuration = Duration(milliseconds: 250);
  static const int _autoChatMinIntervalSeconds = 12;
  static const int _autoChatIntervalJitterSeconds = 9;
  final Random _autoChatRandom = Random();
  AutoChatStatus _autoChatStatus = AutoChatStatus.idle;
  ReplyBlockReason? _lastReplyBlockReason;

  // 待回应 @ 列表
  final List<String> _pendingMentionedIds = [];

  bool _isInputEmpty = true;

  /// 是否允许发送：文案非空 或 有待发送附件。
  bool get _canSend => !_isInputEmpty || _pendingAttachments.isNotEmpty;

  // —— 待发送附件（图片多选 / 视频单选），发送后清空 ——
  final List<MediaAttachment> _pendingAttachments = [];
  final ImagePicker _imagePicker = ImagePicker();
  bool _isPastingAttachments = false;
  bool _isDraggingFiles = false;

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
  Timer? _searchDebounceTimer;

  // —— 流式输出（打字机）相关状态 ——
  Message? _streamingMessage; // 正在逐 token 渲染的内存态临时消息（不落库）
  StreamSubscription<ChatStreamEvent>? _streamSub; // 当前流的订阅，供「停止生成」取消
  Completer<void>? _streamDone; // 标记本轮流式是否结束
  bool _isStreaming = false; // 是否正在流式生成（控制「停止生成」按钮显隐）
  bool _disposed = false; // dispose 守卫，避免异步回调在销毁后写状态
  Timer? _streamUiFlushTimer;
  final Map<String, GlobalKey> _messageKeys = {};

  // —— @我 提醒 ——
  final List<String> _pendingUserMentionMessageIds = [];
  String? _highlightedMentionMessageId;
  Timer? _mentionHighlightTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ConversationPresenceService.instance.enter(widget.groupId);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    ConversationPresenceService.instance.enter(widget.groupId);
  }

  @override
  void dispose() {
    _disposed = true;
    ConversationPresenceService.instance.leave(widget.groupId);
    WidgetsBinding.instance.removeObserver(this);
    for (final attachment in List<MediaAttachment>.from(_pendingAttachments)) {
      unawaited(_deletePendingAttachmentFile(attachment));
    }
    _pendingAttachments.clear();
    // 已提交的流式请求继续在后台收尾并落库；只停止 UI flush。
    _streamSub?.cancel();
    _streamSub = null;
    _streamUiFlushTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _textController.dispose();
    _memberSearchController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    _searchController.dispose();
    _autoChatTimer?.cancel();
    _mentionHighlightTimer?.cancel();
    _hideMentionOverlay();
    _mentionSearchController.dispose();
    _ttsStop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ConversationPresenceService.instance.enter(widget.groupId);
      unawaited(_markCurrentConversationRead());
    }
  }

  bool get _isDirectChat =>
      DirectChatSession.isDirectConversationId(widget.groupId);

  String? get _directCharacterId =>
      DirectChatSession.characterIdFrom(widget.groupId);

  Future<void> _loadData() async {
    if (_isDirectChat) {
      await _loadDirectChatData();
      return;
    }

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

    // 全部群成员（含停用），供 @ 弹窗和成员列表使用。
    final allGroupCharacters = group.aiCharacterIds
        .map((id) => _db.aiCharacterBox.get(id))
        .whereType<AICharacter>()
        .toList();

    // 检测是否有角色配置了 API Key（决定 AI 能否回复/自动聊天）
    final hasApi = characters.any((c) {
      final cfg = _resolveApiConfig(c);
      return cfg != null && cfg.apiKey.isNotEmpty;
    });

    final messages = await _db.messagesForGroup(widget.groupId);
    await _db.markGroupChatRead(
      widget.groupId,
      readAt: _readThrough(messages),
    );

    final memoryBox = _db.groupMemoryBox;
    final now = DateTime.now();
    final memoryKey = '${widget.groupId}_${_memoryPeriodKey(now)}';
    var memory = memoryBox.get(memoryKey);
    if (memory == null) {
      final legacyKey =
          '${widget.groupId}_${ChatOrchestrator.legacyMemoryPeriodKey(now)}';
      final legacyMemory = memoryBox.get(legacyKey);
      if (legacyMemory != null) {
        memory = GroupMemory(
          groupId: legacyMemory.groupId,
          topicSummary: legacyMemory.topicSummary,
          lastSummaryAt: legacyMemory.lastSummaryAt,
        );
        await memoryBox.put(memoryKey, memory);
      }
    }
    if (memory == null) {
      memory = GroupMemory(groupId: widget.groupId, topicSummary: '');
      await memoryBox.put(memoryKey, memory);
    }

    final characterMemories = _db.characterMemoryBox.values
        .where((m) => m.groupId == widget.groupId)
        .toList();
    final relationshipStates = _db.relationshipStateBox.values
        .where((r) => r.groupId == widget.groupId)
        .toList();

    setState(() {
      _group = group;
      _characters = characters;
      _allGroupCharacters = allGroupCharacters;
      _messages = messages;
      _groupMemory = memory;
      _characterMemories = characterMemories;
      _relationshipStates = relationshipStates;
      _hasAnyApiConfig = hasApi;
      _autoChatStatus =
          hasApi ? AutoChatStatus.waiting : AutoChatStatus.unavailable;
      _isLoading = false;
    });

    _scrollToBottom();

    if (_isAutoChatEnabled && _characters.isNotEmpty && hasApi) {
      Future.delayed(_autoChatInitialDelay, () {
        if (_canTouchUi) _startAutoChat();
      });
    }
  }

  Future<void> _loadDirectChatData() async {
    final characterId = _directCharacterId;
    final character =
        characterId == null ? null : _db.aiCharacterBox.get(characterId);
    if (character == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('私聊角色不存在'), behavior: SnackBarBehavior.floating));
        Navigator.pop(context);
      }
      return;
    }

    final activeCharacters =
        character.isActive ? <AICharacter>[character] : <AICharacter>[];
    final config = _resolveApiConfig(character);
    final hasApi =
        character.isActive && config != null && config.apiKey.isNotEmpty;
    final messages = await _db.messagesForGroup(widget.groupId);
    await _db.markDirectChatRead(
      widget.groupId,
      readAt: _readThrough(messages),
    );
    final characterMemories = _db.characterMemoryBox.values
        .where((m) => m.groupId == widget.groupId)
        .toList();
    final relationshipStates = _db.relationshipStateBox.values
        .where((r) => r.groupId == widget.groupId)
        .toList();

    setState(() {
      _group = ChatGroup(
        id: widget.groupId,
        name: '与 ${character.name} 私聊',
        theme: '一对一私聊',
        description: '${character.role} · ${character.age}岁',
        aiCharacterIds: [character.id],
      );
      _characters = activeCharacters;
      _allGroupCharacters = [character];
      _messages = messages;
      _groupMemory = null;
      _characterMemories = characterMemories;
      _relationshipStates = relationshipStates;
      _hasAnyApiConfig = hasApi;
      _isAutoChatEnabled = false;
      _autoChatStatus =
          hasApi ? AutoChatStatus.paused : AutoChatStatus.unavailable;
      _lastReplyBlockReason = hasApi ? null : _blockReasonFor(character);
      _isLoading = false;
    });

    _scrollToBottom();
  }

  void _startAutoChat() {
    if (_isDirectChat) return;
    if (!_canTouchUi || !_isAutoChatEnabled || !_hasAnyApiConfig) return;
    _autoChatTimer?.cancel();
    setState(() => _autoChatStatus = AutoChatStatus.waiting);
    _autoChatTimer = Timer.periodic(
      Duration(
        seconds: _autoChatMinIntervalSeconds +
            _autoChatRandom.nextInt(_autoChatIntervalJitterSeconds),
      ),
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
    if (_isDirectChat) return;
    if (!_canTouchUi || !_isAutoChatEnabled || _characters.isEmpty) return;
    if (_isAiReplying ||
        _isStreaming ||
        _textController.text.trim().isNotEmpty) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (_autoChatRoundCount >= _maxAutoChatRounds) {
      _stopAutoChat();
      Future.delayed(_autoChatBurstPause, () {
        if (_canTouchUi && _isAutoChatEnabled) _startAutoChat();
      });
      return;
    }

    final autoIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _messages.toList(),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: null,
      mentionedIds: const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _autoChatRandom,
      isAutoChat: true,
    );
    final speakers = _charactersForIntents(autoIntents);
    _pendingReplyIntents
      ..clear()
      ..addEntries(
          autoIntents.map((intent) => MapEntry(intent.speakerId, intent)));

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
      _isAiReplying = true;
      _autoChatRoundCount++;
      _autoChatStatus = AutoChatStatus.generating;
    });

    try {
      for (final speaker in speakers) {
        if (!_canTouchUi || !_isAutoChatEnabled) break;
        if (!_isEligibleToReply(speaker)) continue;
        final replyContent = await _generateAiReply(
          speaker,
          _messages.toList(),
          null,
          isAutoChat: true,
          intent: _pendingReplyIntents[speaker.id],
        );
        await _delay(replyContent);
      }

      _autoChatMemoryTick++;
      if (_autoChatMemoryTick >= 3) {
        _autoChatMemoryTick = 0;
        await _maybeUpdateMemory();
      }
    } finally {
      if (_canTouchUi) {
        setState(() {
          _isAiReplying = false;
          _autoChatStatus = _isAutoChatEnabled
              ? AutoChatStatus.waiting
              : AutoChatStatus.paused;
        });
      }
    }

    // 处理排队中的用户消息：当前回合结束后自动触发下一轮 AI 回复。
    if (_pendingUserMessages.isNotEmpty && _canTouchUi) {
      final next = _pendingUserMessages.removeAt(0);
      await _runAiRound(
          userMessage: next.text, mentionedIds: next.mentionedIds);
    }
  }

  bool get _canTouchUi => mounted && !_disposed;

  @override
  void setState(VoidCallback fn) {
    if (!_canTouchUi) return;
    super.setState(fn);
  }

  DateTime _readThrough(List<Message> messages) {
    if (messages.isEmpty) return DateTime.now();
    final latest = messages
        .map((message) => message.timestamp)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final readAt = latest.add(const Duration(milliseconds: 1));
    final now = DateTime.now();
    return readAt.isAfter(now) ? readAt : now;
  }

  Future<void> _markCurrentConversationRead({Message? throughMessage}) async {
    if (_isDirectChat) {
      await _db.markDirectChatRead(
        widget.groupId,
        readAt: throughMessage == null
            ? _readThrough(_messages)
            : _readThrough([throughMessage]),
      );
      _clearActiveUserMentionBanner();
      return;
    }
    await _db.markGroupChatRead(
      widget.groupId,
      readAt: throughMessage == null
          ? _readThrough(_messages)
          : _readThrough([throughMessage]),
    );
    _clearActiveUserMentionBanner();
  }

  String _memoryPeriodKey(DateTime now) {
    return ChatOrchestrator.memoryPeriodKey(now);
  }

  Future<void> _sendMessage() async {
    _hideMentionOverlay();
    final text = _textController.text.trim();
    final hasAttachments = _pendingAttachments.isNotEmpty;
    // 放宽发送条件：文案非空 或 有附件均可发送。
    if (text.isEmpty && !hasAttachments) return;

    _textController.clear();
    final messenger = ScaffoldMessenger.of(context);

    final mentionedIds = _parseMentions(text);
    for (final id in mentionedIds) {
      if (!_pendingMentionedIds.contains(id)) {
        _pendingMentionedIds.add(id);
      }
    }

    // 审批词（「批准」「取消」等）不应作为普通用户消息落库。
    if (await _handlePendingAgentApproval(text)) {
      // 发送后清空待发送附件（即使审批消息本身不展示）。
      if (hasAttachments && mounted) {
        setState(() => _pendingAttachments.clear());
      }
      return;
    }

    // 构造带媒体附件的用户消息（媒体为不可变快照，避免后续清空影响已落库消息）。
    final userMessage = Message(
      groupId: widget.groupId,
      senderId: 'user',
      senderType: 'user',
      content: text,
      replyToMessageId: _quotedMessage?.id,
      media: hasAttachments
          ? List<MediaAttachment>.from(_pendingAttachments)
          : null,
    );
    await _appendMessage(userMessage);
    if (_isDirectChat) {
      await _db.saveDirectChatSource(widget.groupId, DirectChatSource.direct);
      await _db.markDirectChatRead(
        widget.groupId,
        readAt: _readThrough(_messages),
      );
    }
    _cancelQuote();

    // 发送后清空待发送附件。
    if (hasAttachments && mounted) {
      setState(() => _pendingAttachments.clear());
    }

    _autoChatRoundCount = 0;

    if (_characters.isEmpty) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(
            content: Text(_isDirectChat ? '该角色当前不可回复' : '该群聊没有活跃的角色'),
            behavior: SnackBarBehavior.floating));
      }
      return;
    }

    if (_isAiReplying) {
      // AI 正在回复中，排队等待当前回合结束后再处理。
      _pendingUserMessages.add(_PendingUserMessage(text, mentionedIds));
      return;
    }

    await _runAiRound(
        userMessage: text,
        mentionedIds: mentionedIds,
        currentUserMessage: userMessage);
  }

  Future<void> _runAiRound(
      {String? userMessage,
      List<String>? mentionedIds,
      bool isAutoChat = false,
      Message? currentUserMessage}) async {
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

    var charactersToReply = _isDirectChat
        ? _directReplyCharacters()
        : _charactersForIntents(_selectGroupReplyIntents(
            userMessage: userMessage,
            mentionedIds: mentionedIds,
            isAutoChat: isAutoChat,
          ));
    final isExplicitAgenticTask = !isAutoChat &&
        userMessage != null &&
        AgenticTaskClassifier.requiresAgenticWork(userMessage);
    if (!_isDirectChat &&
        isExplicitAgenticTask &&
        mentionedIds != null &&
        mentionedIds.isNotEmpty) {
      charactersToReply = charactersToReply
          .where((character) => mentionedIds.contains(character.id))
          .toList();
    }
    if (charactersToReply.isEmpty) {
      if (_characters.any(_isEligibleToReply)) {
        setState(() {
          _isAiReplying = false;
          if (!isAutoChat) _consecutiveRound = 0;
        });
        return;
      }
      final blockReason = _firstBlockReason(_characters);
      setState(() {
        _isAiReplying = false;
        if (!isAutoChat) _consecutiveRound = 0;
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
      late final String replyContent;
      try {
        replyContent = await _generateAiReply(
          character,
          _recentMessagesForContext(),
          userMessage,
          isAutoChat: isAutoChat,
          intent: _pendingReplyIntents[character.id],
          currentUserMessage: currentUserMessage,
        );
      } catch (e) {
        replyContent = '[${character.name} 回复失败: $e]';
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: character.id,
          senderType: 'ai',
          content: replyContent,
        ));
        if (_canTouchUi) {
          setState(() {
            _autoChatStatus = AutoChatStatus.error;
            _lastReplyBlockReason = ReplyBlockReason.networkError;
          });
        }
      }
      repliedIds.add(character.id);
      await _delay(replyContent);
      if (wasPendingReply) {
        _pendingMentionedIds.remove(character.id);
      }
    }

    if (!_isDirectChat &&
        mentionedIds != null &&
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

    // widget 可能在 _maybeUpdateMemory 的 await 期间被 dispose，
    // 恢复后必须重新检查 _canTouchUi 才能调用 setState。
    if (!_canTouchUi) return;

    setState(() {
      _isAiReplying = false;
      if (!isAutoChat) _consecutiveRound = 0;
    });

    // 处理排队中的用户消息：当前回合结束后自动触发下一轮 AI 回复。
    if (_pendingUserMessages.isNotEmpty && _canTouchUi) {
      final next = _pendingUserMessages.removeAt(0);
      await _runAiRound(
          userMessage: next.text, mentionedIds: next.mentionedIds);
    }
  }

  Future<String> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false,
      ReplyIntent? intent,
      Message? currentUserMessage}) async {
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
      return '[${character.name} 未配置 API]';
    }

    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );

    if (!isAutoChat &&
        userMessage != null &&
        AgenticTaskClassifier.requiresAgenticWork(userMessage)) {
      return _generateAgenticReply(
        character: character,
        config: config,
        provider: provider,
        userMessage: userMessage,
        media: currentUserMessage?.media,
      );
    }

    final apiMessages = _buildApiMessages(
      character,
      context,
      userMessage,
      isAutoChat: isAutoChat,
      intent: intent,
      supportsVision: provider.supportsVision,
      currentUserMessage: currentUserMessage,
    );
    debugPrint(
        '[AI Reply] ${character.name} apiMessages count=${apiMessages.length}');
    for (var i = 0; i < apiMessages.length; i++) {
      final m = apiMessages[i];
      // content 可能是 String（纯文本）或 List（多模态 parts），统一安全打印。
      final content = m['content'];
      final preview = content is String
          ? content.substring(0, content.length.clamp(0, 60))
          : '[${content.runtimeType}]';
      debugPrint('[AI Reply]   [$i] role=${m['role']} content=$preview');
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
    int? cachedTokens;

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
        debugPrint('[AI Stream] ${character.name} event=${e.type}');
        switch (e.type) {
          case ChatStreamEventType.token:
            fullContent += e.delta ?? '';
            temp.content = fullContent;
            if (_canTouchUi) _scheduleStreamingUiFlush();
            break;
          case ChatStreamEventType.done:
            if ((e.content ?? '').isNotEmpty) fullContent = e.content!;
            temp.content = fullContent;
            if (_canTouchUi) _flushStreamingUi();
            if (e.promptTokens != null) promptTokens = e.promptTokens;
            if (e.completionTokens != null) {
              completionTokens = e.completionTokens;
            }
            if (e.cachedTokens != null) cachedTokens = e.cachedTokens;
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
            if (_canTouchUi) _flushStreamingUi();
            if (!done.isCompleted) done.complete();
        }
      },
      onError: (err) {
        failed = true;
        _lastReplyBlockReason = ReplyBlockReason.networkError;
        fullContent = '[${character.name} 回复失败: $err]';
        temp.content = fullContent;
        if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.error);
        if (_canTouchUi) _flushStreamingUi();
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

    debugPrint(
        '[AI Stream] ${character.name} DONE fullContent=${fullContent.isNotEmpty ? fullContent.substring(0, min(50, fullContent.length)) : '(empty)'} failed=$failed');

    // 空内容也给出可见反馈，否则 @ 触发会像没有人理会。
    if (!failed && fullContent.trim().isEmpty) {
      debugPrint(
          '[AI Stream] ${character.name} EMPTY content -> using fallback');
      fullContent = ChatActivityPolicy.emptyReplyFallback(
        characterName: character.name,
        role: character.role,
        groupTheme: _group?.theme ?? '',
        userMessage: userMessage,
        isAutoChat: isAutoChat,
        random: _random,
      );
      temp.content = fullContent;
      _flushStreamingUi();
    }

    // 解析 @ 提及 → mentionedAiIds（未知名称忽略，避免误指向第一个成员）。
    final mentionedIds = _isDirectChat
        ? const <String>[]
        : parseMentionedCharacterIds(fullContent, _characters);

    // 移除 LLM 可能附带的名字前缀（UI 已独立显示角色名）。
    fullContent = _stripNamePrefix(fullContent, character.name);

    // 持久化纪律：仅完成时 put 一次（包含失败占位消息）。
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    await _db.messageBox.put(temp.id, temp);
    await _db.addMessageToGroupIndex(temp);
    await _markCurrentConversationRead(throughMessage: temp);
    _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    if (promptTokens != null && completionTokens != null) {
      _db.recordTokenUsage(
        characterId: character.id,
        groupId: widget.groupId,
        inputTokens: promptTokens!,
        outputTokens: completionTokens!,
        cachedTokens: cachedTokens ?? 0,
      );
    }
    if (!failed && intent != null) {
      await _persistRelationshipForIntent(
        character: character,
        intent: intent,
        userMessage: userMessage,
      );
    }
    if (!failed && fullContent.trim().isNotEmpty) {
      await _maybeEvolveCharacterMemory(character, fullContent);
    }
    if (_canTouchUi) setState(() => _streamingMessage = null);
    return fullContent;
  }

  Future<String> _generateAgenticReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required String userMessage,
    List<MediaAttachment>? media,
  }) async {
    await _ensureAgenticTaskPermissions(character, userMessage);
    final runtime = _agentRuntimeFor(
      character: character,
      config: config,
      provider: provider,
    );

    final mediaEnhancedRequest = media == null || media.isEmpty
        ? userMessage
        : '$userMessage${AgentPromptBuilder.mediaHint(media)}';

    final result = await runtime.run(
      character: character,
      skills: _agenticSkillsFor(character),
      userRequest: mediaEnhancedRequest,
    );
    if (result.status == AgentRuntimeStatus.waitingForApproval &&
        result.pendingToolRequest != null) {
      _pendingAgentApproval = _PendingAgentToolApproval(
        character: character,
        config: config,
        provider: provider,
        userRequest: userMessage,
        request: result.pendingToolRequest!,
        priorExecutedRequests: result.executedToolRequests,
      );
      final content = _stripNamePrefix(result.message, character.name);
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: content,
      ));
      // 审批中：返回提示文案但不消耗 reply slot（不记录 usage/mention/memory）。
      return content;
    }
    if (result.status != AgentRuntimeStatus.completed) {
      final content = _stripNamePrefix(result.message, character.name);
      final message = Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: content,
      );
      await _appendMessage(message);
      return content;
    }
    final content = _stripNamePrefix(result.message, character.name);
    final attachments = await _attachmentsForAgentToolResult(
      character: character,
      result: result,
    );
    final message = Message(
      groupId: widget.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: content,
      media: attachments.isEmpty ? null : attachments,
    );
    await _appendMessage(message);
    _recordReplyUsage(character);
    _registerUserMentionIfNeeded(message);
    if (content.trim().isNotEmpty) {
      await _maybeEvolveCharacterMemory(character, content);
    }
    return content;
  }

  Future<void> _ensureAgenticTaskPermissions(
    AICharacter character,
    String userMessage,
  ) async {
    if (!AgenticTaskClassifier.requiresAgenticWork(userMessage)) return;
    final permissionSet = <ToolPermission>{
      ...character.toolPermissions,
      ...CharacterSkillResolver.defaultsFor(character).permissions,
      ToolPermission.skillCreate,
      ToolPermission.skillDownload,
    };
    final lower = userMessage.toLowerCase();
    final needsWorkspace = lower.contains('文件') ||
        lower.contains('file') ||
        lower.contains('路径') ||
        lower.contains('path') ||
        lower.contains('md') ||
        lower.contains('markdown') ||
        lower.contains('文档') ||
        lower.contains('代码') ||
        lower.contains('code') ||
        lower.contains('review') ||
        lower.contains('修复') ||
        lower.contains('bug');
    if (needsWorkspace) {
      permissionSet.add(ToolPermission.workspaceRead);
      permissionSet.add(ToolPermission.workspacePatch);
    }
    final needsCommand = lower.contains('运行') ||
        lower.contains('测试') ||
        lower.contains('flutter test') ||
        lower.contains('flutter analyze') ||
        lower.contains('命令') ||
        lower.contains('command');
    if (needsCommand) {
      permissionSet.add(ToolPermission.commandRun);
    }
    final next = permissionSet.toList();
    next.sort((a, b) => a.index.compareTo(b.index));
    final current = character.toolPermissions.map((p) => p.name).toSet();
    final changed =
        next.any((permission) => !current.contains(permission.name));
    if (!changed && character.agenticEnabled) return;
    character
      ..agenticEnabled = true
      ..toolPermissions = next;
    await _db.aiCharacterBox.put(character.id, character);
  }

  Future<List<MediaAttachment>> _attachmentsForAgentToolResult({
    required AICharacter character,
    required AgentRuntimeResult result,
  }) async {
    final request = result.pendingToolRequest;
    final patchRequests = <ToolRequest>[
      ...result.executedToolRequests
          .where((request) => request.tool == AgentToolName.workspacePatch),
      if (request != null && request.tool == AgentToolName.workspacePatch)
        request,
    ];
    if (patchRequests.isEmpty) {
      return const [];
    }
    final paths = <String>[];
    for (final request in patchRequests) {
      for (final path
          in _pathsFromPatch(request.args['patch'] as String? ?? '')) {
        if (!paths.contains(path)) paths.add(path);
      }
    }
    if (paths.isEmpty) return const [];

    final attachments = <MediaAttachment>[];
    final bridge = LocalAgentBridgeClient();
    final workspaceTool = WorkspaceFileTool(bridge);
    for (final path in paths.take(6)) {
      try {
        final local = File(path).absolute;
        if (await local.exists()) {
          attachments.add(await _db.copyToAiCharacterDir(
            source: local,
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }

        final read = await workspaceTool.read(path);
        final content = read['content'];
        if (content is String) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(content),
            fileName: _fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
        }
      } catch (e) {
        debugPrint('[AI文件] 复制 $path 失败：$e');
      }
    }
    return attachments;
  }

  List<String> _pathsFromPatch(String patch) {
    final paths = <String>[];
    void addPath(String raw) {
      final path = raw.trim();
      if (path.isEmpty || path == '/dev/null') return;
      final normalized = path.startsWith('b/') ? path.substring(2) : path;
      if (!WorkspacePathGuard.isSafeRelativePath(normalized)) return;
      if (!paths.contains(normalized)) paths.add(normalized);
    }

    for (final line in const LineSplitter().convert(patch)) {
      final plus = RegExp(r'^\+\+\+\s+(.+)$').firstMatch(line);
      if (plus != null) {
        addPath(plus.group(1) ?? '');
        continue;
      }
      final diff = RegExp(r'^diff --git\s+a/(.+?)\s+b/(.+)$').firstMatch(line);
      if (diff != null) {
        addPath(diff.group(2) ?? '');
      }
    }
    return paths;
  }

  AgentRuntime _agentRuntimeFor({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
  }) {
    final bridge = LocalAgentBridgeClient();
    return AgentRuntime(
      complete: (messages) => _chatApi.sendChatMessage(
        apiKey: config.apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: messages,
      ),
      workspaceFileTool: WorkspaceFileTool(bridge),
      browserContextTool: BrowserContextTool(bridge),
      skillCreateHandler: (args) => _saveGeneratedSkillFromArgs(
        character: character,
        args: args,
      ),
      skillDownloadHandler: (args) => _downloadExpertSkillFromArgs(
        character: character,
        args: args,
      ),
    );
  }

  Future<bool> _handlePendingAgentApproval(String text) async {
    final pending = _pendingAgentApproval;
    if (pending == null) return false;
    if (_isAgentRejection(text)) {
      _pendingAgentApproval = null;
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: pending.character.id,
        senderType: 'ai',
        content: '${pending.character.name} 已取消这次工具操作。',
      ));
      return true;
    }
    if (!_isAgentApproval(text)) {
      // 非审批/非拒绝输入：清除过期审批状态，让新消息走正常 AI 回复流程。
      _pendingAgentApproval = null;
      return false;
    }

    _pendingAgentApproval = null;
    if (_canTouchUi) setState(() => _isAiReplying = true);
    try {
      final runtime = _agentRuntimeFor(
        character: pending.character,
        config: pending.config,
        provider: pending.provider,
      );
      final result = await runtime.executeApprovedTool(
        character: pending.character,
        request: pending.request,
        userRequest: pending.userRequest,
        priorExecutedRequests: pending.priorExecutedRequests,
      );
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        _pendingAgentApproval = _PendingAgentToolApproval(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          userRequest: pending.userRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
        );
      }
      final content = _stripNamePrefix(
        result.message.trim().isEmpty
            ? '[${pending.character.name} 工具执行完成，但没有返回内容]'
            : result.message.trim(),
        pending.character.name,
      );
      final attachments = await _attachmentsForAgentToolResult(
        character: pending.character,
        result: result,
      );
      final message = Message(
        groupId: widget.groupId,
        senderId: pending.character.id,
        senderType: 'ai',
        content: content,
        media: attachments.isEmpty ? null : attachments,
      );
      await _appendMessage(message);
      _recordReplyUsage(pending.character);
      _registerUserMentionIfNeeded(message);
      if (result.status == AgentRuntimeStatus.completed &&
          content.trim().isNotEmpty) {
        await _maybeEvolveCharacterMemory(pending.character, content);
      }
      return true;
    } finally {
      if (_canTouchUi) setState(() => _isAiReplying = false);
    }
  }

  bool _isAgentApproval(String text) {
    final normalized = text.trim().toLowerCase();
    return normalized == '批准' ||
        normalized == '同意' ||
        normalized == '执行' ||
        normalized == '继续' ||
        normalized == 'approve' ||
        normalized == 'yes';
  }

  bool _isAgentRejection(String text) {
    final normalized = text.trim().toLowerCase();
    return normalized == '取消' ||
        normalized == '拒绝' ||
        normalized == '不要' ||
        normalized == 'cancel' ||
        normalized == 'no';
  }

  Future<Map<String, dynamic>> _saveGeneratedSkillFromArgs({
    required AICharacter character,
    required Map<String, dynamic> args,
  }) async {
    final instructionsRaw = args['instructions'];
    if (instructionsRaw is! List) {
      return {'ok': false, 'error': 'instructions_missing'};
    }
    final permissionNames = (args['permissions'] is List
            ? args['permissions'] as List
            : args['requiredPermissions'] is List
                ? args['requiredPermissions'] as List
                : const [])
        .whereType<String>()
        .toSet();
    final permissions = ToolPermission.values
        .where((permission) => permissionNames.contains(permission.name))
        .toList();
    final skill = CharacterSkill(
      characterId: character.id,
      name: args['name'] as String? ?? 'Generated Skill',
      domain: args['domain'] as String? ?? 'general',
      description: args['description'] as String? ?? '',
      instructions: instructionsRaw.whereType<String>().toList(),
      requiredPermissions: permissions,
    );
    await _db.characterSkillBox.put(skill.id, skill);
    if (!character.skillIds.contains(skill.id)) {
      character.skillIds = [...character.skillIds, skill.id];
      await _db.aiCharacterBox.put(character.id, character);
    }
    return {
      'ok': true,
      'skillId': skill.id,
      'name': skill.name,
      'permissions': permissions.map((p) => p.name).toList(),
    };
  }

  Future<Map<String, dynamic>> _downloadExpertSkillFromArgs({
    required AICharacter character,
    required Map<String, dynamic> args,
  }) async {
    final templateId = args['templateId'] as String? ??
        args['id'] as String? ??
        _recommendedTemplateIdFor(character, args['domain'] as String?);
    if (templateId == null) {
      return {'ok': false, 'error': 'template_not_found'};
    }
    final template = ExpertSkillCatalog.findById(templateId);
    if (template == null) {
      return {
        'ok': false,
        'error': 'template_not_found',
        'templateId': templateId
      };
    }
    final existing = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id &&
          skill.name == template.name &&
          skill.domain == template.domain,
    );
    final skill = existing.isNotEmpty
        ? existing.first
        : template.instantiateFor(character.id);
    if (existing.isEmpty) {
      await _db.characterSkillBox.put(skill.id, skill);
    }
    final permissionSet = <ToolPermission>{
      ...character.toolPermissions,
      ...template.requiredPermissions,
    };
    final skillIds = <String>{...character.skillIds, skill.id};
    character
      ..skillIds = skillIds.toList()
      ..toolPermissions = permissionSet.toList()
      ..agenticEnabled = true;
    await _db.aiCharacterBox.put(character.id, character);
    return {
      'ok': true,
      'skillId': skill.id,
      'templateId': template.id,
      'name': skill.name,
      'permissions': permissionSet.map((p) => p.name).toList(),
    };
  }

  String? _recommendedTemplateIdFor(AICharacter character, String? domain) {
    final templates = SkillDownloadService.recommendedTemplatesFor(character);
    if (domain != null && domain.trim().isNotEmpty) {
      for (final template in templates) {
        if (template.domain == domain) return template.id;
      }
    }
    return templates.isEmpty ? null : templates.first.id;
  }

  List<CharacterSkill> _agenticSkillsFor(AICharacter character) {
    final defaults = CharacterSkillResolver.defaultsFor(character).skills;
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    final byName = <String, CharacterSkill>{};
    for (final skill in [...defaults, ...saved]) {
      byName['${skill.domain}:${skill.name}'] = skill;
    }
    return byName.values.toList();
  }

  /// 停止当前流式生成：取消订阅并保留已生成的（部分）内容落库。
  void _stopStreaming() {
    if (!_isStreaming) return;
    _flushStreamingUi();
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

  Future<void> _persistRelationshipForIntent({
    required AICharacter character,
    required ReplyIntent intent,
    required String? userMessage,
  }) async {
    final targetId = intent.targetId ?? (userMessage != null ? 'user' : null);
    if (targetId == null || targetId.isEmpty) return;
    final targetType = targetId == 'user'
        ? RelationshipTargetType.user
        : RelationshipTargetType.ai;
    _relationshipStates = HumanizedMemoryService.applyLocalRelationshipRules(
      relationships: _relationshipStates,
      groupId: widget.groupId,
      speakerId: character.id,
      targetId: targetId,
      targetType: targetType,
      actionName: intent.action.name,
      friendlyTone:
          !intent.toneHint.contains('带刺') && !intent.toneHint.contains('冷淡'),
    );
    for (final relation in _relationshipStates) {
      await _db.relationshipStateBox.put(relation.id, relation);
    }
  }

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.isNotEmpty) {
      final config = _db.apiConfigBox.get(character.apiConfigId);
      if (config != null) {
        debugPrint(
            '[DIAG] ${character.name}: config found via apiConfigId, apiKey_len=${config.apiKey.length}, provider=${config.provider}');
        return config;
      }
      debugPrint(
          '[DIAG] ${character.name}: apiConfigId=${character.apiConfigId} NOT found in box');
    }
    if (character.apiKey.isNotEmpty && character.apiProvider.isNotEmpty) {
      debugPrint(
          '[DIAG] ${character.name}: using legacy apiKey, len=${character.apiKey.length}, provider=${character.apiProvider}');
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
      {bool isAutoChat = false,
      ReplyIntent? intent,
      bool supportsVision = false,
      Message? currentUserMessage}) {
    if (_isDirectChat) {
      return _buildDirectApiMessages(character, context, userMessage,
          supportsVision: supportsVision,
          currentUserMessage: currentUserMessage);
    }

    final msgs = <Map<String, dynamic>>[];

    // ── 1. 群聊记忆摘要 ───────────────────────────────────────────────
    if (_groupMemory != null && _groupMemory!.topicSummary.isNotEmpty) {
      msgs.add(
          {'role': 'system', 'content': '【群聊记忆】${_groupMemory!.topicSummary}'});
    }

    // ── 2. 角色个体记忆（如果有的话） ────────────────────────────────
    if (character.memorySummary.isNotEmpty) {
      msgs.add({
        'role': 'system',
        'content': '【${character.name}的自我记忆】${character.memorySummary}'
      });
    }

    if (intent != null) {
      final memory = HumanizedMemoryService.memoryForCharacter(
        groupId: widget.groupId,
        character: character,
        existing: _characterMemories,
      );
      msgs.add({
        'role': 'system',
        'content': HumanizedPromptBuilder.buildIntentContext(
          character: character,
          groupName: _group?.name ?? '这个群',
          groupTheme: _group?.theme ?? '日常聊天',
          ownerName: (_group?.ownerName.trim().isNotEmpty ?? false)
              ? _group!.ownerName.trim()
              : '我',
          intent: intent,
          memory: memory,
          relationships: _relationshipStates,
          charactersById: {for (final c in _characters) c.id: c},
        ),
      });
    }

    // ── 3. 群聊场景 + 当前对话焦点 ─────────────────────────────────
    final groupName = _group?.name ?? '这个群';
    final groupTheme = _group?.theme ?? '日常聊天';
    final groupDescription = _group?.description ?? '';
    final groupMemory = _groupMemory?.topicSummary ?? '';
    final ownerName = (_group?.ownerName.trim().isNotEmpty ?? false)
        ? _group!.ownerName.trim()
        : '我';
    final isGroupAddressed = userMessage != null &&
        ChatActivityPolicy.isGroupAddressedMessage(userMessage);
    final scene = SceneBehavior.resolve(groupTheme);
    final scenarioPrompt = scene.scenarioPrompt;
    final recentContext = _extractRecentFocus(context);
    final nameById = {for (final c in _characters) c.id: c.name};
    final personaContext = ChatOrchestrator.buildPersonaGrowthContext(
      character: character,
      groupName: groupName,
      groupTheme: groupTheme,
      groupDescription: groupDescription,
      groupMemory: groupMemory,
    );
    msgs.add({
      'role': 'system',
      'content': '$personaContext\n\n'
          '你正在参加一个高活跃度群聊「$groupName」，主题是「$groupTheme」。'
          '回复要像真实聊天群：自然接话、简短、有个人观点，可以顺手回应上一位成员或点名邀请别人，但不要每次都长篇总结。'
          '${HumanizedPromptBuilder.ownerMentionInstruction(ownerName)}'
          '重要：你的回复不要带自己的名字前缀（如「张三：」或「【张三】：」），直接说内容即可，头像和名字由界面自动显示。'
          '$scenarioPrompt'
          '$recentContext'
    });

    if (!scene.isGeneral) {
      final otherCharacters =
          _characters.where((c) => c.id != character.id).toList();
      final candidates = otherCharacters.isEmpty
          ? '暂无其他 AI 角色'
          : otherCharacters
              .map((c) =>
                  '${c.name}，${c.age}岁，${c.role}，${c.personalityTags.join('/')} ')
              .join('；');
      final sceneContext = scene.roomContextPrompt(candidates);
      if (sceneContext.isNotEmpty) {
        msgs.add({'role': 'system', 'content': sceneContext});
      }
    }

    if (isGroupAddressed) {
      msgs.add({
        'role': 'system',
        'content': '【多人接力发言】用户这次是在问大家，不是只问你一个人。'
            '本轮会有多位群成员依次回应；你只代表自己说一小段，通常 1-2 句即可。'
            '如果你的角色没有特别新增观点，可以自然地短附和，比如“是的”“对”“+1”“我也这么想”，但尽量带一点你的角色语气。'
            '不要替其他人总结，也不要写成大段正式回答。'
      });
    }

    // ── 3.5 最后一条用户消息强调 ──────────────────────────────────
    if (context.isNotEmpty && !isAutoChat) {
      final lastUserMsg = context.lastWhere((m) => m.senderType == 'user',
          orElse: () => context.first);
      if (lastUserMsg.senderType == 'user') {
        final speakerName = nameById[lastUserMsg.senderId] ?? '一位群友';
        final truncated = lastUserMsg.content.length > 100
            ? '${lastUserMsg.content.substring(0, 100)}...'
            : lastUserMsg.content;
        msgs.add({
          'role': 'system',
          'content':
              '【当前任务】$speakerName 刚说："$truncated" —— 请作为 ${character.name} 针对这条消息做出自然回应。'
        });
      }
    } else if (context.isNotEmpty && isAutoChat) {
      final last = context.last;
      final speakerName = last.senderType == 'user'
          ? ownerName
          : nameById[last.senderId] ?? '一位群友';
      final truncated = last.content.length > 100
          ? '${last.content.substring(0, 100)}...'
          : last.content;
      msgs.add({
        'role': 'system',
        'content': '【当前任务】$speakerName 刚说："$truncated" —— '
            '请作为 ${character.name} 自然接住这条群聊，可以回应、追问、转给某位成员，或轻轻换个相关话题。'
      });
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
        // 真人用户消息 → user 角色；含媒体时按多模态策略生成 content。
        msgs.add({
          'role': 'user',
          'content': buildUserMessageContent(m, supportsVision: supportsVision),
        });
      } else if (m.senderId == character.id) {
        // 当前角色自己的消息 → assistant 角色（LLM 看到自己的历史发言）。
        msgs.add({'role': 'assistant', 'content': m.content});
      } else {
        // 其他 AI 角色的消息 → user 角色 + 发言者标注（LLM 知道这是别人说的话）。
        final speakerName = nameById[m.senderId] ?? '其他角色';
        final content = m.content.startsWith('【$speakerName】：')
            ? m.content
            : '【$speakerName】：${m.content}';
        msgs.add({'role': 'user', 'content': content});
      }
    }

    // ── 8. 当前用户消息（仅当历史为空时） ──────────────────────────
    if (userMessage != null && historyMessages.isEmpty) {
      // 历史为空时当前用户消息尚未进入 context，需直接基于其构建 content。
      final content = currentUserMessage != null
          ? buildUserMessageContent(currentUserMessage,
              supportsVision: supportsVision)
          : userMessage;
      msgs.add({'role': 'user', 'content': content});
    }

    return msgs;
  }

  List<Map<String, dynamic>> _buildDirectApiMessages(
    AICharacter character,
    List<Message> context,
    String? userMessage, {
    bool supportsVision = false,
    Message? currentUserMessage,
  }) {
    final msgs = <Map<String, dynamic>>[];
    if (character.memorySummary.isNotEmpty) {
      msgs.add({
        'role': 'system',
        'content': '【${character.name}的自我记忆】${character.memorySummary}'
      });
    }

    final memory = HumanizedMemoryService.memoryForCharacter(
      groupId: widget.groupId,
      character: character,
      existing: _characterMemories,
    );
    if (memory.facts.isNotEmpty ||
        memory.relationshipNotes.isNotEmpty ||
        memory.personaGrowth.isNotEmpty) {
      msgs.add({
        'role': 'system',
        'content': [
          if (memory.facts.isNotEmpty)
            '记得的事实：${memory.facts.take(4).join('；')}',
          if (memory.relationshipNotes.isNotEmpty)
            '关系记忆：${memory.relationshipNotes.take(4).join('；')}',
          if (memory.personaGrowth.isNotEmpty)
            '表达习惯：${memory.personaGrowth.take(4).join('；')}',
        ].join('\n'),
      });
    }

    msgs.add({
      'role': 'system',
      'content': DirectChatSession.buildPromptContext(
        character: character,
        ownerName: _ownerMentionName,
      ),
    });
    msgs.add({'role': 'system', 'content': character.systemPrompt});

    final recentHistory =
        context.length > 20 ? context.sublist(context.length - 20) : context;
    for (final message in recentHistory) {
      if (message.senderType == 'user') {
        // 含媒体时按多模态策略生成 content。
        msgs.add({
          'role': 'user',
          'content':
              buildUserMessageContent(message, supportsVision: supportsVision),
        });
      } else if (message.senderId == character.id) {
        msgs.add({'role': 'assistant', 'content': message.content});
      }
    }

    if (userMessage != null && recentHistory.isEmpty) {
      // 历史为空时当前用户消息尚未进入 context，直接基于其构建 content。
      final content = currentUserMessage != null
          ? buildUserMessageContent(currentUserMessage,
              supportsVision: supportsVision)
          : userMessage;
      msgs.add({'role': 'user', 'content': content});
    }

    return msgs;
  }

  /// 从最近的消息中提取对话焦点，帮助 AI 理解"现在在聊什么"。
  /// 取最近 3 条消息的内容拼成一段焦点摘要，注入到 system prompt 中。
  String _extractRecentFocus(List<Message> messages) {
    if (messages.isEmpty) return '';
    final recent =
        messages.length > 3 ? messages.sublist(messages.length - 3) : messages;
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
    await _db.addMessageToGroupIndex(message);
    if (message.senderType == 'ai') {
      await _markCurrentConversationRead(throughMessage: message);
    }
    if (!_canTouchUi) return;
    setState(() {
      _messages = List.from(_messages)..add(message);
    });
    _scrollToBottom();
  }

  String get _ownerMentionName {
    final name = _group?.ownerName.trim() ?? '';
    return name.isEmpty ? '我' : name;
  }

  void _registerUserMentionIfNeeded(Message message) {
    if (!_canTouchUi || message.senderType != 'ai') return;
    if (ConversationPresenceService.instance.isActive(widget.groupId)) return;
    if (!ChatActivityPolicy.contentMentionsUser(
      message.content,
      _ownerMentionName,
    )) {
      return;
    }
    if (_pendingUserMentionMessageIds.contains(message.id)) return;
    setState(() => _pendingUserMentionMessageIds.add(message.id));
  }

  void _clearActiveUserMentionBanner() {
    if (!_canTouchUi || _pendingUserMentionMessageIds.isEmpty) return;
    setState(() => _pendingUserMentionMessageIds.clear());
  }

  void _clearUserMentions() {
    if (_pendingUserMentionMessageIds.isEmpty) return;
    setState(() => _pendingUserMentionMessageIds.clear());
  }

  void _jumpToNextUserMention() {
    while (_pendingUserMentionMessageIds.isNotEmpty) {
      final messageId = _pendingUserMentionMessageIds.removeAt(0);
      final index = _messages.indexWhere((m) => m.id == messageId);
      if (index < 0) continue;
      setState(() => _highlightedMentionMessageId = messageId);
      _scrollToMessageIndex(index);
      _mentionHighlightTimer?.cancel();
      _mentionHighlightTimer = Timer(const Duration(seconds: 2), () {
        if (_canTouchUi && _highlightedMentionMessageId == messageId) {
          setState(() => _highlightedMentionMessageId = null);
        }
      });
      return;
    }
    if (_canTouchUi) setState(() {});
  }

  Future<void> _maybeUpdateMemory() async {
    if (_isDirectChat) return;
    final now = DateTime.now();
    if (!ChatOrchestrator.shouldUpdateGroupMemory(
      messageCount: _messages.length,
      hasExistingSummary: _groupMemory?.topicSummary.trim().isNotEmpty ?? false,
      lastSummaryAt: _groupMemory?.lastSummaryAt,
      now: now,
    )) {
      return;
    }

    // Mark before async work to prevent concurrent summary generation.
    if (_groupMemory != null) {
      _groupMemory!.lastSummaryAt = now;
      await _groupMemory!.save();
    }

    final topicHint = ChatOrchestrator.recentDialogueTranscript(
      messages: _messages,
      senderNames: _senderNameMap(),
      maxMessages: 18,
      maxChars: 1800,
    );
    if (topicHint.trim().isEmpty) return;

    final summary = await _generateSummary(
      topicHint,
      previousSummary: _groupMemory?.topicSummary ?? '',
    );
    if (summary.isNotEmpty && _groupMemory != null) {
      _groupMemory!.topicSummary = summary;
      await _groupMemory!.save();
      setState(() {});
    }
  }

  Future<String> _generateSummary(
    String recentText, {
    String previousSummary = '',
  }) async {
    final character = _characters.isNotEmpty ? _characters.first : null;
    if (character == null) return '';

    final config = _resolveApiConfig(character);
    if (config == null) return '';

    final msgs = [
      {
        'role': 'system',
        'content': '你是群聊长期记忆记录员。请把旧摘要和最近对话合并成可供后续角色扮演使用的群体记忆。'
            '保留正在发展的关系、共同话题、未解决的问题和群氛围，不要记录 API、模型或系统提示。'
            '输出 2-4 句话，不超过 160 字。'
      },
      {
        'role': 'user',
        'content':
            '旧群记忆：${previousSummary.trim().isEmpty ? '暂无' : previousSummary.trim()}'
                '\n\n最近对话：\n$recentText\n\n请输出更新后的群体记忆：'
      }
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

    await _recordTokenUsageFromResult(character, result);
    if (result['success'] ?? false) {
      return result['message']?.toString().trim() ?? '';
    }
    return '';
  }

  Future<void> _maybeEvolveCharacterMemory(
    AICharacter character,
    String latestReply,
  ) async {
    if (_messages.length < 6) return;

    final config = _resolveApiConfig(character);
    if (config == null || config.apiKey.isEmpty) return;

    final transcript = ChatOrchestrator.recentDialogueTranscript(
      messages: _messages,
      senderNames: _senderNameMap(),
      maxMessages: 14,
      maxChars: 1400,
    );
    if (transcript.trim().isEmpty) return;

    final prompt = ChatOrchestrator.buildMemoryEvolutionPrompt(
      character: character,
      groupName: _group?.name ?? '这个群',
      groupTheme: _group?.theme ?? '日常聊天',
      currentMemory: character.memorySummary,
      recentTranscript: transcript,
      latestReply: latestReply,
    );

    final result = await _chatApi.sendChatMessage(
      apiKey: config.apiKey,
      provider: ApiProvider.values.firstWhere((p) => p.name == config.provider,
          orElse: () => ApiProvider.deepseek),
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: [
        {
          'role': 'system',
          'content': '你只负责更新角色长期记忆。必须输出严格 JSON，不要 Markdown，不要解释。',
        },
        {
          'role': 'user',
          'content': '$prompt\n\n输出 JSON 形状：'
              '{"facts":["稳定事实"],"relationshipNotes":["关系或情绪变化"],'
              '"personaGrowth":["表达习惯、偏好、雷点或长期执念"],"discard":["不保存内容"]}',
        },
      ],
      temperature: 0.35,
    );

    await _recordTokenUsageFromResult(character, result);
    if (!(result['success'] ?? false)) return;
    final updated = result['message']?.toString().trim() ?? '';
    if (updated.isEmpty) return;
    await _mergeHumanizedMemory(character, updated);
    final parsed = HumanizedMemoryService.parseLayeredMemoryJson(updated);
    character.memorySummary = _memorySummaryFromParsed(parsed);
    await character.save();
    if (_canTouchUi) setState(() {});
  }

  Future<void> _mergeHumanizedMemory(
    AICharacter character,
    String rawJson,
  ) async {
    final update = HumanizedMemoryService.parseLayeredMemoryJson(rawJson);
    if (update.facts.isEmpty &&
        update.relationshipNotes.isEmpty &&
        update.personaGrowth.isEmpty) {
      return;
    }

    final memory = HumanizedMemoryService.memoryForCharacter(
      groupId: widget.groupId,
      character: character,
      existing: _characterMemories,
    );
    HumanizedMemoryService.mergeLayeredMemory(memory, update);
    await _db.characterMemoryBox.put(memory.id, memory);
    final index = _characterMemories.indexWhere((m) => m.id == memory.id);
    if (index == -1) {
      _characterMemories = [..._characterMemories, memory];
    } else {
      _characterMemories = [..._characterMemories]..[index] = memory;
    }
  }

  Map<String, String> _senderNameMap() {
    return {
      'user': _group?.ownerName ?? '我',
      for (final c in _allGroupCharacters) c.id: c.name,
      for (final c in _characters) c.id: c.name,
    };
  }

  String _memorySummaryFromParsed(LayeredMemoryUpdate parsed) {
    final parts = <String>[];
    if (parsed.facts.isNotEmpty) {
      parts.add('【事实】${parsed.facts.take(4).join('；')}');
    }
    if (parsed.relationshipNotes.isNotEmpty) {
      parts.add('【关系】${parsed.relationshipNotes.take(3).join('；')}');
    }
    if (parsed.personaGrowth.isNotEmpty) {
      parts.add('【成长】${parsed.personaGrowth.take(3).join('；')}');
    }
    final text = parts.join('\n');
    if (text.length <= 900) return text;
    return text.substring(0, 900);
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

  Future<void> _recordTokenUsageFromResult(
      AICharacter character, Map<String, dynamic> result) async {
    final promptTokens = result['promptTokens'];
    final completionTokens = result['completionTokens'];
    if (promptTokens is! int || completionTokens is! int) return;
    await _db.recordTokenUsage(
      characterId: character.id,
      groupId: widget.groupId,
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cachedTokens: result['cachedTokens'] is int ? result['cachedTokens'] : 0,
    );
  }

  Future<void> _delay([String content = '']) async {
    await Future.delayed(ChatActivityPolicy.replyDelayForContent(
      content,
      random: _random,
    ));
  }

  void _hideMentionOverlay() {
    _mentionOverlay?.remove();
    _mentionOverlay = null;
    _showMentionPopup = false;
    _filteredMentionMembers = [];
    _mentionSelectedIndex = 0;
    _mentionSearchController.clear();
  }

  void _showMentionOverlay(Offset globalPosition) {
    if (_showMentionPopup) return;
    _showMentionPopup = true;
    _mentionSelectedIndex = 0;

    _mentionOverlay = OverlayEntry(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        // 用 RenderBox 精确定位：找到输入框在屏幕上的位置，弹窗放在其上方。
        final renderBox =
            _inputFieldKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox == null) return const SizedBox.shrink();
        final inputGlobalPos = renderBox.localToGlobal(Offset.zero);
        final screenWidth = MediaQuery.of(context).size.width;
        final screenHeight = MediaQuery.of(context).size.height;
        final inputTop = inputGlobalPos.dy;
        final inputLeft = inputGlobalPos.dx;
        final inputWidth = renderBox.size.width;

        // 弹窗宽度跟随输入框，但保持紧凑，避免遮住整页。
        final popupWidth = min(inputWidth, 280.0);
        // 水平居中于输入框。
        var left = inputLeft + (inputWidth - popupWidth) / 2;
        // 不超出屏幕左右边界。
        left = left.clamp(8.0, max(8.0, screenWidth - popupWidth - 8.0));
        final popupMaxHeight = min(max(inputTop - 16, 120.0), 260.0);

        final content = _buildMentionPopupContent(cs);
        return Positioned(
          left: left,
          bottom: screenHeight - inputTop + 8,
          width: popupWidth,
          child: TapRegion(
            onTapOutside: (_) => _hideMentionOverlay(),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              color: cs.surfaceContainerHighest,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: popupMaxHeight),
                child: content,
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
      constraints: const BoxConstraints(maxWidth: 280, maxHeight: 260),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
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
                const Spacer(),
                Text('${_allGroupCharacters.length} 人',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: TextField(
              controller: _mentionSearchController,
              autofocus: false,
              decoration: InputDecoration(
                hintText: '搜索名称、角色或标签…',
                prefixIcon: Icon(Icons.search_rounded,
                    size: 16, color: cs.onSurfaceVariant),
                isDense: true,
                filled: true,
                fillColor: cs.surfaceContainerHighest.withOpacity(0.6),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: cs.outlineVariant.withOpacity(0.6)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: cs.outlineVariant.withOpacity(0.6)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: cs.primary.withOpacity(0.6)),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: _onMentionSearchChanged,
            ),
          ),
          Divider(height: 1, color: cs.outlineVariant.withOpacity(0.4)),
          // 成员列表（Expanded 保证 ListView 有可滚动的空间）
          Expanded(
            child: _buildMentionList(cs),
          ),
        ],
      ),
    );
  }

  /// @ 弹窗内搜索框的过滤逻辑：匹配名称 / 角色 / 个性标签。
  void _onMentionSearchChanged(String query) {
    final q = query.trim();
    if (q.isEmpty) {
      _filteredMentionMembers = List.from(_allGroupCharacters);
    } else {
      _filteredMentionMembers = _allGroupCharacters
          .where((c) =>
              c.name.contains(q) ||
              c.role.contains(q) ||
              c.personalityTags.any((tag) => tag.contains(q)))
          .toList();
    }
    _mentionSelectedIndex = 0;
    _mentionOverlay?.markNeedsBuild();
  }

  bool get _showMentionAllOption {
    final q = _mentionSearchController.text.trim().toLowerCase();
    return q.isEmpty ||
        'all'.contains(q) ||
        '所有人'.contains(q) ||
        '全部'.contains(q);
  }

  Widget _buildMentionList(ColorScheme cs) {
    final showAll = _showMentionAllOption;
    if (_filteredMentionMembers.isEmpty && !showAll) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(child: Text('无匹配角色', style: TextStyle(fontSize: 14))),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _filteredMentionMembers.length + (showAll ? 1 : 0),
      itemBuilder: (ctx2, i) {
        if (showAll && i == 0) {
          return _buildMentionAllTile(cs, selected: _mentionSelectedIndex == 0);
        }
        final memberIndex = showAll ? i - 1 : i;
        final c = _filteredMentionMembers[memberIndex];
        final pColor = _senderColor(c);
        final selected = i == _mentionSelectedIndex;
        return InkWell(
          onTap: () => _insertMention(c),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color:
                  selected ? cs.primary.withOpacity(0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
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

  Widget _buildMentionAllTile(ColorScheme cs, {required bool selected}) {
    return InkWell(
      onTap: _insertMentionAll,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withOpacity(0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: cs.primary.withOpacity(0.14),
                border: Border.all(color: cs.primary.withOpacity(0.3)),
              ),
              child: Icon(Icons.groups_rounded, size: 18, color: cs.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('@all',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface),
                      overflow: TextOverflow.ellipsis),
                  Text('提到所有群成员',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// @ 弹窗打开时的键盘导航：↑↓ 选择、回车插入、Esc 关闭。
  KeyEventResult _handleMentionKeyEvent(KeyEvent event) {
    if (!_showMentionPopup) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final optionCount =
        _filteredMentionMembers.length + (_showMentionAllOption ? 1 : 0);
    if (optionCount <= 0) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex + 1).clamp(0, optionCount - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _mentionSelectedIndex =
            (_mentionSelectedIndex - 1).clamp(0, optionCount - 1);
      });
      _mentionOverlay?.markNeedsBuild();
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_showMentionAllOption && _mentionSelectedIndex == 0) {
        _insertMentionAll();
      } else {
        final memberIndex = _showMentionAllOption
            ? _mentionSelectedIndex - 1
            : _mentionSelectedIndex;
        if (memberIndex >= 0 && memberIndex < _filteredMentionMembers.length) {
          _insertMention(_filteredMentionMembers[memberIndex]);
        }
      }
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.escape) {
      _hideMentionOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _insertMentionAll() {
    _insertMentionText('@all ');
  }

  void _insertMention(AICharacter character) {
    _insertMentionText('@${character.name} ');
  }

  void _insertMentionText(String mentionText) {
    final text = _textController.text;
    final cursorPos = _textController.selection.baseOffset;

    int atPos = text.lastIndexOf('@', cursorPos - 1);
    if (atPos < 0) atPos = 0;

    final newText =
        '${text.substring(0, atPos)}$mentionText${text.substring(cursorPos)}';
    _textController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: atPos + mentionText.length),
    );

    // Overlay dismissal can steal focus; restore it immediately.
    _inputFocusNode.requestFocus();
    _hideMentionOverlay();
  }

  /// 判断光标是否处于「@后跟非空格字符」的输入状态（即应显示 @ 弹窗）。
  bool _isInMentionQuery(String text, int cursorPos) {
    final textBeforeCursor = text.substring(0, cursorPos);
    final atIndex = textBeforeCursor.lastIndexOf('@');
    if (atIndex < 0) return false;
    final query = textBeforeCursor.substring(atIndex + 1);
    return !query.contains(' ');
  }

  void _handleTextChanged(String text) {
    if (_isDirectChat) return;
    if (!_showMentionPopup) {
      final cursorPos = _textController.selection.baseOffset;
      if (_isInMentionQuery(text, cursorPos)) {
        _filteredMentionMembers = List.from(_allGroupCharacters);
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
        ? List.from(_allGroupCharacters)
        : _allGroupCharacters
            .where((c) =>
                c.name.contains(query) ||
                c.role.contains(query) ||
                c.personalityTags.any((tag) => tag.contains(query)))
            .toList();

    // 列表变化后，高亮索引重置到首项并夹取到合法范围
    if (_mentionSelectedIndex >= _filteredMentionMembers.length) {
      _mentionSelectedIndex = 0;
    }

    if (_mentionOverlay != null) {
      _mentionOverlay!.markNeedsBuild();
    }
  }

  List<String> _parseMentions(String content) {
    if (_isDirectChat) return const [];
    return parseMentionedCharacterIds(content, _characters);
  }

  List<AICharacter> _charactersForIntents(List<ReplyIntent> intents) {
    final byId = {for (final c in _characters) c.id: c};
    return intents
        .map((intent) => byId[intent.speakerId])
        .whereType<AICharacter>()
        .toList();
  }

  List<AICharacter> _directReplyCharacters() {
    _pendingReplyIntents.clear();
    return DirectChatSession.selectReplyCharacters(
      characters: _allGroupCharacters,
      directCharacterId: _directCharacterId ?? '',
      isEligible: _isEligibleToReply,
    );
  }

  List<ReplyIntent> _selectGroupReplyIntents({
    required String? userMessage,
    required List<String>? mentionedIds,
    required bool isAutoChat,
  }) {
    final replyIntents = HumanizedChatOrchestrator.selectReplyIntents(
      characters: _characters,
      recentMessages: _recentMessagesForContext(),
      groupId: widget.groupId,
      groupTheme: _group?.theme ?? '日常聊天',
      userMessage: userMessage,
      mentionedIds: mentionedIds ?? const [],
      memories: _characterMemories,
      relationships: _relationshipStates,
      isEligible: _isEligibleToReply,
      random: _random,
      isAutoChat: isAutoChat,
    );
    _pendingReplyIntents
      ..clear()
      ..addEntries(
          replyIntents.map((intent) => MapEntry(intent.speakerId, intent)));
    return replyIntents;
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
        return _isDirectChat ? '该角色已停用，无法回复' : '当前群聊没有启用中的角色';
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

  void _scheduleStreamingUiFlush() {
    if (_streamUiFlushTimer?.isActive ?? false) return;
    _streamUiFlushTimer = Timer(_streamUiFlushInterval, () {
      _streamUiFlushTimer = null;
      _flushStreamingUi();
    });
  }

  void _flushStreamingUi({bool forceScroll = false}) {
    _streamUiFlushTimer?.cancel();
    _streamUiFlushTimer = null;
    if (!_canTouchUi) return;
    final shouldScroll = forceScroll || _isNearBottom();
    setState(() {});
    if (shouldScroll) {
      _scrollToBottom(animated: false);
    }
  }

  bool _isNearBottom({double threshold = 160}) {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels <= threshold;
  }

  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final target = _scrollController.position.maxScrollExtent;
        if (animated) {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(target);
        }
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
    _searchDebounceTimer?.cancel();
    setState(() {
      _isSearching = false;
      _searchController.clear();
      _searchResults = [];
      _searchFocusIndex = null;
    });
  }

  void _performSearch(String query) {
    if (query.trim().isEmpty) {
      _searchDebounceTimer?.cancel();
      setState(() => _searchResults = []);
      return;
    }
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(_searchDebounceDuration, () {
      _applySearch(query);
    });
  }

  void _applySearch(String query) {
    if (!_canTouchUi) return;
    final q = query.toLowerCase();
    setState(() {
      _searchResults =
          _messages.where((m) => m.content.toLowerCase().contains(q)).toList();
      _searchFocusIndex = _searchResults.isEmpty ? null : 0;
    });
    if (_searchResults.isNotEmpty) {
      final idx = _messages.indexOf(_searchResults[0]);
      _scrollToMessageIndex(idx);
    }
  }

  void _scrollToMessageIndex(int index) {
    if (index < 0 || index >= _messages.length) return;
    if (!_scrollController.hasClients) return;
    final key = _messageKeys[_messages[index].id];
    final keyContext = key?.currentContext;
    if (keyContext != null) {
      Scrollable.ensureVisible(
        keyContext,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: 0.2,
      );
      return;
    }
    // Item not rendered yet: jump close, then refine once item is built.
    final estimatedOffset = index * 80.0;
    _scrollController.jumpTo(
      estimatedOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final k = _messageKeys[_messages[index].id];
      final ctx = k?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: 0.2,
        );
      }
    });
  }

  void _searchPrev() {
    if (_searchResults.isEmpty || _searchFocusIndex == null) return;
    setState(() {
      _searchFocusIndex = ((_searchFocusIndex! - 1 + _searchResults.length) %
          _searchResults.length);
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
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('${sender.name} 的消息',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
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
              _sheetBtn(
                  ctx,
                  cs,
                  _isSpeaking && _speakingMessageId == message.id
                      ? Icons.stop_circle_rounded
                      : Icons.volume_up_rounded,
                  _isSpeaking && _speakingMessageId == message.id
                      ? '停止朗读'
                      : '朗读', () {
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

  Widget _sheetBtn(BuildContext ctx, ColorScheme cs, IconData icon,
      String label, VoidCallback onTap) {
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

  Future<void> _regenerateAiReply(
      Message original, AICharacter character) async {
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

    final provider = ApiProvider.values.firstWhere(
        (p) => p.name == config.provider,
        orElse: () => ApiProvider.deepseek);
    final apiMessages = _buildApiMessages(character, _regenerateContext, null,
        supportsVision: provider.supportsVision);

    final temp = Message(
        groupId: widget.groupId,
        senderId: character.id,
        senderType: 'ai',
        content: '');
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
    int? cachedTokens;

    final sub = _chatApi
        .streamChatMessage(
      apiKey: config.apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
    )
        .listen((e) {
      if (!_canTouchUi) return;
      switch (e.type) {
        case ChatStreamEventType.token:
          fullContent += e.delta ?? '';
          temp.content = fullContent;
          _scheduleStreamingUiFlush();
          break;
        case ChatStreamEventType.done:
          if ((e.content ?? '').isNotEmpty) fullContent = e.content!;
          temp.content = fullContent;
          _flushStreamingUi();
          if (e.promptTokens != null) promptTokens = e.promptTokens;
          if (e.completionTokens != null) completionTokens = e.completionTokens;
          if (e.cachedTokens != null) cachedTokens = e.cachedTokens;
          if (!done.isCompleted) done.complete();
          break;
        case ChatStreamEventType.error:
          failed = true;
          fullContent = '[${character.name} 重新生成失败: ${e.message}]';
          temp.content = fullContent;
          _flushStreamingUi();
          if (!done.isCompleted) done.complete();
      }
    }, onError: (err) {
      if (!_canTouchUi) return;
      failed = true;
      fullContent = '[${character.name} 重新生成失败: $err]';
      temp.content = fullContent;
      _flushStreamingUi();
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
          characterName: character.name,
          role: character.role,
          groupTheme: _group?.theme ?? '',
          userMessage: null,
          isAutoChat: false,
          random: _random);
      temp.content = fullContent;
      _flushStreamingUi();
    }

    final mentionedIds = _isDirectChat
        ? const <String>[]
        : parseMentionedCharacterIds(fullContent, _characters);
    fullContent = _stripNamePrefix(fullContent, character.name);
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    temp.replyToMessageId = original.id;
    await _db.messageBox.put(temp.id, temp);
    await _db.addMessageToGroupIndex(temp);
    _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    if (promptTokens != null && completionTokens != null) {
      _db.recordTokenUsage(
        characterId: character.id,
        groupId: widget.groupId,
        inputTokens: promptTokens!,
        outputTokens: completionTokens!,
        cachedTokens: cachedTokens ?? 0,
      );
    }
    if (!failed && fullContent.trim().isNotEmpty) {
      await _maybeEvolveCharacterMemory(character, fullContent);
      await _maybeUpdateMemory();
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
    if (id == 'user') return _ownerMentionName;
    final c = _allGroupCharacters.firstWhere((c) => c.id == id,
        orElse: () => _unknownCharacter());
    return c.name;
  }

  AICharacter _unknownCharacter() {
    return AICharacter(
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
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            style: TextStyle(
                fontSize: 12, color: cs.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final messagesById = {for (final message in _messages) message.id: message};
    final charactersById = {
      for (final character in _allGroupCharacters) character.id: character,
      for (final character in _characters) character.id: character
    };
    _messageKeys.removeWhere((id, _) => !messagesById.containsKey(id));

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
                  if (!_isDirectChat &&
                      _groupMemory != null &&
                      _groupMemory!.topicSummary.isNotEmpty)
                    Text(_groupMemory!.topicSummary,
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
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
                if (!_isDirectChat)
                  IconButton(
                    icon: const Icon(Icons.upload_rounded, size: 22),
                    onPressed: () {
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            ExportPage(initialGroupId: widget.groupId),
                      ));
                    },
                    tooltip: '导出本群对话',
                  ),
                if (!_isDirectChat)
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
          if (!_isDirectChat) _buildAutoChatStatusBar(cs),
          if (_pendingUserMentionMessageIds.isNotEmpty &&
              !ConversationPresenceService.instance.isActive(widget.groupId))
            _buildUserMentionBanner(cs),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(cs)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final messageKey =
                          _messageKeys.putIfAbsent(message.id, GlobalKey.new);
                      // 日期分隔：首条或与上一条不在同一天时显示
                      final showDate = index == 0 ||
                          !_isSameDay(message.timestamp,
                              _messages[index - 1].timestamp);
                      final sender = message.senderType == 'user'
                          ? null
                          : charactersById[message.senderId] ??
                              _unknownCharacter();
                      final isStreaming = _streamingMessage != null &&
                          _streamingMessage!.id == message.id;
                      final isRegenerating =
                          _isRegenerating && _regenerateMessageId == message.id;
                      final isAiBubble =
                          message.senderType == 'ai' && sender != null;
                      final quotedMessage = message.replyToMessageId == null
                          ? null
                          : messagesById[message.replyToMessageId];
                      return KeyedSubtree(
                        key: messageKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showDate)
                              _buildDateDivider(cs, message.timestamp),
                            _MessageBubble(
                              message: message,
                              sender: sender,
                              characters: _allGroupCharacters,
                              cs: cs,
                              isStreaming: isStreaming,
                              isRegenerating: isRegenerating,
                              isHighlightedMention:
                                  _highlightedMentionMessageId == message.id,
                              onLongPress: isAiBubble
                                  ? () =>
                                      _showMessageActionSheet(message, sender)
                                  : null,
                              senderColor: (c) => _senderColor(c),
                              quotedMessage: quotedMessage,
                              quotedSenderName: quotedMessage == null
                                  ? null
                                  : _senderNameById(quotedMessage.senderId),
                            ),
                          ],
                        ),
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
              child: Icon(
                  _isDirectChat
                      ? Icons.chat_bubble_rounded
                      : Icons.groups_rounded,
                  size: 44,
                  color: Colors.white),
            ),
            const SizedBox(height: 24),
            Text(
                _isDirectChat
                    ? (_group?.name ?? '私聊')
                    : '欢迎来到 ${_group?.name ?? '群聊'}',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface)),
            const SizedBox(height: 8),
            Text(
              _isDirectChat
                  ? '发条消息，和这个角色单独聊聊。\n对话会保存在本地。'
                  : '这是一个 AI 群聊模拟器。\n发条消息，AI 角色会自动回复；\n用 @ 可以指定某个角色回应。',
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
                if (!_isDirectChat) _hintChip(cs, '@角色名 提到谁'),
                if (!_isDirectChat && _characters.isNotEmpty)
                  _hintChip(cs, '${_characters.length} 位 AI 在线'),
                if (_isDirectChat && _allGroupCharacters.isNotEmpty)
                  _hintChip(cs, _allGroupCharacters.first.role),
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
              _isDirectChat
                  ? _replyBlockText(_lastReplyBlockReason)
                  : '尚未配置 API Key，AI 不会回复或自动聊天',
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

  Widget _buildUserMentionBanner(ColorScheme cs) {
    final count = _pendingUserMentionMessageIds.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: cs.primaryContainer.withOpacity(0.72),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: _jumpToNextUserMention,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: cs.primary.withOpacity(0.32)),
            ),
            child: Row(
              children: [
                Icon(Icons.alternate_email_rounded,
                    size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    count == 1 ? '有人 @ 你' : '$count 条 @ 你的消息',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                ),
                Icon(Icons.keyboard_arrow_down_rounded,
                    size: 20, color: cs.primary),
                IconButton(
                  onPressed: _clearUserMentions,
                  icon: Icon(Icons.close_rounded,
                      size: 16, color: cs.onPrimaryContainer),
                  tooltip: '忽略提醒',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
        ),
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
                          onDirectChat: () =>
                              _openDirectChatFromSheet(context, c),
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
    VoidCallback? onDirectChat,
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
          if (onDirectChat != null)
            IconButton(
              onPressed: onDirectChat,
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 20),
              color: cs.primary,
              tooltip: '私聊',
            ),
        ],
      ),
    );
  }

  void _openDirectChatFromSheet(BuildContext sheetContext, AICharacter c) {
    Navigator.of(sheetContext).pop();
    if (!mounted) return;
    Navigator.of(context).pushNamed('/dm/${c.id}');
  }

  bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  /// 输入区键盘事件：@ 弹窗打开时走导航；桌面端回车发送、Shift+回车换行。
  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
            event.logicalKey == LogicalKeyboardKey.shiftRight)) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // @ 弹窗键盘导航优先（↑↓ 选择、回车插入、Esc 关闭）
    if (_showMentionPopup) return _handleMentionKeyEvent(event);
    final key = event.logicalKey;
    // 桌面端：Enter 发送、Shift+Enter 换行
    if (_isDesktop) {
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
        if (!isShiftPressed) {
          if (_canSend) {
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
    return DropTarget(
      onDragEntered: (_) {
        if (_canTouchUi) setState(() => _isDraggingFiles = true);
      },
      onDragExited: (_) {
        if (_canTouchUi) setState(() => _isDraggingFiles = false);
      },
      onDragDone: (detail) {
        if (_canTouchUi) setState(() => _isDraggingFiles = false);
        unawaited(_handleDroppedFiles(detail.files));
      },
      child: Focus(
        onKeyEvent: (_, event) => _handleKeyEvent(event),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_quotedMessage != null) _buildQuoteBar(cs),
            // 待发送附件预览（图片缩略 / 视频占位，可单独移除）。
            if (_pendingAttachments.isNotEmpty) _buildAttachmentPreviewRow(cs),
            Container(
              padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: MediaQuery.of(context).padding.bottom + 12),
              decoration: BoxDecoration(
                color: cs.surface,
                border: Border(
                  top: BorderSide(
                    color: _isDraggingFiles
                        ? cs.primary
                        : cs.outlineVariant.withOpacity(0.5),
                    width: _isDraggingFiles ? 2 : 1,
                  ),
                ),
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
                  // 附件按钮：图片多选 / 视频单选。
                  IconButton(
                    icon: const Icon(Icons.attach_file_rounded, size: 24),
                    color: cs.onSurfaceVariant,
                    onPressed: _showAttachmentMenu,
                    tooltip: '添加附件',
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_paste_rounded, size: 22),
                    color: cs.onSurfaceVariant,
                    onPressed: () =>
                        _pasteClipboardAttachments(showEmptyHint: true),
                    tooltip: '粘贴截图或文件',
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(minHeight: 72, maxHeight: 180),
                      child: TextField(
                        key: _inputFieldKey,
                        controller: _textController,
                        focusNode: _inputFocusNode,
                        decoration: InputDecoration(
                          hintText: _quotedMessage != null
                              ? '回复 ${_senderNameById(_quotedMessage!.senderId)}...'
                              : (_isDirectChat
                                  ? '输入私聊消息…'
                                  : _isDesktop
                                      ? '输入消息，回车发送，Shift+回车换行，@ 提到角色…'
                                      : '输入消息，@ 提到角色…'),
                          suffixIcon: _quotedMessage != null
                              ? IconButton(
                                  icon: Icon(Icons.close_rounded,
                                      size: 18, color: cs.onSurfaceVariant),
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
                              horizontal: 20, vertical: 16),
                          isDense: true,
                        ),
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        maxLines: null,
                        onChanged: _handleTextChanged,
                        // 桌面右键 / 移动端长按均弹出自适应菜单：剪切 / 复制 / 粘贴 / 全选。
                        contextMenuBuilder: (context, editableTextState) {
                          return AdaptiveTextSelectionToolbar.buttonItems(
                            anchors: editableTextState.contextMenuAnchors,
                            buttonItems:
                                editableTextState.contextMenuButtonItems,
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_isStreaming) ...[
                    IconButton(
                      icon: const Icon(Icons.stop_rounded, size: 24),
                      color: cs.error,
                      onPressed: _stopStreaming,
                      tooltip: '停止生成',
                    ),
                    const SizedBox(width: 4),
                  ],
                  IconButton(
                    icon: const Icon(Icons.send_rounded, size: 24),
                    color: _canSend
                        ? cs.primary
                        : cs.onSurfaceVariant.withOpacity(0.4),
                    onPressed: _canSend ? _sendMessage : null,
                    tooltip: '发送',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出附件选择底部菜单：图片（多选）/ 视频（单选）/ 文件（多选）。
  void _showAttachmentMenu() {
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
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text('发送附件',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            _sheetBtn(ctx, cs, Icons.image_rounded, '图片（可多选）', () {
              Navigator.pop(ctx);
              _pickImages();
            }),
            const SizedBox(height: 8),
            _sheetBtn(ctx, cs, Icons.videocam_rounded, '视频（单选）', () {
              Navigator.pop(ctx);
              _pickVideo();
            }),
            const SizedBox(height: 8),
            _sheetBtn(ctx, cs, Icons.insert_drive_file_rounded, '文件（可多选）', () {
              Navigator.pop(ctx);
              _pickFiles();
            }),
            const SizedBox(height: 8),
            _sheetBtn(ctx, cs, Icons.content_paste_rounded, '粘贴截图或文件', () {
              Navigator.pop(ctx);
              _pasteClipboardAttachments(showEmptyHint: true);
            }),
          ],
        ),
      ),
    );
  }

  /// 从相册多选图片，复制到媒体目录并加入待发送列表。
  Future<void> _pickImages() async {
    try {
      final currentImageCount =
          _pendingAttachments.where((att) => att.type == 'image').length;
      final remainingSlots = defaultMaxVisionImages - currentImageCount;
      if (remainingSlots <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('一次最多发送 4 张图片'),
              behavior: SnackBarBehavior.floating));
        }
        return;
      }

      final files = await _imagePicker.pickMultiImage(
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (files.isEmpty) return;
      final selectedFiles = files.take(remainingSlots).toList();
      if (files.length > selectedFiles.length && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已限制为一次最多 4 张图片'),
            behavior: SnackBarBehavior.floating));
      }
      for (final file in selectedFiles) {
        final att = await _db.copyToMedia(File(file.path), 'image');
        if (mounted) setState(() => _pendingAttachments.add(att));
      }
    } catch (e) {
      debugPrint('[附件] 选择图片失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('选择图片失败：$e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  /// 从相册选择单个视频，复制到媒体目录并加入待发送列表。
  Future<void> _pickVideo() async {
    try {
      final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      final att = await _db.copyToMedia(File(file.path), 'video');
      if (mounted) setState(() => _pendingAttachments.add(att));
    } catch (e) {
      debugPrint('[附件] 选择视频失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('选择视频失败：$e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: false,
      );
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final picked in result.files) {
        final path = picked.path;
        if (path == null || path.trim().isEmpty) continue;
        final source = File(path);
        if (!await source.exists()) continue;
        final att = await _db.copyToMedia(
          source,
          _attachmentTypeForPath(path),
          fileName: picked.name,
        );
        if (mounted) setState(() => _pendingAttachments.add(att));
        added++;
      }
      if (mounted && added == 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('没有可读取的文件'), behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      debugPrint('[附件] 选择文件失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('选择文件失败：$e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  Future<void> _handleDroppedFiles(List<dynamic> files) async {
    if (files.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    var addedFiles = 0;
    final droppedDirectories = <String>[];
    try {
      for (final dropped in files) {
        final path = (dropped.path as String?)?.trim() ?? '';
        if (path.isEmpty) continue;
        final directory = Directory(path);
        if (await directory.exists()) {
          droppedDirectories.add(directory.absolute.path);
          continue;
        }
        final source = File(path);
        if (!await source.exists()) continue;
        final att = await _db.copyToMedia(
          source,
          _attachmentTypeForPath(path),
          fileName: _fileNameFromPath(path),
        );
        addedFiles++;
        if (_canTouchUi) {
          setState(() => _pendingAttachments.add(att));
        }
      }

      if (droppedDirectories.isNotEmpty) {
        _insertTextAtCursor(droppedDirectories.join('\n'));
      }
      if (!_canTouchUi) return;
      final parts = <String>[
        if (addedFiles > 0) '$addedFiles 个文件',
        if (droppedDirectories.isNotEmpty)
          '${droppedDirectories.length} 个文件夹路径',
      ];
      if (parts.isNotEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text('已添加 ${parts.join('、')}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      debugPrint('[附件] 拖放失败：$e');
      if (_canTouchUi) {
        messenger.showSnackBar(SnackBar(
          content: Text('拖放失败：$e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  void _insertTextAtCursor(String text) {
    if (text.trim().isEmpty) return;
    final current = _textController.text;
    final selection = _textController.selection;
    final insertion = current.trim().isEmpty ? text : '\n$text';
    final start = selection.start < 0 ? current.length : selection.start;
    final end = selection.end < 0 ? current.length : selection.end;
    final next = current.replaceRange(start, end, insertion);
    final cursor = start + insertion.length;
    _textController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  Future<void> _pasteClipboardAttachments({bool showEmptyHint = false}) async {
    if (_isPastingAttachments) return;
    _isPastingAttachments = true;
    try {
      final attachments = <MediaAttachment>[];

      try {
        final files = await Pasteboard.files();
        for (final path in files) {
          if (path.trim().isEmpty || path.startsWith('content://')) continue;
          final source = File(path);
          if (!await source.exists()) continue;
          attachments.add(await _db.copyToMedia(
            source,
            _attachmentTypeForPath(path),
          ));
        }
      } catch (e) {
        debugPrint('[附件] 剪贴板文件读取失败：$e');
      }

      if (attachments.isEmpty) {
        try {
          final image = await Pasteboard.image;
          if (image != null && image.isNotEmpty) {
            attachments.add(await _db.copyBytesToMedia(
              Uint8List.fromList(image),
              'image',
              fileName:
                  'clipboard_${DateTime.now().millisecondsSinceEpoch}.png',
              mimeType: 'image/png',
            ));
          }
        } catch (e) {
          debugPrint('[附件] 剪贴板图片读取失败：$e');
        }
      }

      if (!mounted) return;
      if (attachments.isEmpty) {
        if (showEmptyHint) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('剪贴板里没有可粘贴的文件或截图'),
              behavior: SnackBarBehavior.floating));
        }
        return;
      }
      setState(() => _pendingAttachments.addAll(attachments));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已粘贴 ${attachments.length} 个附件'),
          behavior: SnackBarBehavior.floating));
    } catch (e) {
      debugPrint('[附件] 粘贴失败：$e');
      if (mounted && showEmptyHint) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('粘贴失败：$e'), behavior: SnackBarBehavior.floating));
      }
    } finally {
      _isPastingAttachments = false;
    }
  }

  String _attachmentTypeForPath(String path) {
    final ext = _extensionOfPath(path);
    const imageExts = {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'heic',
      'bmp',
    };
    const videoExts = {
      'mp4',
      'mov',
      'avi',
      'mkv',
      'webm',
      'm4v',
    };
    if (imageExts.contains(ext)) return 'image';
    if (videoExts.contains(ext)) return 'video';
    return 'file';
  }

  String _extensionOfPath(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// 待发送附件预览行：图片缩略 / 视频占位，每项可单独移除。
  Widget _buildAttachmentPreviewRow(ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: _pendingAttachments.map((att) {
          final child = _buildPendingAttachmentThumb(att, cs);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              child,
              Positioned(
                top: -6,
                right: -6,
                child: InkWell(
                  onTap: () => _removeAttachment(att),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: Icon(Icons.cancel,
                        size: 18, color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildPendingAttachmentThumb(MediaAttachment att, ColorScheme cs) {
    if (att.type == 'image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(att.localPath),
            width: 56, height: 56, fit: BoxFit.cover),
      );
    }
    final icon = att.type == 'video'
        ? Icons.play_circle_outline_rounded
        : _fileIconFor(att);
    return Container(
      width: att.type == 'file' ? 150 : 56,
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
      ),
      child: Row(
        mainAxisAlignment: att.type == 'file'
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Icon(icon, size: 28, color: cs.onSurfaceVariant),
          if (att.type == 'file') ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                att.fileName ?? _fileNameFromPath(att.localPath),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 从待发送列表移除某附件。
  void _removeAttachment(MediaAttachment att) {
    if (!mounted) return;
    final removed = _pendingAttachments
        .where((a) => a.id == att.id)
        .toList(growable: false);
    setState(() => _pendingAttachments.removeWhere((a) => a.id == att.id));
    for (final attachment in removed) {
      unawaited(_deletePendingAttachmentFile(attachment));
    }
  }

  Future<void> _deletePendingAttachmentFile(MediaAttachment attachment) async {
    final dataDir = _db.dataDirPath;
    if (dataDir == null) return;
    final mediaRoot =
        '${Directory(dataDir).absolute.path}${Platform.pathSeparator}media';
    final file = File(attachment.localPath).absolute;
    if (!file.path.startsWith('$mediaRoot${Platform.pathSeparator}')) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      debugPrint('[附件] 清理未发送文件失败：$e');
    }
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
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.primary)),
                Text(snippet,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          IconButton(
            icon:
                Icon(Icons.close_rounded, size: 16, color: cs.onSurfaceVariant),
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

IconData _fileIconFor(MediaAttachment att) {
  final ext = _extensionOfPath(att.fileName ?? att.localPath);
  return switch (ext) {
    'pdf' => Icons.picture_as_pdf_rounded,
    'zip' || 'rar' || '7z' => Icons.folder_zip_rounded,
    'doc' || 'docx' => Icons.description_rounded,
    'xls' || 'xlsx' || 'csv' => Icons.table_chart_rounded,
    'ppt' || 'pptx' => Icons.slideshow_rounded,
    'txt' ||
    'md' ||
    'json' ||
    'yaml' ||
    'yml' ||
    'dart' =>
      Icons.article_rounded,
    _ => Icons.insert_drive_file_rounded,
  };
}

String _fileNameFromPath(String path) {
  final segments = path.split(RegExp(r'[/\\]'));
  return segments.isEmpty ? path : segments.last;
}

String _extensionOfPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

/// 用户在 AI 回复期间发的消息，排队等当前回合结束后再触发 AI 回复。
class _PendingAgentToolApproval {
  final AICharacter character;
  final ApiConfig config;
  final ApiProvider provider;
  final String userRequest;
  final ToolRequest request;
  final List<ToolRequest> priorExecutedRequests;

  const _PendingAgentToolApproval({
    required this.character,
    required this.config,
    required this.provider,
    required this.userRequest,
    required this.request,
    this.priorExecutedRequests = const [],
  });
}

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
  final bool isHighlightedMention;
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
    this.isHighlightedMention = false,
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
                    sender!.avatar.isNotEmpty
                        ? sender!.avatar
                        : sender!.name[0],
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
                              child: SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5, color: cs.primary)),
                            ),
                        ],
                      ),
                    ),
                  if (message.replyToMessageId != null)
                    _buildQuotedRef(
                        cs, quotedMessage ?? message, quotedSenderName),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser
                          ? null
                          : isHighlightedMention
                              ? cs.primaryContainer.withOpacity(0.56)
                              : cs.surfaceContainer,
                      gradient: isUser ? AppTheme.primaryGradient : null,
                      border: isUser
                          ? null
                          : Border.all(
                              color: isHighlightedMention
                                  ? cs.primary.withOpacity(0.84)
                                  : cs.outlineVariant.withOpacity(0.6),
                              width: isHighlightedMention ? 1.6 : 1),
                      boxShadow: isHighlightedMention
                          ? [
                              BoxShadow(
                                color: cs.primary.withOpacity(0.18),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ]
                          : null,
                      borderRadius: BorderRadius.circular(18).copyWith(
                        bottomLeft: isUser
                            ? const Radius.circular(18)
                            : const Radius.circular(4),
                        bottomRight: isUser
                            ? const Radius.circular(4)
                            : const Radius.circular(18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildMediaContent(context, message, cs, isUser),
                        _buildContent(message, sender, isUser, cs),
                      ],
                    ),
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
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: cs.primary)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(snippet,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  /// 气泡内的媒体渲染：图片网格 + 视频播放器，纵向排在文案上方。
  Widget _buildMediaContent(
      BuildContext context, Message message, ColorScheme cs, bool isUser) {
    final media = message.media ?? [];
    if (media.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
        children: media.map((att) {
          if (att.type == 'image') {
            return _buildImageThumb(context, att, cs);
          }
          if (att.type == 'video') {
            return _VideoBubble(localPath: att.localPath, isUser: isUser);
          }
          return _buildFileAttachment(context, att, cs, isUser);
        }).toList(),
      ),
    );
  }

  /// 图片缩略图，点击进入全屏预览（InteractiveViewer 可缩放/拖拽）。
  Widget _buildImageThumb(
      BuildContext context, MediaAttachment att, ColorScheme cs) {
    return GestureDetector(
      onTap: () => _openImageFullscreen(context, att.localPath),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          File(att.localPath),
          width: 140,
          height: 140,
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  /// 全屏预览图片：黑色背景 + InteractiveViewer 支持双指缩放。
  void _openImageFullscreen(BuildContext context, String path) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(0),
        child: Stack(
          children: [
            InteractiveViewer(
              child: Image.file(File(path)),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: '关闭',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileAttachment(
    BuildContext context,
    MediaAttachment att,
    ColorScheme cs,
    bool isUser,
  ) {
    final textColor = isUser ? cs.onPrimary : cs.onSurface;
    final subtleColor =
        isUser ? cs.onPrimary.withOpacity(0.75) : cs.onSurfaceVariant;
    final borderColor =
        isUser ? cs.onPrimary.withOpacity(0.25) : cs.outlineVariant;
    final fillColor =
        isUser ? cs.onPrimary.withOpacity(0.08) : cs.surfaceContainerHighest;
    return InkWell(
      onTap: () => _openAttachment(context, att),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: fillColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          children: [
            Icon(_fileIconFor(att), size: 30, color: subtleColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    att.fileName ?? _fileNameFromPath(att.localPath),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _formatAttachmentSize(att.fileSize),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: subtleColor),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.open_in_new_rounded, size: 18, color: subtleColor),
          ],
        ),
      ),
    );
  }

  Future<void> _openAttachment(
      BuildContext context, MediaAttachment att) async {
    try {
      final result = await OpenFilex.open(att.localPath, type: att.mimeType);
      if (result.type.name != 'done' && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('打开失败：${result.message}'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('打开失败：$e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  IconData _fileIconFor(MediaAttachment att) {
    final ext = _extensionOfPath(att.fileName ?? att.localPath);
    return switch (ext) {
      'pdf' => Icons.picture_as_pdf_rounded,
      'zip' || 'rar' || '7z' => Icons.folder_zip_rounded,
      'doc' || 'docx' => Icons.description_rounded,
      'xls' || 'xlsx' || 'csv' => Icons.table_chart_rounded,
      'ppt' || 'pptx' => Icons.slideshow_rounded,
      'txt' ||
      'md' ||
      'json' ||
      'yaml' ||
      'yml' ||
      'dart' =>
        Icons.article_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
  }

  String _fileNameFromPath(String path) {
    final segments = path.split(RegExp(r'[/\\]'));
    return segments.isEmpty ? path : segments.last;
  }

  String _formatAttachmentSize(int? bytes) {
    if (bytes == null) return '文件';
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
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
          SelectableText(content,
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
      base = SelectableText(content,
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

/// 气泡内视频播放器：使用 chewie 渲染带控制条的播放器。
///
/// 负责 [VideoPlayerController] 与 [ChewieController] 的完整生命周期，
/// 在 [dispose] 中释放，避免资源泄漏。视频初始化完成后才展示控制条，
/// 初始化期间显示占位 loading。
class _VideoBubble extends StatefulWidget {
  final String localPath;
  final bool isUser;

  const _VideoBubble({required this.localPath, required this.isUser});

  @override
  State<_VideoBubble> createState() => _VideoBubbleState();
}

class _VideoBubbleState extends State<_VideoBubble> {
  late final VideoPlayerController _controller;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.localPath));
    _controller.initialize().then((_) {
      if (!mounted) return;
      // 初始化成功后再构造 ChewieController，保证 aspectRatio 可用。
      _chewieController = ChewieController(
        videoPlayerController: _controller,
        autoPlay: false,
        looping: false,
        aspectRatio: _controller.value.aspectRatio,
        placeholder: const Center(child: CircularProgressIndicator()),
      );
      setState(() {});
    }).catchError((e) {
      debugPrint('[视频] 初始化失败：$e');
    });
  }

  @override
  void dispose() {
    _chewieController?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ratio = _chewieController?.aspectRatio ?? 1.0;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
      child: AspectRatio(
        aspectRatio: ratio,
        child: _chewieController != null
            ? Chewie(controller: _chewieController!)
            : Container(
                color: Colors.black.withOpacity(0.08),
                child: const Center(child: CircularProgressIndicator()),
              ),
      ),
    );
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
