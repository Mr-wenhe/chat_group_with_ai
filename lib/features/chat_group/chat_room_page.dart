import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/agent_task_recovery_dialog.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/ai_character/ai_character_form_page.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/chat_group/chat_group_form_page.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/chat_room_loader.dart';
import 'package:chat_group/features/chat_group/chat_room_repository.dart';
import 'package:chat_group/features/chat_group/direct_read_receipt_policy.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';
import 'package:chat_group/features/chat_group/humanized_prompt_builder.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/chat_group/picked_attachment_payload.dart';
import 'package:chat_group/features/chat_group/scene_behavior.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:chat_group/features/chat_group/agentic_reply_utils.dart';
import 'package:chat_group/features/chat_group/attachment_utils.dart';
import 'package:chat_group/features/chat_group/models/chat_room_models.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_list.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_banners.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_app_bar.dart';
import 'package:chat_group/features/chat_group/widgets/member_sheet.dart';
import 'package:chat_group/features/chat_group/widgets/hint_chip.dart';
import 'package:chat_group/features/chat_group/widgets/sheet_button.dart';
import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/features/work_mode/work_mode_config_service.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_session.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:chat_group/services/message_speech_service.dart';
import 'package:chat_group/services/web_search_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:chat_group/services/wecom_push_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pasteboard/pasteboard.dart';

enum AutoChatStatus { idle, waiting, generating, paused, unavailable, error }

class ChatRoomPage extends ConsumerStatefulWidget {
  final String groupId;

  const ChatRoomPage({super.key, required this.groupId});

  @override
  ConsumerState<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends ConsumerState<ChatRoomPage>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocusNode = FocusNode();
  final _chatApi = ChatApiService();
  final _webSearch = WebSearchService();
  final _random = Random();
  late final MessageSpeechService _speech;
  late final DatabaseService _db;
  late final ReplyEligibilityPolicy _replyEligibility;
  late final ChatRoomRepository _repository;
  late final ChatRoomLoader _loader;

  ChatGroup? _group;
  List<AICharacter> _characters = []; // 活跃角色（用于 AI 回复等逻辑）
  List<AICharacter> _allGroupCharacters = []; // 全部群成员（含停用），供 @ 弹窗使用
  List<Message> _messages = [];
  GroupMemory? _groupMemory;
  List<CharacterMemory> _characterMemories = [];
  List<RelationshipState> _relationshipStates = [];
  final WorkModeSession<PendingAgentToolApproval> _workModeSession =
      WorkModeSession<PendingAgentToolApproval>();
  final Map<String, ReplyIntent> _pendingReplyIntents = {};
  int _autoChatMemoryTick = 0;

  bool get _workModeEnabled => _workModeSession.enabled;
  PendingAgentToolApproval? get _pendingAgentApproval =>
      _workModeSession.pendingApproval;
  set _pendingAgentApproval(PendingAgentToolApproval? value) =>
      _workModeSession.pendingApproval = value;

  bool _isLoading = true;
  bool _isAiReplying = false;
  int _consecutiveRound = 0;

  /// 用户发言后的普通群聊最多连续三轮，避免角色互相回复形成无限循环。
  static const int _maxAutoRounds = 3;

  // 用户消息队列：AI 回复期间用户发的消息排队在此，回合结束后自动触发回复。
  final List<PendingUserMessage> _pendingUserMessages = [];

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
  bool _isAutoChatRoundRunning = false;
  bool _discardCurrentStream = false;

  /// 一次空闲自动聊天 burst 的上限；达到后进入冷却，而不是持续灌水。
  static const int _maxAutoChatRounds = 4;
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

  // 并发兜底：记录当前正在执行 agentic 任务的角色 id，防止同一角色在同一轮内
  // 被重复触发（极端情况下的重入会产生重复消息 / 重复文件）。
  final Set<String> _agenticRunningCharacterIds = {};

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
  final ChatMessageListController _messageListController =
      ChatMessageListController();

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
    _loader = ChatRoomLoader(db: _db, resolveApiConfig: _resolveApiConfig);
    _replyEligibility = ReplyEligibilityPolicy(
      resolveApiConfig: _resolveApiConfig,
    );
    _repository = ChatRoomRepository(
      db: _db,
      conversationId: widget.groupId,
      isDirectChat: _isDirectChat,
    );
    _speech = MessageSpeechService(
      engine: FlutterTtsSpeechEngine(),
      onStateChanged: _handleSpeechState,
    );
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
    _workModeSession.requestStop('页面已关闭');
    unawaited(_streamSub?.cancel());
    _streamSub = null;
    if (_streamDone != null && !_streamDone!.isCompleted) {
      _streamDone!.complete();
    }
    _streamDone = null;
    _streamUiFlushTimer?.cancel();
    _searchDebounceTimer?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    _searchController.dispose();
    _autoChatTimer?.cancel();
    _mentionHighlightTimer?.cancel();
    _hideMentionOverlay();
    _mentionSearchController.dispose();
    unawaited(_speech.dispose());
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
    try {
      final loaded = await _loader.load(widget.groupId);
      if (!_canTouchUi) return;

      setState(() {
        _group = loaded.displayGroup;
        _characters = loaded.activeCharacters;
        _allGroupCharacters = loaded.allCharacters;
        _messages = loaded.messages;
        _groupMemory = loaded.groupMemory;
        _characterMemories = loaded.characterMemories;
        _relationshipStates = loaded.relationships;
        _workModeSession.setEnabled(
          WorkModeConfigService(db: _db).isWorkMode(widget.groupId),
        );
        _hasAnyApiConfig = loaded.hasAnyApiConfig;
        _isAutoChatEnabled = true;
        _autoChatStatus = loaded.hasAnyApiConfig
            ? AutoChatStatus.waiting
            : AutoChatStatus.unavailable;
        _lastReplyBlockReason = loaded.isDirectChat &&
                loaded.allCharacters.isNotEmpty &&
                !loaded.hasAnyApiConfig
            ? _blockReasonFor(loaded.allCharacters.first)
            : null;
        _isLoading = false;
      });

      _scrollToBottom();
      _scheduleAgentTaskRecovery();
      if (ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: _workModeEnabled,
        autoChatEnabled: _isAutoChatEnabled,
        hasCharacters: loaded.activeCharacters.isNotEmpty,
        hasApiConfig: loaded.hasAnyApiConfig,
      )) {
        final delay = loaded.isDirectChat
            ? const Duration(seconds: 18)
            : _autoChatInitialDelay;
        Future.delayed(delay, () {
          if (_canTouchUi && !_workModeEnabled) _startAutoChat();
        });
      }
    } on ChatRoomLoadException catch (error) {
      if (!mounted || _disposed) return;
      AppToast.show(context, error.message, icon: Icons.error_outline_rounded);
      Navigator.pop(context);
    }
  }

  void _scheduleAgentTaskRecovery() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canTouchUi) unawaited(_offerAgentTaskRecovery());
    });
  }

  Future<void> _offerAgentTaskRecovery() async {
    if (!_workModeEnabled) return;
    final tasks = _db.agentTaskBox.values
        .where((task) =>
            task.groupId == widget.groupId && task.canResumeInWorkMode)
        .toList()
      ..sort((a, b) =>
          (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt));
    if (tasks.isEmpty || !_canTouchUi) return;
    final task = tasks.first;
    final continueTask = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AgentTaskRecoveryDialog(
        task: task,
        onAbandon: () => Navigator.pop(dialogContext, false),
        onContinue: () => Navigator.pop(dialogContext, true),
      ),
    );
    if (continueTask == true) {
      await _resumeAgentTask(task);
    } else {
      await _cancelAgentTask(task, reason: '用户放弃恢复任务。');
    }
  }

  Future<void> _resumeAgentTask(AgentTask task) async {
    if (!_workModeEnabled || !task.workModeTask) return;
    final character = _db.aiCharacterBox.get(task.characterId);
    if (character == null) return;
    final config = _resolveApiConfig(character);
    if (config == null) return;
    final provider = ApiProvider.values.firstWhere(
      (value) => value.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending != null) {
      final approval = PendingAgentToolApproval(
        character: character,
        config: config,
        provider: provider,
        userRequest: task.userRequest,
        request: pending,
        priorExecutedRequests: _restoredExecutedRequests(task),
        task: task,
      );
      await _presentPendingAgentApproval(approval);
      return;
    }
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    try {
      await _generateAgenticReply(
        character: character,
        config: config,
        provider: provider,
        userMessage: task.userRequest,
        context: _recentMessagesForContext(),
        resumeTask: task,
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
    } finally {
      _workModeSession.finishRun(workModeRun);
    }
  }

  List<ToolRequest> _restoredExecutedRequests(AgentTask task) {
    return task.completedOperations
        .map(ToolRequest.fromJsonString)
        .whereType<ToolRequest>()
        .toList();
  }

  void _startAutoChat() {
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
    )) {
      return;
    }
    if (!_canTouchUi) return;
    _autoChatTimer?.cancel();
    setState(() => _autoChatStatus = AutoChatStatus.waiting);
    _autoChatTimer = Timer.periodic(
      Duration(
        seconds: _autoChatBaseIntervalSeconds +
            _autoChatRandom.nextInt(_autoChatIntervalJitterSeconds),
      ),
      (_) => _tryAutoChatRound(),
    );
  }

  int get _autoChatBaseIntervalSeconds {
    if (_isDirectChat) return 45;
    final configured =
        _group?.replyIntervalSeconds ?? _autoChatMinIntervalSeconds;
    return configured.clamp(5, 60);
  }

  void _stopAutoChat() {
    _autoChatTimer?.cancel();
    _autoChatTimer = null;
    _autoChatRoundCount = 0;
    if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
  }

  Future<void> _tryAutoChatRound() async {
    if (!ChatActivityPolicy.canStartAutoChat(
      workModeEnabled: _workModeEnabled,
      autoChatEnabled: _isAutoChatEnabled,
      hasCharacters: _characters.isNotEmpty,
      hasApiConfig: _hasAnyApiConfig,
    )) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (!_canTouchUi) return;
    if (_isAiReplying ||
        _isStreaming ||
        _textController.text.trim().isNotEmpty) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (_isDirectChat && _directAiMessagesSinceLastUser() >= 3) {
      if (_canTouchUi) setState(() => _autoChatStatus = AutoChatStatus.paused);
      return;
    }
    if (_autoChatRoundCount >= _maxAutoChatRounds) {
      _stopAutoChat();
      Future.delayed(_autoChatBurstPause, () {
        if (_canTouchUi && _isAutoChatEnabled && !_workModeEnabled) {
          _startAutoChat();
        }
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
    var speakers = _charactersForIntents(autoIntents)
        .where((c) => !_agenticRunningCharacterIds.contains(c.id))
        .toList();
    final lastAiSenderId = _lastAiSenderId;
    final speakersToUse = speakers.length <= 1
        ? speakers
        : speakers.where((c) => c.id != lastAiSenderId).toList();
    _pendingReplyIntents
      ..clear()
      ..addEntries(
          autoIntents.map((intent) => MapEntry(intent.speakerId, intent)));

    if (speakersToUse.isEmpty) {
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
      _isAutoChatRoundRunning = true;
      _autoChatRoundCount++;
      _autoChatStatus = AutoChatStatus.generating;
    });

    try {
      for (final speaker in speakersToUse) {
        if (!_isAutoChatEnabled || _workModeEnabled) break;
        if (!_isEligibleToReply(speaker)) continue;
        final replyContent = await _generateAiReply(
          speaker,
          _messages.toList(),
          null,
          isAutoChat: true,
          intent: _pendingReplyIntents[speaker.id],
        );
        if (_workModeEnabled) break;
        await _delay(replyContent);
      }

      if (!_workModeEnabled) {
        _autoChatMemoryTick++;
        if (_autoChatMemoryTick >= 3) {
          _autoChatMemoryTick = 0;
          await _maybeUpdateMemory();
        }
      }
    } finally {
      if (_canTouchUi) {
        setState(() {
          _isAiReplying = false;
          _isAutoChatRoundRunning = false;
          _autoChatStatus = _isAutoChatEnabled && !_workModeEnabled
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
    return ChatRoomLoader.readThrough(
      messages.map((message) => message.timestamp),
    );
  }

  Future<void> _markCurrentConversationRead({Message? throughMessage}) async {
    await _repository.markRead(
      throughMessage == null
          ? _readThrough(_messages)
          : _readThrough([throughMessage]),
    );
    _clearActiveUserMentionBanner();
  }

  Future<void> _sendMessage() async {
    _hideMentionOverlay();
    final text = _textController.text.trim();
    final hasAttachments = _pendingAttachments.isNotEmpty;
    // 放宽发送条件：文案非空 或 有附件均可发送。
    if (text.isEmpty && !hasAttachments) return;

    _textController.clear();
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
      await _repository.markRead(_readThrough(_messages));
    }
    _cancelQuote();

    // 发送后清空待发送附件。
    if (hasAttachments && mounted) {
      setState(() => _pendingAttachments.clear());
    }

    _autoChatRoundCount = 0;

    if (_characters.isEmpty) {
      if (mounted) {
        AppToast.show(context, _isDirectChat ? '该角色当前不可回复' : '该群聊没有活跃的角色',
            icon: Icons.info_outline_rounded);
      }
      return;
    }

    if (_isAiReplying) {
      // AI 正在回复中，排队等待当前回合结束后再处理。
      _pendingUserMessages.add(PendingUserMessage(
        text,
        mentionedIds,
        message: userMessage,
      ));
      return;
    }

    await _dispatchUserRequest(
      text: text,
      mentionedIds: mentionedIds,
      userMessage: userMessage,
    );
  }

  Future<void> _dispatchUserRequest({
    required String text,
    required List<String> mentionedIds,
    Message? userMessage,
  }) async {
    if (_workModeEnabled) {
      await _runWorkModeTask(
        text: text,
        mentionedIds: mentionedIds,
        userMessage: userMessage,
      );
      return;
    }
    await _runAiRound(
      userMessage: text,
      mentionedIds: mentionedIds,
      currentUserMessage: userMessage,
    );
  }

  Future<void> _runWorkModeTask({
    required String text,
    required List<String> mentionedIds,
    Message? userMessage,
  }) async {
    final executor = WorkModePolicy.selectExecutor(
      characters: _characters,
      mentionedIds: mentionedIds,
    );
    if (executor == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: 'system',
        senderType: 'ai',
        content: '工作模式需要至少一个已启用 Agentic 的活跃角色。',
      ));
      return;
    }
    if (!WorkModePolicy.shouldRun(
      enabled: _workModeEnabled,
      character: executor,
      userRequest: text,
    )) {
      return;
    }
    final config = _resolveApiConfig(executor);
    if (config == null) {
      await _appendMessage(Message(
        groupId: widget.groupId,
        senderId: executor.id,
        senderType: 'ai',
        content: '[${executor.name} 未配置 API，无法执行工作任务]',
      ));
      return;
    }
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    if (_canTouchUi) setState(() => _isAiReplying = true);
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    try {
      final workspace = await WorkModeWorkspaceService(db: _db).loadOrCreate(
        conversationId: widget.groupId,
        isDirectChat: _isDirectChat,
      );
      await LocalAgentBridgeLauncher().registerWorkspace(
        conversationId: widget.groupId,
        workspacePath: workspace.workDirPath,
      );
      await _generateAgenticReply(
        character: executor,
        config: config,
        provider: provider,
        userMessage: text,
        media: userMessage?.media,
        context: _recentMessagesForContext(),
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
    } finally {
      _workModeSession.finishRun(workModeRun);
      if (_canTouchUi) setState(() => _isAiReplying = false);
      if (_pendingUserMessages.isNotEmpty && _canTouchUi) {
        final next = _pendingUserMessages.removeAt(0);
        await _dispatchUserRequest(
          text: next.text,
          mentionedIds: next.mentionedIds,
          userMessage: next.message,
        );
      }
    }
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
        AppToast.show(
          context,
          _replyBlockText(blockReason),
          icon: Icons.info_outline_rounded,
          actionLabel:
              blockReason == ReplyBlockReason.noApiConfig ? '去设置' : null,
          onTap: blockReason == ReplyBlockReason.noApiConfig
              ? () => Navigator.pushNamed(context, '/settings')
              : null,
        );
      }
      return;
    }

    final repliedIds = <String>[];
    for (final character in charactersToReply) {
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
      await _delay(
        replyContent,
        fast: mentionedIds?.contains(character.id) ?? false,
      );
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
        // 仅在 proxyId 真实对应一个角色时才播报提醒；兜底分支（proxyId 不属于
        // 任何已知角色）不伪造 @，也避免把脏 id 留在集合里导致后续轮次重复播报。
        final matched = _characters.where((c) => c.id == proxyId).toList();
        if (matched.isNotEmpty && _isEligibleToReply(matched.first)) {
          final proxyChar = matched.first;
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
        // 无论是否真正播报，都从待提醒集合中移除该 id，防止跨轮膨胀 / 重复刷屏。
        _pendingMentionedIds.remove(proxyId);
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
      await _dispatchUserRequest(
        text: next.text,
        mentionedIds: next.mentionedIds,
        userMessage: next.message,
      );
    }
  }

  Future<String> _generateAiReply(
      AICharacter character, List<Message> context, String? userMessage,
      {bool isAutoChat = false,
      ReplyIntent? intent,
      Message? currentUserMessage}) async {
    if (isAutoChat && _workModeEnabled) return '';
    // 并发兜底：同一角色正在执行 agentic 任务时，auto-chat / 其他并发路径
    // 不得触发同一角色的普通 LLM 回复，否则会出现「agentic 兜底文案 + 普通
    // LLM 泄漏代码」两条消息的 Bug（auto-chat 传 userMessage=null 会绕过 agentic
    // 分支直接走流式路径，而 _agenticRunningCharacterIds 此前仅在 _generateAgenticReply
    // 入口检查，覆盖不到这里）。
    if (_agenticRunningCharacterIds.contains(character.id)) {
      return '';
    }

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
    final effectiveContext = await _compactContextIfNeeded(
      character: character,
      config: config,
      provider: provider,
      fallbackContext: context,
    );

    final webSearch = await _webSearch.searchIfNeeded(userMessage);
    final apiMessages = _withWebSearchContext(
      _buildApiMessages(
        character,
        effectiveContext,
        userMessage,
        isAutoChat: isAutoChat,
        intent: intent,
        supportsVision: provider.supportsVision,
        currentUserMessage: currentUserMessage,
      ),
      webSearch,
    );
    if (isAutoChat && _workModeEnabled) {
      _discardCurrentStream = false;
      return '';
    }
    debugPrint(
      '[AI Reply] character=${character.id} messages=${apiMessages.length} '
      'provider=${provider.name}',
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
    if (_disposed) return '';

    if (_discardCurrentStream) {
      _discardCurrentStream = false;
      _streamSub = null;
      _streamDone = null;
      if (_canTouchUi) {
        setState(() {
          _isStreaming = false;
          _streamingMessage = null;
          _messages = List<Message>.from(_messages)
            ..removeWhere((message) => message.id == temp.id);
        });
      }
      return '';
    }

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

    if (failed) {
      final retryContent = await _retryFailedReply(
        character: character,
        config: config,
        provider: provider,
        apiMessages: apiMessages,
      );
      if (retryContent != null && retryContent.trim().isNotEmpty) {
        failed = false;
        fullContent = retryContent.trim();
        temp.content = fullContent;
        if (_canTouchUi) _flushStreamingUi();
      }
    }

    // 解析 @ 提及 → mentionedAiIds（未知名称忽略，避免误指向第一个成员）。
    final mentionedIds = _isDirectChat
        ? const <String>[]
        : parseMentionedCharacterIds(fullContent, _characters);

    // 移除 LLM 可能附带的名字前缀（UI 已独立显示角色名）。
    fullContent = _stripNamePrefix(fullContent, character.name);
    // 防御：非 agentic 路径下 LLM 可能自发输出 tool_call 协议标签文本
    // （尤其使用过 agentic 能力的角色，system prompt 里可能残留工具说明）。
    // 在落库与返回前清洗之，避免协议泄漏被当作普通聊天贴出来。
    fullContent = sanitizeNonAgenticReply(fullContent);
    if (!failed &&
        isDuplicateAiReply(
          fullContent,
          _messages,
          excludeMessageId: temp.id,
        )) {
      debugPrint('[AI Reply] suppressed duplicate from ${character.name}');
      _recordReplyUsage(character);
      if (promptTokens != null && completionTokens != null) {
        await _repository.recordTokenUsage(
          characterId: character.id,
          inputTokens: promptTokens!,
          outputTokens: completionTokens!,
          cachedTokens: cachedTokens ?? 0,
        );
      }
      if (_canTouchUi) {
        setState(() {
          _messages = List.from(_messages)
            ..removeWhere((message) => message.id == temp.id);
          _streamingMessage = null;
        });
      }
      return '';
    }
    // 持久化纪律：仅完成时 put 一次（包含失败占位消息）。
    temp.content = fullContent;
    temp.isMention = mentionedIds.isNotEmpty;
    temp.mentionedAiIds = mentionedIds;
    temp.media = null;
    await _repository.persistNewMessage(temp);
    await _markCurrentConversationRead(throughMessage: temp);
    _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    if (promptTokens != null && completionTokens != null) {
      _repository.recordTokenUsage(
        characterId: character.id,
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

  Future<String?> _retryFailedReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Map<String, dynamic>> apiMessages,
  }) async {
    final result = await _chatApi.sendChatMessageStreamed(
      apiKey: config.apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: apiMessages,
      temperature: 0.75,
    );
    await _recordTokenUsageFromResult(character, result);
    if (result['success'] == true) {
      final content = result['message']?.toString().trim() ?? '';
      if (content.isNotEmpty) return content;
    }
    return null;
  }

  List<Map<String, dynamic>> _withWebSearchContext(
    List<Map<String, dynamic>> messages,
    WebSearchSnapshot? snapshot,
  ) {
    if (snapshot == null) return messages;
    final next = List<Map<String, dynamic>>.from(messages);
    final insertAt = next.indexWhere((message) => message['role'] != 'system');
    final contextMessage = {
      'role': 'system',
      'content': snapshot.toPromptContext(),
    };
    if (insertAt <= 0) {
      next.insert(0, contextMessage);
    } else {
      next.insert(insertAt, contextMessage);
    }
    return next;
  }

  Future<String> _generateAgenticReply({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required String userMessage,
    List<MediaAttachment>? media,
    List<Message>? context,
    AgentTask? resumeTask,
    bool workMode = false,
    CancelToken? cancelToken,
    WorkModeRunHandle? workModeRun,
  }) async {
    // 并发兜底：同一角色已在执行 agentic 任务时，跳过本次重复调用，
    // 避免重入导致重复文件生成 / 重复消息。该角色的本轮任务由首次调用负责。
    if (_agenticRunningCharacterIds.contains(character.id)) {
      return '';
    }
    _agenticRunningCharacterIds.add(character.id);
    try {
      final task = resumeTask ??
          AgentTask(
            groupId: widget.groupId,
            characterId: character.id,
            userRequest: userMessage,
            requestedPermissions: character.toolPermissions,
            workModeTask: workMode,
          );
      task
        ..status = AgentTaskStatus.planning
        ..updatedAt = DateTime.now();
      await _db.agentTaskBox.put(task.id, task);
      await _upsertAgentProgressMessage(
        task,
        agentProgressMessageContent(characterName: character.name),
      );
      final runtime = _agentRuntimeFor(
        character: character,
        config: config,
        provider: provider,
        task: task,
        workMode: workMode,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );

      final mediaEnhancedRequest =
          await AgentAttachmentContext.enhanceCurrentRequest(
        userRequest: userMessage,
        media: media,
      );
      final conversationHistory = await _agenticHistory(
        userMessage,
        messages: context,
      );
      final restoredRequests = resumeTask == null
          ? const <ToolRequest>[]
          : _restoredExecutedRequests(resumeTask);
      if (restoredRequests.isNotEmpty) {
        conversationHistory.insert(0, {
          'role': 'system',
          'content': '这是从检查点恢复的任务。以下工具操作已经完成，'
              '不要重复执行：${restoredRequests.map((request) => request.toJsonString()).join('；')}',
        });
      }
      final skillResolution =
          CharacterSkillResolver.resolveFor(character, userMessage);

      final result = await runtime.run(
        character: character,
        skills: _agenticSkillsFor(
          character,
          userMessage,
          resolution: skillResolution,
        ),
        userRequest: mediaEnhancedRequest,
        conversationHistory: conversationHistory,
        priorExecutedRequests: restoredRequests,
        forceSkillCreation: skillResolution.needsSkillCreation &&
            !_savedSkillMatchesRequest(character, userMessage),
        workModeContext:
            workMode ? WorkModePolicy.planningContext(character) : '',
      );
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        final approval = PendingAgentToolApproval(
          character: character,
          config: config,
          provider: provider,
          userRequest: mediaEnhancedRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
          conversationHistory: conversationHistory,
          task: task,
        );
        await _presentPendingAgentApproval(approval);
        return result.message;
      }
      await _finishAgentTask(task, result);
      if (result.status != AgentRuntimeStatus.completed) {
        final rawContent = result.executedToolRequests.isEmpty
            ? result.message
            : _partialCompletionReport(result);
        final content = _stripNamePrefix(rawContent, character.name);
        final message = Message(
          groupId: widget.groupId,
          senderId: character.id,
          senderType: 'ai',
          content: content,
        );
        await _appendMessage(message);
        if (result.executedToolRequests.isNotEmpty) {
          _scheduleAgentTaskRecovery();
        }
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
    } finally {
      _agenticRunningCharacterIds.remove(character.id);
    }
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
    final requestedPaths = <String>[];
    void addPath(String raw) {
      final path = WorkspacePathGuard.normalizeToRelative(raw);
      if (!WorkspacePathGuard.isSafeRelativePath(path)) return;
      if (!requestedPaths.contains(path)) requestedPaths.add(path);
    }

    for (final request in patchRequests) {
      final directPath = request.args['path'];
      if (directPath is String) {
        addPath(directPath);
      }
      for (final path in _pathsFromPatch(
        request.args['patch'] as String? ?? '',
      )) {
        addPath(path);
      }
    }
    final resultOk =
        result.toolResult?['ok'] == true || result.toolResult?['exitCode'] == 0;
    final normalizedResultPath = result.toolResult?['path'] is String
        ? WorkspacePathGuard.normalizeToRelative(
            result.toolResult!['path'] as String,
          )
        : null;
    final paths = resolveAgentArtifactPaths(
      requestedPaths: requestedPaths,
      actualResultPath: normalizedResultPath,
      resultSucceeded: resultOk,
    ).where(WorkspacePathGuard.isSafeRelativePath).toList();
    if (paths.isEmpty) return const [];

    final attachments = <MediaAttachment>[];
    final bridge = LocalAgentBridgeClient();
    final workspaceTool = WorkspaceFileTool(
      bridge,
      conversationId: widget.groupId,
    );
    final lastPatchWithContent = patchRequests.reversed.firstWhere(
      (request) => request.args['content'] is String,
      orElse: () => patchRequests.last,
    );
    for (final path in paths.take(6)) {
      try {
        final readback = resultOk && path == normalizedResultPath
            ? result.toolResult!['readbackContent']
            : null;
        if (readback is String && readback.isNotEmpty) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(readback),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }
        final generatedContent = resultOk &&
                (path == normalizedResultPath || normalizedResultPath == null)
            ? lastPatchWithContent.args['content']
            : null;
        if (generatedContent is String && generatedContent.isNotEmpty) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(generatedContent),
            fileName: fileNameFromPath(path),
            characterId: character.id,
            characterName: character.name,
            type: _attachmentTypeForPath(path),
          ));
          continue;
        }
        // Always read through the active bridge. Resolving [path] against the
        // app process cwd can attach a same-named file from the old workspace
        // immediately after the user switches project directories.
        final read = await workspaceTool.read(path);
        final content = read['content'];
        if (content is String) {
          attachments.add(await _db.writeBytesToAiCharacterDir(
            bytes: utf8.encode(content),
            fileName: fileNameFromPath(path),
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
    required AgentTask task,
    bool workMode = false,
    CancelToken? cancelToken,
    WorkModeRunHandle? workModeRun,
  }) {
    final bridge = LocalAgentBridgeClient();
    return AgentRuntime(
      complete: (messages) => _chatApi.sendChatMessageStreamed(
        apiKey: config.apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: messages,
        maxTokens: 8192,
        receiveTimeout: AgentRuntime.completionTimeout,
        cancelToken: cancelToken,
      ),
      workspaceFileTool: WorkspaceFileTool(
        bridge,
        conversationId: widget.groupId,
      ),
      browserContextTool: BrowserContextTool(bridge),
      skillCreateHandler: (args) => _saveGeneratedSkillFromArgs(
        character: character,
        args: args,
      ),
      skillDownloadHandler: (args) => _downloadExpertSkillFromArgs(
        character: character,
        args: args,
      ),
      // 关闭本地快速规划器：它原本会绕过 LLM 直接写死一个空壳模板，
      // 导致用户“生成个人主页”却只得到 <p>内容由AI生成</p>。关闭后由 LLM
      // 通过 planning prompt 生成真实文件内容（args.content 放完整内容）。
      enableLocalFilePlanner: false,
      // ChatApiService 负责带降温和非流式降级的重试；Runtime 不再嵌套。
      completionMaxRetries: 0,
      onProgress: (progress) => _persistAgentProgress(task, progress),
      contextWindowManager: ContextWindowManager(
        maxRetries: 0,
        complete: (contextMessages) => _chatApi.sendChatMessage(
          apiKey: config.apiKey,
          provider: provider,
          customBaseUrl: config.customBaseUrl,
          model: config.modelName,
          messages: contextMessages,
          temperature: 0.3,
          maxTokens: 2048,
          cancelToken: cancelToken,
        ),
      ),
      contextIsDirectChat: _isDirectChat,
      onContextSummary: _persistAgentContextSummary,
      approvalPolicy: workMode
          ? WorkModePolicy.requiresApproval
          : AgentRuntime.requiresApproval,
      grantedPermissions: workMode ? ToolPermission.values.toSet() : null,
      // per-run 停止状态：捕获本 run 的句柄，而非共享标志。新 run 的 beginRun
      // 不会把旧 run 复活，旧 run 在自己的检查点读到的是自己的停止状态。
      shouldCancel: workMode ? () => workModeRun?.isRequestedStop ?? false : null,
    );
  }

  Future<void> _persistAgentContextSummary(
    AICharacter character,
    ContextSummary summary,
  ) async {
    final memory = HumanizedMemoryService.memoryForCharacter(
      groupId: widget.groupId,
      character: character,
      existing: _characterMemories,
    );
    final manager = ContextWindowManager(
      complete: (_) async => const {'success': true, 'message': '{}'},
    );
    await manager.persistToCharacterMemory(
      character: character,
      memory: memory,
      summary: summary,
      saveCharacter: (value) => _db.aiCharacterBox.put(value.id, value),
      saveMemory: _saveCompactedCharacterMemory,
    );
  }

  /// 记录每个任务最后一次上报的进度，供 [_finishAgentTask] 生成终态 ✅ 摘要。
  /// 仅运行时态，不写入 Hive。
  final Map<String, AgentRuntimeProgress> _lastAgentProgress = {};

  /// P2：内存 Map，key=task.id，value=runStartedAtMs（进度总耗时起点）；
  /// 非持久化，不写入 Hive。供进度气泡实时耗时展示查表。
  final Map<String, int> _progressStartTimes = {};

  Future<void> _persistAgentProgress(
    AgentTask task,
    AgentRuntimeProgress progress,
  ) async {
    _lastAgentProgress[task.id] = progress;
    // P2：仅首个非空值写入，天然幂等（后续 progress.runStartedAtMs 一致，不漂移）。
    // 若上报未携带 runStartedAtMs，则回退到当前时刻，保证耗时可展示。
    _progressStartTimes[task.id] ??=
        progress.runStartedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    task.markProgress(
      step: progress.executedRequests.length,
      operations: progress.executedRequests
          .map((request) => request.toJsonString())
          .toList(),
      pendingToolJson: progress.pendingRequest?.toJsonString() ?? '',
    );
    await _db.agentTaskBox.put(task.id, task);
    final character = _db.aiCharacterBox.get(task.characterId);
    await _upsertAgentProgressMessage(
      task,
      agentProgressMessageContent(
        characterName: character?.name ?? 'AI',
        progress: progress,
      ),
    );
  }

  Future<void> _upsertAgentProgressMessage(
    AgentTask task,
    String content,
  ) async {
    final id = WorkModeTaskLifecycle.progressMessageId(task);
    final existing = _db.messageBox.get(id);
    if (existing != null) {
      existing.content = content;
      await _repository.updateMessage(existing);
      return;
    }
    await _appendMessage(Message(
      id: id,
      groupId: task.groupId,
      senderId: task.characterId,
      senderType: 'ai',
      content: content,
    ));
  }

  Future<void> _finishAgentTask(
    AgentTask task,
    AgentRuntimeResult result,
  ) async {
    task
      ..resultSummary = result.message
      ..updatedAt = DateTime.now()
      ..pendingToolRequestJson =
          result.pendingToolRequest?.toJsonString() ?? '';
    if (result.status == AgentRuntimeStatus.completed) {
      task
        ..status = AgentTaskStatus.completed
        ..lastError = '';
    } else if (result.executedToolRequests.isNotEmpty) {
      task.markPartiallyCompleted(result.message);
    } else {
      task
        ..status = AgentTaskStatus.failed
        ..lastError = result.message;
    }
    await _db.agentTaskBox.put(task.id, task);
    // 终态气泡处理：
    // - 工作模式：仅 cancelled 删除；completed/failed/partiallyCompleted 保留，
    //   并刷新为终态 ✅ 摘要（末行 ⏳→✅、去光标）。
    // - 非工作模式：沿用旧行为，终态即删除，避免普通回复路径出现残留气泡。
    final removeProgress = task.workModeTask
        ? WorkModeTaskLifecycle.shouldRemoveProgress(task.status)
        : task.isTerminal;
    if (removeProgress) {
      await _removeAgentProgressMessage(task);
    } else {
      final lastProgress = _lastAgentProgress[task.id];
      final character = _db.aiCharacterBox.get(task.characterId);
      // 终态冻结耗时：基于 _progressStartTimes 记录的运行起点计算秒数，
      // 烘焙进终态摘要首行（⏱ Ns），即使随后清理 map 也不丢失耗时展示。
      final startMs = _progressStartTimes[task.id];
      final elapsed = startMs == null
          ? null
          : ((DateTime.now().millisecondsSinceEpoch - startMs) / 1000).round();
      await _upsertAgentProgressMessage(
        task,
        agentProgressMessageContent(
          characterName: character?.name ?? 'AI',
          progress: lastProgress,
          finalResult: true,
          elapsedSeconds: elapsed,
        ),
      );
    }
    // 终态清理：移除内存表里的进度与耗时起点，避免随任务数无界增长。
    // 终态内容已烘焙耗时，气泡不再依赖该表 live 计算，清理后展示不受影响。
    _lastAgentProgress.remove(task.id);
    _progressStartTimes.remove(task.id);
  }

  Future<void> _removeAgentProgressMessage(AgentTask task) async {
    final id = WorkModeTaskLifecycle.progressMessageId(task);
    await _repository.deleteMessage(id);
    if (_canTouchUi) {
      setState(() {
        _messages = List<Message>.from(_messages)
          ..removeWhere((message) => message.id == id);
      });
    }
  }

  Future<void> _cancelAgentTask(
    AgentTask task, {
    required String reason,
  }) async {
    WorkModeTaskLifecycle.cancelTask(task, reason: reason);
    await _db.agentTaskBox.put(task.id, task);
    await _removeAgentProgressMessage(task);
    // 终态清理：cancelled 气泡已删，无需展示耗时，移除内存表条目避免无界增长。
    _lastAgentProgress.remove(task.id);
    _progressStartTimes.remove(task.id);
  }

  String _partialCompletionReport(AgentRuntimeResult result) {
    final operations = result.executedToolRequests.map((request) {
      final path = request.args['path']?.toString();
      return path == null || path.isEmpty
          ? request.tool.wireName
          : '${request.tool.wireName}：$path';
    }).join('；');
    return '任务部分完成，已完成的工具操作和文件均已保留。\n'
        '已完成：$operations\n'
        '中断原因：${result.message}\n'
        '你可以选择“继续执行”从检查点恢复，或“放弃”结束任务。';
  }

  Future<bool> _handlePendingAgentApproval(String text) async {
    final pending = _pendingAgentApproval;
    if (pending == null) return false;
    final action = WorkModeTaskLifecycle.actionForInput(text);
    if (action == WorkModeApprovalAction.reject) {
      _pendingAgentApproval = null;
      final workModeRun = _workModeSession.beginRun();
      final cancelToken = workModeRun.token;
      if (_canTouchUi) setState(() => _isAiReplying = true);
      try {
        final runtime = _agentRuntimeFor(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          task: pending.task,
          workMode: true,
          cancelToken: cancelToken,
          workModeRun: workModeRun,
        );
        final result = await runtime.skipRejectedTool(
          character: pending.character,
          request: pending.request,
          userRequest: pending.userRequest,
          priorExecutedRequests: pending.priorExecutedRequests,
          conversationHistory: pending.conversationHistory,
        );
        if (result.status == AgentRuntimeStatus.waitingForApproval &&
            result.pendingToolRequest != null) {
          final nextApproval = PendingAgentToolApproval(
            character: pending.character,
            config: pending.config,
            provider: pending.provider,
            userRequest: pending.userRequest,
            request: result.pendingToolRequest!,
            priorExecutedRequests: result.executedToolRequests,
            conversationHistory: pending.conversationHistory,
            task: pending.task,
          );
          return _presentPendingAgentApproval(nextApproval);
        }
        await _finishAgentTask(pending.task, result);
        final content =
            _stripNamePrefix(result.message, pending.character.name);
        final attachments = await _attachmentsForAgentToolResult(
          character: pending.character,
          result: result,
        );
        await _appendMessage(Message(
          groupId: widget.groupId,
          senderId: pending.character.id,
          senderType: 'ai',
          content: content,
          media: attachments.isEmpty ? null : attachments,
        ));
        return true;
      } finally {
        _workModeSession.finishRun(workModeRun);
        if (_canTouchUi) setState(() => _isAiReplying = false);
      }
    }
    if (action == WorkModeApprovalAction.cancelPending) {
      _pendingAgentApproval = null;
      await _cancelAgentTask(
        pending.task,
        reason: '用户发送了新的工作指令，旧审批任务已取消。',
      );
      return false;
    }

    _pendingAgentApproval = null;
    final workModeRun = _workModeSession.beginRun();
    final cancelToken = workModeRun.token;
    if (_canTouchUi) setState(() => _isAiReplying = true);
    try {
      final runtime = _agentRuntimeFor(
        character: pending.character,
        config: pending.config,
        provider: pending.provider,
        task: pending.task,
        workMode: true,
        cancelToken: cancelToken,
        workModeRun: workModeRun,
      );
      final result = await runtime.executeApprovedTool(
        character: pending.character,
        request: pending.request,
        userRequest: pending.userRequest,
        priorExecutedRequests: pending.priorExecutedRequests,
        conversationHistory: pending.conversationHistory,
      );
      if (result.status == AgentRuntimeStatus.waitingForApproval &&
          result.pendingToolRequest != null) {
        final nextApproval = PendingAgentToolApproval(
          character: pending.character,
          config: pending.config,
          provider: pending.provider,
          userRequest: pending.userRequest,
          request: result.pendingToolRequest!,
          priorExecutedRequests: result.executedToolRequests,
          conversationHistory: pending.conversationHistory,
          task: pending.task,
        );
        return _presentPendingAgentApproval(nextApproval);
      }
      await _finishAgentTask(pending.task, result);
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
      _workModeSession.finishRun(workModeRun);
      if (_canTouchUi) setState(() => _isAiReplying = false);
    }
  }

  Future<bool> _presentPendingAgentApproval(
    PendingAgentToolApproval approval,
  ) async {
    _pendingAgentApproval = approval;
    final decision = await _showAgentApprovalDialog(
      approval.request,
      approval.character,
    );
    final action = WorkModeTaskLifecycle.actionForDialogDecision(decision);
    if (action == WorkModeApprovalAction.cancelPending) {
      if (identical(_pendingAgentApproval, approval)) {
        _pendingAgentApproval = null;
      }
      await _cancelAgentTask(
        approval.task,
        reason: '用户关闭了工具审批对话框，任务已取消。',
      );
      return true;
    }
    return _handlePendingAgentApproval(
      action == WorkModeApprovalAction.approve ? '批准' : '拒绝',
    );
  }

  /// 以弹层（AlertDialog）形式请求用户批准/拒绝工具调用，替代原来的“打字批准”。
  ///
  /// 返回 `true`=批准，`false`=拒绝，`null`=返回键关闭或无法弹层。
  /// 所有入口都由 [_presentPendingAgentApproval] 将 null 统一转为任务取消，
  /// 避免多步审批遗留 waitingForApproval 检查点。
  Future<bool?> _showAgentApprovalDialog(
    ToolRequest request,
    AICharacter character,
  ) async {
    if (!_canTouchUi || !mounted) return null;
    final decision = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('${character.name} 请求使用工具'),
        content: SingleChildScrollView(
          child: Text(
            '工具：${request.tool.wireName}\n'
            '范围：${WorkModePolicy.approvalSummary(request)}\n\n'
            '原因：${request.reason}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('拒绝'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('批准'),
          ),
        ],
      ),
    );
    return decision;
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
    final skillIds = <String>{...character.skillIds, skill.id};
    character.skillIds = skillIds.toList();
    await _db.aiCharacterBox.put(character.id, character);
    return {
      'ok': true,
      'skillId': skill.id,
      'templateId': template.id,
      'name': skill.name,
      'permissions': template.requiredPermissions.map((p) => p.name).toList(),
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

  List<CharacterSkill> _agenticSkillsFor(
      AICharacter character, String userRequest,
      {CharacterSkillBundle? resolution}) {
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    return WorkModePolicy.resolveSkills(
      character: character,
      userRequest: userRequest,
      installedSkills: saved,
      resolvedSkills: resolution?.skills,
    );
  }

  bool _savedSkillMatchesRequest(
    AICharacter character,
    String userRequest,
  ) {
    final request = userRequest.toLowerCase().trim();
    final saved = _db.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    for (final skill in saved) {
      if (skill.description.toLowerCase().contains(request)) return true;
      final capability = '${skill.name} ${skill.domain}'.toLowerCase();
      final tokens = RegExp(r'[a-z0-9_+#.-]{2,}|[\u4e00-\u9fff]{2,8}')
          .allMatches(capability)
          .map((match) => match.group(0)!)
          .where((token) => token != 'general' && token != 'custom');
      if (tokens.any(request.contains)) return true;
    }
    return false;
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
    final announcement = _group?.announcement.trim() ?? '';
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
          '${announcement.isEmpty ? '' : '群公告：$announcement。'}'
          '回复要像真实聊天群：自然接话、简短、有个人观点，可以顺手回应上一位成员或点名邀请别人，但不要每次都长篇总结。'
          '${HumanizedPromptBuilder.ownerMentionInstruction(ownerName)}'
          '当前真实时间：${DateTime.now().toLocal().toIso8601String()}。'
          '如果用户询问时间、日期、今天/明天/昨天，必须以这个真实时间为准。'
          '如果用户问到你不知道或可能过期的信息，必须明确说不确定，并建议或请求联网搜索；不要编造事实、价格、新闻、人物职位或链接。'
          '如果用户要求你贴图、发图或发送附件，可以在文字中自然说明“我附上了”，应用会把本轮产物作为图片或文件附件显示。'
          '如果正在执行协作任务，开发完成后要明确 @ 测试/验收角色，测试发现问题要 @ 开发角色并列出 BUG。'
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

    final collaborationPrompt = _collaborationPromptFor(
      userMessage: userMessage,
      currentCharacter: character,
    );
    if (collaborationPrompt.isNotEmpty) {
      msgs.add({'role': 'system', 'content': collaborationPrompt});
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

  String _collaborationPromptFor({
    required String? userMessage,
    required AICharacter currentCharacter,
  }) {
    if (userMessage == null || userMessage.trim().isEmpty) return '';
    final mentioned = parseMentionedCharacterIds(userMessage, _characters);
    if (mentioned.length < 2) return '';
    final lower = userMessage.toLowerCase();
    final looksLikeProjectTask = lower.contains('开发') ||
        lower.contains('项目') ||
        lower.contains('测试') ||
        lower.contains('验收') ||
        lower.contains('bug') ||
        lower.contains('修复') ||
        lower.contains('代码') ||
        lower.contains('实现') ||
        lower.contains('build') ||
        lower.contains('test');
    if (!looksLikeProjectTask) return '';

    final mentionedCharacters = <AICharacter>[];
    for (final id in mentioned) {
      for (final character in _characters) {
        if (character.id == id) {
          mentionedCharacters.add(character);
          break;
        }
      }
    }
    if (mentionedCharacters.length < 2) return '';

    AICharacter? verifier;
    for (final character in mentionedCharacters) {
      final text = '${character.name} ${character.role} '
              '${character.personalityTags.join(' ')}'
          .toLowerCase();
      if (text.contains('测试') ||
          text.contains('qa') ||
          text.contains('验收') ||
          text.contains('质量')) {
        verifier = character;
        break;
      }
    }
    verifier ??= mentionedCharacters.last;
    final executor = mentionedCharacters
        .firstWhere((character) => character.id != verifier!.id);

    final currentRole = currentCharacter.id == executor.id
        ? '你是本次任务的开发/执行者。先给出实现计划或交付内容；完成后必须 @${verifier.name} 请他验收。'
        : currentCharacter.id == verifier.id
            ? '你是本次任务的测试/验收者。等待开发者交付后进行验收；发现问题要明确 @${executor.name} 并列出 BUG 和复现/修改建议。'
            : '你不是主责角色，只在被点名时补充，不要抢主责。';

    return '【AI 协作任务】用户一次 @ 了多位 AI 做一个项目/任务。'
        '分工：${executor.name}=开发/执行，${verifier.name}=测试/验收。'
        '$currentRole'
        '不要替对方完成职责；用 @ 推动下一棒。';
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
    msgs.add({
      'role': 'system',
      'content': '当前真实时间：${DateTime.now().toLocal().toIso8601String()}。'
          '涉及当前事实、新闻、价格、职位、规则或你不知道的内容时，不要编造；请说明不确定，并建议联网搜索或让用户授权搜索。'
          '如果用户要求你贴图、发图或发送附件，可以自然说明“我附上了”，应用会把本轮产物作为图片或文件附件显示。'
          '私聊主动找用户时最多连续三条，之后等待用户回复。',
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
    return ChatOrchestrator.extractRecentFocus(messages);
  }

  /// 移除 LLM 回复中可能附带的名字前缀（如「张三：」「【张三】：」）。
  /// UI 已独立显示角色名，内容中不应重复。
  String _stripNamePrefix(String content, String characterName) {
    return ChatOrchestrator.stripNamePrefix(content, characterName);
  }

  Future<void> _appendMessage(Message message) async {
    await _repository.persistNewMessage(message);
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
    if (!ChatOrchestrator.shouldEvolveCharacterMemory(
      messageCount: _messages.length,
      hasUserMessage: _messages.any((message) => message.senderType == 'user'),
    )) {
      return;
    }

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
    character.memorySummary = HumanizedMemoryService.mergeGlobalSummary(
      existing: character.memorySummary,
      update: parsed,
    );
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

  bool _isEligibleToReply(AICharacter character) {
    return _replyEligibility.isEligible(character);
  }

  ReplyBlockReason? _blockReasonFor(AICharacter character) {
    return _replyEligibility.blockReasonFor(character);
  }

  List<AICharacter> get _eligibleCharacters =>
      _characters.where(_isEligibleToReply).toList();

  ReplyBlockReason? _firstBlockReason(List<AICharacter> characters) {
    return _replyEligibility.firstBlockReason(characters);
  }

  void _recordReplyUsage(AICharacter character) {
    _replyEligibility.recordReplyUsage(character);
    _repository.persistReplyUsage(character);
  }

  Future<void> _recordTokenUsageFromResult(
      AICharacter character, Map<String, dynamic> result) async {
    final promptTokens = result['promptTokens'];
    final completionTokens = result['completionTokens'];
    if (promptTokens is! int || completionTokens is! int) return;
    await _repository.recordTokenUsage(
      characterId: character.id,
      inputTokens: promptTokens,
      outputTokens: completionTokens,
      cachedTokens: result['cachedTokens'] is int ? result['cachedTokens'] : 0,
    );
  }

  Future<void> _delay(String content, {bool fast = false}) async {
    if (fast) {
      await Future.delayed(const Duration(milliseconds: 180));
      return;
    }
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
    int cursorPos = _textController.selection.baseOffset;
    if (cursorPos < 0) cursorPos = text.length;

    final searchEnd = cursorPos > 0 ? cursorPos - 1 : 0;
    int atPos = text.lastIndexOf('@', searchEnd);
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
    if (cursorPos <= 0) return false;
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
    if (cursorPos <= 0) {
      _hideMentionOverlay();
      return;
    }
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
    var replyIntents = HumanizedChatOrchestrator.selectReplyIntents(
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
    final lastAiSenderId = _lastAiSenderId;
    if (lastAiSenderId != null &&
        (mentionedIds == null || mentionedIds.isEmpty)) {
      final filtered = replyIntents
          .where((intent) => intent.speakerId != lastAiSenderId)
          .toList();
      if (filtered.isNotEmpty) replyIntents = filtered;
    }
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

  Future<List<Message>> _compactContextIfNeeded({
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required List<Message> fallbackContext,
  }) async {
    final checkpointKey =
        'context_compressed_through:${widget.groupId}:${character.id}';
    final checkpoint = _db.appSettingsBox.get(checkpointKey) as String?;
    final pending = _messagesAfterCheckpoint(checkpoint);
    final apiHistory = pending
        .map((message) => <String, dynamic>{
              'role': message.senderType == 'user' ? 'user' : 'assistant',
              'content': message.content,
            })
        .toList();
    final manager = ContextWindowManager(
      maxRetries: 0,
      complete: (messages) => _chatApi.sendChatMessage(
        apiKey: config.apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: messages,
        temperature: 0.3,
        maxTokens: 2048,
      ),
    );
    if (!manager.shouldSummarize(apiHistory)) return fallbackContext;

    try {
      final summary = await manager.summarize(
        apiHistory,
        isDirectChat: _isDirectChat,
      );
      final memory = HumanizedMemoryService.memoryForCharacter(
        groupId: widget.groupId,
        character: character,
        existing: _characterMemories,
      );
      await manager.persistToCharacterMemory(
        character: character,
        memory: memory,
        summary: summary,
        saveCharacter: (value) => _db.aiCharacterBox.put(value.id, value),
        saveMemory: _saveCompactedCharacterMemory,
      );
      if (pending.isNotEmpty) {
        await _db.appSettingsBox.put(checkpointKey, pending.last.id);
      }
      return _lastUserOnly(fallbackContext);
    } catch (error) {
      debugPrint('[Context] 上下文压缩失败，保留原上下文：$error');
      return fallbackContext;
    }
  }

  List<Message> _messagesAfterCheckpoint(String? checkpoint) {
    if (checkpoint == null || checkpoint.isEmpty) return _messages.toList();
    final index = _messages.indexWhere((message) => message.id == checkpoint);
    if (index < 0 || index + 1 >= _messages.length) return const [];
    return _messages.sublist(index + 1);
  }

  Future<void> _saveCompactedCharacterMemory(CharacterMemory memory) async {
    await _db.characterMemoryBox.put(memory.id, memory);
    final index = _characterMemories.indexWhere((item) => item.id == memory.id);
    if (index < 0) {
      _characterMemories = [..._characterMemories, memory];
    } else {
      _characterMemories = [..._characterMemories]..[index] = memory;
    }
  }

  List<Message> _lastUserOnly(List<Message> messages) {
    for (final message in messages.reversed) {
      if (message.senderType == 'user') return [message];
    }
    return const [];
  }

  /// 把最近的对话记录转换成 LLM 消息格式，供 AgentRuntime 调用时携带上下文，
  /// 修复“追问时 AI 失忆”的问题。
  ///
  /// - 取最近 12 条，排除当前请求对应的用户消息（已在 userRequest 中，避免重复）。
  /// - user 消息 → role 'user'，ai 消息 → role 'assistant'。
  /// - 附件会保留文件名、跨平台本地路径；安全的小型文本文件还会内联内容。
  Future<List<Map<String, dynamic>>> _agenticHistory(
    String userMessage, {
    List<Message>? messages,
  }) {
    return AgentAttachmentContext.buildHistory(
      messages: messages ?? _recentMessagesForContext(),
      currentUserRequest: userMessage,
    );
  }

  String? get _lastAiSenderId {
    for (final message in _messages.reversed) {
      if (message.senderType == 'ai') return message.senderId;
      if (message.senderType == 'user') return null;
    }
    return null;
  }

  int _directAiMessagesSinceLastUser() {
    var count = 0;
    for (final message in _messages.reversed) {
      if (message.senderType == 'user') break;
      if (message.senderType == 'ai') count++;
    }
    return count;
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
    const palette = [
      Color(0xFF576B95),
      Color(0xFF2F7D65),
      Color(0xFF9A5B31),
      Color(0xFF7A5C99),
      Color(0xFF3F6F8F),
      Color(0xFF8B5D6B),
      Color(0xFF5F7548),
    ];
    final hash = sender.id.codeUnits.fold<int>(0, (sum, unit) => sum + unit);
    return palette[hash % palette.length];
  }

  String get _autoChatStatusText {
    if (_workModeEnabled) return '工作模式中，自动发言已暂停';
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

  void _toggleAutoChat(bool enabled) {
    if (!_canTouchUi) return;
    setState(() {
      _isAutoChatEnabled = enabled;
      _autoChatStatus =
          enabled ? AutoChatStatus.waiting : AutoChatStatus.paused;
    });
    if (enabled && !_workModeEnabled) {
      _startAutoChat();
    } else {
      _autoChatTimer?.cancel();
      _autoChatTimer = null;
    }
  }

  Future<void> _toggleWorkMode(bool enabled) async {
    await WorkModeConfigService(db: _db).setWorkMode(widget.groupId, enabled);
    _workModeSession.setEnabled(enabled);
    if (enabled) {
      if (_isAutoChatRoundRunning) {
        _discardCurrentStream = true;
        _stopStreaming();
      }
      _stopAutoChat();
    } else {
      final pending = _workModeSession.takePendingApproval();
      if (pending != null) {
        await _cancelAgentTask(
          pending.task,
          reason: '工作模式已关闭，待审批任务已取消。',
        );
      }
    }
    if (_canTouchUi) {
      setState(() {});
    }
    if (enabled) {
      _scheduleAgentTaskRecovery();
    } else if (_isAutoChatEnabled) {
      _startAutoChat();
    }
  }

  Widget _buildConversationControls(ColorScheme cs) {
    return CompactConversationControls(
      showAutoChat: !_isDirectChat,
      autoChatEnabled: _isAutoChatEnabled && _hasAnyApiConfig,
      workModeEnabled: _workModeEnabled,
      autoChatAvailable: _hasAnyApiConfig,
      autoChatTooltip: _autoChatStatusText,
      workModeTooltip: _workModeEnabled ? '工作模式已开启 · 敏感操作需确认' : '工作模式已关闭',
      onAutoChatChanged: _toggleAutoChat,
      onWorkModeChanged: _toggleWorkMode,
    );
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
    final keyContext = _messageListController.contextFor(_messages[index].id);
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
      final ctx = _messageListController.contextFor(_messages[index].id);
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

  void _handleSpeechState(SpeechPlaybackState state) {
    if (!_canTouchUi) return;
    setState(() {
      _isSpeaking = state.isSpeaking;
      _speakingMessageId = state.messageId;
    });
    final error = state.error;
    if (error != null && error.isNotEmpty) {
      AppToast.show(
        context,
        error,
        icon: Icons.volume_off_rounded,
      );
    }
  }

  Future<void> _ttsSpeak(Message message) async {
    if (_isSpeaking) {
      await _speech.stop();
    }
    final text = message.content;
    if (text.trim().isEmpty) return;
    await _speech.speak(messageId: message.id, text: text);
  }

  Future<void> _ttsStop() => _speech.stop();

  void _showMessageActionSheet(Message message, AICharacter? sender) {
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
            Text(
              sender != null ? '${sender.name} 的消息' : '消息',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            if (sender != null) ...[
              SheetButton(ctx, cs, Icons.refresh_rounded, '重新生成', () {
                Navigator.pop(ctx);
                _regenerateAiReply(message, sender);
              }),
              const SizedBox(height: 8),
              SheetButton(ctx, cs, Icons.format_quote_rounded, '引用回复', () {
                Navigator.pop(ctx);
                _quoteMessage(message);
              }),
              const SizedBox(height: 8),
              SheetButton(
                  ctx, cs, Icons.alternate_email_rounded, '@${sender.name}',
                  () {
                Navigator.pop(ctx);
                _insertMention(sender);
              }),
              const SizedBox(height: 8),
            ],
            if (_isTtsEnabled) ...[
              SheetButton(
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
              const SizedBox(height: 8),
            ],
            SheetButton(ctx, cs, Icons.send_to_mobile_rounded, '推送到企业微信', () {
              Navigator.pop(ctx);
              _showWeComPushDialog(message.content);
            }),
          ],
        ),
      ),
    );
  }

  void _showWeComPushDialog(String defaultContent) {
    final service = WeComPushService();
    var targetType = 'user';
    final userIdCtl = TextEditingController();
    final webhookCtl = TextEditingController();
    final contentCtl = TextEditingController(text: defaultContent);
    var sending = false;
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('推送到企业微信'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'user', label: Text('同事')),
                    ButtonSegment(value: 'group', label: Text('群')),
                  ],
                  selected: {targetType},
                  onSelectionChanged: (sel) =>
                      setSt(() => targetType = sel.first),
                ),
                const SizedBox(height: 12),
                if (targetType == 'user')
                  TextField(
                    controller: userIdCtl,
                    decoration: const InputDecoration(
                      labelText: '同事 UserID',
                      hintText: '如 zhangsan',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  )
                else
                  TextField(
                    controller: webhookCtl,
                    decoration: const InputDecoration(
                      labelText: '群机器人 Webhook Key',
                      hintText: '粘贴群机器人的 key',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentCtl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '内容',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: sending
                  ? null
                  : () async {
                      setSt(() => sending = true);
                      final content = contentCtl.text.trim();
                      final WeComPushResult res;
                      if (targetType == 'user') {
                        final uid = userIdCtl.text.trim();
                        if (uid.isEmpty) {
                          AppToast.show(context, '请填写同事 UserID');
                          setSt(() => sending = false);
                          return;
                        }
                        res = await service.sendToUser(uid, content);
                      } else {
                        final key = webhookCtl.text.trim();
                        if (key.isEmpty) {
                          AppToast.show(context, '请填写群 Webhook Key');
                          setSt(() => sending = false);
                          return;
                        }
                        res = await service.sendToGroup(key, content);
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                      if (mounted) {
                        AppToast.show(
                          context,
                          res.ok ? '已推送到企业微信' : res.detail,
                          icon: res.ok ? Icons.check : Icons.error_outline,
                        );
                      }
                    },
              child: sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('发送'),
            ),
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
      if (!mounted) return;
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
    if (_disposed) return;
    _streamSub = null;
    _streamDone = null;
    if (mounted) setState(() => _isStreaming = false);

    if (failed) {
      final retryContent = await _retryFailedReply(
        character: character,
        config: config,
        provider: provider,
        apiMessages: apiMessages,
      );
      if (retryContent != null && retryContent.trim().isNotEmpty) {
        failed = false;
        fullContent = retryContent.trim();
        temp.content = fullContent;
        if (_canTouchUi) _flushStreamingUi();
      }
    }

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
    await _repository.persistNewMessage(temp);
    _recordReplyUsage(character);
    _registerUserMentionIfNeeded(temp);
    if (promptTokens != null && completionTokens != null) {
      _repository.recordTokenUsage(
        characterId: character.id,
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        backgroundColor: WeComChatTokens.chatBackground(context),
        appBar: AppBar(
          backgroundColor: WeComChatTokens.chatBackground(context),
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

    final readUserMessageIds =
        _isDirectChat ? directReadUserMessageIds(_messages) : const <String>{};
    // #5 性能：消息/角色索引 Map 在父页预计算一次，避免在子组件每次 build 重建。
    final messageIndex = {for (final message in _messages) message.id: message};
    final characterIndex = {
      for (final character in _allGroupCharacters) character.id: character,
    };
    return Scaffold(
      backgroundColor: WeComChatTokens.chatBackground(context),
      appBar: ChatRoomAppBar(
        title: _group?.name ?? '群聊',
        subtitle:
            !_isDirectChat && (_groupMemory?.topicSummary.isNotEmpty ?? false)
                ? _groupMemory!.topicSummary
                : null,
        isSearching: _isSearching,
        searchController: _searchController,
        hasSearchResults: _searchResults.isNotEmpty,
        searchResultLabel: _searchResultLabel,
        showGroupActions: !_isDirectChat,
        memberChip: GestureDetector(
          onTap: _showMembersSheet,
          child: MemberStackChip(
            characters: _characters,
            senderColor: _senderColor,
          ),
        ),
        onSearchChanged: _performSearch,
        onEnterSearch: _enterSearch,
        onPreviousResult: _searchPrev,
        onNextResult: _searchNext,
        onExitSearch: _exitSearch,
        onExport: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ExportPage(initialGroupId: widget.groupId),
        )),
      ),
      body: Column(
        children: [
          // 未配置 API Key 时给出醒目提示，避免「发了消息 AI 不回复」的困惑
          if (!_hasAnyApiConfig)
            ApiWarningBanner(
              message: _isDirectChat
                  ? _replyBlockText(_lastReplyBlockReason)
                  : '尚未配置 API Key，AI 不会回复或自动聊天',
              onConfigure: () => Navigator.pushNamed(context, '/settings'),
            ),
          if (!_isDirectChat &&
              (_group?.announcement.trim().isNotEmpty ?? false))
            AnnouncementBanner(
              announcement: _group!.announcement.trim(),
              onEdit: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => ChatGroupFormPage(group: _group),
              )),
            ),
          _buildConversationControls(cs),
          if (_pendingUserMentionMessageIds.isNotEmpty &&
              !ConversationPresenceService.instance.isActive(widget.groupId))
            UserMentionBanner(
              count: _pendingUserMentionMessageIds.length,
              onTap: _jumpToNextUserMention,
              onClear: _clearUserMentions,
            ),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState(cs)
                : ChatMessageList(
                    messages: _messages,
                    characters: _allGroupCharacters,
                    progressStartTimes: _progressStartTimes,
                    messageIndex: messageIndex,
                    characterIndex: characterIndex,
                    scrollController: _scrollController,
                    controller: _messageListController,
                    streamingMessageId: _streamingMessage?.id,
                    regeneratingMessageId:
                        _isRegenerating ? _regenerateMessageId : null,
                    highlightedMentionMessageId: _highlightedMentionMessageId,
                    isDirectChat: _isDirectChat,
                    readUserMessageIds: readUserMessageIds,
                    ownerName: _ownerMentionName,
                    unknownCharacter: _unknownCharacter(),
                    senderColor: _senderColor,
                    senderNameById: _senderNameById,
                    onLongPress: _showMessageActionSheet,
                    onSenderTap: _openCharacterSettings,
                    onMentionSender: _insertMention,
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
          _buildInputArea(),
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
                HintChip(text: '说句「你好」试试', cs: cs),
                if (!_isDirectChat) HintChip(text: '@角色名 提到谁', cs: cs),
                if (!_isDirectChat && _characters.isNotEmpty)
                  HintChip(text: '${_characters.length} 位 AI 在线', cs: cs),
                if (_isDirectChat && _allGroupCharacters.isNotEmpty)
                  HintChip(text: _allGroupCharacters.first.role, cs: cs),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showMembersSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => MemberSheet(
        characters: _characters,
        ownerName: _group?.ownerName ?? '我',
        senderColor: _senderColor,
        statusText: _memberStatusText,
        onOpenSettings: _openCharacterSettings,
        onDirectChat: (character) {
          if (mounted) Navigator.of(context).pushNamed('/dm/${character.id}');
        },
      ),
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

  void _openCharacterSettings(AICharacter character) {
    Navigator.of(context).push(
      MaterialPageRoute(
          builder: (_) => AICharacterFormPage(character: character)),
    );
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
    if (key == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      unawaited(_pasteClipboardAttachments(showEmptyHint: false));
      // 阻止 Flutter 默认粘贴行为，避免手动插入与 TextField 原生粘贴重复。
      return KeyEventResult.handled;
    }
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

  Widget _buildInputArea() {
    return ChatRoomComposer(
      textController: _textController,
      focusNode: _inputFocusNode,
      inputFieldKey: _inputFieldKey,
      quotedMessage: _quotedMessage,
      quotedSenderName: _quotedMessage == null
          ? ''
          : _senderNameById(_quotedMessage!.senderId),
      attachments: _pendingAttachments,
      isDraggingFiles: _isDraggingFiles,
      isStreaming: _isStreaming,
      canSend: _canSend,
      isDirectChat: _isDirectChat,
      isDesktop: _isDesktop,
      onKeyEvent: _handleKeyEvent,
      onTextChanged: _handleTextChanged,
      onDragStateChanged: (dragging) {
        if (_canTouchUi) setState(() => _isDraggingFiles = dragging);
      },
      onDroppedPaths: (paths) => unawaited(_handleDroppedFiles(paths)),
      onShowAttachmentMenu: _showAttachmentMenu,
      onPasteAttachments: () => _pasteClipboardAttachments(showEmptyHint: true),
      onShowEmojiPanel: _showEmojiPanel,
      onCancelQuote: _cancelQuote,
      onRemoveAttachment: _removeAttachment,
      onStopStreaming: _stopStreaming,
      onSend: _sendMessage,
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
            SheetButton(ctx, cs, Icons.image_rounded, '图片（可多选）', () {
              Navigator.pop(ctx);
              _pickImages();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.videocam_rounded, '视频（单选）', () {
              Navigator.pop(ctx);
              _pickVideo();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.insert_drive_file_rounded, '文件（可多选）',
                () {
              Navigator.pop(ctx);
              _pickFiles();
            }),
            const SizedBox(height: 8),
            SheetButton(ctx, cs, Icons.content_paste_rounded, '粘贴截图或文件', () {
              Navigator.pop(ctx);
              _pasteClipboardAttachments(showEmptyHint: true);
            }),
          ],
        ),
      ),
    );
  }

  void _showEmojiPanel() {
    const emojis = [
      '😀',
      '😂',
      '🥹',
      '😍',
      '😎',
      '🤔',
      '👍',
      '👏',
      '🙏',
      '🔥',
      '✨',
      '🎉',
      '💡',
      '✅',
      '🧪',
      '🚀',
    ];
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: emojis.map((emoji) {
            return InkWell(
              onTap: () {
                Navigator.pop(ctx);
                _insertTextAtCursor(emoji, inline: true);
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outlineVariant.withOpacity(0.5)),
                ),
                child: Text(emoji, style: const TextStyle(fontSize: 24)),
              ),
            );
          }).toList(),
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
          AppToast.show(context, '一次最多发送 4 张图片',
              icon: Icons.info_outline_rounded);
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
        AppToast.show(context, '已限制为一次最多 4 张图片',
            icon: Icons.info_outline_rounded);
      }
      for (final file in selectedFiles) {
        late final MediaAttachment att;
        if (kIsWeb) {
          final bytes = await file.readAsBytes();
          if (!_canAddWebAttachment(bytes.lengthInBytes)) {
            if (mounted) {
              AppToast.show(context, '${file.name} 加入后超过 Web 端单条消息 10 MB 限制',
                  icon: Icons.info_outline_rounded);
            }
            continue;
          }
          att = await _db.copyBytesToMedia(
            bytes,
            'image',
            fileName: file.name,
            mimeType: file.mimeType,
          );
        } else {
          att = await _db.copyToMedia(
            File(file.path),
            'image',
            fileName: file.name,
          );
        }
        if (mounted) setState(() => _pendingAttachments.add(att));
      }
    } catch (e) {
      debugPrint('[附件] 选择图片失败：$e');
      if (mounted) {
        AppToast.show(context, '选择图片失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  /// 从相册选择单个视频，复制到媒体目录并加入待发送列表。
  Future<void> _pickVideo() async {
    try {
      final file = await _imagePicker.pickVideo(source: ImageSource.gallery);
      if (file == null) return;
      late final MediaAttachment att;
      if (kIsWeb) {
        final bytes = await file.readAsBytes();
        if (!_canAddWebAttachment(bytes.lengthInBytes)) {
          if (mounted) {
            AppToast.show(context, '${file.name} 加入后超过 Web 端单条消息 10 MB 限制',
                icon: Icons.info_outline_rounded);
          }
          return;
        }
        att = await _db.copyBytesToMedia(
          bytes,
          'video',
          fileName: file.name,
          mimeType: file.mimeType,
        );
      } else {
        att = await _db.copyToMedia(
          File(file.path),
          'video',
          fileName: file.name,
        );
      }
      if (mounted) setState(() => _pendingAttachments.add(att));
    } catch (e) {
      debugPrint('[附件] 选择视频失败：$e');
      if (mounted) {
        AppToast.show(context, '选择视频失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _pickFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.any,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;
      var added = 0;
      for (final picked in result.files) {
        final payload = resolvePickedAttachmentPayload(picked, isWeb: kIsWeb);
        if (payload == null) continue;
        late final MediaAttachment att;
        if (payload is PickedAttachmentBytes) {
          if (!_canAddWebAttachment(payload.bytes.lengthInBytes)) {
            if (mounted) {
              AppToast.show(
                  context, '${payload.fileName} 加入后超过 Web 端单条消息 10 MB 限制',
                  icon: Icons.info_outline_rounded);
            }
            continue;
          }
          att = await _db.copyBytesToMedia(
            payload.bytes,
            _attachmentTypeForPath(payload.fileName),
            fileName: payload.fileName,
          );
        } else if (payload is PickedAttachmentPath) {
          final source = File(payload.path);
          if (!await source.exists()) continue;
          att = await _db.copyToMedia(
            source,
            _attachmentTypeForPath(payload.path),
            fileName: payload.fileName,
          );
        } else {
          continue;
        }
        if (mounted) setState(() => _pendingAttachments.add(att));
        added++;
      }
      if (mounted && added == 0) {
        AppToast.show(context, '没有可读取的文件', icon: Icons.info_outline_rounded);
      }
    } catch (e) {
      debugPrint('[附件] 选择文件失败：$e');
      if (mounted) {
        AppToast.show(context, '选择文件失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _handleDroppedFiles(Iterable<String> paths) async {
    if (paths.isEmpty) return;
    var addedFiles = 0;
    final droppedDirectories = <String>[];
    try {
      for (final droppedPath in paths) {
        final path = droppedPath.trim();
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
          fileName: fileNameFromPath(path),
        );
        addedFiles++;
        if (_canTouchUi) {
          setState(() => _pendingAttachments.add(att));
        }
      }

      if (droppedDirectories.isNotEmpty) {
        _insertTextAtCursor(droppedDirectories.join('\n'));
      }
      if (!mounted) return;
      if (!_canTouchUi) return;
      final parts = <String>[
        if (addedFiles > 0) '$addedFiles 个文件',
        if (droppedDirectories.isNotEmpty)
          '${droppedDirectories.length} 个文件夹路径',
      ];
      if (parts.isNotEmpty) {
        AppToast.show(context, '已添加 ${parts.join('、')}',
            icon: Icons.attach_file_rounded);
      }
    } catch (e) {
      debugPrint('[附件] 拖放失败：$e');
      if (_canTouchUi && mounted) {
        AppToast.show(context, '拖放失败：$e', icon: Icons.error_outline_rounded);
      }
    }
  }

  void _insertTextAtCursor(String text, {bool inline = false}) {
    if (text.trim().isEmpty) return;
    final current = _textController.text;
    final selection = _textController.selection;
    final insertion = inline || current.trim().isEmpty ? text : '\n$text';
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
            if (!_canAddWebAttachment(image.length)) {
              if (mounted) {
                AppToast.show(context, '剪贴板图片加入后超过 Web 端单条消息 10 MB 限制',
                    icon: Icons.info_outline_rounded);
              }
              return;
            }
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

      if (attachments.isEmpty) {
        String? clipboardText;
        try {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          clipboardText = clipboardTextFallback(data?.text);
        } catch (e) {
          debugPrint('[附件] 剪贴板文本读取失败：$e');
        }

        if (clipboardText != null) {
          if (!mounted || !_canTouchUi) return;
          setState(() {
            _insertTextAtCursor(clipboardText!, inline: true);
          });
          _handleTextChanged(_textController.text);
          _inputFocusNode.requestFocus();
          if (showEmptyHint) {
            AppToast.show(context, '已粘贴剪贴板文本',
                icon: Icons.content_paste_rounded);
          }
          return;
        }
      }

      if (!mounted) return;
      if (attachments.isEmpty) {
        if (showEmptyHint) {
          AppToast.show(context, '剪贴板里没有可粘贴的文本、文件或截图',
              icon: Icons.info_outline_rounded);
        }
        return;
      }
      setState(() => _pendingAttachments.addAll(attachments));
      AppToast.show(context, '已粘贴 ${attachments.length} 个附件',
          icon: Icons.content_paste_rounded);
    } catch (e) {
      debugPrint('[附件] 粘贴失败：$e');
      if (mounted && showEmptyHint) {
        AppToast.show(context, '粘贴失败：$e', icon: Icons.error_outline_rounded);
      }
    } finally {
      _isPastingAttachments = false;
    }
  }

  String _attachmentTypeForPath(String path) {
    final ext = extensionOfPath(path);
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

  bool _canAddWebAttachment(int newBytes) {
    if (!kIsWeb) return true;
    final existingBytes = _pendingAttachments.fold<int>(
      0,
      (sum, attachment) => sum + (attachment.fileSize ?? 0),
    );
    return canAddWebAttachment(
      existingBytes: existingBytes,
      newBytes: newBytes,
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
}
